// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { IERC20 } from "council/interfaces/IERC20.sol";
import { IVotingVault } from "council/interfaces/IVotingVault.sol";
import { History } from "council/libraries/History.sol";
import { VestingVaultStorage } from "council/libraries/VestingVaultStorage.sol";
import { Storage } from "council/libraries/Storage.sol";
import { AbstractVestingVault } from "council/vaults/VestingVault.sol";

/// @title MigrationRewardsVault
/// @notice A migration vault that converts ELFI tokens to HD tokens. Migrated
///         tokens have a cliff. After this cliff, they will accrue a bonus
///         linearly as time passes. The grant is created at a destination
///         address provided by the migrator. This contract inherits full voting
///         power tracking from `AbstractVestingVault`.
contract MigrationRewardsVault is AbstractVestingVault {
    using History for History.HistoricalBalances;

    /// @notice Thrown when an existing grant is found.
    error ExistingGrantFound();

    /// @notice Thrown when ELFI transfers fail.
    error ElfiTransferFailed();

    /// @notice Thrown when there are insufficient HD tokens.
    error InsufficientHDTokens();

    /// @notice Thrown when no tokens are withdrawable during a claim attempt.
    error NothingToClaim();

    /// @notice Thrown when the HD token transfer to the claimant fails.
    error TransferFailed();

    /// @notice Thrown when the HD token transfer to the treasury fails.
    error TreasuryTransferFailed();

    /// @notice One in basis points.
    uint256 public constant ONE = 1e18;

    /// @notice The conversion rate from ELFI to HD.
    uint256 public constant CONVERSION_MULTIPLIER = 10;

    /// @notice The bonus multiplier, representing a 5% APR over
    ///         a three-month cliff period. For a 5% APR over 2 months (0.16
    ///         years), bonus = 5% * 0.16 which is approximately 0.83%.
    uint256 public constant BONUS_MULTIPLIER = 1.008333333333333333e18;

    /// @notice The number of blocks between deploying the contract and the
    ///         vesting cliff.
    uint256 public constant CLIFF_DURATION = 91 days / 12; // ~3 months

    /// @notice The number of blocks between deploying the contract and the
    ///         expiration.
    uint256 public constant EXPIRATION_DURATION = 152 days / 12; // ~5 months

    /// @notice The HD treasury that is funding this migration contract.
    address public immutable hdTreasury;

    /// @notice The ELFI token to migrate from.
    IERC20 public immutable elfiToken;

    /// @notice The global start block at which all grants start vesting.
    uint256 public immutable startBlock;

    /// @notice The global cliff block at which all grants have vested their cliff
    ///      amount.
    uint256 public immutable cliff;

    /// @notice The global expiration block at which all grants fully vest.
    uint256 public immutable expiration;

    /// @notice Constructs the migration vault.
    /// @param _hdTreasury The HD treasury funding this migration contract.
    /// @param _hdToken The ERC20 token to be vested (HD token).
    /// @param _elfiToken The ERC20 token to migrate from (ELFI token).
    /// @param _stale The stale block lag for voting power calculations.
    constructor(
        address _hdTreasury,
        IERC20 _hdToken,
        IERC20 _elfiToken,
        uint256 _stale
    ) AbstractVestingVault(_hdToken, _stale) {
        // Set immutable variables
        hdTreasury = _hdTreasury;
        elfiToken = _elfiToken;

        // Use deployment block as startBlock.
        startBlock = block.number;

        // Calculate cliff and expiration based on durations.
        cliff = block.number + CLIFF_DURATION;
        expiration = block.number + EXPIRATION_DURATION;
    }

    /// @notice Migrates a specified amount of ELFI tokens into a vesting grant
    ///         of HD tokens.
    /// @dev Converts ELFI to HD at the conversion rate. Pre-cliff migrations
    ///      receive a 5% bonus vesting post-cliff over 2 months. Post-cliff,
    ///      pre-expiration migrations receive a reduced bonus proportional to
    ///      remaining time, vesting from creation. Post-expiration migrations
    ///      receive no bonus, just the base amount. Caller must approve this
    ///      contract for ELFI tokens, and the treasury must approve HD tokens.
    /// @param _amount The amount of ELFI tokens to migrate.
    /// @param _destination The address to receive the HD token grant.
    function migrate(uint256 _amount, address _destination) external {
        // Prevent duplicate grants at the destination.
        VestingVaultStorage.Grant storage existingGrant = _grants()[_destination];
        if (existingGrant.allocation != 0) {
            revert ExistingGrantFound();
        }

        // Transfer ELFI tokens from the caller to this contract.
        if (!elfiToken.transferFrom(msg.sender, address(this), _amount)) {
            revert ElfiTransferFailed();
        }

        // Calculate the base HD amount from ELFI conversion.
        uint256 baseHdAmount = _amount * CONVERSION_MULTIPLIER;
        uint256 totalHdAmount;

        // Determine the total HD amount based on migration timing.
        if (block.number < cliff) {
            // Full 5% bonus for pre-cliff migrations.
            totalHdAmount = (baseHdAmount * BONUS_MULTIPLIER) / ONE;
        } else if (block.number < expiration) {
            // Reduced bonus for post-cliff, pre-expiration migrations.
            uint256 blocksRemaining = expiration - block.number;
            uint256 bonusPeriod = expiration - cliff;
            uint256 bonusFactor = ONE + ((BONUS_MULTIPLIER - ONE) * blocksRemaining) / bonusPeriod;
            totalHdAmount = (baseHdAmount * bonusFactor) / ONE;
        } else {
            // No bonus for post-expiration migrations, just base amount.
            totalHdAmount = baseHdAmount;
        }

        // Transfer HD tokens from the treasury to this contract.
        if (!token.transferFrom(hdTreasury, address(this), totalHdAmount)) {
            revert InsufficientHDTokens();
        }

        // Create the grant with current block as creation time and base as initial voting power.
        _grants()[_destination] = VestingVaultStorage.Grant({
            allocation: uint128(totalHdAmount),
            withdrawn: 0,
            created: uint128(block.number),
            expiration: uint128(expiration),
            cliff: uint128(cliff),
            latestVotingPower: uint128(baseHdAmount),
            delegatee: _destination,
            range: [uint256(0), uint256(0)]
        });

        // Update voting power history with the base amount.
        History.HistoricalBalances memory votingPower = _votingPower();
        votingPower.push(_destination, baseHdAmount);
        emit VoteChange(_destination, _destination, int256(baseHdAmount));
    }

    /// @notice Claims all withdrawable HD tokens from the caller's grant and
    ///         terminates it.
    /// @dev Withdraws the currently withdrawable amount (base plus vested
    ///      bonus), returns any unvested bonus to the treasury, resets voting
    ///      power to 0, and deletes the grant. Fails if no tokens are
    ///      withdrawable (e.g., before cliff for early migrators or before
    ///      creation).
    function claim() public override {
        // Load the caller’s grant and calculate the withdrawable amount.
        VestingVaultStorage.Grant storage grant = _grants()[msg.sender];
        uint256 withdrawable = _getWithdrawableAmount(grant);
        if (withdrawable == 0) {
            revert NothingToClaim();
        }

        // Calculate the unvested amount to return to the treasury.
        uint256 unvested = grant.allocation > withdrawable ? grant.allocation - withdrawable : 0;

        // Transfer withdrawable amount to the claimant.
        if (!token.transfer(msg.sender, withdrawable)) {
            revert TransferFailed();
        }

        // Return any unvested bonus to the treasury.
        if (unvested > 0) {
            if (!token.transfer(hdTreasury, unvested)) {
                revert TreasuryTransferFailed();
            }
        }

        // Reset voting power to 0 and update delegatee’s history.
        if (grant.latestVotingPower > 0) {
            History.HistoricalBalances memory votingPower = _votingPower();
            uint256 delegateeVotes = votingPower.loadTop(grant.delegatee);
            votingPower.push(grant.delegatee, delegateeVotes - grant.latestVotingPower);
            emit VoteChange(grant.delegatee, msg.sender, -int256(uint256(grant.latestVotingPower)));
        }

        // Delete the grant to prevent further vesting or claims.
        delete _grants()[msg.sender];
    }

    /// @notice Calculates the current voting power of a grant.
    /// @dev Returns 0 before creation. For early migrators (pre-cliff), returns
    ///      the base amount until the cliff, then tracks the withdrawable
    ///      amount. For late migrators (post-cliff), returns 0 until creation,
    ///      then tracks the withdrawable amount (base immediately, plus vested
    ///      bonus).
    /// @param _grant The grant to check.
    /// @return The current voting power of the grant.
    function _currentVotingPower(VestingVaultStorage.Grant memory _grant)
        internal
        view
        override
        returns (uint256)
    {
        // No voting power before the grant is created.
        if (block.number < _grant.created) {
            return 0;
        }

        // Before the cliff (for early migrators), use the base amount set at
        // creation.
        if (block.number < _grant.cliff) {
            return _grant.latestVotingPower;
        }

        // After the cliff (or creation for late migrators), use the
        // withdrawable amount.
        return _getWithdrawableAmount(_grant);
    }

    /// @notice Calculates the amount of HD tokens withdrawable from a grant.
    /// @dev Returns 0 before the vesting start (cliff for early migrators,
    ///      creation for late migrators). For early migrators (pre-cliff), the
    ///      base unlocks at the cliff, and the 5% bonus vests linearly over 2
    ///      months. For late migrators (post-cliff), the base is immediately
    ///      withdrawable, and a reduced bonus vests linearly over the remaining
    ///      time to expiration.
    /// @param _grant The grant to check.
    /// @return The total withdrawable amount (base plus vested bonus, less any
    ///         prior withdrawals).
    function _getWithdrawableAmount(VestingVaultStorage.Grant memory _grant)
        internal
        view
        override
        returns (uint256)
    {
        // Nothing withdrawable before creation or before cliff for early migrators.
        if (block.number < _grant.created || (_grant.created < cliff && block.number < cliff)) {
            return 0;
        }

        // Calculate the effective bonus factor based on creation time.
        uint256 effectiveBonusFactor;
        if (_grant.created < cliff) {
            effectiveBonusFactor = BONUS_MULTIPLIER; // Full 5% bonus (10,500)
        } else {
            // For late migrators, scale bonus based on remaining blocks to expiration.
            uint256 blocksRemaining = _grant.expiration > _grant.created ? _grant.expiration - _grant.created : 0;
            uint256 bonusPeriod = _grant.expiration - cliff;
            effectiveBonusFactor = ONE + ((BONUS_MULTIPLIER - ONE) * blocksRemaining) / bonusPeriod;
        }

        // Derive the base amount using the effective bonus factor.
        uint256 baseAmount = (_grant.allocation * ONE) / effectiveBonusFactor;
        uint256 maxBonusAmount = _grant.allocation - baseAmount;

        // Return full allocation if past expiration.
        if (block.number >= _grant.expiration) {
            return _grant.allocation;
        }

        // Vesting starts at cliff for early migrators, creation for late migrators.
        uint256 vestingStart = _grant.created < cliff ? cliff : _grant.created;
        if (block.number < vestingStart) {
            return 0;
        }

        // Calculate vested bonus linearly from vesting start to expiration.
        uint256 blocksSinceVestingStart = block.number - vestingStart;
        uint256 vestingPeriod = _grant.expiration - vestingStart;
        uint256 vestedBonus = (maxBonusAmount * blocksSinceVestingStart) / vestingPeriod;

        // Clamp the result to allocation to handle rounding errors.
        uint256 withdrawable = baseAmount + vestedBonus;
        return withdrawable > _grant.allocation ? _grant.allocation : withdrawable;
    }
}
