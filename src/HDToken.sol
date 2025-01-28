// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { AccessControl } from "openzeppelin/access/AccessControl.sol";
import { ERC20 } from "openzeppelin/token/ERC20/ERC20.sol";

/// @author DELV
/// @title HDToken
/// @notice ERC-20 token with mint/burn functionality and role-based access control
/// @custom:disclaimer The language used in this code is for coding convenience
///                    only, and is not intended to, and does not, have any
///                    particular legal or regulatory significance.
contract HDToken is ERC20, AccessControl {
    /// @dev Thrown when an unauthorized account tries to mint or burn tokens.
    error Unauthorized();

    /// @dev Thrown when attempting to mint or burn zero tokens.
    error InvalidAmount();

    /// @dev The identifier for the minter role.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev The identifier for the burner role.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @dev Initializes the token contract.
    /// @param _name The name of the token.
    /// @param _symbol The symbol of the token.
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        // Set up role administration with deployer as default admin
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
    }

    /// @dev Mints new tokens to the specified address.
    /// @param _to The address receiving the minted tokens.
    /// @param _amount The amount of tokens to mint.
    function mint(
        address _to,
        uint256 _amount
    ) external onlyRole(MINTER_ROLE) {
        // Check for valid amount.
        if (_amount == 0) {
            revert InvalidAmount();
        }

        // Perform mint operation.
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
