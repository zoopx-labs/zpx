// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {EmissionsManager, IZPX} from "contracts/Emissions/EmissionsManager.sol";
import {RewardsDistributor} from "contracts/Emissions/RewardsDistributor.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {SupplyRegistry} from "contracts/SupplyRegistry.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

contract EmissionsManagerTest is Test {
    EmissionsManager internal manager;
    SupplyRegistry internal registry;
    ZPXV1 internal token;
    address internal admin = address(0xA11CE);
    address internal emitter = address(0xEeeE);
    address internal scheduler = address(0x500D);
    address internal pauser = address(0xAAA0);
    address internal user = address(0xBEEF);

    function setUp() external {
        // Token proxy
        ZPXV1 impl = new ZPXV1();
        bytes memory initData = abi.encodeWithSelector(ZPXV1.initialize.selector, admin, new address[](0), pauser);
        LocalERC1967Proxy proxy = new LocalERC1967Proxy(address(impl), initData);
        token = ZPXV1(address(proxy));

        // Registry proxy
        SupplyRegistry regImpl = new SupplyRegistry();
        bytes memory regInit = abi.encodeWithSelector(SupplyRegistry.initialize.selector, admin, admin);
        LocalERC1967Proxy regProxy = new LocalERC1967Proxy(address(regImpl), regInit);
        registry = SupplyRegistry(address(regProxy));

        // EmissionsManager proxy
        EmissionsManager manImpl = new EmissionsManager();
        bytes memory manInit = abi.encodeWithSelector(EmissionsManager.initialize.selector, admin, address(token), address(registry));
        LocalERC1967Proxy manProxy = new LocalERC1967Proxy(address(manImpl), manInit);
        manager = EmissionsManager(address(manProxy));

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(manager));
    registry.grantRole(registry.RECORDER_ROLE(), address(manager));
        manager.grantRole(manager.SCHEDULER_ROLE(), scheduler);
        manager.grantRole(manager.EMITTER_ROLE(), emitter);
        manager.grantRole(manager.PAUSER_ROLE(), pauser);
        manager.grantRole(manager.EMITTER_ROLE(), admin);
        manager.grantRole(manager.SCHEDULER_ROLE(), admin);
        vm.stopPrank();
    }

    function _warpTo(uint256 t) internal {
        vm.warp(t);
    }

    function testScheduleAndEmitSingle() external {
        uint64 start = uint64(block.timestamp + 100);
        uint64 end = start + 1 days;
    vm.prank(scheduler);
    manager.scheduleEpoch(start, end, 1_000 ether);

        // Active only after start
        vm.warp(start + 1);
    vm.prank(emitter);
    manager.emitTo(user, 100 ether);
        assertEq(token.balanceOf(user), 100 ether);
    }

    function testOverlapRevert() external {
        uint64 start = uint64(block.timestamp + 50);
        uint64 end = start + 10;
    vm.prank(scheduler);
    manager.scheduleEpoch(start, end, 10 ether);

    vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.Overlap.selector);
        manager.scheduleEpoch(start + 5, end + 100, 20 ether);
    }

    function testOverBudgetRevert() external {
        uint64 start = uint64(block.timestamp + 10);
        uint64 end = start + 100;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 50 ether);
        vm.warp(start + 1);
        vm.startPrank(emitter);
        manager.emitTo(user, 40 ether);
        vm.expectRevert(EmissionsManager.BudgetExceeded.selector);
        manager.emitTo(user, 11 ether); // 40 + 11 > 50
        vm.stopPrank();
    }

    function testFinalizeEarly() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 100;
    vm.prank(scheduler);
    manager.scheduleEpoch(start, end, 500 ether);
        vm.warp(start + 1);
    vm.prank(emitter);
    manager.emitTo(user, 100 ether);
    vm.prank(scheduler);
    manager.finalizeEpoch(1);
    vm.prank(emitter);
        vm.expectRevert(EmissionsManager.EpochNotActive.selector);
        manager.emitTo(user, 1 ether);
    }

    function testPauseUnpause() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 50;
    vm.prank(scheduler);
    manager.scheduleEpoch(start, end, 100 ether);
        vm.warp(start + 1);
        vm.prank(pauser);
        manager.pause();
    vm.prank(emitter);
    vm.expectRevert();
    manager.emitTo(user, 1 ether);
        vm.prank(pauser);
        manager.unpause();
    vm.prank(emitter);
    manager.emitTo(user, 1 ether);
        assertEq(token.balanceOf(user), 1 ether);
    }

    function testEmitBatch() external {
        uint64 start = uint64(block.timestamp + 10);
        uint64 end = start + 100;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 300 ether);
        vm.warp(start + 1);
        address[] memory tos = new address[](3);
        uint256[] memory amts = new uint256[](3);
        tos[0] = address(0x100); tos[1] = address(0x101); tos[2] = address(0x102);
        amts[0] = 50 ether; amts[1] = 60 ether; amts[2] = 70 ether;
        vm.prank(emitter);
        manager.emitBatch(tos, amts);
        assertEq(token.balanceOf(tos[0]), 50 ether);
        assertEq(token.balanceOf(tos[1]), 60 ether);
        assertEq(token.balanceOf(tos[2]), 70 ether);
    }

    function testEmitBatchLengthMismatchReverts() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 20;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 50 ether);
        vm.warp(start + 1);
        address[] memory tos = new address[](2);
        uint256[] memory amts = new uint256[](1);
        tos[0] = address(0xABCD); tos[1] = address(0xABCE);
        amts[0] = 10 ether;
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.LengthMismatch.selector);
        manager.emitBatch(tos, amts);
    }

    function testEmitToDistributorAndRegistry() external {
        // Deploy a distributor
    RewardsDistributor distImpl = new RewardsDistributor();
    bytes memory init = abi.encodeWithSelector(RewardsDistributor.initialize.selector, admin, address(token), address(registry));
        LocalERC1967Proxy p = new LocalERC1967Proxy(address(distImpl), init);
        RewardsDistributor dist = RewardsDistributor(address(p));
        // schedule epoch
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 50;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 40 ether);
        vm.warp(start + 1);
        uint256 beforeNative = registry.nativeCirculating();
        vm.prank(emitter);
        manager.emitToDistributor(address(dist), 25 ether);
        assertEq(token.balanceOf(address(dist)), 25 ether);
        assertEq(registry.nativeCirculating(), beforeNative + 25 ether);
    }

    function testIncreaseEpochBudget() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 40;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        vm.prank(scheduler);
        manager.increaseEpochBudget(1, 5 ether);
        vm.warp(start + 1);
        vm.prank(emitter);
        manager.emitTo(user, 14 ether); // within 15 total
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.BudgetExceeded.selector);
        manager.emitTo(user, 2 ether);
    }

    function testScheduleStartInPastReverts() external {
        uint64 start = uint64(block.timestamp - 1);
        vm.prank(scheduler);
        vm.expectRevert();
        manager.scheduleEpoch(start, start + 10, 10 ether);
    }

    function testFinalizeAlreadyFinalReverts() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 20;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 5 ether);
        vm.warp(start + 1);
        vm.prank(scheduler);
        manager.finalizeEpoch(1);
        vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.AlreadyFinal.selector);
        manager.finalizeEpoch(1);
    }

    function testRoleRestrictions() external {
        // non-scheduler cannot schedule
        vm.expectRevert();
        manager.scheduleEpoch(uint64(block.timestamp + 100), uint64(block.timestamp + 200), 1 ether);
        // grant minimal epoch and test non-emitter cannot emit
        uint64 start = uint64(block.timestamp + 10);
        uint64 end = start + 50;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 2 ether);
        vm.warp(start + 1);
        vm.expectRevert();
        manager.emitTo(user, 1 ether); // msg.sender is this test contract without EMITTER_ROLE
    }

    function testActiveEpochIdZeroWhenNone() external {
        // no epochs scheduled yet
        assertEq(manager.activeEpochId(), 0);
    }

    function testEmitAfterEpochEndReverts() external {
        uint64 start = uint64(block.timestamp + 2);
        uint64 end = start + 5;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        vm.warp(end + 1); // after epoch end
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.EpochNotActive.selector);
        manager.emitTo(user, 1 ether);
    }

    function testFinalizeAfterNaturalEndEmitsZeroUnused() external {
        uint64 start = uint64(block.timestamp + 2);
        uint64 end = start + 5;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        vm.warp(start + 1);
        vm.prank(emitter);
        manager.emitTo(user, 3 ether);
        vm.warp(end + 10); // past end
        vm.expectEmit();
        emit EmissionsManager.EpochFinalized(1, 0); // unused should be zero because finalized after end uses 0 logic
        vm.prank(scheduler);
        manager.finalizeEpoch(1);
    }

    function testIncreaseEpochBudgetNoOpAdditionalZero() external {
        uint64 start = uint64(block.timestamp + 2);
        uint64 end = start + 5;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        // capture gas maybe; just ensure state unchanged
        (, , uint128 beforeBudget, , ) = manager.epochs(1);
        vm.prank(scheduler);
        manager.increaseEpochBudget(1, 0); // no-op
        (, , uint128 afterBudget, , ) = manager.epochs(1);
        assertEq(beforeBudget, afterBudget);
    }

    function testFinalizeBeforeStartReverts() external {
        uint64 start = uint64(block.timestamp + 50);
        uint64 end = start + 100;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 20 ether);
        vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.NotStarted.selector);
        manager.finalizeEpoch(1);
    }

    function testEmitToDistributorZeroAddressReverts() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 10;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 5 ether);
        vm.warp(start + 1);
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.ZeroAddress.selector);
        manager.emitToDistributor(address(0), 1 ether);
    }

    function testFinalizeAlreadyFinalAfterEndReverts() external {
        uint64 start = uint64(block.timestamp + 2);
        uint64 end = start + 4;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 5 ether);
        vm.warp(end + 1);
        vm.prank(scheduler);
        manager.finalizeEpoch(1); // first finalize after end
        vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.AlreadyFinal.selector);
        manager.finalizeEpoch(1);
    }

    function testScheduleInvalidEndLteStartReverts() external {
        uint64 start = uint64(block.timestamp + 10);
        uint64 end = start; // equal
        vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.InvalidTime.selector);
        manager.scheduleEpoch(start, end, 10 ether);
    }

    function testScheduleInvalidZeroBudgetReverts() external {
        uint64 start = uint64(block.timestamp + 10);
        uint64 end = start + 100;
        vm.prank(scheduler);
        vm.expectRevert(EmissionsManager.InvalidTime.selector);
        manager.scheduleEpoch(start, end, 0);
    }

    function testEmitBeforeStartReverts() external {
        uint64 start = uint64(block.timestamp + 30);
        uint64 end = start + 60;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 50 ether);
        vm.warp(start - 1); // before start
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.EpochNotActive.selector);
        manager.emitTo(user, 1 ether);
    }

    function testEpochRemainingVariants() external {
        // schedule epoch
        uint64 start = uint64(block.timestamp + 20);
        uint64 end = start + 40;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 25 ether);
        // before start -> remaining = 0
        assertEq(manager.epochRemaining(1), 0);
        vm.warp(start + 1);
        vm.prank(emitter);
        manager.emitTo(user, 5 ether);
        uint256 remMid = manager.epochRemaining(1);
        assertEq(remMid, 20 ether);
        vm.prank(scheduler);
        manager.finalizeEpoch(1);
        assertEq(manager.epochRemaining(1), 0); // finalized
        vm.warp(end + 1);
        assertEq(manager.epochRemaining(1), 0); // after end
    }

    // --- Additional branch tests ---

    function testIncreaseEpochBudgetNotEpochReverts() external {
        // no epochs scheduled yet -> id 1 is nonexistent
        vm.expectRevert(EmissionsManager.NotEpoch.selector);
        vm.prank(scheduler);
        manager.increaseEpochBudget(1, 10 ether);
    }

    function testFinalizeEpochNotEpochReverts() external {
        vm.expectRevert(EmissionsManager.NotEpoch.selector);
        vm.prank(scheduler);
        manager.finalizeEpoch(99);
    }

    function testEmitToWithoutAnyEpochsReverts() external {
        vm.prank(emitter);
        vm.expectRevert(EmissionsManager.EpochNotActive.selector);
        manager.emitTo(user, 1 ether);
    }

    function testEpochRemainingNonexistentIdReturnsZero() external {
        assertEq(manager.epochRemaining(12345), 0);
    }

    function testActiveEpochIdAfterFinalizeReturnsZero() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 30;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        vm.warp(start + 1);
        vm.prank(scheduler);
        manager.finalizeEpoch(1);
        assertEq(manager.activeEpochId(), 0);
    }

    function testActiveEpochIdAfterNaturalEndReturnsZero() external {
        uint64 start = uint64(block.timestamp + 5);
        uint64 end = start + 10;
        vm.prank(scheduler);
        manager.scheduleEpoch(start, end, 10 ether);
        vm.warp(end + 1); // after end without finalize
        assertEq(manager.activeEpochId(), 0);
    }
}
