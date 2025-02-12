// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { HDToken } from "../src/HDToken.sol";
import { IERC20 } from "council/interfaces/IERC20.sol";
import { CoreVoting } from "council/CoreVoting.sol";
import { MigrationVestingVault } from "../src/MigrationVestingVault.sol";
import { VestingVaultStorage } from "council/libraries/VestingVaultStorage.sol";

/// @dev This test suite provides coverage for the MigrationVestingVault contract's
///      functionality, including migration, voting power tracking, and delegation.
contract MigrationVestingVaultTest is Test {
    /// @dev Events to test
    event VoteChange(address indexed from, address indexed to, int256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev Constants for mainnet contracts and configuration
    uint256 internal constant FORK_BLOCK = 19_000_000;
    uint256 internal constant STALE_BLOCKS = 100;
    uint256 internal constant CONVERSION_MULTIPLIER = 1;
    uint256 internal constant VESTING_DURATION = 90 days;
    address internal constant ELFI_WHALE = 0x6De73946eab234F1EE61256F10067D713aF0e37A;

    /// @dev Contract instances
    CoreVoting internal constant CORE_VOTING = CoreVoting(0xEaCD577C3F6c44C3ffA398baaD97aE12CDCFed4a);
    IERC20 internal constant ELFI = IERC20(0x5c6D51ecBA4D8E4F20373e3ce96a62342B125D6d);
    MigrationVestingVault internal vault;
    HDToken internal hdToken;

    /// @dev Test accounts
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal charlie;

    /// @notice Sets up the test environment with the following:
    ///         1. Fork mainnet at specified block
    ///         2. Set up test accounts
    ///         3. Deploy HDToken and MigrationVestingVault
    ///         4. Configure CoreVoting with the new vault
    function setUp() public {
        // Create test accounts
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fork mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        // Deploy HD token
        vm.startPrank(deployer);
        hdToken = new HDToken(
            "HD Token",
            "HD",
            block.timestamp + 1 days
        );

        // Deploy migration vault
        uint256 globalExpiration = block.number + (VESTING_DURATION / 12);
        vault = new MigrationVestingVault(
            IERC20(address(hdToken)), // Cast HDToken to IERC20
            ELFI,
            STALE_BLOCKS,
            CONVERSION_MULTIPLIER,
            globalExpiration
        );
        // FIXME: This is a bit janky. It would be better to use the real timelock.
        vault.initialize(deployer, deployer);

        // Add vault to CoreVoting
        vm.startPrank(CORE_VOTING.owner());
        CORE_VOTING.changeVaultStatus(address(vault), true);

        // FIXME: This is janky. It would be better if the vault pulled directly
        // from an address.
        //
        // Fund vault with HD tokens for migration
        vm.startPrank(deployer);
        hdToken.approve(address(vault), 1_000_000e18);
        vault.deposit(1_000_000e18);

        // Fund the addresses with ELFI.
        vm.startPrank(ELFI_WHALE);
        uint256 whaleBalance = ELFI.balanceOf(ELFI_WHALE);
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        for (uint256 i = 0; i < accounts.length; i++) {
            ELFI.transfer(accounts[i], whaleBalance / accounts.length);
        }
    }

    // ==============================
    // Migration Tests
    // ==============================

    /// @dev Ensures migration fails when destination already has a grant.
    function test_migrate_failure_existingGrant() external {
        // First migration
        uint256 amount = 100e18;
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);

        // Attempt second migration to same destination
        vm.expectRevert(MigrationVestingVault.ExistingGrantFound.selector);
        vault.migrate(amount, alice);
        vm.stopPrank();
    }

    /// @dev Ensures migration fails when ELFI transfer fails.
    function test_migrate_failure_transferFailed() external {
        // Try transferring ELFI without setting an approval. This should
        // fail.
        uint256 amount = 100e18;
        vm.startPrank(alice);
        vm.expectRevert();
        vault.migrate(amount, alice);
        vm.stopPrank();
    }

    /// @dev Ensures migration fails when insufficient HD tokens are available
    function test_migrate_failure_insufficientHDTokens() external {
        uint256 excessiveAmount = hdToken.balanceOf(address(vault)) / vault.conversionMultiplier() + 1;

        vm.startPrank(alice);
        ELFI.approve(address(vault), excessiveAmount);

        vm.expectRevert(MigrationVestingVault.InsufficientHDTokens.selector);
        vault.migrate(excessiveAmount, alice);
        vm.stopPrank();
    }

    /// @dev Ensures successful migration with correct grant creation
    function test_migrate_success() external {
        uint256 amount = 100e18;

        // Record initial states
        uint256 vaultElfiBalanceBefore = ELFI.balanceOf(address(vault));
        uint256 aliceElfiBalanceBefore = ELFI.balanceOf(alice);

        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);

        // Expect Transfer events
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(vault), amount);

        vault.migrate(amount, alice);
        vm.stopPrank();

        // Verify grant parameters
        VestingVaultStorage.Grant memory grant = vault.getGrant(alice);

        assertEq(grant.allocation, amount * CONVERSION_MULTIPLIER, "Wrong allocation");
        assertEq(grant.withdrawn, 0, "Should not have withdrawals");
        assertEq(grant.cliff, grant.created, "Cliff should equal creation block");
        assertEq(grant.expiration, vault.globalExpiration(), "Wrong expiration");
        assertEq(grant.delegatee, alice, "Wrong delegatee");

        // Verify token transfers
        assertEq(
            ELFI.balanceOf(address(vault)),
            vaultElfiBalanceBefore + amount,
            "Vault ELFI balance not updated"
        );
        assertEq(
            ELFI.balanceOf(alice),
            aliceElfiBalanceBefore - amount,
            "Alice ELFI balance not updated"
        );
    }

    // ==============================
    // Voting Power Tests
    // ==============================

    /// @dev Ensures correct voting power calculation after migration
    function test_votingPower_afterMigration() external {
        uint256 amount = 100e18;

        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);
        vm.stopPrank();

        // Wait for power to be queryable (past stale blocks)
        vm.roll(block.number + STALE_BLOCKS + 1);

        // Get voting power of alice at the last block number
        uint256 votingPower = vault.queryVotePower(alice, block.number - 1, "");
        assertEq(
            votingPower,
            amount * CONVERSION_MULTIPLIER,
            "Incorrect voting power"
        );
    }

    /// @dev Tests voting power transfer through delegation
    function test_votingPower_afterDelegation() external {
        uint256 amount = 100e18;

        // Set up initial grant
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);

        // Delegate to bob
        vm.expectEmit(true, true, true, true);
        emit VoteChange(alice, alice, -int256(uint256(amount * CONVERSION_MULTIPLIER)));
        vm.expectEmit(true, true, true, true);
        emit VoteChange(bob, alice, int256(uint256(amount * CONVERSION_MULTIPLIER)));
        vault.delegate(bob);
        vm.stopPrank();

        // Wait for power to be queryable
        vm.roll(block.number + STALE_BLOCKS + 1);

        // Verify voting powers
        uint256 aliceVotingPower = vault.queryVotePower(alice, block.number - 1, "");
        uint256 bobVotingPower = vault.queryVotePower(bob, block.number - 1, "");

        assertEq(aliceVotingPower, 0, "Alice should have no voting power");
        assertEq(
            bobVotingPower,
            amount * CONVERSION_MULTIPLIER,
            "Bob should have Alice's voting power"
        );
    }

    /// @dev Tests voting power changes through vesting progression
    function test_votingPower_throughVesting() external {
        uint256 amount = 100e18;

        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);
        vm.stopPrank();
        {
            uint256 votingPower = vault.queryVotePower(alice, block.number, "");
        }

        // Move to middle of vesting period
        uint256 halfwayBlock = (block.number + vault.globalExpiration()) / 2;
        vm.roll(halfwayBlock);

        // Check voting power is maintained through vesting
        uint256 votingPower = vault.queryVotePower(alice, block.number - 1, "");
        assertEq(
            votingPower,
            amount * CONVERSION_MULTIPLIER,
            "Voting power should remain constant"
        );
    }
}
