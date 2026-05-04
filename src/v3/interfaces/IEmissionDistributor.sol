// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IEmissionDistributor — hooks invoked by ArdiNFT v3 lifecycle.
/// @notice The distributor maintains the accPerShare reward index plus a per-NFT
///         power mirror (cached locally to avoid cross-contract reads on every
///         claim — Q9 default). ArdiNFT MUST call these hooks every time an NFT
///         enters or leaves the active set, or transfers between holders while
///         active.
interface IEmissionDistributor {
    /// @notice Called when an NFT becomes eligible to earn emission (mint, repair-success, fuse-mint).
    function onActivate(uint256 tokenId, address holder, uint256 power) external;

    /// @notice Called when an NFT stops earning emission (durability=0, broken, burned).
    ///         MUST settle pending rewards into the holder's claim balance before
    ///         removing power from the active set.
    function onDeactivate(uint256 tokenId, address holder) external;

    /// @notice Called on transfer of an active NFT. Settles the from-holder's
    ///         accrued rewards and re-attributes future rewards to `to`.
    function onTransfer(uint256 tokenId, address from, address to) external;

    /// @notice Push fresh emission into the pool. Caller is the operator that
    ///         received daily mint from WorknetToken (Q1: Operator address, not the
    ///         distributor itself, holds the minter role).
    function notifyReward(uint256 amount) external;
}
