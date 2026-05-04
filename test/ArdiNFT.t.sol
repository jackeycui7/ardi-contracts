// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {MockEpochDraw} from "./Mocks.sol";

/// @notice ArdiNFT unit tests. Eligibility is enforced upstream in
///         ArdiEpochDraw.commit (AWPRegistry stake check). Inscribe just
///         reads the winner from EpochDraw — no bond/KYA gate here in v2.
contract ArdiNFTTest is Test {
    ArdiNFT nft;
    MockEpochDraw epochDraw;

    address owner = address(0xA11CE);
    uint256 coordinatorPk = 0xC00D;
    address coordinator;
    bytes32 constant VAULT_ROOT = bytes32(uint256(0xCAFE));

    address agent = address(0xBEEF);
    address agent2 = address(0xDEAD);

    function setUp() public {
        coordinator = vm.addr(coordinatorPk);
        epochDraw = new MockEpochDraw();

        vm.startPrank(owner);
        nft = new ArdiNFT(owner, coordinator, VAULT_ROOT);
        nft.setEpochDraw(address(epochDraw));
        vm.stopPrank();
    }

    /// @dev Helper: declare `who` as the winner of (epoch, wordId) with answer (word, power, lang).
    function _setupWin(uint64 epochId, uint256 wordId, address who, string memory word, uint16 power, uint8 lang)
        internal
    {
        epochDraw.setWinner(epochId, wordId, who);
        epochDraw.setAnswer(epochId, wordId, word, power, lang);
    }

    function _signFuse(
        address holder,
        uint256 a,
        uint256 b,
        string memory newWord,
        uint16 newPower,
        uint8 newLang,
        bool success,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "ARDI_FUSE_V3",
                block.chainid,
                address(nft),
                holder,
                a,
                b,
                newWord,
                newPower,
                newLang,
                success,
                nonce
            )
        );
        bytes32 ethSigned =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(coordinatorPk, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    // ============================ Inscribe ===================================

    function test_inscribe_happyPath() public {
        _setupWin(1, 0, agent, "bitcoin", 100, 0);

        vm.prank(agent);
        nft.inscribe(1, 0, "bitcoin");

        assertEq(nft.ownerOf(1), agent); // tokenId = wordId + 1
        assertEq(nft.totalInscribed(), 1);
        assertTrue(nft.wordMinted(0));

        ArdiNFT.Inscription memory ins = nft.getInscription(1);
        assertEq(ins.word, "bitcoin");
        assertEq(ins.power, 100);
        assertEq(ins.languageId, 0);
        assertEq(ins.generation, 0);
        assertEq(ins.inscriber, agent);
    }

    function test_inscribe_revertsIfNotWinner() public {
        // agent2 is the declared winner, but agent calls inscribe
        _setupWin(1, 0, agent2, "bitcoin", 100, 0);

        vm.prank(agent);
        vm.expectRevert(ArdiNFT.NotWinner.selector);
        nft.inscribe(1, 0, "bitcoin");
    }

    function test_inscribe_revertsIfAnswerNotPublished() public {
        // Winner set but no answer
        epochDraw.setWinner(1, 0, agent);

        vm.prank(agent);
        vm.expectRevert(ArdiNFT.AnswerNotPublished.selector);
        nft.inscribe(1, 0, "any");
    }

    function test_inscribe_revertsIfWordAlreadyMinted() public {
        _setupWin(1, 0, agent, "bitcoin", 100, 0);
        vm.prank(agent);
        nft.inscribe(1, 0, "bitcoin");

        // Same word, different epoch, different agent — still blocked by wordMinted
        // (eligibility / bond gates are now in EpochDraw.commit, not here)
        _setupWin(2, 0, agent2, "bitcoin", 100, 0);
        vm.prank(agent2);
        vm.expectRevert(ArdiNFT.WordAlreadyMinted.selector);
        nft.inscribe(2, 0, "bitcoin");
    }

    function test_inscribe_capPerAgent() public {
        // Mint 3 different words across 3 epochs
        for (uint256 i; i < 3; i++) {
            string memory w = string(abi.encodePacked("w", vm.toString(i)));
            _setupWin(uint64(i + 1), i, agent, w, 50, 0);
            vm.prank(agent);
            nft.inscribe(uint64(i + 1), i, w);
        }
        assertEq(nft.balanceOf(agent), 3);

        // 4th attempt should fail (bond now reports isMiner=false because cap=3)
        _setupWin(4, 3, agent, "w3", 50, 0);
        vm.prank(agent);
        vm.expectRevert(ArdiNFT.AgentCapReached.selector);
        nft.inscribe(4, 3, "w3");
    }

    // NOTE: v2 dropped the BondEscrow.isMiner gate from inscribe.
    // Eligibility (AWP allocation) is enforced at commit-time in
    // ArdiEpochDraw, not here. The "NotMiner at inscribe" test is gone.

    function test_inscribe_invalidLanguage() public {
        _setupWin(1, 0, agent, "x", 50, 99);
        vm.prank(agent);
        vm.expectRevert(ArdiNFT.InvalidLanguage.selector);
        nft.inscribe(1, 0, "x");
    }

    function test_inscribe_invalidPower() public {
        _setupWin(1, 0, agent, "x", 0, 0);
        vm.prank(agent);
        vm.expectRevert(ArdiNFT.InvalidPower.selector);
        nft.inscribe(1, 0, "x");

        _setupWin(2, 1, agent, "x", 101, 0);
        vm.prank(agent);
        vm.expectRevert(ArdiNFT.InvalidPower.selector);
        nft.inscribe(2, 1, "x");
    }

    function test_inscribe_revertsIfEpochDrawNotSet() public {
        // Deploy a fresh NFT with no epochDraw set
        vm.startPrank(owner);
        ArdiNFT nft2 = new ArdiNFT(owner, coordinator, VAULT_ROOT);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(ArdiNFT.EpochDrawNotSet.selector);
        nft2.inscribe(1, 0, "any");
    }

    // ============================ Fuse =====================================

    function test_fuse_success() public {
        // Mint two originals
        _setupWin(1, 10, agent, "fire", 80, 0);
        _setupWin(2, 11, agent, "water", 60, 0);
        vm.startPrank(agent);
        nft.inscribe(1, 10, "fire");
        nft.inscribe(2, 11, "water");
        vm.stopPrank();

        // Fuse: success, new word "steam", power 280 (140 × 2.0×)
        bytes memory fsig = _signFuse(agent, 11, 12, "steam", 280, 0, true, 0);
        vm.prank(agent);
        nft.fuse(11, 12, "steam", 280, 0, true, fsig);

        // Both burned, new minted at 21001
        assertEq(nft.balanceOf(agent), 1);
        assertEq(nft.ownerOf(21_001), agent);

        ArdiNFT.Inscription memory ins = nft.getInscription(21_001);
        assertEq(ins.word, "steam");
        assertEq(ins.power, 280);
        assertEq(ins.generation, 1);
        assertEq(ins.parents.length, 2);
    }

    function test_fuse_failure_burnsLowerPower() public {
        _setupWin(1, 10, agent, "fire", 80, 0);
        _setupWin(2, 11, agent, "tofu", 30, 0);
        vm.startPrank(agent);
        nft.inscribe(1, 10, "fire");
        nft.inscribe(2, 11, "tofu");
        vm.stopPrank();

        bytes memory fsig = _signFuse(agent, 11, 12, "", 0, 0, false, 0);
        vm.prank(agent);
        nft.fuse(11, 12, "", 0, 0, false, fsig);

        assertEq(nft.balanceOf(agent), 1);
        assertEq(nft.ownerOf(11), agent); // fire stays
    }

    function test_fuse_nonceIncrementsBlocksReplay() public {
        _setupWin(1, 10, agent, "fire", 80, 0);
        _setupWin(2, 11, agent, "water", 60, 0);
        _setupWin(3, 12, agent, "wood", 40, 0);
        vm.startPrank(agent);
        nft.inscribe(1, 10, "fire");
        nft.inscribe(2, 11, "water");
        nft.inscribe(3, 12, "wood");
        vm.stopPrank();

        // First failure-fuse, nonce 0: burns wood (lowest power)
        bytes memory f1 = _signFuse(agent, 11, 13, "", 0, 0, false, 0);
        vm.prank(agent);
        nft.fuse(11, 13, "", 0, 0, false, f1);
        // tokenIds: 11 (fire), 12 (water) survive; 13 (wood) burned
        // v2: per-holder nonce — agent's nonce now 1; other addresses unaffected.
        assertEq(nft.fusionNonceOf(agent), 1);

        // Replay first sig with nonce 0 should fail (current nonce for agent is 1)
        vm.prank(agent);
        vm.expectRevert(ArdiNFT.InvalidSignature.selector);
        nft.fuse(11, 12, "", 0, 0, false, f1);
    }
}
