// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OtcSweeper} from "../src/OtcSweeper.sol";

interface IArdiOTC {
    function list(uint256 tokenId, uint256 priceWei) external;
    function unlist(uint256 tokenId) external;
    function buy(uint256 tokenId) external payable;
    function getListing(uint256 tokenId) external view returns (
        address seller, uint256 priceWei, uint64 listedAt
    );
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// @notice Fork test: deploy OtcSweeper against the real mainnet OTC + NFT,
///   prank a few real holders into listing their NFTs, then sweep them
///   from a fresh buyer wallet. Verifies happy path + skip-on-failure.
///
/// Run: forge test --match-path test/OtcSweeperFork.t.sol \
///        --fork-url https://mainnet.base.org -vv
contract OtcSweeperForkTest is Test {
    address constant OTC      = 0xEd4A2B66756fB3aB0f7a4fC9d442dccF3162B68F;
    address constant ARDI_NFT = 0xf68425D0d451699d0d766150634E436Acd2F05A1;

    OtcSweeper sweeper;
    address buyer = address(0xB44E5);

    // Pre-checked tokenIds — pulled by reading first 3 active NFTs on
    // chain. Re-runnable: if any of these get burned/transferred we
    // just pick fresh ones.
    uint256[3] sampleTokenIds = [uint256(4), 34, 47];

    function setUp() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        sweeper = new OtcSweeper(OTC, ARDI_NFT);
        vm.deal(buyer, 10 ether);
    }

    // ──────────────────────────── tests ─────────────────────────────

    /// 3 listings -> sweep all 3 -> buyer gets all 3 NFTs + correct refund.
    function test_fork_sweep_happyPath_allSucceed() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        uint256[] memory tids = new uint256[](3);
        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.001 ether;
        prices[1] = 0.002 ether;
        prices[2] = 0.003 ether;
        uint256 totalAsk;
        for (uint i; i < 3; i++) {
            tids[i] = sampleTokenIds[i];
            totalAsk += prices[i];
            _listAs(IERC721Min(ARDI_NFT).ownerOf(tids[i]), tids[i], prices[i]);
        }

        // Send EXTRA ETH to verify refund path.
        uint256 sent = totalAsk + 0.5 ether;
        uint256 buyerBalBefore = buyer.balance;
        vm.prank(buyer);
        sweeper.sweep{value: sent}(tids, prices);

        // All NFTs landed in buyer's wallet
        for (uint i; i < 3; i++) {
            assertEq(IERC721Min(ARDI_NFT).ownerOf(tids[i]), buyer, "buyer owns it");
        }
        // Buyer paid exactly totalAsk; the 0.5 extra refunded
        uint256 spent = buyerBalBefore - buyer.balance;
        assertEq(spent, totalAsk, "buyer spent only totalAsk");
        // Sweeper holds zero ETH and zero NFTs
        assertEq(address(sweeper).balance, 0, "sweeper drained");
    }

    /// 3 listings, but tid #2 is unlisted under us mid-sweep (front-run /
    /// race) -> sweeper skips that one, keeps going, refunds its share.
    function test_fork_sweep_skipsFailedListing() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        uint256[] memory tids = new uint256[](3);
        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.001 ether;
        prices[1] = 0.002 ether;
        prices[2] = 0.003 ether;
        for (uint i; i < 3; i++) {
            tids[i] = sampleTokenIds[i];
            _listAs(IERC721Min(ARDI_NFT).ownerOf(tids[i]), tids[i], prices[i]);
        }
        // Race-unlist the middle one before the sweep call.
        (address midSeller, , ) = IArdiOTC(OTC).getListing(tids[1]);
        vm.prank(midSeller);
        IArdiOTC(OTC).unlist(tids[1]);

        uint256 sent = 0.006 ether + 0.4 ether;
        uint256 buyerBalBefore = buyer.balance;
        vm.prank(buyer);
        sweeper.sweep{value: sent}(tids, prices);

        // tid 0 + tid 2 -> buyer; tid 1 -> still original seller
        assertEq(IERC721Min(ARDI_NFT).ownerOf(tids[0]), buyer, "tid0 -> buyer");
        assertNotEq(IERC721Min(ARDI_NFT).ownerOf(tids[1]), buyer, "tid1 NOT -> buyer");
        assertEq(IERC721Min(ARDI_NFT).ownerOf(tids[2]), buyer, "tid2 -> buyer");

        // Buyer should have paid only 0.001 + 0.003 = 0.004 ETH; the
        // skipped 0.002 + the 0.4 padding refunded.
        uint256 spent = buyerBalBefore - buyer.balance;
        assertEq(spent, 0.001 ether + 0.003 ether, "spent = bought legs only");
        assertEq(address(sweeper).balance, 0, "sweeper drained");
    }

    /// Empty input + length-mismatch + insufficient ETH all revert cleanly.
    function test_fork_sweep_inputValidation() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        uint256[] memory empty = new uint256[](0);
        uint256[] memory emptyP = new uint256[](0);
        vm.expectRevert(OtcSweeper.EmptyBatch.selector);
        sweeper.sweep{value: 0}(empty, emptyP);

        uint256[] memory tids = new uint256[](2);
        uint256[] memory prices = new uint256[](3);
        vm.expectRevert(OtcSweeper.LengthMismatch.selector);
        sweeper.sweep{value: 0}(tids, prices);

        uint256[] memory tids2 = new uint256[](1);
        uint256[] memory prices2 = new uint256[](1);
        prices2[0] = 1 ether;
        vm.expectRevert(OtcSweeper.InsufficientPayment.selector);
        sweeper.sweep{value: 0.5 ether}(tids2, prices2);
    }

    // ───────────────────────── helpers ──────────────────────────────

    function _listAs(address seller, uint256 tid, uint256 price) internal {
        // The seller has to approve the OTC for transferFrom before
        // listing actually moves anything. We prank both calls.
        vm.startPrank(seller);
        if (!IERC721Min(ARDI_NFT).isApprovedForAll(seller, OTC)) {
            IERC721Min(ARDI_NFT).setApprovalForAll(OTC, true);
        }
        IArdiOTC(OTC).list(tid, price);
        vm.stopPrank();
    }
}
