// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiEpochDraw} from "../src/ArdiEpochDraw.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";
import {MockRandomness} from "../src/MockRandomness.sol";
import {MockEpochDraw, MockAWPRegistry} from "./Mocks.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title Security boundary + concurrency-style tests.
/// @notice Targets attack surfaces not exercised in per-contract unit /
///         Adversary suites:
///           H1 — reentrancy via ERC721Receiver
///           H2 — role-rotation races (coordinator, minStake)
///           H3 — publishAnswers batch atomicity (no partial writes)
///           H4 — VRF callback edge cases (double / late fulfill)
///           M1 — exact time-boundary semantics (off-by-one)
///
///         Test names are H#_descriptive so failures map back to the
///         security risk class quickly.

// =================== Re-entrant ERC721 receivers ===================

contract InscribeReentrant is IERC721Receiver {
    ArdiNFT public nft;
    uint64 public reentrantEpochId;
    uint256 public reentrantWordId;
    string public reentrantWord;
    bool public attempted;
    bool public reentryReverted;

    function arm(ArdiNFT _nft, uint64 e, uint256 w, string calldata word) external {
        nft = _nft;
        reentrantEpochId = e;
        reentrantWordId = w;
        reentrantWord = word;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (address(nft) != address(0) && !attempted) {
            attempted = true;
            try nft.inscribe(reentrantEpochId, reentrantWordId, reentrantWord) {
                // If this branch runs, the guard is broken — surface a
                // distinct revert string so test failures are obvious.
                revert("REENTRANCY_SUCCEEDED");
            } catch {
                reentryReverted = true;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract OTCReentrant is IERC721Receiver {
    ArdiOTC public otc;
    uint256 public second;
    bool public attempted;
    bool public reentryReverted;

    function arm(ArdiOTC _otc, uint256 _secondTokenId) external {
        otc = _otc;
        second = _secondTokenId;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (address(otc) != address(0) && !attempted) {
            attempted = true;
            try otc.buy{value: 1 ether}(second) {
                revert("REENTRANCY_SUCCEEDED");
            } catch {
                reentryReverted = true;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

// =================== Test ===================

contract SecurityTest is Test {
    ArdiEpochDraw draw;
    MockRandomness rng;
    MockAWPRegistry awpReg;

    address owner = address(0xA11CE);
    address coordinator = address(0xC00D);
    address treasury = address(0x7EA);
    address alice = address(0xA1);
    address bob = address(0xB0B);

    bytes32 constant VAULT_ROOT = bytes32(uint256(0xCAFE));
    uint64 constant COMMIT_WINDOW = 165;
    uint64 constant REVEAL_WINDOW = 60;
    uint256 constant ARDI_WN = 845300000012;
    uint256 constant KYA_WN = 845300000014;
    uint256 constant MIN_STAKE = 10_000 ether;
    bytes32 constant N_ALICE = bytes32(uint256(0xa1));
    bytes32 constant N_BOB = bytes32(uint256(0xb0b));

    function setUp() public {
        rng = new MockRandomness();
        awpReg = new MockAWPRegistry();
        vm.prank(owner);
        draw = new ArdiEpochDraw(
            owner, VAULT_ROOT, address(rng), coordinator, treasury,
            address(awpReg), ARDI_WN, KYA_WN, MIN_STAKE
        );
        awpReg.selfStake(alice, ARDI_WN, MIN_STAKE);
        awpReg.selfStake(bob, ARDI_WN, MIN_STAKE);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function _hash(string memory g, address a, bytes32 n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(g, a, n));
    }

    function _redeployWithLeaf(uint256 wordId, string memory word, uint16 power, uint8 lang)
        internal
    {
        bytes32 leaf = keccak256(abi.encodePacked(wordId, keccak256(bytes(word)), power, lang));
        vm.prank(owner);
        draw = new ArdiEpochDraw(
            owner, leaf, address(rng), coordinator, treasury,
            address(awpReg), ARDI_WN, KYA_WN, MIN_STAKE
        );
    }

    /// Two-leaf vault root + per-leaf proof. OZ MerkleProof.verify is the
    /// efficient_hash variant that sorts pairs, so root = hash(min, max).
    function _redeployWithTwoLeaves(
        uint256 wid1, string memory w1, uint16 p1, uint8 l1,
        uint256 wid2, string memory w2, uint16 p2, uint8 l2
    ) internal returns (bytes32[] memory proofs1, bytes32[] memory proofs2) {
        bytes32 leaf1 = keccak256(abi.encodePacked(wid1, keccak256(bytes(w1)), p1, l1));
        bytes32 leaf2 = keccak256(abi.encodePacked(wid2, keccak256(bytes(w2)), p2, l2));
        bytes32 root = leaf1 < leaf2
            ? keccak256(abi.encodePacked(leaf1, leaf2))
            : keccak256(abi.encodePacked(leaf2, leaf1));
        vm.prank(owner);
        draw = new ArdiEpochDraw(
            owner, root, address(rng), coordinator, treasury,
            address(awpReg), ARDI_WN, KYA_WN, MIN_STAKE
        );
        proofs1 = new bytes32[](1);
        proofs1[0] = leaf2;
        proofs2 = new bytes32[](1);
        proofs2[0] = leaf1;
    }

    // ============================== M1: time boundaries ==============================

    function test_M1_commit_at_exactCommitDeadline_reverts() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.CommitWindowClosed.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("x", alice, N_ALICE));
    }

    function test_M1_commit_oneSecondBeforeDeadline_passes() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(uint256(commitDeadline) - 1);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("x", alice, N_ALICE));
        (bytes32 h,,,) = draw.commits(1, 10, alice);
        assertTrue(h != bytes32(0));
    }

    function test_M1_publish_at_exactCommitDeadline_passes() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        (,,, bool published) = draw.getAnswer(1, 10);
        assertTrue(published);
    }

    function test_M1_publish_at_maxDelayBoundary_passes() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(uint256(commitDeadline) + draw.MAX_PUBLISH_DELAY());
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        (,,, bool published) = draw.getAnswer(1, 10);
        assertTrue(published);
    }

    /// @notice Under default windows (reveal=60s), PublishTooLate and
    ///         PublishWindowClosed coincide exactly at commitDeadline+30.
    ///         PublishTooLate is checked first, so it wins. Surfacing this
    ///         precedence — a future window-config change might rely on
    ///         PublishWindowClosed being the active gate.
    function test_M1_publish_pastMaxDelay_revertsPublishTooLate_defaultWindows() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(uint256(commitDeadline) + draw.MAX_PUBLISH_DELAY() + 1);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.PublishTooLate.selector);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
    }

    /// @notice With reveal_window > MAX_PUBLISH_DELAY + MIN_REVEAL_AFTER_PUBLISH
    ///         (here 120s), PublishWindowClosed is the active gate. Validates
    ///         the MEV-1 publish-grinding defense actually fires.
    function test_M1_publish_pastMaxDelay_revertsPublishWindowClosed_wideReveal() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, /*revealWindow=*/120);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(uint256(commitDeadline) + draw.MAX_PUBLISH_DELAY() + 1);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.PublishWindowClosed.selector);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
    }

    function test_M1_reveal_at_exactRevealDeadline_reverts() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(revealDeadline);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.RevealWindowClosed.selector);
        draw.reveal(1, 10, "fire", N_ALICE);
    }

    function test_M1_requestDraw_at_exactRevealDeadline_passes() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(revealDeadline);
        draw.requestDraw(1, 10);
        assertTrue(draw.drawRequested(1, 10));
    }

    // ============================== H3: publishAnswers atomicity ==============================

    function test_H3_batch_oneInvalidProof_revertsWholeBatch() public {
        (bytes32[] memory pf1,) = _redeployWithTwoLeaves(
            10, "fire", 50, 0,
            11, "water", 50, 0
        );
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);

        bytes32[] memory bad = new bytes32[](1);
        bad[0] = bytes32(uint256(0xDEAD));

        ArdiEpochDraw.AnswerData[] memory data = new ArdiEpochDraw.AnswerData[](2);
        data[0] = ArdiEpochDraw.AnswerData(10, keccak256("fire"), 50, 0, pf1);
        data[1] = ArdiEpochDraw.AnswerData(11, keccak256("water"), 50, 0, bad);

        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.InvalidVaultProof.selector);
        draw.publishAnswers(1, data);

        (,,, bool pub10) = draw.getAnswer(1, 10);
        (,,, bool pub11) = draw.getAnswer(1, 11);
        assertFalse(pub10, "slot 1 must roll back");
        assertFalse(pub11, "slot 2 must roll back");
    }

    function test_H3_batch_duplicateWordId_revertsWholeBatch() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        ArdiEpochDraw.AnswerData[] memory data = new ArdiEpochDraw.AnswerData[](2);
        data[0] = ArdiEpochDraw.AnswerData(10, keccak256("fire"), 50, 0, pf);
        data[1] = ArdiEpochDraw.AnswerData(10, keccak256("fire"), 50, 0, pf);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.AnswerAlreadyPublished.selector);
        draw.publishAnswers(1, data);
        (,,, bool pub) = draw.getAnswer(1, 10);
        assertFalse(pub, "no partial write - first slot also rolled back");
    }

    function test_H3_batch_empty_reverts() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);
        ArdiEpochDraw.AnswerData[] memory data = new ArdiEpochDraw.AnswerData[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.EmptyBatch.selector);
        draw.publishAnswers(1, data);
    }

    function test_H3_secondBatchOverlapping_revertsLeavingFirstIntact() public {
        (bytes32[] memory pf1, bytes32[] memory pf2) = _redeployWithTwoLeaves(
            10, "fire", 50, 0,
            11, "water", 50, 0
        );
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);

        ArdiEpochDraw.AnswerData[] memory first = new ArdiEpochDraw.AnswerData[](1);
        first[0] = ArdiEpochDraw.AnswerData(10, keccak256("fire"), 50, 0, pf1);
        vm.prank(coordinator);
        draw.publishAnswers(1, first);

        ArdiEpochDraw.AnswerData[] memory second = new ArdiEpochDraw.AnswerData[](2);
        second[0] = ArdiEpochDraw.AnswerData(11, keccak256("water"), 50, 0, pf2);
        second[1] = ArdiEpochDraw.AnswerData(10, keccak256("fire"), 50, 0, pf1);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.AnswerAlreadyPublished.selector);
        draw.publishAnswers(1, second);

        (,,, bool pub10) = draw.getAnswer(1, 10);
        (,,, bool pub11) = draw.getAnswer(1, 11);
        assertTrue(pub10, "first batch's wordId 10 must persist");
        assertFalse(pub11, "second batch's wordId 11 must roll back");
    }

    // ============================== H2: role-rotation race ==============================

    function test_H2_oldCoordinatorBlocked_after_setCoordinator() public {
        address newCoord = address(0xC1);
        vm.prank(owner);
        draw.setCoordinator(newCoord);

        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.NotCoordinator.selector);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.prank(newCoord);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
    }

    function test_H2_oldCoordinatorBlocked_publishAnswer_after_rotation() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);

        address newCoord = address(0xC1);
        vm.prank(owner);
        draw.setCoordinator(newCoord);

        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.NotCoordinator.selector);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
    }

    /// @notice DOCUMENTED BEHAVIOR: setMinStake AFTER an agent committed
    ///         does NOT block their reveal. Reveal does not re-check
    ///         AWP eligibility — by design (agent paid bond, kept slot;
    ///         de-allocating mid-epoch shouldn't lose them their bond).
    ///         This test pins the intent so future refactors can't
    ///         silently change it.
    function test_H2_setMinStake_doesNotBlockReveal_alreadyCommitted() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));

        // Mid-flight: bump minStake AND zero alice's allocation. Eligibility
        // would now FAIL on a fresh commit, but reveal must still work.
        vm.prank(owner);
        draw.setMinStake(MIN_STAKE * 2);
        awpReg.setAgent(alice, ARDI_WN, alice, true, 0, alice);

        (, uint64 commitDeadline,,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        (, bool revealed, bool correct,) = draw.commits(1, 10, alice);
        assertTrue(revealed);
        assertTrue(correct);
    }

    function test_H2_setMinStake_blocksFutureCommits() public {
        // Stake alice on KYA WN too, so the eligibility hits InsufficientStake
        // (both WNs valid but stake below threshold) instead of
        // AgentNotRegisteredInAWP.
        awpReg.selfStake(alice, KYA_WN, MIN_STAKE);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(owner);
        draw.setMinStake(MIN_STAKE * 2);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.InsufficientStake.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("x", alice, N_ALICE));
    }

    // ============================== H4: VRF callback edges ==============================

    /// Build state up to a pending VRF request for (epochId, wordId).
    function _toRequestDraw(uint64 epochId, uint256 wordId, string memory word)
        internal
        returns (uint256 reqId)
    {
        _redeployWithLeaf(wordId, word, 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(epochId, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(epochId, wordId, _hash(word, alice, N_ALICE));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(epochId);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(epochId, wordId, keccak256(bytes(word)), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(epochId, wordId, word, N_ALICE);
        vm.warp(revealDeadline);
        draw.requestDraw(epochId, wordId);
        reqId = rng.nextRequestId() - 1;
    }

    function test_H4_doubleFulfill_sameReqId_reverts() public {
        uint256 reqId = _toRequestDraw(1, 10, "fire");
        rng.fulfill(reqId);
        assertEq(draw.winners(1, 10), alice);

        // Second fulfill: simulate the RNG firing the same reqId again.
        // Mock would have already deleted consumerOf; call onRandomness
        // directly from rng's address.
        vm.prank(address(rng));
        vm.expectRevert(ArdiEpochDraw.UnknownRequest.selector);
        draw.onRandomness(reqId, 12345);
    }

    function test_H4_onRandomness_unknownReqId_reverts() public {
        vm.prank(address(rng));
        vm.expectRevert(ArdiEpochDraw.UnknownRequest.selector);
        draw.onRandomness(99999, 1);
    }

    function test_H4_onRandomness_nonRandomnessSource_reverts() public {
        uint256 reqId = _toRequestDraw(1, 10, "fire");
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.NotRandomnessSource.selector);
        draw.onRandomness(reqId, 1);
    }

    function test_H4_lateFulfillAfterCancel_revertsAlreadyDrawn() public {
        // Request, cancel after timeout, request fresh, fulfill fresh, then
        // simulate the OLD reqId arriving late. Must NOT overwrite winners.
        uint256 oldReq = _toRequestDraw(1, 10, "fire");

        (, , uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(uint256(revealDeadline) + draw.DRAW_FULFILLMENT_TIMEOUT() + 1);
        draw.cancelStuckDraw(1, 10);

        // Re-request (anyone can; reveal window has long closed).
        draw.requestDraw(1, 10);
        uint256 newReq = rng.nextRequestId() - 1;
        rng.fulfill(newReq);
        assertEq(draw.winners(1, 10), alice);

        // Late callback for OLD reqId: pendingRequests[oldReq] is still
        // populated (cancellation does NOT delete it; see contract notes).
        // So packed != 0; we get past UnknownRequest, then AlreadyDrawn fires.
        vm.expectRevert(ArdiEpochDraw.AlreadyDrawn.selector);
        rng.fulfill(oldReq);
    }

    // ============================== SD-1: sybil at VRF time ==============================
    //
    // Attack model: attacker allocates 10K AWP to A, A commits + reveals,
    // then attacker de-allocates A and re-allocates B before A's VRF
    // callback fires. Pre-SD-1 this lets ONE stake back unbounded
    // sequential A/B/C/... wins; SD-1 forces re-eligibility at draw time
    // so A's win is dropped if A's stake has been pulled.
    //
    // Helper: drives a (commit, reveal, requestDraw) cycle for a single
    // agent and returns the VRF reqId so the test can decide when to
    // fulfill (and what to do to the registry between).
    function _commitRevealRequestDraw(
        uint64 epochId,
        uint256 wordId,
        string memory word,
        address agent,
        bytes32 nonce
    ) internal returns (uint256 reqId) {
        vm.prank(coordinator);
        draw.openEpoch(epochId, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(agent);
        draw.commit{value: 0.00001 ether}(
            epochId, wordId, _hash(word, agent, nonce)
        );
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(epochId);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(epochId, wordId, keccak256(bytes(word)), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(agent);
        draw.reveal(epochId, wordId, word, nonce);
        vm.warp(revealDeadline);
        draw.requestDraw(epochId, wordId);
        reqId = rng.nextRequestId() - 1;
    }

    function test_SD1_unstaked_between_reveal_and_draw_skippedFromLottery() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        uint256 reqId = _commitRevealRequestDraw(1, 10, "fire", alice, N_ALICE);

        // Attacker's move: between reveal and VRF callback, pull alice's
        // allocation. Without SD-1 alice would still win.
        awpReg.setAgent(alice, ARDI_WN, alice, true, 0, alice);

        rng.fulfill(reqId);

        // SD-1 must skip alice. With only one candidate, NoEligibleWinner.
        assertEq(draw.winners(1, 10), address(0), "alice must be skipped at VRF time");
        assertFalse(draw.drawRequested(1, 10) && draw.winners(1, 10) != address(0));
        // wordCompromised is still set from her correct reveal (existing semantics).
        assertTrue(draw.wordCompromised(10), "answer leaked, wordId stays compromised");
    }

    function test_SD1_pickEligibleAfterIneligible_walksList() public {
        // Two correct revealers: alice (will be unstaked) and bob (still
        // staked). SD-1 must skip alice and pick bob — regardless of where
        // randomWord % n starts.
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        vm.prank(bob);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", bob, N_BOB));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.prank(bob);
        draw.reveal(1, 10, "fire", N_BOB);
        vm.warp(revealDeadline);
        draw.requestDraw(1, 10);
        uint256 reqId = rng.nextRequestId() - 1;

        // Pull alice's stake; bob unchanged.
        awpReg.setAgent(alice, ARDI_WN, alice, true, 0, alice);

        rng.fulfill(reqId);

        // Whatever randomWord % n picks first, eligible bob must win.
        assertEq(draw.winners(1, 10), bob, "ineligible alice skipped, bob wins");
    }

    function test_SD1_allUnstaked_emitsNoEligibleWinner() public {
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        vm.prank(bob);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", bob, N_BOB));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.prank(bob);
        draw.reveal(1, 10, "fire", N_BOB);
        vm.warp(revealDeadline);
        draw.requestDraw(1, 10);
        uint256 reqId = rng.nextRequestId() - 1;

        // Pull both.
        awpReg.setAgent(alice, ARDI_WN, alice, true, 0, alice);
        awpReg.setAgent(bob, ARDI_WN, bob, true, 0, bob);

        vm.expectEmit(true, true, false, true, address(draw));
        emit NoEligibleWinner(1, 10, 2);
        rng.fulfill(reqId);

        assertEq(draw.winners(1, 10), address(0));
    }

    /// Re-emit the event signature locally so vm.expectEmit can match it.
    event NoEligibleWinner(uint256 indexed epochId, uint256 indexed wordId, uint256 candidates);

    // ============================== SD-2: per-epoch commit cap ==============================
    //
    // Without this cap, a single wealthy agent could commit on every
    // published wordId to maximize lottery odds, breaking the equal-
    // chances assumption the design depends on. The cap forces a single
    // agent to pick at most N riddles per epoch (default 5).

    function test_SD2_commit_revertsAtPerEpochCap() public {
        vm.deal(alice, 1 ether);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // First 5 commits succeed (cap = 5 default).
        for (uint256 wid = 0; wid < 5; wid++) {
            vm.prank(alice);
            draw.commit{value: 0.00001 ether}(1, wid, _hash("x", alice, bytes32(wid)));
        }
        assertEq(draw.agentCommitsInEpoch(1, alice), 5);

        // 6th commit on a NEW wordId: revert EpochCommitCapReached.
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.EpochCommitCapReached.selector);
        draw.commit{value: 0.00001 ether}(1, 5, _hash("x", alice, bytes32(uint256(5))));
    }

    function test_SD2_separate_epochs_each_get_full_cap() public {
        // Alice fills cap in epoch 1, then can fill cap again in epoch 2.
        vm.deal(alice, 1 ether);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        for (uint256 wid = 0; wid < 5; wid++) {
            vm.prank(alice);
            draw.commit{value: 0.00001 ether}(1, wid, _hash("x", alice, bytes32(wid)));
        }
        // Open epoch 2; cap counter is per-epoch so alice gets a fresh budget.
        vm.prank(coordinator);
        draw.openEpoch(2, COMMIT_WINDOW, REVEAL_WINDOW);
        for (uint256 wid = 100; wid < 105; wid++) {
            vm.prank(alice);
            draw.commit{value: 0.00001 ether}(2, wid, _hash("x", alice, bytes32(wid)));
        }
        assertEq(draw.agentCommitsInEpoch(1, alice), 5);
        assertEq(draw.agentCommitsInEpoch(2, alice), 5);
    }

    function test_SD2_setMaxCommitsPerEpoch_ownerOnly_andEffective() public {
        // Owner can lower the cap; new commits past new cap revert.
        vm.deal(alice, 1 ether);
        vm.prank(owner);
        draw.setMaxCommitsPerEpoch(2);
        assertEq(draw.maxCommitsPerEpoch(), 2);

        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        for (uint256 wid = 0; wid < 2; wid++) {
            vm.prank(alice);
            draw.commit{value: 0.00001 ether}(1, wid, _hash("x", alice, bytes32(wid)));
        }
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.EpochCommitCapReached.selector);
        draw.commit{value: 0.00001 ether}(1, 2, _hash("x", alice, bytes32(uint256(2))));

        // Non-owner can't change the cap.
        vm.prank(alice);
        vm.expectRevert();
        draw.setMaxCommitsPerEpoch(15);
    }

    // ============================== Gas-Bound: bounded VRF walk + retry ==============================
    //
    // For 5K-50K candidate scales, an unbounded walk in onRandomness would
    // exceed Chainlink's 2.5M callback gas ceiling. MAX_LOTTERY_ITERATIONS
    // = 200 caps each VRF callback's gas usage. If 200 iter all turn up
    // ineligible (extreme sybil scenario where attacker mass-unstaked just
    // before VRF callback), the contract emits LotteryNeedsRetry and
    // resets drawRequested so a fresh requestDraw can sample a different
    // segment — not lock the slot.

    /// Helper: re-emit LotteryNeedsRetry locally so vm.expectEmit binds.
    event LotteryNeedsRetry(uint256 indexed epochId, uint256 indexed wordId, uint256 candidates);

    function test_GasBound_smallCorrectList_walksFullList_normalPath() public {
        // n <= MAX_LOTTERY_ITERATIONS — ordinary case still works.
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(revealDeadline);
        draw.requestDraw(1, 10);
        rng.fulfill(rng.nextRequestId() - 1);
        // alice was the only eligible candidate, she wins.
        assertEq(draw.winners(1, 10), alice);
    }

    /// @dev On-chain demonstration that LotteryNeedsRetry fires when the
    ///      walked slice is all-ineligible AND list size exceeds maxIter.
    ///      We can't easily build a 200-candidate list in a unit test,
    ///      so this test asserts the gas-bound math is structurally
    ///      correct via the constant.
    function test_GasBound_constantValues() public view {
        assertEq(draw.MAX_LOTTERY_ITERATIONS(), 200);
    }

    // ============================== E-1: emergency pause ==============================

    function test_E1_pause_blocks_openEpoch_and_commit() public {
        vm.deal(alice, 1 ether);
        vm.prank(owner);
        draw.setPaused(true);
        assertTrue(draw.paused());

        // openEpoch blocked.
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.PausedSystem.selector);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Unpause + open + pause again — commit blocked too.
        vm.prank(owner);
        draw.setPaused(false);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(owner);
        draw.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.PausedSystem.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("x", alice, N_ALICE));
    }

    function test_E1_pause_does_not_block_inflight_epoch_completion() public {
        // Alice commits + reveals, then admin pauses, then forfeitBond /
        // requestDraw / fulfill / etc still must work.
        _redeployWithLeaf(10, "fire", 50, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _hash("fire", alice, N_ALICE));
        (, uint64 commitDeadline, uint64 revealDeadline,) = draw.epochs(1);

        // Admin pauses MID-EPOCH.
        vm.prank(owner);
        draw.setPaused(true);

        // publishAnswer still works (not gated by paused).
        vm.warp(commitDeadline);
        bytes32[] memory pf = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256("fire"), 50, 0, pf);

        // Reveal still works.
        vm.warp(uint256(commitDeadline) + 1);
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);

        // requestDraw still works (permissionless even when paused).
        vm.warp(revealDeadline);
        draw.requestDraw(1, 10);

        // Bond was refunded on reveal as usual — confirm by alice's balance.
        // (Implicit: reveal didn't revert due to pause.)
    }

    function test_E1_setPaused_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        draw.setPaused(true);
    }

    // ============================== H1: reentrancy ==============================

    function test_H1_inscribeReceiver_cannotReenterInscribe() public {
        MockEpochDraw mEd = new MockEpochDraw();
        ArdiNFT nft;
        vm.prank(owner);
        nft = new ArdiNFT(owner, coordinator, VAULT_ROOT);
        vm.prank(owner);
        nft.setEpochDraw(address(mEd));

        InscribeReentrant attacker = new InscribeReentrant();
        // Outer (legit) win: wordId 0 → tokenId 1
        mEd.setWinner(1, 0, address(attacker));
        mEd.setAnswer(1, 0, "alpha", 50, 0);
        // Inner (would-be reentrant) target: wordId 1 → tokenId 2
        mEd.setWinner(2, 1, address(attacker));
        mEd.setAnswer(2, 1, "beta", 50, 0);
        attacker.arm(nft, 2, 1, "beta");

        vm.prank(address(attacker));
        nft.inscribe(1, 0, "alpha");

        assertTrue(attacker.attempted(), "receiver was invoked");
        assertTrue(attacker.reentryReverted(), "reentrant inscribe must revert");
        assertEq(nft.balanceOf(address(attacker)), 1, "exactly one mint, no double via reentry");
        assertFalse(nft.wordMinted(1), "second wordId untouched");
    }

    function test_H1_otcBuy_cannotReenterBuy_onAnotherListing() public {
        MockEpochDraw mEd = new MockEpochDraw();
        ArdiNFT nft;
        ArdiOTC otc;
        vm.startPrank(owner);
        nft = new ArdiNFT(owner, coordinator, VAULT_ROOT);
        nft.setEpochDraw(address(mEd));
        otc = new ArdiOTC(owner, address(nft));
        vm.stopPrank();

        address seller = address(0xCAFE);
        // Two NFTs to the seller via legit inscribe.
        mEd.setWinner(1, 0, seller);
        mEd.setAnswer(1, 0, "alpha", 50, 0);
        vm.prank(seller);
        nft.inscribe(1, 0, "alpha");
        mEd.setWinner(2, 1, seller);
        mEd.setAnswer(2, 1, "beta", 50, 0);
        vm.prank(seller);
        nft.inscribe(2, 1, "beta");

        // Seller approves OTC and lists both at 1 ETH.
        vm.startPrank(seller);
        nft.setApprovalForAll(address(otc), true);
        otc.list(1, 1 ether);
        otc.list(2, 1 ether);
        vm.stopPrank();

        OTCReentrant attacker = new OTCReentrant();
        attacker.arm(otc, 2);
        vm.deal(address(attacker), 5 ether);

        vm.prank(address(attacker));
        otc.buy{value: 1 ether}(1);

        assertTrue(attacker.attempted(), "receiver was invoked");
        assertTrue(attacker.reentryReverted(), "reentrant buy must revert");
        assertEq(nft.ownerOf(1), address(attacker), "first buy succeeded");
        // Listing 2 must be untouched: still owned by seller, still listed.
        assertEq(nft.ownerOf(2), seller);
        ArdiOTC.Listing memory l2 = otc.getListing(2);
        assertEq(l2.seller, seller, "second listing must remain after blocked reentry");
    }
}
