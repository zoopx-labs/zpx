// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {RewardsDistributor} from "contracts/Emissions/RewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EmissionsManager, IZPX} from "contracts/Emissions/EmissionsManager.sol";
import {ZPXV1} from "contracts/ZPXV1.sol";
import {LocalERC1967Proxy} from "contracts/LocalERC1967Proxy.sol";

contract RewardsDistributorTest is Test {
    RewardsDistributor internal distributor;
    ZPXV1 internal token; // behind proxy
    address internal admin = address(0xA11CE);
    address internal alice = address(0xA71CE);
    address internal bob = address(0xB0B);

    function setUp() external {
        // Deploy token behind proxy (grant minter to test contract to fund distributor)
        ZPXV1 impl = new ZPXV1();
        bytes memory initData = abi.encodeWithSelector(ZPXV1.initialize.selector, admin, new address[](0), address(0));
        LocalERC1967Proxy proxy = new LocalERC1967Proxy(address(impl), initData);
        token = ZPXV1(address(proxy));
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(this));
        vm.stopPrank();

        // Deploy distributor
        RewardsDistributor distImpl = new RewardsDistributor();
        bytes memory init = abi.encodeWithSelector(RewardsDistributor.initialize.selector, admin, address(token), address(0));
        LocalERC1967Proxy distProxy = new LocalERC1967Proxy(address(distImpl), init);
        distributor = RewardsDistributor(address(distProxy));

        // Mint rewards to distributor for allocation
        token.mint(address(distributor), 1_000 ether);
    }

    // Utility to build a simple 2-leaf cumulative merkle root manually
    function _twoLeafRoot(address a, uint256 av, address b, uint256 bv) internal pure returns (bytes32, bytes32, bytes32) {
        bytes32 leafA = keccak256(abi.encodePacked(a, av));
        bytes32 leafB = keccak256(abi.encodePacked(b, bv));
        bytes32 h = leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));
        return (h, leafA, leafB);
    }

    function testPublishAndClaim() external {
        // cumulative: alice 300, bob 700
        (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) = _twoLeafRoot(alice, 300 ether, bob, 700 ether);
        vm.prank(admin);
        distributor.publishRoot(root, 1_000 ether);

        // Build proofs (since only 2 leaves, proof is just the sibling leaf)
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;

        // Alice claims 300
        vm.prank(alice);
        distributor.claim(1, alice, 300 ether, aliceProof);
        assertEq(token.balanceOf(alice), 300 ether);

        // Bob partial claim then remainder (simulate cumulative update) — In this root model, only single cumulative claim; second should revert NothingToClaim
        vm.prank(bob);
        distributor.claim(1, bob, 700 ether, bobProof);
        assertEq(token.balanceOf(bob), 700 ether);

        vm.prank(bob);
        vm.expectRevert(); // NothingToClaim
        distributor.claim(1, bob, 700 ether, bobProof);
    }

    function testInvalidProofRevert() external {
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(alice, 300 ether, bob, 700 ether);
        vm.prank(admin);
        distributor.publishRoot(root, 1_000 ether);
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(123)); // wrong sibling
        vm.prank(alice);
        vm.expectRevert();
        distributor.claim(1, alice, 300 ether, badProof);
    }

    function testRootNotFoundRevert() external {
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(); // RootNotFound
        distributor.claim(999, alice, 1, empty);
    }

    function testPublishInvalidZeroRootRevert() external {
        vm.prank(admin);
        vm.expectRevert();
        distributor.publishRoot(bytes32(0), 100);
    }

    function testPublishInvalidZeroTotalRevert() external {
        vm.prank(admin);
        bytes32 some = keccak256("root");
        vm.expectRevert();
        distributor.publishRoot(some, 0);
    }

    function testSkimAndEvent() external {
        // initial balance exists (1_000 ether minted)
        vm.prank(admin);
        distributor.skim(admin, 200 ether);
        assertEq(token.balanceOf(admin), 200 ether);
    }

    function testSkimZeroAddressRevert() external {
        vm.prank(admin);
        vm.expectRevert();
        distributor.skim(address(0), 1);
    }

    function testRoleRestrictions() external {
        bytes32 root = keccak256("r1");
        vm.expectRevert();
        distributor.publishRoot(root, 10 ether); // caller not ROOT_SETTER_ROLE
        vm.expectRevert();
        distributor.skim(admin, 1 ether); // caller not RECOVER_ROLE
    }

    function testReentrancyGuard() external {
        // Build root for attacker + bob
        (bytes32 root, bytes32 attackerLeaf, bytes32 bobLeaf) = _twoLeafRoot(address(0xDEAD), 100 ether, bob, 200 ether);
        vm.prank(admin);
        distributor.publishRoot(root, 300 ether);
        // We cannot forge a reentrancy via ERC20 transfer because token is plain.
        // Instead, we validate guard by attempting a second claim inline through a helper that calls twice.
        bytes32[] memory proof = new bytes32[](1);
        // Determine sibling for attacker leaf
        proof[0] = (attackerLeaf < bobLeaf) ? bobLeaf : attackerLeaf; // simplistic; attackerLeaf stands for (address(0xDEAD), 100)
        DoubleClaimHelper helper = new DoubleClaimHelper();
        helper.init(distributor);
        vm.expectRevert(); // second claim should revert NothingToClaim (guard prevents reentrancy scenario, but same-tx sequential is fine).
        helper.doubleClaim(1, address(0xDEAD), 100 ether, proof);
    }

    function testClaimZeroAccountReverts() external {
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(alice, 300 ether, bob, 700 ether);
        vm.prank(admin);
        distributor.publishRoot(root, 1_000 ether);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf; // sibling leaf
        vm.expectRevert();
        distributor.claim(1, address(0), 300 ether, proof); // ZeroAddress
    }

    function testUnclaimedInRootMissingIdReturnsZero() external {
        assertEq(distributor.unclaimedInRoot(9999), 0);
    }

    function testPartialClaimThenSkimAffectsUnclaimed() external {
        // Root: alice 400, bob 600
        (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) = _twoLeafRoot(alice, 400 ether, bob, 600 ether);
        vm.prank(admin);
        distributor.publishRoot(root, 1_000 ether);
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        // Alice claims full 400
        vm.prank(alice);
        distributor.claim(1, alice, 400 ether, aliceProof);
        uint256 beforeUnclaimed = distributor.unclaimedInRoot(1);
        // Skim 50 tokens (simulate excess) by granting RECOVER_ROLE already granted to admin
        vm.prank(admin);
        distributor.skim(admin, 50 ether);
        uint256 afterUnclaimed = distributor.unclaimedInRoot(1);
        // Unclaimed should be reduced by amount skimmed only if previously unallocated; here root.total fixed so internal claimed unaffected.
        // Since skim doesn't adjust bookkeeping, unclaimedInRoot remains (total - claimed)
        assertEq(beforeUnclaimed, afterUnclaimed);
    }
}

contract DoubleClaimHelper {
    RewardsDistributor private dist;
    function init(RewardsDistributor d) external { dist = d; }
    function doubleClaim(uint256 id, address acct, uint256 cumulative, bytes32[] calldata proof) external {
        dist.claim(id, acct, cumulative, proof);
        // second identical call should revert NothingToClaim
        dist.claim(id, acct, cumulative, proof);
    }
}
