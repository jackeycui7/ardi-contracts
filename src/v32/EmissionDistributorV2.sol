// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EmissionDistributor} from "../v3/EmissionDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interface for the v32 ArdiNFT extension.
interface IArdiNFTv32 {
    function bumpDecayRound() external returns (uint128 expiredPower, uint64 newRound);
    function expirationRoundOf(uint256 tokenId) external view returns (uint64);
    function globalDecayRound() external view returns (uint64);
}

/// @title  EmissionDistributorV2 — round-aware reward distribution
/// @notice UUPS upgrade over v3 EmissionDistributor. Three changes:
///
///   1. `notifyReward` now atomically:
///        - distributes `amount` over today's `totalActivePower`
///          (snapshot — only NFTs with `dura > 0` count)
///        - calls ArdiNFTv32.bumpDecayRound(), gets back the power
///          expiring this round, subtracts it from `totalActivePower`
///        - snapshots accRewardPerPower into `accAtEndOfRound[newRound]`
///          so newly-expired NFTs can still claim their rightful share
///          even after their expirationRound has passed.
///
///   2. `pendingFor` and `claim` honor per-token expirationRound. An NFT
///      whose `globalDecayRound > expirationRound` still has its accrued
///      pending paid out, but capped at `accAtEndOfRound[expirationRound]`
///      — they don't earn rewards from rounds after they expired.
///
///   3. `onActivate` / `onDeactivate` are unchanged in behavior here; the
///      ArdiNFT side maintains the round registry. We only consume.
///
/// Storage layout: appends two new state slots (accAtEndOfRound mapping +
/// ArdiNFTv32 reference). UUPS upgrade safe — uses v3's __gap.
contract EmissionDistributorV2 is EmissionDistributor {
    using SafeERC20 for IERC20;

    // ============================ V32 storage ============================

    /// @notice Snapshot of `accRewardPerPower` at the end of round R.
    ///         Used by pendingFor / claim to cap an expired NFT's
    ///         accumulator at what it was at the end of its last live
    ///         round, so future rounds' rewards don't leak to it.
    mapping(uint64 => uint256) public accAtEndOfRound;

    /// @notice The ArdiNFTv32 contract — same address as ardiNFT but
    ///         exposed via the v32 interface so we can call bumpDecayRound
    ///         without a fragile low-level call.
    IArdiNFTv32 public ardiNFTv32;

    // ============================ V32 events ============================

    event RewardNotifiedV2(
        uint256 amount,
        uint256 newAcc,
        uint128 totalPowerBefore,
        uint128 totalPowerAfter,
        uint64 newRound
    );
    event ArdiNFTv32Set(address ardiNFTv32);

    error AdapterNotSet();
    error AdapterMismatch();

    // ============================ Setup =================================

    /// @notice Owner: bind the v32 interface. Address must match the
    ///         existing `ardiNFT` (the proxy doesn't change on upgrade).
    function setArdiNFTv32(address a) external onlyOwner {
        if (a != ardiNFT) revert AdapterMismatch();
        ardiNFTv32 = IArdiNFTv32(a);
        emit ArdiNFTv32Set(a);
    }

    // ============================ Reward =================================

    /// @notice Round-aware notify. Distributes the round's reward over
    ///         the *pre-bump* totalActivePower (so NFTs whose dura
    ///         reaches 0 this round still get their last share), then
    ///         decrements totalActivePower by the power expiring this
    ///         round, snapshots the post-distribution accumulator, and
    ///         bumps the round counter via ArdiNFTv32.
    function notifyReward(uint256 amount) external virtual override whenNotPaused nonReentrant {
        if (msg.sender != operator) revert NotOperator();
        if (address(ardiNFTv32) == address(0)) revert AdapterNotSet();

        if (maxNotifyAmount != 0 && amount > maxNotifyAmount) revert AmountAboveCap();

        if (amount > 0) {
            ardi.safeTransferFrom(msg.sender, address(this), amount);
        }

        uint128 totalPowerBefore = uint128(totalActivePower);
        // 1. Distribute `amount` (plus any queued pendingPool) at current
        //    denominator. Same math as v3: includes about-to-expire NFTs
        //    in this round, which is what "they participate in this
        //    round's distribution" means.
        uint256 toDistribute = amount + pendingPool;
        uint256 cap = maxNotifyAmount;
        uint256 leftover = 0;
        if (cap != 0 && toDistribute > cap) {
            leftover = toDistribute - cap;
            toDistribute = cap;
        }
        if (totalActivePower == 0) {
            pendingPool += amount;
            emit RewardNotified(amount, accRewardPerPower, 0);
            // Still bump the round so dura accounting stays linear with
            // wall-clock launches even before any NFT activates.
            (uint128 expired, uint64 newR) = ardiNFTv32.bumpDecayRound();
            accAtEndOfRound[newR] = accRewardPerPower;
            // expired must be 0 (no active power); ignore.
            (expired);
            emit RewardNotifiedV2(amount, accRewardPerPower, 0, 0, newR);
            return;
        }
        pendingPool = leftover;
        accRewardPerPower += (toDistribute * ACC_PRECISION) / totalActivePower;
        totalEmittedToDate += toDistribute;
        emit RewardNotified(toDistribute, accRewardPerPower, totalActivePower);

        // 2. Bump round on the NFT side. ardiNFTv32 returns how much
        //    power is expiring at this new round (NFTs whose dura just
        //    hit 0).
        (uint128 expiredPower, uint64 newRound) = ardiNFTv32.bumpDecayRound();

        // 3. Snapshot acc — note it AFTER the bump above so expired NFTs'
        //    accumulator includes the round they were just paid for.
        accAtEndOfRound[newRound] = accRewardPerPower;

        // 4. Drop expired power out of the active pool.
        uint128 totalPowerAfter = totalPowerBefore;
        if (expiredPower != 0) {
            // Defensive: bound by current totalActivePower in case some
            // path (admin override?) caused drift.
            uint128 toSubtract =
                expiredPower <= totalPowerBefore ? expiredPower : totalPowerBefore;
            unchecked {
                totalActivePower -= toSubtract;
            }
            totalPowerAfter = uint128(totalActivePower);
        }

        emit RewardNotifiedV2(amount, accRewardPerPower, totalPowerBefore, totalPowerAfter, newRound);
    }

    // =========================== Pending / claim =========================

    /// @notice Effective accumulator for a token. Capped at the snapshot
    ///         of accRewardPerPower from the end of its expirationRound
    ///         once we're past that round, so post-expiration rewards
    ///         don't accrue to it.
    /// @dev    M-1 audit fix: `expR == 0` previously fell through to
    ///         `accRewardPerPower`, which let UNMIGRATED pre-v32 NFTs
    ///         claim the full accumulated reward as if they'd been
    ///         alive the whole time (their `s.rewardDebt = 0` from v3
    ///         mint multiplies straight against acc). Now we return the
    ///         already-settled debt's-equivalent acc — i.e. the NFT's
    ///         pending sums to 0 — so an operator who notifyReward'd
    ///         before completing migration cannot accidentally give
    ///         away the protocol's $ardi. Owner is forced to follow
    ///         the documented order: pause → migrate → unpause.
    function _capAcc(uint256 tokenId) internal view returns (uint256) {
        uint64 expR = ardiNFTv32.expirationRoundOf(tokenId);
        if (expR == 0) {
            // Unmigrated. Return the per-power debt level so accrued
            // exactly equals s.rewardDebt and pending = 0.
            // (Equivalent to "this NFT earns nothing until migrated".)
            TokenSlot storage s = tokens[tokenId];
            if (s.power == 0) return 0;
            return (uint256(s.rewardDebt) * ACC_PRECISION) / uint256(s.power);
        }
        uint64 cur = ardiNFTv32.globalDecayRound();
        if (cur <= expR) return accRewardPerPower;
        // Expired — use snapshot. Should always be set because
        // notifyReward stamps it every round; guard anyway.
        uint256 snap = accAtEndOfRound[expR];
        return snap == 0 ? accRewardPerPower : snap;
    }

    function pendingFor(address holder, uint256[] calldata tokenIds)
        external
        view
        virtual
        override
        returns (uint256 total)
    {
        total = pendingOf[holder];
        if (address(ardiNFTv32) == address(0)) {
            // Fallback to v3 behavior if not yet wired post-upgrade.
            for (uint256 i = 0; i < tokenIds.length; ++i) {
                TokenSlot storage s = tokens[tokenIds[i]];
                if (s.power == 0) continue;
                uint256 accrued = (uint256(s.power) * accRewardPerPower) / ACC_PRECISION;
                if (accrued > s.rewardDebt) total += accrued - s.rewardDebt;
            }
            return total;
        }
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            TokenSlot storage s = tokens[tokenIds[i]];
            if (s.power == 0) continue;
            uint256 accrued = (uint256(s.power) * _capAcc(tokenIds[i])) / ACC_PRECISION;
            if (accrued > s.rewardDebt) total += accrued - s.rewardDebt;
        }
    }

    function claim(uint256[] calldata tokenIds) external virtual override whenNotPaused nonReentrant {
        uint256 total = pendingOf[msg.sender];
        pendingOf[msg.sender] = 0;

        if (address(ardiNFTv32) == address(0)) {
            // Pre-wire fallback — same as v3.
            for (uint256 i = 0; i < tokenIds.length; ++i) {
                TokenSlot storage s = tokens[tokenIds[i]];
                if (s.power == 0) continue;
                if (s.holder != msg.sender) revert NotHolder();
                uint256 accrued = (uint256(s.power) * accRewardPerPower) / ACC_PRECISION;
                if (accrued > s.rewardDebt) {
                    total += accrued - s.rewardDebt;
                    s.rewardDebt = uint128(accrued);
                }
            }
        } else {
            for (uint256 i = 0; i < tokenIds.length; ++i) {
                TokenSlot storage s = tokens[tokenIds[i]];
                if (s.power == 0) continue;
                if (s.holder != msg.sender) revert NotHolder();
                uint256 cap = _capAcc(tokenIds[i]);
                uint256 accrued = (uint256(s.power) * cap) / ACC_PRECISION;
                if (accrued > s.rewardDebt) {
                    total += accrued - s.rewardDebt;
                    s.rewardDebt = uint128(accrued);
                }
            }
        }

        if (total > 0) {
            ardi.safeTransfer(msg.sender, total);
        }
        emit Claimed(msg.sender, total);
    }

    /// @notice Round-aware deactivate. Settles `holder`'s pending with the
    ///         cap-aware accumulator, then conditionally decrements
    ///         totalActivePower.
    ///
    ///         The "conditional" part is the v32 fix: when an NFT is
    ///         expireToZero'd, it ALREADY had its power subtracted from
    ///         totalActivePower during a prior `notifyReward.bumpDecayRound`
    ///         (we removed expiringPowerAt[round] worth from the pool).
    ///         Calling super.onDeactivate would subtract again, producing
    ///         negative-or-wrong totalActivePower. We detect "already
    ///         bump-evicted" via `ardiNFTv32.expirationRoundOf(tokenId) <=
    ///         globalDecayRound` and skip the second subtraction.
    function onDeactivate(uint256 tokenId, address holder) external virtual override onlyArdiNFT {
        TokenSlot storage s = tokens[tokenId];
        if (s.power == 0) revert NotActive();
        uint256 power = s.power;
        uint256 cap = address(ardiNFTv32) == address(0)
            ? accRewardPerPower
            : _capAcc(tokenId);
        uint256 accrued = (power * cap) / ACC_PRECISION;
        uint256 owed = accrued > s.rewardDebt ? accrued - s.rewardDebt : 0;
        if (owed > 0) {
            pendingOf[holder] += owed;
        }

        bool wasBumpEvicted = false;
        if (address(ardiNFTv32) != address(0)) {
            uint64 expR = ardiNFTv32.expirationRoundOf(tokenId);
            // expR == 0 means never registered (very old / pre-v32) — treat
            // as still-active to avoid leaking power.
            if (expR != 0 && expR <= ardiNFTv32.globalDecayRound()) {
                wasBumpEvicted = true;
            }
        }
        if (!wasBumpEvicted) {
            totalActivePower -= power;
        }
        s.power = 0;
        s.rewardDebt = 0;
        s.holder = address(0);
        emit Deactivated(tokenId, holder, owed);
    }

    /// @notice Round-aware transfer hook. Settles `from`'s pending using
    ///         the cap-aware accumulator (so an expired NFT being
    ///         transferred doesn't credit `from` with post-expiration
    ///         rewards), then rotates holder. Same shape as the v3 hook.
    function onTransfer(uint256 tokenId, address from, address to) external virtual override onlyArdiNFT {
        TokenSlot storage s = tokens[tokenId];
        if (s.power == 0) revert NotActive();
        uint256 cap = address(ardiNFTv32) == address(0)
            ? accRewardPerPower
            : _capAcc(tokenId);
        uint256 accrued = (uint256(s.power) * cap) / ACC_PRECISION;
        uint256 owed = accrued > s.rewardDebt ? accrued - s.rewardDebt : 0;
        if (owed > 0) {
            pendingOf[from] += owed;
        }
        s.rewardDebt = uint128(accrued);
        s.holder = to;
        emit Transferred(tokenId, from, to);
    }

    // ============================ Storage gap ============================

    uint256[48] private __v32Gap;
}
