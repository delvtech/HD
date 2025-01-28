// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { HDToken } from "../src/HDToken.sol";

/// @dev This test suite provides coverage for the HDToken contract's functionality,
///      including role-based access control, minting, and burning operations.
contract HDTokenTest is Test {
    /// @dev Events to test
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev The deployed token contract
    HDToken internal token;

    /// @dev Test accounts
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal charlie;

    /// @notice Sets up the test environment with the following:
    ///         1. Create test accounts
    ///         2. Deploy HDToken
    ///         3. Start recording logs for event testing
    function setUp() public {
        // Create test accounts
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy token
        token = new HDToken("Test Token", "TEST");
    }

    // ==============================
    // Constructor Tests
    // ==============================

    /// @dev Ensures the constructor properly sets up the token with correct
    ///      name, symbol, and initial roles.
    function test_constructor() external view {
        assertEq(token.name(), "Test Token", "Token name not set correctly");
        assertEq(token.symbol(), "TEST", "Token symbol not set correctly");

        // Verify initial roles
        assertTrue(
            token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer),
            "Deployer not granted admin role"
        );
        assertTrue(
            token.hasRole(token.MINTER_ROLE(), deployer),
            "Deployer not granted minter role"
        );
        assertTrue(
            token.hasRole(token.BURNER_ROLE(), deployer),
            "Deployer not granted burner role"
        );
    }

    // ==============================
    // Minting Tests
    // ==============================

    /// @dev Ensures minting fails when attempted by non-minter account.
    function test_mint_failure_unauthorizedMinter() external {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                alice,
                token.MINTER_ROLE()
            )
        );
        token.mint(alice, 100e18);
    }

    /// @dev Ensures minting fails when attempting to mint zero tokens.
    function test_mint_failure_zeroAmount() external {
        vm.expectRevert(abi.encodeWithSelector(HDToken.InvalidAmount.selector));
        token.mint(alice, 0);
    }

    /// @dev Ensures successful minting operation by authorized minter.
    function test_mint_success() external {
        uint256 amount = 100e18;

        // Record state before mint
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(alice);

        // Expect the Transfer event before minting
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, amount);

        // Perform mint
        token.mint(alice, amount);

        // Verify state changes
        assertEq(
            token.totalSupply(),
            totalSupplyBefore + amount,
            "Total supply not updated correctly"
        );
        assertEq(
            token.balanceOf(alice),
            balanceBefore + amount,
            "Recipient balance not updated correctly"
        );
    }

    // ==============================
    // Burning Tests
    // ==============================

    /// @dev Ensures burning fails when attempted by non-burner account.
    function test_burn_failure_unauthorizedBurner() external {
        // First mint some tokens to alice
        token.mint(alice, 100e18);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                alice,
                token.BURNER_ROLE()
            )
        );
        token.burn(50e18);
    }

    /// @dev Ensures burning fails when attempting to burn zero tokens.
    function test_burn_failure_zeroAmount() external {
        vm.expectRevert(abi.encodeWithSelector(HDToken.InvalidAmount.selector));
        token.burn(0);
    }

    /// @dev Ensures burning fails when attempting to burn more tokens than owned.
    function test_burn_failure_insufficientBalance() external {
        // Mint tokens to deployer
        token.mint(deployer, 100e18);

        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                deployer,
                100e18,
                101e18
            )
        );
        token.burn(101e18);
    }

    /// @dev Ensures successful burning operation by authorized burner.
    function test_burn_success() external {
        uint256 mintAmount = 100e18;
        uint256 burnAmount = 60e18;

        // Setup: mint tokens to deployer
        token.mint(deployer, mintAmount);

        // Record state before burn
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(deployer);

        // Expect the Transfer event before burning
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, address(0), burnAmount);

        // Perform burn
        token.burn(burnAmount);

        // Verify state changes
        assertEq(
            token.totalSupply(),
            totalSupplyBefore - burnAmount,
            "Total supply not updated correctly"
        );
        assertEq(
            token.balanceOf(deployer),
            balanceBefore - burnAmount,
            "Burner balance not updated correctly"
        );
    }

    // ==============================
    // Role Management Tests
    // ==============================

    /// @dev Ensures role management fails when attempted by non-admin account.
    function test_grantRole_failure_unauthorizedAdmin() external {
        // Verify alice doesn't have admin role
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), alice));

        // Try to grant minter role to bob as alice (who is not an admin)
        vm.startPrank(alice);
        bytes32 minterRole = token.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                alice,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        token.grantRole(minterRole, bob);
    }

    /// @dev Ensures successful granting of roles by admin.
    function test_grantRole_success() external {
        // Expect the RoleGranted event before granting
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(token.MINTER_ROLE(), alice, deployer);

        // Grant minter role to alice
        token.grantRole(token.MINTER_ROLE(), alice);

        // Verify role assignment
        assertTrue(
            token.hasRole(token.MINTER_ROLE(), alice),
            "Role not granted successfully"
        );

        // Verify alice can now mint
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), bob, 100e18);
        token.mint(bob, 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100e18, "Minting with new role failed");
    }

    /// @dev Ensures successful revocation of roles by admin.
    function test_revokeRole_success() external {
        // First grant minter role to alice
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(token.MINTER_ROLE(), alice, deployer);
        token.grantRole(token.MINTER_ROLE(), alice);

        // Expect the RoleRevoked event before revoking
        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(token.MINTER_ROLE(), alice, deployer);

        // Then revoke it
        token.revokeRole(token.MINTER_ROLE(), alice);

        // Verify role removal
        assertFalse(
            token.hasRole(token.MINTER_ROLE(), alice),
            "Role not revoked successfully"
        );

        // Verify alice can no longer mint
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                alice,
                token.MINTER_ROLE()
            )
        );
        token.mint(bob, 100e18);
        vm.stopPrank();
    }

    /// @dev Tests role transfer scenario where admin transfers roles to new admin
    function test_transferAdmin_success() external {
        // Expect the RoleGranted event before granting admin role
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(token.DEFAULT_ADMIN_ROLE(), alice, deployer);

        // Transfer admin role to alice
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), alice);

        // Alice should now be able to grant roles
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(token.MINTER_ROLE(), bob, alice);
        token.grantRole(token.MINTER_ROLE(), bob);
        vm.stopPrank();

        // Verify bob received the role
        assertTrue(
            token.hasRole(token.MINTER_ROLE(), bob),
            "New admin couldn't grant role"
        );
    }
}
