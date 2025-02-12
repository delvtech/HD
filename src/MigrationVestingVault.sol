// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { IERC20 } from "council/interfaces/IERC20.sol";
import { IVotingVault } from "council/interfaces/IVotingVault.sol";
import { History } from "council/libraries/History.sol";
import { VestingVaultStorage } from "council/libraries/VestingVaultStorage.sol";
import { Storage } from "council/libraries/Storage.sol";
import { AbstractVestingVault } from "council/vaults/VestingVault.sol";

// FIXME: Scrutinize this.
//
// FIXME: Test this.
//
// FIXME: We can retrofit this to pull funds from the treasury instead of needing
// to be funded directly by the treasury. This would be more flexible since we'll
// have two migration vaults.
//
// FIXME: What should happen to the ELFI? Should it be burned?
//
/// @title MigrationVestingVault
/// @notice A migration vault that converts ELFI tokens to HD tokens. Migrated
///         tokens are granted with a linear vesting schedule of three months.
///         The grant is created at a destination address provided by the
///         migrator. This contract inherits full voting power tracking from
///         `AbstractVestingVault`.
contract MigrationVestingVault is AbstractVestingVault {
    using History for History.HistoricalBalances;

    /// @dev Thrown when an existing grant is found.
    error ExistingGrantFound();

    /// @dev Thrown when ELFI transfers fail.
    error ElfiTransferFailed();

    /// @dev Thrown when there are insufficient HD tokens.
    error InsufficientHDTokens();

    /// @dev The ELFI token to migrate from.
    IERC20 public immutable elfiToken;

    // The conversion rate from ELFI to HD.
    uint256 public immutable conversionMultiplier;

    // The global expiration block at which all grants fully vest.
    uint256 public immutable globalExpiration;

    /// @notice Constructs the migration vault.
    /// @param _hdToken The ERC20 token to be vested (HD token).
    /// @param _elfiToken The ERC20 token to migrate from (ELFI token).
    /// @param _stale The stale block lag used in voting power calculations.
    /// @param _conversionMultiplier The conversion multiplier from ELFI to HD.
    /// @param _globalExpiration The global expiration block for all grants.
    constructor(
        IERC20 _hdToken,
        IERC20 _elfiToken,
        uint256 _stale,
        uint256 _conversionMultiplier,
        uint256 _globalExpiration
    ) AbstractVestingVault(_hdToken, _stale) {
        elfiToken = _elfiToken;
        conversionMultiplier = _conversionMultiplier;
        globalExpiration = _globalExpiration;
    }

    /// @notice Migrates a specified amount of ELFI tokens into a vesting grant of HD tokens.
    /// @dev The caller must have approved this contract for the ELFI token amount.
    ///      The destination address must not have an existing grant.
    /// @param amount The number of tokens to migrate (in ELFI units).
    /// @param destination The address at which the vesting grant will be created.
    function migrate(uint256 amount, address destination) external {
        // Ensure the destination does not already have an active grant.
        VestingVaultStorage.Grant storage existingGrant = _grants()[destination];
        if (existingGrant.allocation != 0) {
            revert ExistingGrantFound();
        }

        // Transfer ELFI tokens from the caller to this contract.
        if (!elfiToken.transferFrom(msg.sender, address(this), amount)) {
            revert ElfiTransferFailed();
        }

        // Calculate the HD token amount to be granted.
        uint256 hdAmount = amount * conversionMultiplier;

        // Ensure sufficient HD tokens are available in the unassigned pool.
        Storage.Uint256 storage unassigned = _unassigned();
        if (unassigned.data < hdAmount) {
            revert InsufficientHDTokens();
        }

        // Set the vesting parameters. We use the global expiration for all
        // grants, and the vesting starts immediately.
        uint128 startBlock = uint128(block.number);
        uint128 expiration = uint128(globalExpiration);
        uint128 cliff = startBlock;

        // Calculate the initial voting power using the current unvested multiplier.
        Storage.Uint256 memory unvestedMultiplier = _unvestedMultiplier();
        uint128 initialVotingPower = uint128((hdAmount * uint128(unvestedMultiplier.data)) / 100);

        // Create the grant at the destination address.
        _grants()[destination] = VestingVaultStorage.Grant({
            allocation: uint128(hdAmount),
            withdrawn: 0,
            created: startBlock,
            expiration: expiration,
            cliff: cliff,
            latestVotingPower: initialVotingPower,
            delegatee: destination,
            range: [uint256(0), uint256(0)]
        });

        // Deduct the granted tokens from the unassigned pool.
        unassigned.data -= hdAmount;

        // Update the destination's voting power.
        History.HistoricalBalances memory votingPower = History.load("votingPower");
        votingPower.push(destination, initialVotingPower);
        emit VoteChange(destination, destination, int256(uint256(initialVotingPower)));
    }
}
