// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArdiNFTv32} from "./ArdiNFTv32.sol";

/// @title  ArdiNFTv321 — dynamic repair pricing
/// @notice Patch upgrade over v32. Two changes, both around `repair()`:
///
///   1. **Dynamic repairFee** — formula now ties cost to the NFT's
///      expected lifetime earnings:
///
///        pricePerPower = maintenanceRatioBps / 10_000
///                      × dailyEmissionWei / totalActivePower
///        repairFee     = pricePerPower × power × maxDurability
///
///      So a power-50 maxDur-10 NFT pays half its remaining lifetime
///      earnings to repair, regardless of supply. Both ratios are
///      admin-tunable via `setMaintenanceRatio` and `setDailyEmission`
///      so launch-day surprises can be patched without a redeploy.
///
///   2. **Post-mortem repair only** — repair now requires
///      `effectiveDurability(tokenId) == 0`. Preemptive refresh (the v32
///      behavior, where a holder could pay anytime to top up to
///      maxDurability) is gone. The new flow forces NFTs through their
///      natural expiration before redemption — sky-mandated to prevent
///      whales from rolling NFTs forever.
///
/// Storage: appends two slots from v32's __v32Gap (which currently has
/// 45 free, see v32). UUPS-safe — existing slots untouched.
contract ArdiNFTv321 is ArdiNFTv32 {
    // ============================ V321 storage ===========================

    /// @notice Maintenance ratio (bps) + daily emission target. Frontend
    ///         can preview pricing via `repairFee(tokenId)`; the raw
    ///         params are intentionally not auto-getter'd to save
    ///         bytecode (EIP-170).
    uint16  internal _maintenanceRatioBps;
    uint256 internal _dailyEmissionWei;

    // ============================ V321 errors ============================

    error NotYetExpired();

    // ============================ Setup =================================

    /// @notice Owner: set both dynamic-repair params atomically.
    ///         Recommended: ratio=5000 (0.5×), daily=24_000_000e18.
    ///         No event/cap to keep bytecode under EIP-170 — values are
    ///         visible via `repairFee()` on any token, and the surface
    ///         is owner-only anyway.
    function configureRepair(uint16 ratioBps, uint256 dailyWei) external onlyOwner {
        _maintenanceRatioBps = ratioBps;
        _dailyEmissionWei = dailyWei;
    }

    // ===================== Dynamic repairFee override ====================

    /// @notice Repair fee for `tokenId` under the v3.2.1 formula. Reverts
    ///         (NotYetExpired, reused as a generic "not callable yet"
    ///         signal — separate selector would push us over EIP-170)
    ///         when the dynamic params haven't been configured or the
    ///         active pool is empty. Owner MUST call configureRepair
    ///         atomically with the upgrade so this branch is unreachable
    ///         in production.
    function repairFee(uint256 tokenId) public view virtual override returns (uint256) {
        uint16 ratio = _maintenanceRatioBps;
        uint256 daily = _dailyEmissionWei;
        uint256 totalPower = emissionDist.totalActivePower();
        if (ratio == 0 || daily == 0 || totalPower == 0) revert NotYetExpired();
        Inscription storage ins = inscriptions[tokenId];
        // pricePerPower = ratio/10_000 × daily / totalPower; multiply
        // numerators first to keep precision, then divide once.
        return (uint256(ratio) * daily * uint256(ins.power) * uint256(ins.maxDurability))
             / (10_000 * totalPower);
    }

    // =========================== Repair gate =============================

    /// @notice Override of v3's `_beforeRepair` hook. Requires the NFT
    ///         has fully expired (effectiveDurability == 0) before a
    ///         repair can be initiated. Preemptive refresh — the v32
    ///         behavior — is no longer allowed; whales can't roll a
    ///         high-power NFT forever by paying maintenance.
    function _beforeRepair(uint256 tokenId) internal virtual override {
        if (effectiveDurability(tokenId) > 0) revert NotYetExpired();
    }

    // ============================ Storage gap ============================

    // Two slots taken from v32's __v32Gap[45]. Updated to keep the gap
    // at the end of v32 storage; UUPS layout invariant preserved.
    uint256[43] private __v321Gap;
}
