// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { HDToken } from "../src/HDToken.sol"; // Assuming HDToken.sol exists
import { IERC20 } from "council/interfaces/IERC20.sol";
import { CoreVoting } from "council/CoreVoting.sol";
import { MigrationRewardsVault } from "../src/MigrationRewardsVault.sol";
import { VestingVaultStorage } from "council/libraries/VestingVaultStorage.sol";

/// @title MigrationRewardsVaultTest
/// @notice Test suite for the MigrationRewardsVault contract, covering migration,
///         vesting, bonus application, voting power tracking, and claiming.
contract MigrationRewardsVaultTest is Test {
    /// @dev Events to test
    event VoteChange(address indexed from, address indexed to, int256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev Constants for mainnet contracts and configuration
    uint256 internal constant FORK_BLOCK = 19_000_000;
    uint256 internal constant STALE_BLOCKS = 100;
    address internal constant ELFI_WHALE = 0x6De73946eab234F1EE61256F10067D713aF0e37A;

    /// @dev Contract instances
    CoreVoting internal constant CORE_VOTING = CoreVoting(0xEaCD577C3F6c44C3ffA398baaD97aE12CDCFed4a);
    IERC20 internal constant ELFI = IERC20(0x5c6D51ecBA4D8E4F20373e3ce96a62342B125D6d);
    MigrationRewardsVault internal vault;
    HDToken internal hdToken;

    /// @dev Test accounts
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal charlie;

    /// @notice Sets up the test environment by forking mainnet, deploying contracts,
    ///         and configuring accounts and CoreVoting.
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
        vault = new MigrationRewardsVault(
            deployer, // Treasury is deployer for simplicity
            IERC20(address(hdToken)),
            ELFI,
            STALE_BLOCKS
        );

        // Add vault to CoreVoting
        vm.startPrank(CORE_VOTING.owner());
        CORE_VOTING.changeVaultStatus(address(vault), true);

        // Approve vault to spend 1,000,000 HD tokens from deployer (treasury)
        vm.startPrank(deployer);
        hdToken.approve(address(vault), 1_000_000e18);

        // Fund test accounts with ELFI from whale
        vm.startPrank(ELFI_WHALE);
        uint256 whaleBalance = ELFI.balanceOf(ELFI_WHALE);
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        for (uint256 i = 0; i < accounts.length; i++) {
            ELFI.transfer(accounts[i], whaleBalance / accounts.length);
        }
        vm.stopPrank();
    }

    // ==============================
    // Migration Tests
    // ==============================

    /// @notice Tests that migration fails if the destination already has a grant.
    function test_migrate_failure_existingGrant() external {
        uint256 amount = 100e18;
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);

        // Attempt second migration to same destination
        vm.expectRevert(MigrationRewardsVault.ExistingGrantFound.selector);
        vault.migrate(amount, alice);
        vm.stopPrank();
    }

    /// @notice Tests that migration fails if ELFI transfer fails (no approval).
    function test_migrate_failure_transferFailed() external {
        uint256 amount = 100e18;
        vm.startPrank(alice);
        vm.expectRevert(); // ERC20: insufficient allowance
        vault.migrate(amount, alice);
        vm.stopPrank();
    }

    /// @notice Tests that migration fails if insufficient HD tokens are available.
    function test_migrate_failure_insufficientHDTokens() external {
        uint256 excessiveAmount = (hdToken.allowance(deployer, address(vault)) / 10) + 1e18;
        vm.startPrank(alice);
        ELFI.approve(address(vault), excessiveAmount);
        vm.expectRevert();
        vault.migrate(excessiveAmount, alice);
        vm.stopPrank();
    }

    /// @notice Tests successful migration and claiming for a pre-cliff migrator.
    function test_migrate_and_claim_preCliff() external {
        uint256 amount = 100e18;

        // Record initial states
        uint256 vaultElfiBalanceBefore = ELFI.balanceOf(address(vault));
        uint256 aliceElfiBalanceBefore = ELFI.balanceOf(alice);
        uint256 vaultHdBalanceBefore = hdToken.balanceOf(address(vault));
        uint256 bobHdBalanceBefore = hdToken.balanceOf(bob);

        // Alice migrates ELFI to Bob (pre-cliff)
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(vault), amount);
        vault.migrate(amount, bob);
        vm.stopPrank();

        // Verify grant configuration
        uint256 treasuryHdBalanceBefore = hdToken.balanceOf(vault.hdTreasury());
        VestingVaultStorage.Grant memory grant = vault.getGrant(bob);
        uint256 expectedAllocation = (amount * 10 * vault.BONUS_MULTIPLIER()) / vault.ONE();
        assertEq(grant.allocation, expectedAllocation, "Wrong allocation");
        assertEq(grant.withdrawn, 0, "Should not have withdrawals");
        assertEq(grant.created, block.number, "Wrong creation block");
        assertEq(grant.cliff, vault.cliff(), "Wrong cliff");
        assertEq(grant.expiration, vault.expiration(), "Wrong expiration");
        assertEq(grant.delegatee, bob, "Wrong delegatee");

        // Verify token transfers
        assertEq(ELFI.balanceOf(address(vault)), vaultElfiBalanceBefore + amount, "Vault ELFI balance not updated");
        assertEq(ELFI.balanceOf(alice), aliceElfiBalanceBefore - amount, "Alice ELFI balance not updated");
        assertEq(hdToken.balanceOf(address(vault)), vaultHdBalanceBefore + expectedAllocation, "Vault HD balance not updated");

        // Move to halfway between cliff and expiration
        uint256 halfwayBlock = vault.cliff() + (vault.expiration() - vault.cliff()) / 2;
        vm.roll(halfwayBlock);

        // Bob claims
        vm.startPrank(bob);
        vault.claim();

        // Verify claim outcomes
        uint256 bobHdBalanceAfter = hdToken.balanceOf(bob);
        uint256 vaultHdBalanceAfter = hdToken.balanceOf(address(vault));
        uint256 votingPowerAfter = vault.queryVotePower(bob, block.number, "");
        uint256 expectedBase = amount * 10; // CONVERSION_MULTIPLIER = 10e18
        uint256 expectedBonusHalf = ((expectedAllocation - expectedBase) / 2);
        assertEq(bobHdBalanceAfter, bobHdBalanceBefore + expectedBase + expectedBonusHalf, "Bob HD balance incorrect");
        assertEq(vaultHdBalanceAfter, 0, "Vault HD balance incorrect");
        assertEq(votingPowerAfter, 0, "Voting power should be zero after claim");
        assertEq(hdToken.balanceOf(vault.hdTreasury()), treasuryHdBalanceBefore + expectedBonusHalf, "Treasury should receive unvested bonus");

        // Verify grant is deleted
        grant = vault.getGrant(bob);
        assertEq(grant.allocation, 0, "Grant should be deleted");
    }

    /// @notice Tests migration and immediate partial claim for a post-cliff migrator.
    function test_migrate_and_claim_postCliff_halfway() external {
        uint256 amount = 100e18;

        // Move to halfway between cliff and expiration
        uint256 halfwayBlock = vault.cliff() + (vault.expiration() - vault.cliff()) / 2;
        vm.roll(halfwayBlock);

        // Record initial states
        uint256 bobHdBalanceBefore = hdToken.balanceOf(bob);
        uint256 treasuryHdBalanceBefore = hdToken.balanceOf(vault.hdTreasury());

        // Alice migrates ELFI to Bob (post-cliff)
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, bob);
        vm.stopPrank();

        // Verify grant configuration
        VestingVaultStorage.Grant memory grant = vault.getGrant(bob);
        uint256 blocksRemaining = vault.expiration() - halfwayBlock;
        uint256 bonusPeriod = vault.expiration() - vault.cliff();
        uint256 bonusFactor = vault.ONE() + ((vault.BONUS_MULTIPLIER() - vault.ONE()) * blocksRemaining) / bonusPeriod;
        uint256 expectedBase = amount * 10; // CONVERSION_MULTIPLIER = 10e18
        uint256 expectedAllocation = (expectedBase * bonusFactor) / vault.ONE();
        assertEq(grant.allocation, expectedAllocation, "Wrong allocation");
        assertEq(grant.created, halfwayBlock, "Wrong creation block");

        // Bob claims immediately
        vm.startPrank(bob);
        vault.claim();

        // Verify claim outcomes
        uint256 bobHdBalanceAfter = hdToken.balanceOf(bob);
        uint256 vaultHdBalanceAfter = hdToken.balanceOf(address(vault));
        uint256 votingPowerAfter = vault.queryVotePower(bob, block.number, "");
        assertEq(bobHdBalanceAfter, bobHdBalanceBefore + expectedBase, "Bob HD balance incorrect");
        assertEq(vaultHdBalanceAfter, 0, "Vault HD balance incorrect");
        assertEq(votingPowerAfter, 0, "Voting power should be zero after claim");
        assertEq(hdToken.balanceOf(vault.hdTreasury()), treasuryHdBalanceBefore - expectedBase, "Treasury balance incorrect");
    }

    /// @notice Tests migration and full claim after expiration.
    function test_migrate_and_claim_postExpiration() external {
        uint256 amount = 100e18;

        // Move past expiration
        vm.roll(vault.expiration() + 1);

        // Record initial states
        uint256 vaultHdBalanceBefore = hdToken.balanceOf(address(vault));
        uint256 bobHdBalanceBefore = hdToken.balanceOf(bob);

        // Alice migrates ELFI to Bob (post-expiration)
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, bob);
        vm.stopPrank();

        // Verify grant configuration (no bonus post-expiration)
        uint256 treasuryHdBalanceBefore = hdToken.balanceOf(vault.hdTreasury());
        VestingVaultStorage.Grant memory grant = vault.getGrant(bob);
        uint256 expectedBase = amount * 10; // CONVERSION_MULTIPLIER = 10e18
        assertEq(grant.allocation, expectedBase, "Wrong allocation");

        // Bob claims immediately
        vm.startPrank(bob);
        vault.claim();

        // Verify claim outcomes
        uint256 bobHdBalanceAfter = hdToken.balanceOf(bob);
        uint256 vaultHdBalanceAfter = hdToken.balanceOf(address(vault));
        uint256 votingPowerAfter = vault.queryVotePower(bob, block.number, "");
        assertEq(bobHdBalanceAfter, bobHdBalanceBefore + expectedBase, "Bob HD balance incorrect");
        assertEq(vaultHdBalanceAfter, vaultHdBalanceBefore, "Vault HD balance should not decrease beyond base");
        assertEq(votingPowerAfter, 0, "Voting power should be zero after claim");
        assertEq(hdToken.balanceOf(vault.hdTreasury()), treasuryHdBalanceBefore, "Treasury should receive no bonus post-expiration");
    }

    // ==============================
    // Voting Power Tests
    // ==============================

    /// @notice Tests voting power after pre-cliff migration.
    function test_votingPower_afterPreCliffMigration() external {
        uint256 amount = 100e18;

        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);
        vm.stopPrank();

        // Wait past stale blocks
        vm.roll(block.number + STALE_BLOCKS + 1);

        // Verify voting power
        uint256 votingPower = vault.queryVotePower(alice, block.number - 1, "");
        assertEq(votingPower, amount * 10, "Incorrect voting power pre-cliff"); // Base amount
    }

    /// @notice Tests voting power delegation.
    function test_votingPower_afterDelegation() external {
        uint256 amount = 100e18;

        // Alice migrates and delegates to Bob
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);
        vm.expectEmit(true, true, true, true);
        emit VoteChange(alice, alice, -int256(amount * 10));
        vm.expectEmit(true, true, true, true);
        emit VoteChange(bob, alice, int256(amount * 10));
        vault.delegate(bob);
        vm.stopPrank();

        // Wait past stale blocks
        vm.roll(block.number + STALE_BLOCKS + 1);

        // Verify voting powers
        uint256 aliceVotingPower = vault.queryVotePower(alice, block.number - 1, "");
        uint256 bobVotingPower = vault.queryVotePower(bob, block.number - 1, "");
        assertEq(aliceVotingPower, 0, "Alice should have no voting power");
        assertEq(bobVotingPower, amount * 10, "Bob should have Alice's voting power");
    }

    /// @notice Tests voting power progression through vesting.
    function test_votingPower_throughVesting() external {
        uint256 amount = 100e18;

        // Alice migrates pre-cliff
        vm.startPrank(alice);
        ELFI.approve(address(vault), amount);
        vault.migrate(amount, alice);
        vm.stopPrank();

        // Move to cliff
        vm.roll(vault.cliff());
        uint256 votingPowerAtCliff = vault.queryVotePower(alice, block.number - 1, "");
        assertEq(votingPowerAtCliff, amount * 10, "Voting power incorrect at cliff");

        // Move halfway between cliff and expiration
        uint256 halfwayBlock = vault.cliff() + (vault.expiration() - vault.cliff()) / 2;
        vm.roll(halfwayBlock);
        vault.updateVotingPower(alice);
        uint256 votingPowerHalfway = vault.queryVotePower(alice, block.number, "");
        uint256 expectedAllocation = (amount * 10 * vault.BONUS_MULTIPLIER()) / vault.ONE();
        uint256 expectedBonusHalf = ((expectedAllocation - (amount * 10)) / 2);
        assertEq(votingPowerHalfway, amount * 10 + expectedBonusHalf, "Voting power incorrect halfway");

        // Move to expiration
        vm.roll(vault.expiration());
        vault.updateVotingPower(alice);
        uint256 votingPowerAtExpiration = vault.queryVotePower(alice, block.number, "");
        assertEq(votingPowerAtExpiration, expectedAllocation, "Voting power incorrect at expiration");
    }
}
