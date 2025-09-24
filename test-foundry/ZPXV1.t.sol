// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {BaseZPXTest} from "./BaseZPXTest.t.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ZPXV1UnitTest is BaseZPXTest {
    function setUp() public {
        deployV1(0);
    }

    function testMetadata() public {
        assertEq(token.name(), "ZoopX");
        assertEq(token.symbol(), "ZPX");
    }

    function testRoles() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        assertTrue(token.hasRole(adminRole, admin));
    }

    function testMintWithinCap() public {
        vm.prank(minter);
        token.mint(minter, 100 ether);
        assertEq(token.balanceOf(minter), 100 ether);
    }

    function testCannotExceedCap() public {
        uint256 cap = token.TOTAL_SUPPLY_CAP();
        vm.startPrank(minter);
        // Mint up to cap - 50
        token.mint(minter, cap - 50);
        // Next mint that would exceed by 100 should revert
        vm.expectRevert();
        token.mint(minter, 100);
        vm.stopPrank();
    }

    function testPauseBlocksMint() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(minter);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.mint(minter, 1 ether);
    }

    function testMintBatchAndCap() public {
        vm.startPrank(minter);
        address[] memory tos = new address[](3);
        uint256[] memory amts = new uint256[](3);
        tos[0] = address(0x1); tos[1] = address(0x2); tos[2] = address(0x3);
        amts[0] = 10 ether; amts[1] = 20 ether; amts[2] = 30 ether;
        token.mintBatch(tos, amts);
        assertEq(token.balanceOf(address(0x1)), 10 ether);
        assertEq(token.balanceOf(address(0x2)), 20 ether);
        assertEq(token.balanceOf(address(0x3)), 30 ether);
        vm.stopPrank();
    }

    function testMintBatchLengthMismatchReverts() public {
        vm.prank(minter);
        address[] memory tos = new address[](2);
        uint256[] memory amts = new uint256[](1);
        tos[0] = address(0x1); tos[1] = address(0x2);
        amts[0] = 1 ether;
        vm.expectRevert(ZPXV1.LengthMismatch.selector);
        token.mintBatch(tos, amts);
    }

    function testBurnFromConsumesAllowance() public {
        vm.prank(minter);
        token.mint(address(this), 5 ether);
        // approve helper contract (self) to burn via different address
        address burner = address(0xB0B);
        vm.prank(address(this));
        token.approve(burner, 3 ether);
        vm.prank(burner);
        token.burnFrom(address(this), 2 ether);
        assertEq(token.allowance(address(this), burner), 1 ether);
        assertEq(token.balanceOf(address(this)), 3 ether);
    }

    function testRescueCannotRescueSelf() public {
        vm.prank(admin);
        vm.expectRevert(ZPXV1.CannotRescueSelf.selector);
        token.rescueERC20(address(token), admin, 1);
    }

    function testRescueTransfersOtherToken() public {
        // deploy a dummy ERC20 minimal for test
        DummyERC20 other = new DummyERC20();
        other.mint(address(token), 100);
        vm.prank(admin);
        token.rescueERC20(address(other), admin, 40);
        assertEq(other.balanceOf(admin), 40);
    }

    function testCannotReinitialize() public {
        address[] memory none = new address[](0);
        vm.expectRevert();
        token.initialize(admin, none, pauser);
    }

    function testPauseBlocksTransfer() public {
        vm.prank(minter);
        token.mint(address(this), 2 ether);
        vm.prank(pauser);
        token.pause();
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transfer(address(0x123), 1 ether);
    }

    function testMintZeroAddressReverts() public {
        vm.prank(minter);
        vm.expectRevert(ZPXV1.ZeroAddress.selector);
        token.mint(address(0), 1);
    }

    function testMintBatchIncludesZeroAddressReverts() public {
        vm.prank(minter);
        address[] memory tos = new address[](2);
        uint256[] memory amts = new uint256[](2);
        tos[0] = address(0x1);
        tos[1] = address(0); // zero
        amts[0] = 1 ether; amts[1] = 2 ether;
        vm.expectRevert(ZPXV1.ZeroAddress.selector);
        token.mintBatch(tos, amts);
    }

    function testMintBatchExceedsCapReverts() public {
        uint256 cap = token.TOTAL_SUPPLY_CAP();
        // mint up to cap - 10
        vm.prank(minter);
        token.mint(minter, cap - 10);
        vm.prank(minter);
        address[] memory tos = new address[](1);
        uint256[] memory amts = new uint256[](1);
        tos[0] = address(0x2);
        amts[0] = 20; // pushes over by 10
        vm.expectRevert();
        token.mintBatch(tos, amts);
    }

    function testRescueZeroRecipientReverts() public {
        // deploy dummy token
        DummyERC20 other = new DummyERC20();
        other.mint(address(token), 10);
        vm.prank(admin);
        vm.expectRevert(ZPXV1.ZeroAddress.selector);
        token.rescueERC20(address(other), address(0), 1);
    }

    function testBurnFromInsufficientAllowanceReverts() public {
        vm.prank(minter);
        token.mint(address(this), 5 ether);
        // approve only 1 ether
        token.approve(address(0xB0B), 1 ether);
        vm.prank(address(0xB0B));
        vm.expectRevert();
        token.burnFrom(address(this), 2 ether);
    }

    function testBurnFromAllowanceExhaustionExactly() public {
        vm.prank(minter);
        token.mint(address(this), 5 ether);
        token.approve(address(0xB0B), 3 ether);
        vm.prank(address(0xB0B));
        token.burnFrom(address(this), 3 ether); // should succeed and allowance to 0
        assertEq(token.allowance(address(this), address(0xB0B)), 0);
    }
}

// Minimal dummy token for rescue test
contract DummyERC20 is ERC20Upgradeable {
    constructor() {
        _disableInitializers();
    }
    function initialize() external initializer {
        __ERC20_init("Dummy", "DUM");
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
