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
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev The deployed token contract
    HDToken internal token;

    /// @dev Test accounts
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal charlie;

    /// @dev Initial mint start timestamp
    uint256 internal mintStartTime;

    /// @notice Sets up the test environment with the following:
    ///         1. Create test accounts
    ///         2. Set initial mint start time
    ///         3. Deploy HDToken
    function setUp() public {
        // Create test accounts
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Set mint start time to 1 day from now
        mintStartTime = block.timestamp + 1 days;

        // Deploy token
        token = new HDToken("Test Token", "TEST", mintStartTime);
    }

    // ==============================
    // Constructor Tests
    // ==============================

    /// @dev Ensures the constructor properly sets up the token
    function test_constructor() external view {
        assertEq(token.name(), "Test Token", "Token name not set correctly");
        assertEq(token.symbol(), "TEST", "Token symbol not set correctly");
        assertEq(token.mintingAllowedAfter(), mintStartTime, "Minting start time not set correctly");
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY(), "Initial supply not minted");
        assertEq(token.balanceOf(deployer), token.INITIAL_SUPPLY(), "Initial supply not allocated to deployer");

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

    /// @dev Ensures constructor reverts if mint start time is in the past
    function test_constructor_failure_invalidStartTime() external {
        vm.expectRevert("HDToken: minting can only begin after deployment");
        new HDToken("Test Token", "TEST", block.timestamp - 1);
    }

    // ==============================
    // Minting Tests
    // ==============================

    /// @dev Ensures minting fails when attempted by non-minter account
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
        vm.stopPrank();
    }

    /// @dev Ensures minting fails when attempting to mint zero tokens
    function test_mint_failure_zeroAmount() external {
        vm.warp(mintStartTime);
        vm.expectRevert(abi.encodeWithSelector(HDToken.InvalidAmount.selector));
        token.mint(alice, 0);
    }

    /// @dev Ensures minting fails when attempted before allowed time
    function test_mint_failure_beforeAllowedTime() external {
        vm.expectRevert(abi.encodeWithSelector(HDToken.MintingNotAllowed.selector));
        token.mint(alice, 100e18);
    }

    /// @dev Ensures minting fails when attempting to mint more than the cap
    function test_mint_failure_exceedsCap() external {
        vm.warp(mintStartTime);

        // Try to mint more than 2% of total supply
        uint256 maxMint = (token.totalSupply() * token.MINT_CAP()) / 100;
        vm.expectRevert(abi.encodeWithSelector(HDToken.MintCapExceeded.selector));
        token.mint(alice, maxMint + 1);
    }

    /// @dev Ensures successful minting operation by authorized minter
    function test_mint_success() external {
        vm.warp(mintStartTime);
        // Calculate valid mint amount (2% of total supply)
        uint256 amount = (token.totalSupply() * token.MINT_CAP()) / 100;

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
        assertEq(
            token.mintingAllowedAfter(),
            mintStartTime + token.MINIMUM_TIME_BETWEEN_MINTS(),
            "Next mint time not updated correctly"
        );
    }

    /// @dev Ensures minting respects the time delay between mints
    function test_mint_success_respectsTimeDelay() external {
        uint256 validAmount = (token.totalSupply() * token.MINT_CAP()) / 100;

        // First mint
        vm.warp(mintStartTime);
        token.mint(alice, validAmount);

        // Try to mint before delay is over
        vm.expectRevert(abi.encodeWithSelector(HDToken.MintingNotAllowed.selector));
        token.mint(alice, validAmount);

        // Mint after delay
        vm.warp(mintStartTime + token.MINIMUM_TIME_BETWEEN_MINTS());
        token.mint(alice, validAmount);
    }

    // ==============================
    // Burning Tests
    // ==============================

    /// @dev Ensures burning fails when attempted by non-burner account
    function test_burn_failure_unauthorizedBurner() external {
        // First mint some tokens to alice
        vm.warp(mintStartTime);
        token.mint(alice, 100e18);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                alice,
                token.BURNER_ROLE()
            )
        );
        token.burn(alice, 50e18);
        vm.stopPrank();
    }

    /// @dev Ensures burning fails when attempting to burn zero tokens
    function test_burn_failure_zeroAmount() external {
        vm.expectRevert(abi.encodeWithSelector(HDToken.InvalidAmount.selector));
        token.burn(alice, 0);
    }

    /// @dev Ensures burning fails when attempting to burn more tokens than owned
    function test_burn_failure_insufficientBalance() external {
        // The amount of tokens to burn.
        uint256 amountToBurn = 101e18;

        // Grant the burner role to Alice.
        token.grantRole(token.BURNER_ROLE(), alice);

        // Mint tokens to Alice to ensure that she has something to burn.
        vm.warp(mintStartTime);
        token.mint(alice, 100e18);

        // Alice fails to burn her tokens.
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                alice,
                100e18,
                amountToBurn
            )
        );
        token.burn(alice, amountToBurn);
    }

    /// @dev Ensures successful burning operation by authorized burner
    function test_burn_success() external {
        // Setup: mint tokens to alice.
        vm.warp(mintStartTime);
        uint256 mintAmount = 100e18;
        uint256 burnAmount = 60e18;
        token.mint(alice, mintAmount);

        // Record state before burn
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(alice);

        // Expect the Transfer event before burning
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), burnAmount);

        // The deployer burns tokens from alice.
        token.burn(alice, burnAmount);

        // Verify state changes
        assertEq(
            token.totalSupply(),
            totalSupplyBefore - burnAmount,
            "Total supply not updated correctly"
        );
        assertEq(
            token.balanceOf(alice),
            balanceBefore - burnAmount,
            "Alice balance not updated correctly"
        );
    }

    // ==============================
    // Role Management Tests
    // ==============================

    /// @dev Ensures role management fails when attempted by non-admin account.
    function test_grantRole_failure_unauthorizedAdmin() external {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.startPrank(alice);
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
        vm.warp(mintStartTime);
        uint256 validAmount = (token.totalSupply() * token.MINT_CAP()) / 100;

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), bob, validAmount);
        token.mint(bob, validAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), validAmount, "Minting with new role failed");
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
