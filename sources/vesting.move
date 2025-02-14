module blockchain::vesting {
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use std::simple_map::{Self, SimpleMap};
    use aptos_framework::event;
    use std::debug;
    #[test_only]
    use aptos_std::math_fixed64::exp;

    /// Error codes
    const SEED: vector<u8> = b"vesting";
    const ERROR_NOT_OWNER: u64 = 1;
    const ERROR_STREAM_EXISTS: u64 = 2;
    const ERROR_STREAM_NOT_FOUND: u64 = 3;
    const ERROR_INVALID_DURATION: u64 = 4;
    const ERROR_NO_VESTED_TOKENS: u64 = 5;
    const ERROR_CLIFF_EXCEEDS_DURATION: u64 = 6;
    const ERROR_NOTHING_TO_CLAIM: u64 = 7;
    const ERROR_INVALID_AMOUNT: u64 = 8;
    const ERROR_CLIFF_HAS_NOT_PASSED: u64 = 9;

    /// Event emitted when a new stream is created
    struct StreamCreatedEvent has drop, store {
        beneficiary: address,
        total_amount: u64,
        start_time: u64,
        cliff: u64,
        duration: u64
    }

    /// Event emitted when tokens are claimed
    struct ClaimCreatedEvent has drop, store {
        beneficiary: address,
        amount: u64,
        timestamp: u64
    }

    /// Represents a single vesting stream
    struct VestingStream has store, copy, drop {
        beneficiary: address,
        total_amount: u64,
        start_time: u64,
        cliff: u64,
        duration: u64,
        claimed_amount: u64,
    }

    /// Main vesting contract resource
    struct VestingContract has key {
        owner: address,
        streams: SimpleMap<address, VestingStream>,
    }

    struct State has key {
        signer_cap: account::SignerCapability,
        stream_created: event::EventHandle<StreamCreatedEvent>,
        claimed: event::EventHandle<ClaimCreatedEvent>
    }

    fun init_module(admin: &signer) {
        let (resource_signer, signer_cap) = account::create_resource_account(admin, SEED);

        // Initialize the vesting contract with resource account as owner
        let streams = simple_map::create();
        let vesting_contract = VestingContract {
            owner: signer::address_of(&resource_signer),
            streams,
        };

        move_to(&resource_signer, vesting_contract);
        move_to(&resource_signer, State {
            signer_cap,
            stream_created: account::new_event_handle<StreamCreatedEvent>(&resource_signer),
            claimed: account::new_event_handle<ClaimCreatedEvent>(&resource_signer)
        })
    }

    /// Create a new vesting stream
    public entry fun create_stream(
        owner: &signer,
        user: address,
        total_amount: u64,
        duration: u64,
        cliff: u64
    ) acquires VestingContract, State {
        let resources_address = account::create_resource_address(&@blockchain, SEED);
        assert!(signer::address_of(owner) == @blockchain, ERROR_NOT_OWNER);
        assert!(!has_stream(user), ERROR_STREAM_EXISTS);
        assert!(duration > 0, ERROR_INVALID_DURATION);
        assert!(total_amount > 0, ERROR_INVALID_AMOUNT);
        assert!(cliff <= duration, ERROR_CLIFF_EXCEEDS_DURATION);

        let vesting_stream = VestingStream {
            beneficiary: user,
            total_amount,
            start_time: timestamp::now_seconds(),
            duration,
            cliff,
            claimed_amount: 0
        };

        let contract = borrow_global_mut<VestingContract>(resources_address);
        let state = borrow_global_mut<State>(resources_address);
        simple_map::add(&mut contract.streams, user, vesting_stream);

        event::emit_event(&mut state.stream_created, StreamCreatedEvent{
            beneficiary: vesting_stream.beneficiary,
            total_amount: vesting_stream.total_amount,
            start_time: vesting_stream.start_time,
            duration: vesting_stream.duration,
            cliff: vesting_stream.cliff
        })
    }

    // get the vested amount
    public fun get_vested_amount(
        beneficiary: address,
        current_time: u64
    ): u64 acquires VestingContract {
        let resources_address = account::create_resource_address(&@blockchain, SEED);
        assert!(has_stream(beneficiary), ERROR_STREAM_NOT_FOUND);
        let contract = borrow_global<VestingContract>(resources_address);

        let stream = simple_map::borrow(&contract.streams, &beneficiary);

        // If we're still in cliff period, return 0
        if (current_time < (stream.start_time + stream.cliff)) {
            0
        } else {
            // After cliff period, if no tokens claimed, return total amount
            if (stream.claimed_amount == 0 && current_time >=  (stream.start_time + stream.duration)) {
                stream.total_amount
            } else {
                // Otherwise calculate the normal vesting schedule
                calculate_current_vested_without_cliff_amount(
                    stream.total_amount,
                    stream.start_time,
                    stream.duration,
                    current_time
                )
            }
        }
    }

    /// Claim vested tokens
    public entry fun claim(
        beneficiary: &signer,
        amount_to_claim: u64
    ) acquires VestingContract, State {
        let resources_address = account::create_resource_address(&@blockchain, SEED);

        let beneficiary_addr = signer::address_of(beneficiary);

        assert!(has_stream(beneficiary_addr), ERROR_STREAM_NOT_FOUND);

        let contract = borrow_global_mut<VestingContract>(resources_address);

        let state = borrow_global_mut<State>(resources_address);

        let stream = simple_map::borrow_mut(&mut contract.streams, &beneficiary_addr);
        let now_seconds = timestamp::now_seconds();

        // Check if cliff period has passed
        assert!(now_seconds >= (stream.cliff + stream.start_time), ERROR_CLIFF_HAS_NOT_PASSED);
        assert!(now_seconds <= (stream.duration + stream.start_time), ERROR_INVALID_DURATION);
        assert!(amount_to_claim > 0, ERROR_INVALID_AMOUNT);

        let current_vested = calculate_current_vested_without_cliff_amount(
            stream.total_amount,
            stream.start_time,
            stream.duration,
            now_seconds
        );

        // Check if we've already claimed all currently vested tokens
        assert!(stream.claimed_amount < current_vested, ERROR_NOTHING_TO_CLAIM);

        // Calculate actual claimable amount (minus what's already been claimed)
        let actual_claimable = current_vested - stream.claimed_amount;
        assert!(actual_claimable > 0, ERROR_NOTHING_TO_CLAIM);

        // Update claimed amount
        stream.claimed_amount = stream.claimed_amount + amount_to_claim;
        event::emit_event(&mut state.claimed, ClaimCreatedEvent{
            beneficiary: beneficiary_addr,
            amount: amount_to_claim,
            timestamp: now_seconds
        })
    }

    /// View function to get stream details
    public fun get_stream(
        beneficiary: address
    ): (u64, u64, u64, u64, u64) acquires VestingContract {
        let resources_address = account::create_resource_address(&@blockchain, SEED);

        assert!(has_stream(beneficiary), ERROR_STREAM_NOT_FOUND);
        let contract = borrow_global<VestingContract>(resources_address);

        let stream = simple_map::borrow(&contract.streams, &beneficiary);
        (
            stream.total_amount,
            stream.start_time,
            stream.cliff,
            stream.duration,
            stream.claimed_amount
        )
    }

    /// Check if an address has a vesting stream
    public fun has_stream(
        beneficiary: address
    ): bool acquires VestingContract {
        let resources_address = account::create_resource_address(&@blockchain, SEED);
        let contract = borrow_global<VestingContract>(resources_address);
        simple_map::contains_key(&contract.streams, &beneficiary)
    }

    /// Helper function to calculate claimable amount
    inline fun calculate_current_vested_without_cliff_amount(
        total: u64,
        start: u64,
        duration: u64,
        current_time: u64,
    ): u64 {
        let end_date = start + duration;
        if (current_time > end_date) {
            total
        } else {
            let current_duration = current_time - start;
            let total = (current_duration * total) / duration;
            total
        }
    }


    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test(admin = @blockchain)]
    fun test_init_module_success(
        admin: &signer,
    ) acquires State {
        let admin_address = signer::address_of(admin);
        account::create_account_for_test(admin_address);

        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        assert!(exists<VestingContract>(expected_resource_account_address), 0);
        assert!(exists<State>(expected_resource_account_address), 0);

        let state = borrow_global<State>(expected_resource_account_address);
        assert!(
            account::get_signer_capability_address(&state.signer_cap) == expected_resource_account_address,
            0
        );

        assert!(event::counter(&state.stream_created) == 0, 0);
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_INVALID_AMOUNT)]
    public fun test_create_stream_failed_invalid_amount(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 0; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_INVALID_DURATION)]
    public fun test_create_stream_failed_invalid_duration(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 0;
        let cliff = 31104000;

        // This should fail because duration is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);
        assert!(event::counter(&state.stream_created) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_NOT_OWNER)]
    public fun test_create_stream_failed_not_owner(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(user, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_STREAM_EXISTS)]
    public fun test_create_stream_failed_existing_beneficiary(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_CLIFF_EXCEEDS_DURATION)]
    public fun test_create_stream_failed_cliff_greater_than_duration(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 31104000;
        let cliff = 124416000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_create_stream_success_one_beneficiary(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 1, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_create_stream_success_multiple_beneficiary(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amountA = 1000; // Invalid amount to trigger failure
        let durationA = 124416000;
        let cliffA = 31104000;

        let amountB = 1000; // Invalid amount to trigger failure
        let durationB = 93312000;
        let cliffB = 15552000;


        // This should fail because amount is 0
        create_stream(admin, user_address, amountA, durationA, cliffA);
        create_stream(admin, @0xB, amountB, durationB, cliffB);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 2, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_create_stream_success_zero_cliff(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 0;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 1, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_create_stream_success_cliff_equal_duration(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 124416000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 1, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_CLIFF_HAS_NOT_PASSED)]
    public fun test_claimed_stream_failed_claim_before_cliff_end(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the current state to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that one stream was created
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Fast forward time by ~23 days (2000000 seconds), which is before cliff period ends
        timestamp::fast_forward_seconds(stream.start_time + 2000000);

        // Attempt to claim tokens before cliff period ends
        claim(user, amount_to_claim);

        // Get updated state
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that no tokens were claimed (event counter is still 0)
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_INVALID_AMOUNT)]
    public fun test_claimed_stream_failed_inavalid_claim_amount(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 0;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the current state to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that one stream was created
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Fast forward time past cliff period (36104000 seconds)
        timestamp::fast_forward_seconds(stream.start_time + 36104000);

        // Attempt to claim with invalid amount (0)
        claim(user, amount_to_claim);

        // Get updated state
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify no tokens were claimed
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_INVALID_DURATION)]
    public fun test_claimed_stream_failed_claim_after_vesting_duration(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.stream_created) == 1, 0);
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        timestamp::fast_forward_seconds(stream.start_time+ 144416000);

        claim(user, amount_to_claim);

        let state = borrow_global<State>(expected_resource_account_address);

        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    #[expected_failure(abort_code = ERROR_NOTHING_TO_CLAIM)]
    public fun test_claimed_stream_failed_claim_when_no_vested_token(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Borrow mutable reference to the vesting contract to modify stream data
        let contract = borrow_global_mut<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow_mut(&mut contract.streams, &user_address);
        // Set claimed amount higher than total amount to test claiming more than available
        stream.claimed_amount = amount + 100;

        // Borrow immutable reference to get stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);
        // Fast forward time by ~1 year + 7 months to test claiming after cliff period
        timestamp::fast_forward_seconds(stream.start_time+ 51104000);
        // Attempt to claim tokens which should fail since claimed amount > total amount
        claim(user, amount_to_claim);
        // Verify no claim event was emitted
        let state = borrow_global<State>(expected_resource_account_address);
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA, userB=@0xB)]
    #[expected_failure(abort_code = ERROR_STREAM_NOT_FOUND)]
    public fun test_claimed_stream_failed_no_stream(
        admin: &signer,
        user: &signer,
        userB: &signer,
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        let user_B_address = signer::address_of(userB);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);
        account::create_account_for_test(user_B_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);
        // Fast forward time by ~1 year + 4 months (35104000 seconds) from stream start
        timestamp::fast_forward_seconds(stream.start_time+ 35104000);

        // Attempt to claim tokens using a different user (userB) which should fail
        claim(userB, amount_to_claim);

        // Get the state resource again to verify claim status
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify no claims were processed by checking the event counter
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA, userB=@0xB)]
    #[expected_failure(abort_code = ERROR_INVALID_DURATION)]
    public fun test_claimed_stream_failed_all_duration_to_get_vested_token(
        admin: &signer,
        user: &signer,
        userB: &signer,
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        let user_B_address = signer::address_of(userB);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);
        account::create_account_for_test(user_B_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Fast forward time past the total duration (124417000 > 124416000) to test claiming after vesting period
        timestamp::fast_forward_seconds(stream.start_time + 124417000);

        // Attempt to claim tokens after vesting period has ended
        claim(user, amount_to_claim);

        // Get updated state to verify claim
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that no claim event was emitted (should fail since duration is invalid)
        assert!(event::counter(&state.claimed) == 0, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_claimed_stream_success_claim_exactly_when_cliff_end(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);
        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Fast forward time to exactly when cliff period ends (31104000 seconds after start)
        timestamp::fast_forward_seconds(stream.start_time + 31104000);

        // Attempt to claim tokens
        claim(user, amount_to_claim);

        // Get updated state to verify claim
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one claim event was emitted
        assert!(event::counter(&state.claimed) == 1, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_claimed_stream_success_claim_exactly_after_cliff_end(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;
        let amount_to_claim = 10;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource and stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Fast forward time to 32104000 seconds after stream start (just after cliff period)
        timestamp::fast_forward_seconds(stream.start_time + 32104000);

        // Attempt to claim tokens
        claim(user, amount_to_claim);

        // Get updated state to verify claim
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one claim event was emitted
        assert!(event::counter(&state.claimed) == 1, 0);
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_during_cliff(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        let expected_vested_amount = 0;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to 22104000 seconds after start (during cliff period)
        let current = stream.start_time + 22104000;

        // Get actual vested amount at current time
        let vested_amount = get_vested_amount(user_address, current);

        // Verify that vested amount is 0 since we're still in cliff period
        assert!(expected_vested_amount == vested_amount, 0)
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_after_cliff(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to 32104000 seconds after start (slightly after cliff period)
        let current = stream.start_time + 32104000;

        // Calculate expected vested amount at current time without considering cliff
        let expected_vested_amount = calculate_current_vested_without_cliff_amount(amount, stream.start_time, duration, current);

        // Get actual vested amount at current time
        let vested_amount = get_vested_amount(user_address, current);

        // Verify that calculated and actual vested amounts match
        assert!(expected_vested_amount == vested_amount, 0)
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_at_cliff_end(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to the end of cliff period (start_time + cliff)
        let current = stream.start_time + 31104000;

        // Calculate expected vested amount at the cliff end
        let expected_vested_amount = calculate_current_vested_without_cliff_amount(amount, stream.start_time, duration, current);

        // Get actual vested amount at the cliff end
        let vested_amount = get_vested_amount(user_address, current);

        // Verify that calculated and actual vested amounts match
        assert!(expected_vested_amount == vested_amount, 0)
    }

    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_at_vesting_end(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to the end of vesting period (start_time + duration)
        let current = stream.start_time + 124416000;

        // Calculate expected vested amount at the end of vesting
        let expected_vested_amount = calculate_current_vested_without_cliff_amount(amount, stream.start_time, duration, current);

        // Get actual vested amount at the end of vesting
        let vested_amount = get_vested_amount(user_address, current);

        // Verify that expected and actual vested amounts match
        assert!(expected_vested_amount == vested_amount, 0);
        // Verify that full amount is vested at the end
        assert!(expected_vested_amount == amount, 0);
    }


    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_at_vesting_after_half_claim(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to a point after half the vesting period
        let current = stream.start_time + 104416000;

        // Calculate expected vested amount at the current time
        let expected_vested_amount = calculate_current_vested_without_cliff_amount(amount, stream.start_time, duration, current);

        // Fast forward time to the same point and claim half the tokens
        timestamp::fast_forward_seconds(stream.start_time + 104416000);
        claim(user, 500);

        // Get actual vested amount and verify it matches expected
        let vested_amount = get_vested_amount(user_address, current);

        // Verify the vested amount matches what we calculated
        assert!(expected_vested_amount == vested_amount, 0);
    }


    #[test(admin = @blockchain, user = @0xA)]
    public fun test_get_vested_token_at_vesting_after_full_claim(
        admin: &signer,
        user: &signer
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Set current time to the end of vesting period (start_time + duration)
        let current = stream.start_time + 124416000;

        // Calculate expected vested amount at the end of vesting period
        let expected_vested_amount = calculate_current_vested_without_cliff_amount(amount, stream.start_time, duration, current);

        // Fast forward time to the end of vesting period
        timestamp::fast_forward_seconds(stream.start_time + 124416000);

        // Claim the full vested amount
        claim(user, 1000);

        // Get actual vested amount and verify it matches expected
        let vested_amount = get_vested_amount(user_address, current);
        assert!(expected_vested_amount == vested_amount, 0);

        // Verify that the full amount has vested
        assert!(expected_vested_amount == amount, 0);
    }

    #[test(admin = @blockchain, user = @0xA, userB=@0xB)]
    #[expected_failure(abort_code = ERROR_STREAM_NOT_FOUND)]
    public fun test_get_stream_failed_no_stream(
        admin: &signer,
        user: &signer,
        userB: &signer,
    ) acquires VestingContract, State {
        // Set up test accounts
        let admin_address = signer::address_of(admin);
        let user_address = signer::address_of(user);
        let user_B_address = signer::address_of(userB);
        account::create_account_for_test(admin_address);
        account::create_account_for_test(user_address);
        account::create_account_for_test(user_B_address);

        // Set up timestamp for testing
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize the module
        init_module(admin);

        let expected_resource_account_address = account::create_resource_address(&@blockchain, SEED);

        // Test parameters
        let amount = 1000; // Invalid amount to trigger failure
        let duration = 124416000;
        let cliff = 31104000;

        // This should fail because amount is 0
        // Create a new vesting stream for the user with specified parameters
        create_stream(admin, user_address, amount, duration, cliff);

        // Get the state resource to verify stream creation
        let state = borrow_global<State>(expected_resource_account_address);

        // Verify that exactly one stream was created by checking the event counter
        assert!(event::counter(&state.stream_created) == 1, 0);

        // Get the vesting contract resource to access stream details
        let contract = borrow_global<VestingContract>(expected_resource_account_address);

        // Get the stream details for the user
        let stream = simple_map::borrow(&contract.streams, &user_address);

        // Calculate current timestamp by adding cliff duration to start time
        let current = stream.start_time + 31104000;

        // Try to get vested amount for a different user (userB) which should fail
        // since they don't have a stream
        let vested_amount = get_vested_amount(user_B_address, current);
        debug::print(&vested_amount)
    }
}