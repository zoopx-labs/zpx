// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {BaseZPXTest} from "./BaseZPXTest.t.sol";
import {ZPXV2} from "contracts/ZPXV2.sol";

contract ZPXV2UpgradeTest is BaseZPXTest {
    function setUp() public {
        deployV1(1_000_000 ether);
    }

    function testUpgradeAndBridgeConfig() public {
        ZPXV2 v2 = upgradeToV2(address(0xB123));
        assertEq(v2.superchainBridge(), address(0xB123));
    }

    function testBridgeMintBurn() public {
        ZPXV2 v2 = upgradeToV2(address(this));
        // grant bridge role done in initializer. prank as bridge (this)
        v2.crosschainMint(address(0xAABB), 10 ether);
        assertEq(v2.balanceOf(address(0xAABB)), 10 ether);
        v2.crosschainBurn(address(0xAABB), 5 ether);
        assertEq(v2.balanceOf(address(0xAABB)), 5 ether);
    }
}
