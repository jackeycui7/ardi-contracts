// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArdiNFTv3} from "../v3/ArdiNFTv3.sol";

/// @title  ArdiNFTv32 — round-based durability + repair-reactivate fix
/// @notice UUPS upgrade over ArdiNFTv3. Two semantic shifts:
///
///   1. Durability decay is now driven by **reward rounds**, not wall-clock.
///      The owner-side EmissionDistributorV2 calls `bumpDecayRound()` once
///      per `notifyReward`, which atomically increments `globalDecayRound`
///      and removes any NFTs whose `expirationRound` matches the new round
///      from the active power pool. NFTs with `dura > 0` participate in
///      that round's reward distribution; their dura is then -1 by virtue
///      of the round counter advancing. NFTs with `dura == 0` are excluded
///      from the denominator of the next round automatically.
///
///   2. Repair after expiration now correctly re-activates the NFT. v3 had
///      a latent bug: an NFT that hit `effectiveDurability == 0` and was
///      kicked out of the pool by `expireToZero` could be paid for via
///      `repair()` and durability would refresh, but the contract never
///      re-added it to `EmissionDistributor.totalActivePower`. The owner
///      paid the repair fee for nothing. v32's `_onRepairRandomness`
///      success path now calls `_activate` if the NFT is no longer
///      tracked.
///
/// Storage layout: this contract appends new state after v3's. The 50-slot
/// __gap in ArdiNFTv3 is consumed for these. UUPS upgrade safe.
///
/// IMPORTANT MIGRATION NOTE
/// ────────────────────────
/// Existing NFTs from v3 carry `lastDecayCheckpoint = block.timestamp at
/// mint`. Their `expirationRound` slot is 0 by default after upgrade.
/// Owner MUST call `migrateExisting(uint256[] tokenIds)` in batches before
/// the first `notifyReward` after upgrade — without this, every active
/// pre-v32 NFT would have `expirationRound == 0` and get evicted on the
/// first round bump (they'd lose their durability instantly). Migration
/// resets each NFT to `currentDurability == maxDurability` and registers
/// `expirationRound = 0 + maxDurability`, giving every existing holder a
/// full-charge restart.
contract ArdiNFTv32 is ArdiNFTv3 {
    // ============================ V32 storage ============================
    //
    // All new fields appended via the v3 __gap. Do NOT reorder.

    /// @notice Reward-round counter. Incremented exactly once per
    ///         `EmissionDistributorV2.notifyReward`. Starts at 0.
    uint64 public globalDecayRound;

    /// @notice Sum of `power` of NFTs whose `expirationRound` equals R.
    ///         When `notifyReward` advances the round, the new round's
    ///         entry is read once (O(1)) and that much power is removed
    ///         from the active pool.
    mapping(uint64 => uint128) public expiringPowerAt;

    /// @notice Per-token absolute round at which it last earns. Computed
    ///         at activate / repair as `globalDecayRound + currentDurability`.
    mapping(uint256 => uint64) public expirationRoundOf;

    /// @notice True for tokens that have already been migrated from the
    ///         v3 time-decay model into the v32 round model. Existing
    ///         holders get refreshed to maxDurability the first time
    ///         migrateExisting visits them; this flag prevents double-credit.
    mapping(uint256 => bool) public v32Migrated;

    // ============================ V32 events ============================

    event DecayRoundBumped(uint64 indexed newRound, uint128 expiredPower);
    event V32Migrated(uint256 indexed tokenId, uint8 newDurability, uint64 expirationRound);
    event AdminDurabilitySet(uint256 indexed tokenId, uint8 oldValue, uint8 newValue);
    event AdminMaxDurabilitySet(uint256 indexed tokenId, uint8 oldValue, uint8 newValue);
    event AdminBumpedAll(uint8 by);
    event AdminRoundRewound(uint64 by, uint64 newRound);

    // ============================ V32 errors ============================

    error NotEmissionDistributor();
    error AlreadyMigrated();
    error NotActiveTracked();
    // InvalidDurability re-uses the inherited declaration from ArdiNFTv3.
    error CannotRewindBelowZero();

    // =========================== Round bump =============================

    /// @notice Called by EmissionDistributorV2.notifyReward exactly once
    ///         per round. Atomically:
    ///           1. globalDecayRound++
    ///           2. Look up `expiringPowerAt[newRound]`
    ///           3. Return that value to the caller, who is responsible
    ///              for decrementing its own `totalActivePower` accordingly.
    /// @return expiredPower power leaving the pool this round (≥0)
    /// @return newRound the value of `globalDecayRound` after the bump
    /// @dev Only the EmissionDistributor proxy may call. Restricting via
    ///      address comparison avoids a circular interface — the
    ///      distributor address is already set on this contract via
    ///      `setEmissionDistributor` (inherited from v3).
    function bumpDecayRound() external returns (uint128 expiredPower, uint64 newRound) {
        if (msg.sender != address(emissionDist)) revert NotEmissionDistributor();
        unchecked {
            newRound = globalDecayRound + 1;
        }
        globalDecayRound = newRound;
        expiredPower = expiringPowerAt[newRound];
        if (expiredPower != 0) {
            // Free the slot so subsequent round bumps don't re-read stale
            // values if any future logic ever revisits the round.
            delete expiringPowerAt[newRound];
        }
        emit DecayRoundBumped(newRound, expiredPower);
    }

    // ====================== effectiveDurability override =================

    /// @notice Round-based effective durability.
    ///
    ///   roundsConsumed = globalDecayRound - lastSyncedRound
    ///   effective      = currentDurability - roundsConsumed (clamped to 0)
    ///
    /// We store `lastSyncedRound` implicitly via `expirationRoundOf` and
    /// `currentDurability`: at any sync point, `expirationRoundOf` is set
    /// to `globalDecayRound + currentDurability`, so reading them back
    /// yields `roundsRemaining = expirationRoundOf - globalDecayRound`.
    function effectiveDurability(uint256 tokenId)
        public
        view
        virtual
        override
        returns (uint8)
    {
        Inscription storage ins = inscriptions[tokenId];
        if (ins.broken) return 0;
        if (!ins.activeTracked) return 0;
        uint64 expR = expirationRoundOf[tokenId];
        uint64 cur = globalDecayRound;
        if (expR <= cur) return 0;
        uint64 remaining = expR - cur;
        if (remaining > type(uint8).max) return type(uint8).max;
        return uint8(remaining);
    }

    // ===================== _activate / _deactivate =======================

    /// @notice Override registers the NFT's expiration round in
    ///         `expiringPowerAt[round]` so the round-bump path can pop it
    ///         out of the active pool atomically when its time comes.
    function _activate(uint256 tokenId, address holder) internal virtual override {
        super._activate(tokenId, holder);
        Inscription storage ins = inscriptions[tokenId];
        // Compute expiration round = currentRound + currentDurability.
        // For freshly-minted NFTs, currentDurability == maxDurability.
        // For repair-reactivation, currentDurability has been refreshed
        // to maxDurability by the repair() path before _activate fires.
        uint64 expR = globalDecayRound + uint64(ins.currentDurability);
        expirationRoundOf[tokenId] = expR;
        expiringPowerAt[expR] += uint128(ins.power);
    }

    /// @notice Override unregisters the NFT from the expiration registry
    ///         so a later round bump doesn't double-count its power.
    ///         Safe even if the registration was already consumed (e.g.
    ///         because notifyReward already evicted it) — the subtraction
    ///         is guarded against underflow.
    /// @dev IMPORTANT: we do NOT delete `expirationRoundOf` before calling
    ///      super. The EmissionDistributorV2.onDeactivate hook reads it to
    ///      decide whether to decrement totalActivePower (skipping when
    ///      the NFT was already bump-evicted in a prior notifyReward).
    ///      Cleared after super so future re-activates start fresh.
    function _deactivate(uint256 tokenId, address holder) internal virtual override {
        uint64 expR = expirationRoundOf[tokenId];
        if (expR > globalDecayRound) {
            // Active in pool — pull our power back out of the future bucket.
            uint128 p = uint128(inscriptions[tokenId].power);
            uint128 cur = expiringPowerAt[expR];
            expiringPowerAt[expR] = cur > p ? cur - p : 0;
        }
        super._deactivate(tokenId, holder);
        delete expirationRoundOf[tokenId];
    }

    // =========================== Repair fix ==============================

    /// @notice On a successful repair VRF callback, restore the NFT to
    ///         the active pool if it had been kicked out (by expireToZero).
    ///         v3 didn't do this — the holder paid the fee + got
    ///         currentDurability refreshed but the contract never called
    ///         `_activate`, leaving the NFT silent in EmissionDistributor.
    ///         v32 patches this by calling _activate when ins.activeTracked
    ///         is false at fulfilment time. If still tracked, just bump
    ///         the expiration round forward (the pool position is preserved).
    function _onRepairRandomness(uint256 reqId, PendingRequest memory req, uint256 r)
        internal
        virtual
        override
    {
        bool failed = (r % BPS_DENOM) < REPAIR_FAIL_BPS;
        if (failed) {
            // Failure path unchanged: settle as broken, deactivate.
            super._onRepairRandomness(reqId, req, r);
            return;
        }

        // Success path. The base implementation flushes the sink + cleans
        // up `pendingRepairOf`. We DON'T defer to super because we need
        // to also re-activate or refresh expiration BEFORE the cleanup,
        // and super conflates both.
        Inscription storage ins = inscriptions[req.tokenId];
        if (!ins.activeTracked) {
            // NFT was kicked out (expireToZero). Re-activate. _activate
            // computes expirationRound from the freshly refreshed
            // currentDurability (which repair() set to maxDurability
            // before scheduling the VRF request).
            _activate(req.tokenId, ownerOf(req.tokenId));
        } else {
            // NFT still in the pool. Refresh expiration: pull old
            // expiration's power, push new one.
            uint64 oldExp = expirationRoundOf[req.tokenId];
            uint128 p = uint128(ins.power);
            if (oldExp > globalDecayRound) {
                uint128 cur = expiringPowerAt[oldExp];
                expiringPowerAt[oldExp] = cur > p ? cur - p : 0;
            }
            uint64 newExp = globalDecayRound + uint64(ins.currentDurability);
            expirationRoundOf[req.tokenId] = newExp;
            expiringPowerAt[newExp] += p;
        }

        _flushSinkRepair(req.paid);
        delete pendingRepairOf[req.tokenId];
        delete pending[reqId];
        unchecked {
            --pendingRequestsCount;
        }
        emit RepairFulfilled(req.tokenId, reqId, false);
    }

    // ===================== One-time v3 → v32 migration ===================

    /// @notice Owner-only batch migration. Iterates the supplied tokenIds
    ///         and, for each tracked but unmigrated NFT, refreshes
    ///         currentDurability to maxDurability and registers it in the
    ///         expiration ledger as if freshly minted at globalDecayRound.
    ///         Sky-mandated launch-day reset: every existing holder gets
    ///         a full charge in the new system.
    /// @dev    Owner runs this AFTER the upgrade and BEFORE the first
    ///         post-upgrade `notifyReward`. Idempotent — re-supplying
    ///         already-migrated tokenIds is a no-op (does not double-credit).
    ///         Safe to chunk over many tx; recommend ≤ 200 tokenIds/call
    ///         to stay well under the block gas limit.
    function migrateExisting(uint256[] calldata tokenIds) external onlyOwner {
        uint64 cur = globalDecayRound;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tid = tokenIds[i];
            if (v32Migrated[tid]) continue;
            Inscription storage ins = inscriptions[tid];
            if (!ins.activeTracked) {
                v32Migrated[tid] = true; // mark even when skipped — never revisit
                continue;
            }

            uint8 maxD = ins.maxDurability;
            ins.currentDurability = maxD;
            ins.lastDecayCheckpoint = uint64(block.timestamp);
            uint64 expR = cur + uint64(maxD);
            expirationRoundOf[tid] = expR;
            expiringPowerAt[expR] += uint128(ins.power);
            v32Migrated[tid] = true;
            emit V32Migrated(tid, maxD, expR);
        }
    }

    // ============================ Admin tools ============================

    /// @notice Owner override: set a single NFT's currentDurability and
    ///         re-register its expirationRound. Useful for one-off
    ///         corrections (e.g. an NFT got into a weird state via a
    ///         partial migration). Reverts on inactive tokens.
    function adminSetDurability(uint256 tokenId, uint8 newValue) external onlyOwner {
        Inscription storage ins = inscriptions[tokenId];
        if (!ins.activeTracked) revert NotActiveTracked();
        if (newValue > ins.maxDurability) revert InvalidDurability();

        // Pull old expiration credit.
        uint64 oldExp = expirationRoundOf[tokenId];
        uint128 p = uint128(ins.power);
        if (oldExp > globalDecayRound) {
            uint128 c = expiringPowerAt[oldExp];
            expiringPowerAt[oldExp] = c > p ? c - p : 0;
        }
        uint8 prev = ins.currentDurability;
        ins.currentDurability = newValue;
        if (newValue == 0) {
            // Schedule for removal at the very next bump.
            uint64 newExp = globalDecayRound + 1;
            expirationRoundOf[tokenId] = newExp;
            expiringPowerAt[newExp] += p;
        } else {
            uint64 newExp = globalDecayRound + uint64(newValue);
            expirationRoundOf[tokenId] = newExp;
            expiringPowerAt[newExp] += p;
        }
        emit AdminDurabilitySet(tokenId, prev, newValue);
    }

    /// @notice Owner override: bump ALL active NFTs' currentDurability by
    ///         a constant. Implemented as a globalDecayRound rewind +
    ///         per-NFT registry refresh would require iteration; instead
    ///         we use the rewind: subtract `by` from globalDecayRound,
    ///         which is mathematically equivalent to "every active NFT
    ///         got `by` extra rounds".
    /// @dev    Refuses to rewind below 0.
    function adminBumpAllDurability(uint8 by) external onlyOwner {
        if (by == 0) return;
        if (uint64(by) > globalDecayRound) revert CannotRewindBelowZero();
        unchecked {
            globalDecayRound -= uint64(by);
        }
        emit AdminBumpedAll(by);
        emit AdminRoundRewound(uint64(by), globalDecayRound);
    }

    /// @notice Owner override: directly rewind globalDecayRound (e.g. for
    ///         operational mistakes — a notifyReward fired that shouldn't
    ///         have, want to give everyone a round back). Does NOT undo
    ///         the accRewardPerPower change in EmissionDistributor; that's
    ///         a separate concern.
    function adminRewindDecayRound(uint64 by) external onlyOwner {
        if (by == 0) return;
        if (by > globalDecayRound) revert CannotRewindBelowZero();
        unchecked {
            globalDecayRound -= by;
        }
        emit AdminRoundRewound(by, globalDecayRound);
    }

    /// @notice Owner override: set maxDurability for a single NFT. Use
    ///         when raising / lowering the cap on a token (e.g. limited
    ///         edition). currentDurability is clamped down to the new max
    ///         if necessary.
    function adminSetMaxDurability(uint256 tokenId, uint8 newMax) external onlyOwner {
        if (newMax == 0) revert InvalidDurability();
        Inscription storage ins = inscriptions[tokenId];
        uint8 prev = ins.maxDurability;
        ins.maxDurability = newMax;
        if (ins.currentDurability > newMax) {
            // Walk the registry to keep it consistent.
            this.adminSetDurability(tokenId, newMax);
        }
        emit AdminMaxDurabilitySet(tokenId, prev, newMax);
    }

    // ============================ Storage gap ============================
    //
    // We've consumed a few of v3's __gap slots. New v32 contracts in the
    // future should consume from this gap, not v3's.
    uint256[46] private __v32Gap;
}
