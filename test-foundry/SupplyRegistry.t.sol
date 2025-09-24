// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {SupplyRegistry} from "contracts/SupplyRegistry.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

contract SupplyRegistryTest is Test {
    SupplyRegistry internal registry;
    address internal admin = address(0xA11CE);
    address internal recorder = address(0xBEEF);

    function setUp() public {
        SupplyRegistry impl = new SupplyRegistry();
        bytes memory data = abi.encodeCall(SupplyRegistry.initialize,(admin, recorder));
        LocalERC1967Proxy proxy = new LocalERC1967Proxy(address(impl), data);
        registry = SupplyRegistry(address(proxy));
    }

    function testRecordNativeMint() public {
        vm.prank(recorder);
        registry.recordNativeMint(1_000 ether);
        assertEq(registry.nativeCirculating(), 1_000 ether);
    }

    function testRecordRemoteEmission() public {
        vm.startPrank(recorder);
        registry.recordRemoteEmission(500 ether);
        registry.recordRemoteEmission(250 ether);
        vm.stopPrank();
        assertEq(registry.remoteRecognized(), 750 ether);
        assertEq(registry.totalMarketSupply(), 750 ether);
    }

    function testBridgeLifecycle() public {
        vm.startPrank(recorder);
        registry.recordBridgeBurn(2_000 ether);
        assertEq(registry.bridgePending(), 2_000 ether);
        registry.recordBridgeMint(500 ether);
        assertEq(registry.bridgePending(), 1_500 ether);
        vm.expectRevert(SupplyRegistry.InsufficientPending.selector);
        registry.recordBridgeMint(2_000 ether);
        vm.stopPrank();
    }

    function testBurnReconciliation() public {
        vm.startPrank(recorder);
        registry.recordNativeMint(5_000 ether);
        registry.recordNativeBurnReconciliation(2_000 ether, "remote_reconcile:42161");
        vm.stopPrank();
        assertEq(registry.nativeCirculating(), 3_000 ether);
    }

    function testVestingLocked() public {
        vm.prank(recorder);
        registry.updateVestingLocked(42_000 ether);
        assertEq(registry.vestingLocked(), 42_000 ether);
        assertEq(registry.fdvSupply(), registry.totalMarketSupply() + 42_000 ether);
    }

    function testSnapshotEmits() public {
        vm.startPrank(recorder);
        registry.recordNativeMint(100 ether);
        registry.recordRemoteEmission(50 ether);
        registry.updateVestingLocked(20 ether);
        registry.recordBridgeBurn(10 ether);
        registry.snapshot();
        vm.stopPrank();
    }

    function testRevertsNotPositive() public {
        vm.prank(recorder);
        vm.expectRevert(SupplyRegistry.NotPositive.selector);
        registry.recordNativeMint(0);
    }

    function testVestingLockedSecondUpdateDownward() public {
        vm.prank(recorder);
        registry.updateVestingLocked(1000 ether);
        vm.prank(recorder);
        registry.updateVestingLocked(400 ether);
        assertEq(registry.vestingLocked(), 400 ether);
    }

    function testBridgeExactSettlementPath() public {
        vm.startPrank(recorder);
        registry.recordBridgeBurn(750 ether);
        registry.recordBridgeMint(750 ether); // should settle to zero
        assertEq(registry.bridgePending(), 0);
        vm.stopPrank();
    }

    function testMultipleBridgePendingAndPartialSettlements() public {
        vm.startPrank(recorder);
        registry.recordBridgeBurn(500 ether);
        registry.recordBridgeBurn(300 ether); // total 800 pending
        registry.recordBridgeMint(200 ether); // 600 left
        registry.recordBridgeMint(100 ether); // 500 left
        assertEq(registry.bridgePending(), 500 ether);
        vm.stopPrank();
    }

    function testZeroAmountRevertsAllRecorders() public {
        vm.startPrank(recorder);
        vm.expectRevert(SupplyRegistry.NotPositive.selector);
        registry.recordRemoteEmission(0);
        vm.expectRevert(SupplyRegistry.NotPositive.selector);
        registry.recordNativeMint(0);
        vm.expectRevert(SupplyRegistry.NotPositive.selector);
        registry.recordBridgeBurn(0);
        vm.expectRevert(SupplyRegistry.NotPositive.selector);
        registry.recordBridgeMint(0);
        vm.stopPrank();
    }

    function testNativeBurnReconciliationBeforeAnyMintUnderflowReverts() public {
        vm.prank(recorder);
        // NativeBurnReconciliation with amount > current (0) will underflow and revert automatically.
        vm.expectRevert();
        registry.recordNativeBurnReconciliation(1 ether, "underflow");
    }
}

contract SupplyRegistryInitializeZeroAddrTest is Test {
    function testInitializeZeroAdminReverts() public {
        SupplyRegistry impl = new SupplyRegistry();
        bytes memory data = abi.encodeCall(SupplyRegistry.initialize,(address(0), address(0xBEEF)));
        vm.expectRevert(SupplyRegistry.ZeroAddress.selector);
        new LocalERC1967Proxy(address(impl), data);
    }

    function testInitializeZeroRecorderReverts() public {
        SupplyRegistry impl = new SupplyRegistry();
        bytes memory data = abi.encodeCall(SupplyRegistry.initialize,(address(0xA11CE), address(0)));
        vm.expectRevert(SupplyRegistry.ZeroAddress.selector);
        new LocalERC1967Proxy(address(impl), data);
    }
}
