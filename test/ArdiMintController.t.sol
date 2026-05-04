// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ArdiToken} from "../src/ArdiToken.sol";
import {ArdiMintController} from "../src/ArdiMintController.sol";
import {MockAWP} from "./Mocks.sol";

contract ArdiMintControllerTest is Test {
    ArdiToken token;
    MockAWP awp;
    ArdiMintController ctrl;

    address admin = address(0xA11CE);          // DEFAULT_ADMIN_ROLE
    address coordinator = address(0xC00D);     // MERKLE_ROLE
    address ownerOps = address(0x0DAD);        // OWNER_OPS_ROLE recipient

    address alice = address(0xA11);
    address bob = address(0xB0B);

    uint256 GENESIS;

    function setUp() public {
        GENESIS = block.timestamp;

        awp = new MockAWP();

        vm.startPrank(admin);
        token = new ArdiToken(admin);
        ctrl = new ArdiMintController(
            admin, address(token), address(awp), coordinator, ownerOps, GENESIS
        );
        token.setMinter(address(ctrl));
        // CH-2: tests historically allocate full daily emission to a single
        // address. Default per-holder cap (50%) blocks that. Open it for tests.
        ctrl.setMaxPerHolderBps(10_000);
        vm.stopPrank();

        awp.transfer(address(ctrl), 10_000_000 ether);
    }

    // --- Emission curve sanity ---

    function test_dailyEmission_phase1Day1() public view {
        uint256 d1 = ctrl.dailyEmission(1);
        assertEq(d1, ctrl.PHASE1_DAY1());
    }

    function test_dailyEmission_phase1Day14() public view {
        uint256 d14 = ctrl.dailyEmission(14);
        assertGt(d14, 130_000_000 ether);
        assertLt(d14, 160_000_000 ether);
    }

    function test_dailyEmission_phase2Day15() public view {
        uint256 d15 = ctrl.dailyEmission(15);
        assertEq(d15, ctrl.PHASE2_DAY1());
    }

    function test_dailyEmission_phase2Day180() public view {
        uint256 d180 = ctrl.dailyEmission(180);
        assertGt(d180, 0);
        assertLt(d180, 5_000_000 ether);
    }

    function test_dailyEmission_zeroAfter180() public view {
        assertEq(ctrl.dailyEmission(181), 0);
        assertEq(ctrl.dailyEmission(0), 0);
    }

    function test_totalScheduledEmission_approxNineBillion() public view {
        uint256 total = ctrl.totalScheduledEmission();
        assertGt(total, 8_500_000_000 ether);
        assertLt(total, 9_500_000_000 ether);
    }

    // --- Settlement / dual-token claim ---

    /// @dev New leaf format: keccak256(abi.encodePacked(account, ardiAmount, awpAmount)).
    function _leaf(address account, uint256 ardiAmount, uint256 awpAmount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(account, ardiAmount, awpAmount));
    }

    function test_settleDay_andClaim_dualToken() public {
        // 2-leaf Merkle: alice gets (100 ardi, 5 awp), bob gets (200 ardi, 10 awp)
        bytes32 leafA = _leaf(alice, 100 ether, 5 ether);
        bytes32 leafB = _leaf(bob, 200 ether, 10 ether);
        (bytes32 lo, bytes32 hi) = leafA < leafB ? (leafA, leafB) : (leafB, leafA);
        bytes32 root = keccak256(abi.encodePacked(lo, hi));

        vm.warp(GENESIS + 1 days + 1);

        uint256 ardiTotal = 300 ether;
        uint256 awpToHolders = 15 ether;
        uint256 awpOwnerCut = 1 ether + 666666666666666666; // ~1.667 AWP, 10% of holder + cut

        vm.prank(coordinator);
        ctrl.settleDay(1, root, ardiTotal, awpToHolders, awpOwnerCut, uint64(1));

        // Reserves recorded
        assertEq(ctrl.awpReservedForClaims(), awpToHolders);
        assertEq(ctrl.ownerAwpReserve(), awpOwnerCut);

        // Alice claims (proof = [leafB])
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        vm.prank(alice);
        ctrl.claim(1, 100 ether, 5 ether, proofA);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(awp.balanceOf(alice), 5 ether);

        // Bob claims (proof = [leafA])
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;
        vm.prank(bob);
        ctrl.claim(1, 200 ether, 10 ether, proofB);
        assertEq(token.balanceOf(bob), 200 ether);
        assertEq(awp.balanceOf(bob), 10 ether);

        // Holder reserve fully drained
        assertEq(ctrl.awpReservedForClaims(), 0);

        // Double claim fails
        vm.prank(alice);
        vm.expectRevert(ArdiMintController.AlreadyClaimed.selector);
        ctrl.claim(1, 100 ether, 5 ether, proofA);
    }

    function test_claim_invalidProof() public {
        bytes32 leafA = _leaf(alice, 100 ether, 5 ether);
        bytes32 leafB = _leaf(bob, 200 ether, 10 ether);
        (bytes32 lo, bytes32 hi) = leafA < leafB ? (leafA, leafB) : (leafB, leafA);
        bytes32 root = keccak256(abi.encodePacked(lo, hi));

        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, root, 300 ether, 15 ether, 1 ether, uint64(1));

        // Wrong amount (still under per-holder cap) → invalid proof
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        vm.prank(alice);
        vm.expectRevert(ArdiMintController.InvalidProof.selector);
        ctrl.claim(1, 99 ether, 5 ether, proofA);
    }

    function test_settle_revertsIfExceedsEmission() public {
        vm.warp(GENESIS + 1 days + 1);
        uint256 cap = ctrl.dailyEmission(1);

        vm.prank(coordinator);
        vm.expectRevert(ArdiMintController.EmissionExhausted.selector);
        ctrl.settleDay(1, bytes32(uint256(1)), cap + 1, 0, 0, uint64(1));
    }

    function test_settle_revertsIfDayInFuture() public {
        vm.prank(coordinator);
        vm.expectRevert(ArdiMintController.DayInFuture.selector);
        ctrl.settleDay(2, bytes32(uint256(1)), 1 ether, 0, 0, uint64(2));
    }

    function test_settle_revertsIfNotMerkleRole() public {
        vm.warp(GENESIS + 1 days + 1);
        // OZ AccessControl reverts with AccessControlUnauthorizedAccount(addr, role)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                ctrl.MERKLE_ROLE()
            )
        );
        ctrl.settleDay(1, bytes32(uint256(1)), 1 ether, 0, 0, uint64(1));
    }

    function test_settle_revertsIfInsufficientAwpHeld() public {
        vm.warp(GENESIS + 1 days + 1);
        // Controller only holds 10M AWP. Try to commit more than that.
        vm.prank(coordinator);
        vm.expectRevert(ArdiMintController.InsufficientAwpHeld.selector);
        ctrl.settleDay(1, bytes32(uint256(1)), 1 ether, 11_000_000 ether, 0, uint64(1));
    }

    function test_settle_revertsIfAlreadySettled() public {
        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, bytes32(uint256(1)), 1 ether, 0, 0, uint64(1));

        vm.prank(coordinator);
        vm.expectRevert(ArdiMintController.AlreadySettled.selector);
        ctrl.settleDay(1, bytes32(uint256(2)), 1 ether, 0, 0, uint64(1));
    }

    // --- Owner ops withdrawal ---

    function test_ownerOps_withdraw_routesToConfiguredAddr() public {
        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, bytes32(uint256(1)), 0, 0, 100 ether, uint64(1));
        assertEq(ctrl.ownerAwpReserve(), 100 ether);

        // OWNER_OPS_ROLE was granted to ownerOps in constructor.
        // Critical invariant: caller is the role holder, but the AWP routes
        // to ctrl.ownerOpsAddr() — NOT msg.sender. Hot-key compromise can't
        // redirect funds.
        vm.prank(ownerOps);
        ctrl.withdrawOwnerAwp(40 ether);
        assertEq(awp.balanceOf(ownerOps), 40 ether);
        assertEq(ctrl.ownerAwpReserve(), 60 ether);

        vm.prank(ownerOps);
        ctrl.withdrawAllOwnerAwp();
        assertEq(awp.balanceOf(ownerOps), 100 ether);
        assertEq(ctrl.ownerAwpReserve(), 0);
    }

    function test_ownerOps_withdraw_unauthorized() public {
        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, bytes32(uint256(1)), 0, 0, 100 ether, uint64(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                ctrl.OWNER_OPS_ROLE()
            )
        );
        ctrl.withdrawOwnerAwp(1 ether);
    }

    function test_ownerOps_withdraw_exceedsReserve() public {
        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, bytes32(uint256(1)), 0, 0, 100 ether, uint64(1));

        vm.prank(ownerOps);
        vm.expectRevert(ArdiMintController.ExceedsReserve.selector);
        ctrl.withdrawOwnerAwp(101 ether);
    }

    // --- Admin role: set bps ---

    function test_setOwnerOpsBps_onlyAdmin() public {
        vm.prank(admin);
        ctrl.setOwnerOpsBps(500);
        assertEq(ctrl.ownerOpsBps(), 500);
    }

    function test_setOwnerOpsBps_capEnforced() public {
        vm.prank(admin);
        vm.expectRevert(ArdiMintController.ExceedsBpsCap.selector);
        ctrl.setOwnerOpsBps(2001); // > MAX_OWNER_OPS_BPS = 2000 (20%)
    }

    function test_setOwnerOpsBps_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                ctrl.DEFAULT_ADMIN_ROLE()
            )
        );
        ctrl.setOwnerOpsBps(500);
    }

    // --- Admin role: rotate coordinator ---

    function test_setCoordinator_rotatesMerkleRole() public {
        address newCoord = address(0xCAFE);
        vm.prank(admin);
        ctrl.setCoordinator(newCoord);
        assertEq(ctrl.coordinator(), newCoord);
        assertTrue(ctrl.hasRole(ctrl.MERKLE_ROLE(), newCoord));
        assertFalse(ctrl.hasRole(ctrl.MERKLE_ROLE(), coordinator));
    }

    // --- Admin role: rotate ownerOpsAddr ---

    function test_setOwnerOpsAddr_rotatesRoleAndRoutes() public {
        address newOps = address(0xFEED);
        vm.prank(admin);
        ctrl.setOwnerOpsAddr(newOps);
        assertEq(ctrl.ownerOpsAddr(), newOps);
        assertTrue(ctrl.hasRole(ctrl.OWNER_OPS_ROLE(), newOps));
        assertFalse(ctrl.hasRole(ctrl.OWNER_OPS_ROLE(), ownerOps));

        // Settle some AWP and verify new addr receives it.
        vm.warp(GENESIS + 1 days + 1);
        vm.prank(coordinator);
        ctrl.settleDay(1, bytes32(uint256(1)), 0, 0, 50 ether, uint64(1));
        vm.prank(newOps);
        ctrl.withdrawAllOwnerAwp();
        assertEq(awp.balanceOf(newOps), 50 ether);
    }
}
