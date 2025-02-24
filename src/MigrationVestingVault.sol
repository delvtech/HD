// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { IERC20 } from "council/interfaces/IERC20.sol";
import { IVotingVault } from "council/interfaces/IVotingVault.sol";
import { History } from "council/libraries/History.sol";
import { VestingVaultStorage } from "council/libraries/VestingVaultStorage.sol";
import { Storage } from "council/libraries/Storage.sol";
import { AbstractVestingVault } from "council/vaults/VestingVault.sol";

/// @title MigrationVestingVault
/// @notice A migration vault that converts ELFI tokens to HD tokens. Migrated
///         tokens are granted with a linear vesting schedule. The grant is
///         created at a destination address provided by the migrator. This
///         contract inherits full voting power tracking from
///         `AbstractVestingVault`.
contract MigrationVestingVault is AbstractVestingVault {
    using History for History.HistoricalBalances;

    /// @dev Thrown when an existing grant is found.
    error ExistingGrantFound();

    /// @dev Thrown when ELFI transfers fail.
    error ElfiTransferFailed();

    /// @dev Thrown when there are insufficient HD tokens.
    error InsufficientHDTokens();

    /// @notice The number of blocks between deploying the contract and the
    ///         expiration.
    uint256 public constant EXPIRATION_DURATION = 91 days / 12; // ~3 months

    /// @dev The HD treasury that is funding this migration contract.
    address public immutable hdTreasury;

    /// @dev The ELFI token to migrate from.
    IERC20 public immutable elfiToken;

    /// @dev The conversion rate from ELFI to HD.
    uint256 public immutable conversionMultiplier;

    /// @dev The global start block at which all grants start vesting.
    uint256 public immutable startBlock;

    /// @dev The global expiration block at which all grants fully vest.
    uint256 public immutable expiration;

    /// @notice Constructs the migration vault.
    /// @param _hdTreasury The HD treasury that is funding this migration
    ///        contract.
    /// @param _hdToken The ERC20 token to be vested (HD token).
    /// @param _elfiToken The ERC20 token to migrate from (ELFI token).
    /// @param _stale The stale block lag used in voting power calculations.
    /// @param _conversionMultiplier The conversion multiplier from ELFI to HD.
    constructor(
        address _hdTreasury,
        IERC20 _hdToken,
        IERC20 _elfiToken,
        uint256 _stale,
        uint256 _conversionMultiplier
    ) AbstractVestingVault(_hdToken, _stale) {
        hdTreasury = _hdTreasury;
        elfiToken = _elfiToken;
        conversionMultiplier = _conversionMultiplier;
        startBlock = block.number;
        expiration = startBlock + EXPIRATION_DURATION;
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

        // Pull the HD tokens from the source.
        if (!token.transferFrom(hdTreasury, address(this), hdAmount)) {
            revert InsufficientHDTokens();
        }

        // Calculate the initial voting power using the current unvested multiplier.
        Storage.Uint256 memory unvestedMultiplier = _unvestedMultiplier();
        uint128 initialVotingPower = uint128((hdAmount * uint128(unvestedMultiplier.data)) / 100);

        // Create the grant at the destination address.
        _grants()[destination] = VestingVaultStorage.Grant({
            allocation: uint128(hdAmount),
            withdrawn: 0,
            created: uint128(startBlock),
            expiration: uint128(expiration),
            cliff: uint128(startBlock), // vesting starts immediately
            latestVotingPower: initialVotingPower,
            delegatee: destination,
            range: [uint256(0), uint256(0)]
        });

        // Update the destination's voting power.
        History.HistoricalBalances memory votingPower = History.load("votingPower");
        votingPower.push(destination, initialVotingPower);
        emit VoteChange(destination, destination, int256(uint256(initialVotingPower)));
    }
}
