// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ArdiOTC — peer-to-peer Ardinal trading
/// @notice Zero-fee P2P listing for Ardinal NFTs. Sellers list at fixed prices in
///         native currency (ETH on Base). Buyers pay in full; 100% goes to seller.
///         Fusion mechanic requires both Ardinals at the same address, which drives
///         genuine OTC demand — agents who maxed their 3-mint cap need to acquire
///         more via this market to participate in The Forge.
/// @dev    Listings are non-custodial: the NFT stays in the seller's wallet, only
///         requiring approval to this contract. Cancellation is implicit on transfer
///         or revoke.
contract ArdiOTC is ReentrancyGuard, Ownable2Step {
    IERC721 public immutable ARDI_NFT;

    struct Listing {
        address seller;
        uint256 priceWei;
        uint64 listedAt;
    }

    /// @notice tokenId → Listing struct
    mapping(uint256 => Listing) public listings;

    event Listed(address indexed seller, uint256 indexed tokenId, uint256 priceWei);
    event Unlisted(address indexed seller, uint256 indexed tokenId);
    event Sold(
        address indexed seller, address indexed buyer, uint256 indexed tokenId, uint256 priceWei
    );

    error NotOwner();
    error ZeroPrice();
    error NotListed();
    error InsufficientPayment();
    error TransferFailed();
    error CallerIsSeller();

    constructor(address initialOwner, address ardiNFT_) Ownable(initialOwner) {
        ARDI_NFT = IERC721(ardiNFT_);
    }

    /// @notice List an Ardinal for sale at fixed wei price.
    /// @dev    Caller must own the token AND have approved this contract OR
    ///         set this contract as operator via setApprovalForAll.
    function list(uint256 tokenId, uint256 priceWei) external {
        if (ARDI_NFT.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (priceWei == 0) revert ZeroPrice();

        listings[tokenId] = Listing({
            seller: msg.sender,
            priceWei: priceWei,
            listedAt: uint64(block.timestamp)
        });

        emit Listed(msg.sender, tokenId, priceWei);
    }

    /// @notice Remove an active listing. Only callable by current seller / owner.
    function unlist(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotOwner();
        delete listings[tokenId];
        emit Unlisted(msg.sender, tokenId);
    }

    /// @notice Buy a listed Ardinal. Pays full price in ETH; 100% to seller, no fee.
    /// @dev    Verifies seller still owns the token at execution time (defends against
    ///         stale listings). Refunds any excess ETH sent.
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (msg.value < l.priceWei) revert InsufficientPayment();
        if (l.seller == msg.sender) revert CallerIsSeller();

        // Verify seller still owns it (defense vs. stale listing after transfer)
        if (ARDI_NFT.ownerOf(tokenId) != l.seller) {
            delete listings[tokenId];
            revert NotListed();
        }

        delete listings[tokenId];

        // Pull NFT from seller (requires prior approval)
        ARDI_NFT.safeTransferFrom(l.seller, msg.sender, tokenId);

        // Pay seller
        (bool ok,) = l.seller.call{value: l.priceWei}("");
        if (!ok) revert TransferFailed();

        // Refund excess
        if (msg.value > l.priceWei) {
            (bool refundOk,) = msg.sender.call{value: msg.value - l.priceWei}("");
            if (!refundOk) revert TransferFailed();
        }

        emit Sold(l.seller, msg.sender, tokenId, l.priceWei);
    }

    // --- Views ---

    function getListing(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }

    function isListed(uint256 tokenId) external view returns (bool) {
        return listings[tokenId].seller != address(0);
    }
}
