// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IArdiOTC {
    function buy(uint256 tokenId) external payable;
}

/// @title  OtcSweeper — batch-buy across ArdiOTC listings in a single tx.
/// @notice Solves the "10 wallet prompts to buy 10 floor NFTs" UX wart.
///         Caller sends ETH covering the sum of priceCaps and gets:
///           - every successfully-bought NFT forwarded to their wallet
///           - any unspent ETH refunded at the end (failed listings +
///             OTC's per-buy excess refunds)
///
/// Failure model: a listing that's already sold / unlisted / had its
///   price changed under us → `OTC.buy()` reverts → try/catch swallows,
///   the loop continues, and that ETH stays with this contract for the
///   final refund. Atomically all-or-nothing IS NOT what we want here:
///   half-filling a sweep is more useful than reverting the whole batch
///   when a single listing got front-run.
///
/// Trust model: this contract holds NFTs only inside `sweep()`'s loop —
///   never across calls. Anyone can call sweep with any tokenIds. There
///   is no admin, no upgradeability, no token approvals to set. Loss
///   surface is bounded to "ETH sent in this tx" (refunded on failure).
contract OtcSweeper is IERC721Receiver, ReentrancyGuard {
    /// @notice ArdiOTC marketplace address. Immutable so the sweeper is
    ///         pinned to one marketplace — if OTC ever gets redeployed,
    ///         deploy a new sweeper alongside.
    IArdiOTC public immutable OTC;

    /// @notice ArdiNFT proxy address. Same reasoning as OTC.
    IERC721 public immutable ARDI_NFT;

    /// @notice One log line per attempted buy. `bought=true` for the
    ///         successful ones; `bought=false` for skipped (revert).
    ///         Frontends can show a per-row "✓ / —" without re-parsing
    ///         OTC's `Sold` events.
    event SweepLine(uint256 indexed tokenId, bool bought, uint256 spent);

    /// @notice Final summary: how many of N attempts landed and total ETH spent.
    event SweepDone(address indexed recipient, uint256 attempted, uint256 bought, uint256 spent);

    error LengthMismatch();
    error EmptyBatch();
    error InsufficientPayment();
    error RefundFailed();

    constructor(address otc, address ardiNft) {
        OTC = IArdiOTC(otc);
        ARDI_NFT = IERC721(ardiNft);
    }

    /// @notice Buy each `(tokenIds[i], prices[i])` from ArdiOTC, forwarding
    ///         the NFT to msg.sender on success and refunding all unspent
    ///         ETH at the end.
    /// @param tokenIds Listings to attempt, in order.
    /// @param prices   Per-listing price cap (must equal current listing
    ///                 price; OTC reverts on lower, sweeper retains
    ///                 excess if higher and refunds at the end). Pass
    ///                 the price your UI showed the user — protects
    ///                 against the seller hiking price under you.
    function sweep(uint256[] calldata tokenIds, uint256[] calldata prices)
        external
        payable
        nonReentrant
    {
        uint256 n = tokenIds.length;
        if (n == 0) revert EmptyBatch();
        if (prices.length != n) revert LengthMismatch();

        uint256 sumPrices;
        unchecked {
            for (uint256 i; i < n; ++i) sumPrices += prices[i];
        }
        if (msg.value < sumPrices) revert InsufficientPayment();

        address recipient = msg.sender;
        uint256 boughtCount;
        uint256 totalSpent;

        for (uint256 i; i < n; ++i) {
            uint256 tid = tokenIds[i];
            uint256 priceCap = prices[i];

            try OTC.buy{value: priceCap}(tid) {
                // OTC sent NFT to this contract via safeTransferFrom.
                // Forward to the buyer immediately; the contract should
                // never own NFTs outside the body of this call.
                ARDI_NFT.safeTransferFrom(address(this), recipient, tid);
                emit SweepLine(tid, true, priceCap);
                unchecked {
                    ++boughtCount;
                    totalSpent += priceCap;
                }
            } catch {
                // Listing gone, price changed, race-loss, etc — swallow,
                // continue. ETH for this attempt stays in the contract
                // (try/catch rolls back the failed call, including the
                // value transfer) and rolls into the final refund.
                emit SweepLine(tid, false, 0);
            }
        }

        // Refund anything we still hold: untouched-on-failure ETH +
        // OTC's per-success excess refunds. Single end-of-loop transfer.
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            (bool ok, ) = recipient.call{value: leftover}("");
            if (!ok) revert RefundFailed();
        }

        emit SweepDone(recipient, n, boughtCount, totalSpent);
    }

    /// @notice IERC721Receiver — required to receive NFTs via
    ///         `safeTransferFrom`. We accept anything but never hold
    ///         NFTs across calls (each is forwarded inside sweep()).
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Receive plain ETH transfers (used by OTC's per-buy excess
    ///         refunds). No fallback because we don't want to be a
    ///         catch-all sink for stray sends — `receive` is enough for
    ///         the OTC refund path which is a plain `.call{value}("")`.
    receive() external payable {}
}
