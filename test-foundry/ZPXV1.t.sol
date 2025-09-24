// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {BaseZPXTest} from "./BaseZPXTest.t.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";

contract ZPXV1UnitTest is BaseZPXTest {
    function setUp() public {
        deployV1(1_000_000 ether);
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
        vm.startPrank(minter);
        token.mint(minter, 1_000_000 ether);
        vm.expectRevert();
        token.mint(minter, 1 ether); // exceed
        vm.stopPrank();
    }

    function testPauseBlocksMint() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(minter);
        vm.expectRevert();
        token.mint(minter, 1 ether);
    }
}
