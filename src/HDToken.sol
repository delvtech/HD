// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { AccessControl } from "openzeppelin/access/AccessControl.sol";
import { ERC20 } from "openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

contract HDToken is ERC20, ERC20Permit, AccessControl {
    /// @dev Thrown when an unauthorized account tries to mint or burn tokens.
    error Unauthorized();

    /// @dev Thrown when attempting to mint or burn zero tokens.
    error InvalidAmount();

    /// @dev Thrown when minting is not yet allowed
    error MintingNotAllowed();

    /// @dev Thrown when mint amount exceeds cap
    error MintCapExceeded();

    /// @dev The identifier for the minter role.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev The identifier for the burner role.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice The timestamp after which minting may occur
    uint256 public mintingAllowedAfter;

    /// @notice Minimum time between mints (1 year)
    uint256 public constant MINIMUM_TIME_BETWEEN_MINTS = 365 days;

    /// @notice Cap on the percentage of totalSupply that can be minted at each mint (2%)
    uint8 public constant MINT_CAP = 2;

    /// @dev Initial supply of tokens
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18; // 1 billion tokens

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _mintStartTimestamp
    ) ERC20(_name, _symbol) ERC20Permit(_name) {
        if (_mintStartTimestamp < block.timestamp) {
            revert("HDToken: minting can only begin after deployment");
        }

        // Set up role administration with deployer as default admin
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);

        mintingAllowedAfter = _mintStartTimestamp;

        // Mint initial supply to deployer
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @dev Mints new tokens to the specified address.
    /// @param _to The address receiving the minted tokens.
    /// @param _amount The amount of tokens to mint.
    function mint(
        address _to,
        uint256 _amount
    ) external onlyRole(MINTER_ROLE) {
        // Check timing restrictions
        if (block.timestamp < mintingAllowedAfter) {
            revert MintingNotAllowed();
        }

        // Check for valid amount
        if (_amount == 0) {
            revert InvalidAmount();
        }

        // Check mint cap
        if (_amount > (totalSupply() * MINT_CAP) / 100) {
            revert MintCapExceeded();
        }

        // Update timing restriction
        mintingAllowedAfter = block.timestamp + MINIMUM_TIME_BETWEEN_MINTS;

        // Perform mint operation
        _mint(_to, _amount);
    }

    /// @dev Burns tokens from the caller's balance.
    /// @param _amount The amount of tokens to burn.
    function burn(
        uint256 _amount
    ) external onlyRole(BURNER_ROLE) {
        // Check for valid amount
        if (_amount == 0) {
            revert InvalidAmount();
        }

        // Burn tokens from the caller's balance
        _burn(msg.sender, _amount);
    }
}
