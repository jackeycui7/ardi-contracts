// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArdiNFT} from "../src/ArdiNFT.sol";
import {ArdiOTC} from "../src/ArdiOTC.sol";
import {ArdiToken} from "../src/ArdiToken.sol";
import {MockEpochDraw} from "./Mocks.sol";

/// @title Adversary tests — every attack we can think of, must all revert.
/// @notice v2 dropped BondEscrow + slash. Eligibility is at EpochDraw.commit.
///         What remains in this file: cap bypass, fuse signature replay,
///         OTC seller protection, mint authority. Bond/slash adversary
///         tests went away with the contract.
contract AdversaryTest is Test {
    ArdiNFT nft;
    ArdiOTC otc;
    ArdiToken token;
    MockEpochDraw epochDraw;

    address owner = address(0xA11CE);
    uint256 coordPk = 0xC00D;
    address coord;
    uint256 attackerPk = 0xBAD;
    address attacker;
    address victim = address(0x1234);

    function setUp() public {
        coord = vm.addr(coordPk);
        attacker = vm.addr(attackerPk);
        epochDraw = new MockEpochDraw();

        vm.startPrank(owner);
        token = new ArdiToken(owner);
        nft = new ArdiNFT(owner, coord, bytes32(0));
        nft.setEpochDraw(address(epochDraw));
        otc = new ArdiOTC(owner, address(nft));
        vm.stopPrank();
    }

    /// @dev Helper: declare a winner + answer in MockEpochDraw.
    function _setupWin(uint64 epochId, uint256 wordId, address who, string memory word, uint16 power, uint8 lang)
        internal
    {
        epochDraw.setWinner(epochId, wordId, who);
        epochDraw.setAnswer(epochId, wordId, word, power, lang);
    }

    // ============ Inscribe authorization attacks ============

    function test_attack_inscribeAsNonWinner() public {
        // EpochDraw says victim won; attacker tries to mint
        _setupWin(1, 0, victim, "bitcoin", 100, 0);
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.NotWinner.selector);
        nft.inscribe(1, 0, "bitcoin");
    }

    function test_attack_inscribeWithoutAnyWinnerSet() public {
        // Neither winner nor answer published
        vm.prank(attacker);
        // winners[1][0] is address(0); attacker is non-zero, so NotWinner
        vm.expectRevert(ArdiNFT.NotWinner.selector);
        nft.inscribe(1, 0, "any");
    }

    function test_attack_inscribeWordIdOutOfRange() public {
        _setupWin(1, 21_000, attacker, "x", 50, 0);
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.InvalidWordId.selector);
        nft.inscribe(1, 21_000, "x");
    }

    function test_attack_inscribeAfterCap() public {
        for (uint256 i; i < 3; i++) {
            string memory w = string(abi.encodePacked("w", vm.toString(i)));
            _setupWin(uint64(i + 1), i, attacker, w, 50, 0);
            vm.prank(attacker);
            nft.inscribe(uint64(i + 1), i, w);
        }

        // 4th attempt: AgentCapReached before any other gate.
        _setupWin(4, 3, attacker, "w3", 50, 0);
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.AgentCapReached.selector);
        nft.inscribe(4, 3, "w3");
    }

    function test_attack_doubleInscribeSameWordIdAcrossEpochs() public {
        _setupWin(1, 0, attacker, "bitcoin", 100, 0);
        vm.prank(attacker);
        nft.inscribe(1, 0, "bitcoin");

        _setupWin(2, 0, victim, "bitcoin", 100, 0);
        vm.prank(victim);
        vm.expectRevert(ArdiNFT.WordAlreadyMinted.selector);
        nft.inscribe(2, 0, "bitcoin");
    }

    // Bond / slash adversary tests removed in v2 — BondEscrow is gone.
    // Equivalent eligibility-bypass attacks are in ArdiEpochDraw.t.sol
    // (commit-time AWP allocation gate).

    // ============ Token / mint authority attacks ============

    function test_attack_mintBypassController() public {
        vm.prank(attacker);
        vm.expectRevert(ArdiToken.NotMinter.selector);
        token.mint(attacker, 1 ether);
    }

    function test_attack_setMinterAfterLock() public {
        vm.startPrank(owner);
        token.setMinter(address(0xC0FFEE));
        token.lockMinter();
        vm.expectRevert(ArdiToken.MinterLocked.selector);
        token.setMinter(attacker);
        vm.stopPrank();
    }

    function test_attack_mintLpDoubleSpend() public {
        // After C-1 fix, mintLp is one-shot — second call must revert.
        vm.startPrank(owner);
        token.mintLp(attacker, 1_000_000_000 ether);
        vm.expectRevert(ArdiToken.LpAlreadyMinted.selector);
        token.mintLp(attacker, 1_000_000_000 ether);
        vm.stopPrank();
    }

    function test_attack_mintBeyondCap() public {
        vm.startPrank(owner);
        token.setMinter(address(this));
        vm.stopPrank();

        // Cap = 10B; mintLp 1B (one-shot consumed) then minter tries 9.5B (would exceed)
        vm.prank(owner);
        token.mintLp(attacker, 1_000_000_000 ether);

        vm.expectRevert(ArdiToken.CapExceeded.selector);
        token.mint(attacker, 9_500_000_000 ether);
    }

    // ============ Fuse attacks ============

    function _signFuseV2(
        address holder,
        uint256 a,
        uint256 b,
        string memory newWord,
        uint16 newPower,
        uint8 newLang,
        bool success,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 d = keccak256(
            abi.encodePacked(
                "ARDI_FUSE_V2",
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
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", d));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(coordPk, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    function test_attack_fuseSomeoneElsesTokens() public {
        _setupWin(1, 0, attacker, "w0", 50, 0);
        vm.prank(attacker);
        nft.inscribe(1, 0, "w0");

        _setupWin(2, 1, victim, "w1", 50, 0);
        vm.prank(victim);
        nft.inscribe(2, 1, "w1");

        // Attacker tries to fuse with victim's token (id 2). Coordinator-signed
        // for attacker, but attacker doesn't own token 2.
        bytes memory fsig = _signFuseV2(attacker, 1, 2, "x", 100, 0, true, 0);
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.NotTokenOwner.selector);
        nft.fuse(1, 2, "x", 100, 0, true, fsig);
    }

    function test_attack_fuseSameToken() public {
        _setupWin(1, 0, attacker, "w0", 50, 0);
        vm.prank(attacker);
        nft.inscribe(1, 0, "w0");

        bytes memory fsig = _signFuseV2(attacker, 1, 1, "x", 100, 0, true, 0);
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.SameTokenId.selector);
        nft.fuse(1, 1, "x", 100, 0, true, fsig);
    }

    function test_attack_fuseSigStolen_differentHolderRejected() public {
        // V2 binds msg.sender — a sig signed for `victim` cannot be used by attacker
        _setupWin(1, 0, attacker, "w0", 50, 0);
        _setupWin(2, 1, attacker, "w1", 50, 0);
        vm.startPrank(attacker);
        nft.inscribe(1, 0, "w0");
        nft.inscribe(2, 1, "w1");
        vm.stopPrank();

        // Coordinator signs a fuse for VICTIM as holder
        bytes memory victimFsig = _signFuseV2(victim, 1, 2, "x", 100, 0, true, 0);

        // attacker tries to redeem it; digest mismatch → InvalidSignature
        vm.prank(attacker);
        vm.expectRevert(ArdiNFT.InvalidSignature.selector);
        nft.fuse(1, 2, "x", 100, 0, true, victimFsig);
    }

    // ============ OTC attacks ============

    function test_attack_listSomeoneElsesNFT() public {
        _setupWin(1, 0, victim, "w0", 50, 0);
        vm.prank(victim);
        nft.inscribe(1, 0, "w0");

        vm.prank(attacker);
        vm.expectRevert(ArdiOTC.NotOwner.selector);
        otc.list(1, 1 ether);
    }

    function test_attack_unlistSomeoneElsesListing() public {
        _setupWin(1, 0, victim, "w0", 50, 0);
        vm.prank(victim);
        nft.inscribe(1, 0, "w0");

        vm.startPrank(victim);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(ArdiOTC.NotOwner.selector);
        otc.unlist(1);
    }

    function test_attack_buyOwnListing() public {
        _setupWin(1, 0, attacker, "w0", 50, 0);
        vm.prank(attacker);
        nft.inscribe(1, 0, "w0");

        vm.startPrank(attacker);
        nft.approve(address(otc), 1);
        otc.list(1, 1 ether);
        vm.deal(attacker, 1 ether);
        vm.expectRevert(ArdiOTC.CallerIsSeller.selector);
        otc.buy{value: 1 ether}(1);
        vm.stopPrank();
    }
}
