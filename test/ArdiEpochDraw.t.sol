// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiEpochDraw} from "../src/ArdiEpochDraw.sol";
import {MockRandomness} from "../src/MockRandomness.sol";
import {MockAWPRegistry} from "./Mocks.sol";

contract ArdiEpochDrawTest is Test {
    ArdiEpochDraw draw;
    MockRandomness rng;

    address owner = address(0xA11CE);
    address coordinator = address(0xC00D);
    address treasury = address(0x7EA);

    address alice = address(0xA1);
    address bob = address(0xB0B);
    address carol = address(0xCA01);

    bytes32 constant VAULT_ROOT = bytes32(uint256(0xCAFE));

    uint64 constant COMMIT_WINDOW = 165;
    uint64 constant REVEAL_WINDOW = 60;

    // Predictable nonces for tests
    bytes32 constant N_ALICE = bytes32(uint256(0xa1));
    bytes32 constant N_BOB = bytes32(uint256(0xb0b));
    bytes32 constant N_CAROL = bytes32(uint256(0xca));

    MockAWPRegistry awpReg;
    uint256 constant ARDI_WN = 845300000012;
    uint256 constant KYA_WN = 845300000014;
    uint256 constant MIN_STAKE = 10_000 ether;

    function setUp() public {
        rng = new MockRandomness();
        awpReg = new MockAWPRegistry();
        vm.startPrank(owner);
        draw = new ArdiEpochDraw(
            owner, VAULT_ROOT, address(rng), coordinator, treasury,
            address(awpReg), ARDI_WN, KYA_WN, MIN_STAKE
        );
        vm.stopPrank();

        // All commit-time agents need passing AWP eligibility for the
        // commit() gate. Self-stake them all on Ardi WN.
        awpReg.selfStake(alice, ARDI_WN, MIN_STAKE);
        awpReg.selfStake(bob, ARDI_WN, MIN_STAKE);
        awpReg.selfStake(carol, ARDI_WN, MIN_STAKE);

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    function _commitHash(string memory guess, address agent, bytes32 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(guess, agent, nonce));
    }

    /// @dev Build a single-leaf vault root for tests so publishAnswer's
    ///      Merkle verification accepts our answer. Setting the contract's
    ///      VAULT_MERKLE_ROOT to keccak(leaf) directly gives us a valid root
    ///      with an empty proof (single-element tree).
    function _redeployWithLeafRoot(uint256 wordId, string memory word, uint16 power, uint8 lang) internal {
        // v1.0 leaf: keccak(wordId, keccak(word), power, lang). Hash-only.
        bytes32 leaf = keccak256(abi.encodePacked(wordId, keccak256(bytes(word)), power, lang));
        vm.startPrank(owner);
        draw = new ArdiEpochDraw(
            owner, leaf, address(rng), coordinator, treasury,
            address(awpReg), ARDI_WN, KYA_WN, MIN_STAKE
        );
        vm.stopPrank();
    }

    /// Test convenience: publishAnswer takes the wordHash, not plaintext.
    function _publishWord(uint256 epochId, uint256 wordId, string memory word, uint16 power, uint8 lang)
        internal
    {
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(epochId, wordId, keccak256(bytes(word)), power, lang, emptyProof);
    }

    // ============================== Lifecycle ===============================

    function test_openEpoch() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        (uint64 startTs, uint64 commitDeadline, uint64 revealDeadline, bool exists) = draw.epochs(1);
        assertEq(startTs, uint64(block.timestamp));
        assertEq(commitDeadline, uint64(block.timestamp) + COMMIT_WINDOW);
        assertEq(revealDeadline, uint64(block.timestamp) + COMMIT_WINDOW + REVEAL_WINDOW);
        assertTrue(exists);
    }

    function test_openEpoch_onlyCoordinator() public {
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.NotCoordinator.selector);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
    }

    function test_openEpoch_alreadyOpen() public {
        vm.startPrank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.expectRevert(ArdiEpochDraw.EpochAlreadyOpen.selector);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.stopPrank();
    }

    // ============================== Commit ==================================

    function test_commit_happyPath() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        bytes32 h = _commitHash("fire", alice, N_ALICE);
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, h);

        (bytes32 hash_, bool revealed, bool correct, bool bondClaimed) = draw.commits(1, 10, alice);
        assertEq(hash_, h);
        assertFalse(revealed);
        assertFalse(correct);
        assertFalse(bondClaimed);
    }

    function test_commit_wrongBond() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        bytes32 h = _commitHash("fire", alice, N_ALICE);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.WrongBond.selector);
        draw.commit{value: 0.000005 ether}(1, 10, h);
    }

    function test_commit_afterDeadline() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.CommitWindowClosed.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("x", alice, N_ALICE));
    }

    function test_commit_alreadyCommitted() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.startPrank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("x", alice, N_ALICE));
        vm.expectRevert(ArdiEpochDraw.AlreadyCommitted.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("y", alice, N_ALICE));
        vm.stopPrank();
    }

    // ============================== Eligibility =============================
    // v2: commit() reads AWPRegistry.getAgentInfo. Agent must be registered
    // (isValid) AND have stake ≥ minStake on Ardi WN OR KYA WN. These tests
    // exercise each branch.

    function test_commit_revertsIfNotRegisteredInAWP() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Brand new address — no AWPRegistry entry at all.
        address rando = address(0xFAFA);
        vm.deal(rando, 1 ether);

        vm.prank(rando);
        vm.expectRevert(ArdiEpochDraw.AgentNotRegisteredInAWP.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", rando, N_ALICE));
    }

    function test_commit_revertsIfStakeBelowMin() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Address registered but stake < minStake on BOTH WNs.
        address rando = address(0xFAFB);
        vm.deal(rando, 1 ether);
        awpReg.selfStake(rando, ARDI_WN, MIN_STAKE - 1);
        awpReg.selfStake(rando, KYA_WN, MIN_STAKE - 1);

        vm.prank(rando);
        vm.expectRevert(ArdiEpochDraw.InsufficientStake.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", rando, N_ALICE));
    }

    function test_commit_passesViaKyaWnIfArdiWnBelowMin() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Stake too low on Ardi WN, but enough on KYA WN — should pass.
        address rando = address(0xFAFC);
        vm.deal(rando, 1 ether);
        awpReg.selfStake(rando, ARDI_WN, MIN_STAKE - 1);
        awpReg.selfStake(rando, KYA_WN, MIN_STAKE);

        vm.prank(rando);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", rando, N_ALICE));
        (bytes32 h,,,) = draw.commits(1, 10, rando);
        assertTrue(h != bytes32(0), "commit should have stored hash");
    }

    function test_commit_revertsIfRegisteredButZeroStake() public {
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // isValid = true via setAgent, but zero stake on both.
        address rando = address(0xFAFD);
        vm.deal(rando, 1 ether);
        awpReg.setAgent(rando, ARDI_WN, rando, true, 0, rando);
        awpReg.setAgent(rando, KYA_WN, rando, true, 0, rando);

        vm.prank(rando);
        vm.expectRevert(ArdiEpochDraw.InsufficientStake.selector);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", rando, N_ALICE));
    }

    function test_setMinStake_ownerOnly_andEffective() public {
        // Non-owner can't tune.
        vm.prank(alice);
        vm.expectRevert();
        draw.setMinStake(1 ether);

        // Make alice eligible on both WNs so the failure isn't "not registered"
        // when we raise the bar — we want the InsufficientStake branch.
        awpReg.selfStake(alice, KYA_WN, MIN_STAKE);

        // Owner raises the bar past both stakes → her commit reverts.
        vm.prank(owner);
        draw.setMinStake(MIN_STAKE * 2);
        vm.prank(coordinator);
        draw.openEpoch(2, COMMIT_WINDOW, REVEAL_WINDOW);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.InsufficientStake.selector);
        draw.commit{value: 0.00001 ether}(2, 10, _commitHash("x", alice, N_ALICE));
    }

    // ============================== PublishAnswer ===========================

    function test_publishAnswer_acceptsValidLeaf() public {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.warp(block.timestamp + COMMIT_WINDOW);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);

        (bytes32 wordHash, uint16 power, uint8 lang, bool published) = draw.getAnswer(1, 10);
        assertEq(wordHash, keccak256(bytes("fire")));
        assertEq(power, 80);
        assertEq(lang, 0);
        assertTrue(published);
    }

    function test_publishAnswer_rejectsInvalidLeaf() public {
        // Vault root committed for ("fire", 80, 0); Coordinator tries ("water", 60, 0)
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.warp(block.timestamp + COMMIT_WINDOW);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.InvalidVaultProof.selector);
        draw.publishAnswer(1, 10, keccak256(bytes("water")), 60, 0, proof);
    }

    function test_publishAnswer_beforeCommitWindowEnds() public {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.CommitWindowNotClosed.selector);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);
    }

    function test_publishAnswer_tooLateRejected() public {
        // H-1 mitigation: publishing within MIN_REVEAL_AFTER_PUBLISH (30s)
        // of the reveal deadline must revert.
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Warp to just 10s before reveal deadline (less than 30s)
        vm.warp(block.timestamp + COMMIT_WINDOW + REVEAL_WINDOW - 10);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        vm.expectRevert(ArdiEpochDraw.PublishTooLate.selector);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);
    }

    function test_publishAnswer_onlyCoordinator() public {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.warp(block.timestamp + COMMIT_WINDOW);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.NotCoordinator.selector);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);
    }

    // ============================== Reveal ==================================

    function _setupCommitsAndAnswer() internal {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // alice and bob commit "fire" (correct), carol commits "water" (wrong)
        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", alice, N_ALICE));
        vm.prank(bob);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", bob, N_BOB));
        vm.prank(carol);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("water", carol, N_CAROL));

        vm.warp(block.timestamp + COMMIT_WINDOW);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);
    }

    function test_reveal_correctAndIncorrect() public {
        _setupCommitsAndAnswer();

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        // Bond refunded
        assertEq(alice.balance, aliceBefore + draw.COMMIT_BOND());

        (, bool revealed, bool correct,) = draw.commits(1, 10, alice);
        assertTrue(revealed);
        assertTrue(correct);
        assertEq(draw.correctCount(1, 10), 1);

        // bob also reveals fire
        vm.prank(bob);
        draw.reveal(1, 10, "fire", N_BOB);
        assertEq(draw.correctCount(1, 10), 2);

        // carol reveals water — bond refunded but not in correct list
        vm.prank(carol);
        draw.reveal(1, 10, "water", N_CAROL);
        (, , bool carolCorrect,) = draw.commits(1, 10, carol);
        assertFalse(carolCorrect);
        assertEq(draw.correctCount(1, 10), 2);
    }

    function test_reveal_commitMismatch() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.CommitMismatch.selector);
        draw.reveal(1, 10, "different_word", N_ALICE);
    }

    function test_reveal_wrongNonce() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.CommitMismatch.selector);
        draw.reveal(1, 10, "fire", bytes32(uint256(0xdead)));
    }

    function test_reveal_alreadyRevealed() public {
        _setupCommitsAndAnswer();
        vm.startPrank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.expectRevert(ArdiEpochDraw.AlreadyRevealed.selector);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.stopPrank();
    }

    function test_reveal_afterDeadline() public {
        _setupCommitsAndAnswer();
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.RevealWindowClosed.selector);
        draw.reveal(1, 10, "fire", N_ALICE);
    }

    function test_reveal_answerNotPublished() public {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", alice, N_ALICE));

        vm.warp(block.timestamp + COMMIT_WINDOW);
        // Coordinator hasn't called publishAnswer
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.AnswerNotPublished.selector);
        draw.reveal(1, 10, "fire", N_ALICE);
    }

    // ============================== Draw + VRF ==============================

    function test_draw_picksFromCorrectList() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.prank(bob);
        draw.reveal(1, 10, "fire", N_BOB);

        // After reveal window
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);

        // Anyone can request the draw
        vm.prank(carol);
        draw.requestDraw(1, 10);

        // VRF callback (in real life: Chainlink). Here: mock fulfills
        rng.fulfill(1);

        address winner = draw.winners(1, 10);
        assertTrue(winner == alice || winner == bob, "winner not from correct list");
    }

    function test_draw_noCorrectRevealers_emitsButNoWinner() public {
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        // Only carol commits, with wrong guess
        vm.prank(carol);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("water", carol, N_CAROL));

        vm.warp(block.timestamp + COMMIT_WINDOW);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(coordinator);
        draw.publishAnswer(1, 10, keccak256(bytes("fire")), 80, 0, proof);

        vm.prank(carol);
        draw.reveal(1, 10, "water", N_CAROL);

        vm.warp(block.timestamp + REVEAL_WINDOW + 1);

        vm.prank(carol);
        draw.requestDraw(1, 10);

        // No VRF call needed; drawRequested is set, winners stays 0
        assertEq(draw.winners(1, 10), address(0));
        assertTrue(draw.drawRequested(1, 10));
    }

    function test_draw_alreadyRequested() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);

        vm.prank(carol);
        draw.requestDraw(1, 10);

        vm.prank(carol);
        vm.expectRevert(ArdiEpochDraw.DrawAlreadyRequested.selector);
        draw.requestDraw(1, 10);
    }

    function test_draw_beforeRevealWindow() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);

        // Reveal still open
        vm.prank(carol);
        vm.expectRevert(ArdiEpochDraw.RevealWindowNotClosed.selector);
        draw.requestDraw(1, 10);
    }

    function test_onRandomness_onlyFromRandomnessSource() public {
        vm.prank(alice);
        vm.expectRevert(ArdiEpochDraw.NotRandomnessSource.selector);
        draw.onRandomness(1, 12345);
    }

    // ============================== Forfeit Bond ============================

    function test_forfeitBond_unrevealed() public {
        _setupCommitsAndAnswer();
        // alice does NOT reveal; reveal window closes
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);

        uint256 treasuryBefore = treasury.balance;
        // Anyone can sweep
        draw.forfeitBond(1, 10, alice);
        assertEq(treasury.balance, treasuryBefore + draw.COMMIT_BOND());

        (, , , bool bondClaimed) = draw.commits(1, 10, alice);
        assertTrue(bondClaimed);
    }

    function test_forfeitBond_refundsAgentIfAnswerNeverPublished() public {
        // Coordinator opens an epoch + alice commits, but Coordinator never
        // publishes the answer. After reveal window closes, alice's bond
        // should refund to her (not the treasury).
        _redeployWithLeafRoot(10, "fire", 80, 0);
        vm.prank(coordinator);
        draw.openEpoch(1, COMMIT_WINDOW, REVEAL_WINDOW);

        vm.prank(alice);
        draw.commit{value: 0.00001 ether}(1, 10, _commitHash("fire", alice, N_ALICE));

        // Skip past commit + reveal windows; Coordinator never publishes
        vm.warp(block.timestamp + COMMIT_WINDOW + REVEAL_WINDOW + 1);

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = treasury.balance;
        draw.forfeitBond(1, 10, alice);

        // Refunded to alice, NOT to treasury
        assertEq(alice.balance, aliceBefore + draw.COMMIT_BOND());
        assertEq(treasury.balance, treasuryBefore);
    }

    function test_forfeitBond_alreadyRevealed() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);

        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        vm.expectRevert(ArdiEpochDraw.AlreadyRevealed.selector);
        draw.forfeitBond(1, 10, alice);
    }

    function test_forfeitBond_beforeRevealClosed() public {
        _setupCommitsAndAnswer();
        // Still inside reveal window
        vm.expectRevert(ArdiEpochDraw.RevealWindowNotClosed.selector);
        draw.forfeitBond(1, 10, alice);
    }

    // ============================== Admin ===================================

    function test_setCoordinator_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        draw.setCoordinator(alice);

        vm.prank(owner);
        draw.setCoordinator(alice);
        assertEq(draw.coordinator(), alice);
    }

    function test_setRandomness_onlyOwner() public {
        MockRandomness rng2 = new MockRandomness();
        vm.prank(alice);
        vm.expectRevert();
        draw.setRandomnessSource(address(rng2));

        vm.prank(owner);
        draw.setRandomnessSource(address(rng2));
        assertEq(address(draw.randomness()), address(rng2));
    }

    function test_setRandomness_blockedWhenPending() public {
        // H-3 mitigation: cannot swap randomness while a request is in flight.
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        vm.prank(carol);
        draw.requestDraw(1, 10);
        // Now there's a pending request
        assertEq(draw.pendingRequestsCount(), 1);

        MockRandomness rng2 = new MockRandomness();
        vm.prank(owner);
        vm.expectRevert(ArdiEpochDraw.PendingRequestsExist.selector);
        draw.setRandomnessSource(address(rng2));

        // Fulfill closes out the pending count
        rng.fulfill(1);
        assertEq(draw.pendingRequestsCount(), 0);

        // Now swap is allowed
        vm.prank(owner);
        draw.setRandomnessSource(address(rng2));
        assertEq(address(draw.randomness()), address(rng2));
    }

    function test_cancelStuckDraw() public {
        // H-2 mitigation: stuck VRF can be cancelled after timeout, then
        // requestDraw is callable again.
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        vm.prank(carol);
        draw.requestDraw(1, 10);
        assertEq(draw.pendingRequestsCount(), 1);

        // Before timeout: cancel reverts
        vm.expectRevert(ArdiEpochDraw.DrawNotStuck.selector);
        draw.cancelStuckDraw(1, 10);

        // After timeout: cancel succeeds
        vm.warp(block.timestamp + 1 days + 1);
        draw.cancelStuckDraw(1, 10);
        assertFalse(draw.drawRequested(1, 10));
        assertEq(draw.pendingRequestsCount(), 0);

        // Re-request works (assuming randomness source still ok)
        vm.prank(carol);
        draw.requestDraw(1, 10);
        assertTrue(draw.drawRequested(1, 10));
    }

    function test_cancelStuckDraw_blockedAfterFulfill() public {
        _setupCommitsAndAnswer();
        vm.prank(alice);
        draw.reveal(1, 10, "fire", N_ALICE);
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        vm.prank(carol);
        draw.requestDraw(1, 10);
        rng.fulfill(1);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ArdiEpochDraw.AlreadyDrawn.selector);
        draw.cancelStuckDraw(1, 10);
    }

    function test_zeroAddressRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(ArdiEpochDraw.ZeroAddress.selector);
        draw.setCoordinator(address(0));
        vm.expectRevert(ArdiEpochDraw.ZeroAddress.selector);
        draw.setTreasury(address(0));
        vm.expectRevert(ArdiEpochDraw.ZeroAddress.selector);
        draw.setRandomnessSource(address(0));
        vm.stopPrank();
    }
}
