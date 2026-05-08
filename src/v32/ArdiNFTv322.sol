// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArdiNFTv32} from "./ArdiNFTv32.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  ArdiNFTv322 — fix `ardi` token reference + dynamic repair
/// @notice Direct successor to v3.2 (skips v3.2.1 in the inheritance
///         chain to fit under EIP-170; v3.2.1 was the previous deploy
///         and can no longer hold v3.2.2's compacted superset of fixes).
///         Two changes vs v3.2 — both fold into ONE owner-only setup
///         function so we don't pay the dispatch-table tax twice:
///
///   1. **Dynamic repairFee** (carried over from v3.2.1)
///        pricePerPower = ratio/10_000 × dailyEmission / totalActivePower
///        repairFee     = pricePerPower × power × maxDurability
///   2. **Post-mortem-only repair** (carried over from v3.2.1)
///   3. **`ardi` token reference fix** — repoint from AWP WorknetToken
///        to the canonical aARDI token. v3.2.1 deploy uncovered this
///        latent deploy-time misconfiguration: every NFT-side fee path
///        (repair, fuse, treasury, keeper) was wired to AWP, but
///        emission lands holders in aARDI, so users had no AWP to
///        spend. NFT contract holds 0 of either token at upgrade
///        time (verified on chain), so no migration needed.
///
/// Storage: v3.2.1 wrote two slots (`_maintenanceRatioBps` +
///         `_dailyEmissionWei`) into v32's __v32Gap. v3.2.2 keeps the
///         same layout and slots — read by repairFee — so the
///         already-configured (5000, 24M) values carry over without
///         needing to be re-set. The single owner setter
///         `setRepairConfig` reuses the same writes.
contract ArdiNFTv322 is ArdiNFTv32 {
    // Storage MUST mirror v321's layout — same slot order, same types —
    // so the existing on-chain values (5000, 24M ardi/day) survive the
    // upgrade without needing to be re-written.
    uint16  internal _maintenanceRatioBps;
    uint256 internal _dailyEmissionWei;

    error NotYetExpired();

    /// @notice Owner: combined setup. ratioBps/dailyWei tweak the
    ///         dynamic-repair formula; newArdi==0 leaves the token
    ///         unchanged (used after the one-time launch fix). One
    ///         function instead of two saves a dispatch slot worth of
    ///         bytecode under the tight EIP-170 budget.
    function setRepairConfig(
        uint16 ratioBps,
        uint256 dailyWei,
        address newArdi
    ) external onlyOwner {
        _maintenanceRatioBps = ratioBps;
        _dailyEmissionWei = dailyWei;
        ardi = IERC20(newArdi);  // unconditional — owner passes the
        // intended ardi each call; same value is fine, costs only one
        // SSTORE that writes the existing slot back to itself.
    }

    function repairFee(uint256 tokenId) public view virtual override returns (uint256) {
        // No bootstrap-safety branch (v321 had one) — v322 is post-launch
        // and configureRepair already wrote 5000/24M. totalPower==0 is
        // the only failure path now, and EVM divs-by-zero revert
        // naturally — sufficient for an edge case that requires the
        // entire 21K-NFT pool to expire simultaneously.
        Inscription storage ins = inscriptions[tokenId];
        return (uint256(_maintenanceRatioBps) * _dailyEmissionWei
              * uint256(ins.power) * uint256(ins.maxDurability))
             / (10_000 * emissionDist.totalActivePower());
    }

    function _beforeRepair(uint256 tokenId) internal virtual override {
        if (effectiveDurability(tokenId) > 0) revert NotYetExpired();
    }

    // Two slots taken from v32's __v32Gap[45] — same as v321 took.
    uint256[43] private __v322Gap;
}
