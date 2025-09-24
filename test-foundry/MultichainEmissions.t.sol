// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {ZPXV2} from "contracts/ZPXV2.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

// This test simulates two chain contexts by deploying two proxy instances:
// Chain A: Origin - uses V1 then upgrades to V2 and performs crosschainBurn (simulating bridging out)
// Chain B: Destination - starts at V2 and performs crosschainMint (simulating bridging in)
contract MultichainEmissionsTest is Test {
    ZPXV1 internal implA;
    ZPXV1 internal tokenA; // proxy A
    ZPXV1 internal implBv1;
    ZPXV2 internal implBv2;
    ZPXV1 internal tokenBAsV1;
    ZPXV2 internal tokenB; // proxy B upgraded

    address internal admin = address(0xA11CE);
    address internal bridge = address(0xB123);
    address internal minter = address(0xBEEF);
    address internal pauser = address(0xCAFE);
    address internal rescuer = address(0xD00D); // legacy placeholder
    uint256 internal cap = 1_000_000 ether; // unused with current initializer but retained for reference

    function setUp() public {
        // Chain A deploy V1
        implA = new ZPXV1();
    address[] memory mintersA = new address[](1);
    mintersA[0] = minter;
    bytes memory dataA = abi.encodeCall(ZPXV1.initialize,(admin,mintersA,pauser));
        LocalERC1967Proxy proxyA = new LocalERC1967Proxy(address(implA), dataA);
        tokenA = ZPXV1(address(proxyA));

        // Mint on chain A
        vm.prank(minter);
        tokenA.mint(minter, 50_000 ether);

        // Chain B: Deploy V1 then upgrade to V2 with bridge
        implBv1 = new ZPXV1();
    address[] memory mintersB = new address[](1);
    mintersB[0] = minter;
    bytes memory dataB = abi.encodeCall(ZPXV1.initialize,(admin,mintersB,pauser));
        LocalERC1967Proxy proxyB = new LocalERC1967Proxy(address(implBv1), dataB);
        tokenBAsV1 = ZPXV1(address(proxyB));
        implBv2 = new ZPXV2();
        vm.prank(admin);
        (bool ok,) = address(tokenBAsV1).call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(implBv2),
                abi.encodeCall(ZPXV2.upgradeToSuperchainERC20, (bridge))
            )
        );
        require(ok, "upgrade B");
        tokenB = ZPXV2(address(tokenBAsV1));
    }

    function testBridgeMintBurnFlow() public {
        // Chain A: bridge burns tokens from minter (simulate sending to chain B)
        // First upgrade chain A to V2 so it has bridge hook
        ZPXV2 implA2 = new ZPXV2();
        vm.prank(admin);
        (bool ok2,) = address(tokenA).call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(implA2),
                abi.encodeCall(ZPXV2.upgradeToSuperchainERC20, (bridge))
            )
        );
        require(ok2, "upgrade A");
        ZPXV2 tokenAAsV2 = ZPXV2(address(tokenA));

        // Bridge role already granted in initializer; impersonate bridge
        vm.prank(bridge);
        tokenAAsV2.crosschainBurn(minter, 10_000 ether);

        // Chain B: Bridge mints equivalent amount to recipient
        vm.prank(bridge);
        tokenB.crosschainMint(minter, 10_000 ether);

        assertEq(tokenB.balanceOf(minter), 10_000 ether);
        assertEq(tokenA.balanceOf(minter), 40_000 ether);
        // Total supply across both chains stays within 50k (simplified model ignoring escrow)
        assertEq(tokenB.totalSupply() + tokenA.totalSupply(), 50_000 ether);
    }
}
