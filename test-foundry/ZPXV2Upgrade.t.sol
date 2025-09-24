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
        // bridge role granted to this contract via upgrade initializer
        v2.crosschainMint(address(0xAABB), 10 ether);
        assertEq(v2.balanceOf(address(0xAABB)), 10 ether);
        v2.crosschainBurn(address(0xAABB), 5 ether);
        assertEq(v2.balanceOf(address(0xAABB)), 5 ether);
    }

    function testBridgeUnauthorizedReverts() public {
        ZPXV2 v2 = upgradeToV2(address(0xB123));
        vm.expectRevert();
        v2.crosschainMint(address(0x1), 1 ether); // caller not bridge
        vm.expectRevert();
        v2.crosschainBurn(address(0x1), 1 ether);
    }

    function testBridgePauseBlocksOps() public {
        ZPXV2 v2 = upgradeToV2(address(this));
        vm.prank(pauser);
        v2.pause();
        vm.expectRevert();
        v2.crosschainMint(address(0x2), 1 ether);
        vm.expectRevert();
        v2.crosschainBurn(address(0x2), 1 ether);
    }

    function testCapEnforcedBridgeMint() public {
        // Deploy fresh with small cap by minting near cap first then upgrading
        // Original deployV1 invoked with 1_000_000 ether cap param (unused). We'll simulate by minting up to cap - 5.
        ZPXV2 v2 = upgradeToV2(address(this));
        uint256 cap = v2.TOTAL_SUPPLY_CAP();
        // grant minter role already holds? minter holds MINTER_ROLE from V1
        vm.prank(minter);
        v2.mint(minter, cap - 5);
        vm.expectRevert(); // cap exceeded on bridge mint 10
        v2.crosschainMint(address(0x9), 10);
    }

    function testReinitializerGuard() public {
        ZPXV2 v2 = upgradeToV2(address(this));
        vm.expectRevert();
        v2.upgradeToSuperchainERC20(address(0x1234));
    }

    function testZeroBridgeReverts() public {
        ZPXV2 implementation = new ZPXV2();
        vm.prank(admin);
        // upgrade to v2 first time with zero bridge should revert in initializer
        (bool ok, ) = address(token).call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(implementation),
                abi.encodeCall(ZPXV2.upgradeToSuperchainERC20, (address(0)))
            )
        );
        assertTrue(!ok, "zero bridge should revert");
    }

    function testBridgeEvents() public {
        ZPXV2 v2 = upgradeToV2(address(this));
        vm.expectEmit(true, false, false, true);
        emit ZPXV2.CrosschainMint(address(0x44), 7 ether);
        v2.crosschainMint(address(0x44), 7 ether);
        vm.expectEmit(true, false, false, true);
        emit ZPXV2.CrosschainBurn(address(0x44), 2 ether);
        v2.crosschainBurn(address(0x44), 2 ether);
    }

    function testBridgeMintZeroRecipientReverts() public {
        ZPXV2 v2 = upgradeToV2(address(this));
        vm.expectRevert(bytes("ZPXV2: zero recipient"));
        v2.crosschainMint(address(0), 1);
    }
}
