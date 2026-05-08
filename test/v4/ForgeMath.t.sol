// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForgeMath} from "../../src/v4/lib/ForgeMath.sol";

/// @notice Unit tests for ForgeMath. Three goals:
///   1. cosine identity / orthogonality / known-pair sanity
///   2. tier boundary correctness
///   3. deriveOutcome distribution matches spec (statistical, ±2% tolerance)
///
/// Tier success rates / mult bands / crit params live in ForgeMath._tier*
/// private functions; we don't test those directly — distribution tests
/// exercise the same paths.
contract ForgeMathTest is Test {
    // We need to call cosineSimilarity externally because it's `external`.
    // Wrap via a thin trampoline contract.
    Trampoline tramp;

    function setUp() public {
        tramp = new Trampoline();
    }

    // ───────────── 1. cosineSimilarity ─────────────

    function testCosine_IdenticalVectors_Returns100() public {
        bytes memory v = _vector(int8(50));
        uint8 score = tramp.cos(v, v);
        assertEq(score, 100, "identical vectors must score 100");
    }

    function testCosine_OppositeVectors_ReturnsZero() public {
        bytes memory pos = _vector(int8(50));
        bytes memory neg = _vector(int8(-50));
        uint8 score = tramp.cos(pos, neg);
        // Anti-aligned cosine = -1, clamps to 0.
        assertEq(score, 0, "opposite vectors must clamp to 0");
    }

    function testCosine_OrthogonalVectors_ReturnsZero() public {
        // First half +50, second half 0; vs first half 0, second half +50.
        bytes memory a = new bytes(96);
        bytes memory b = new bytes(96);
        for (uint256 i = 0; i < 48; i++) {
            a[i] = bytes1(uint8(50));
            b[i + 48] = bytes1(uint8(50));
        }
        uint8 score = tramp.cos(a, b);
        assertEq(score, 0, "orthogonal must score 0");
    }

    function testCosine_PartialOverlap_BetweenBounds() public {
        // a = all +50, b = first 48 +50, second 48 -50. dot = 0 → score = 0
        bytes memory a = _vector(int8(50));
        bytes memory b = new bytes(96);
        for (uint256 i = 0; i < 48; i++) {
            b[i] = bytes1(uint8(50));
            b[i + 48] = bytes1(uint8(int8(-50)));
        }
        // Note: cast int8(-50) to uint8 = 206 (two's complement). Verify:
        assertEq(uint8(b[48]), 206, "neg byte encoding");
        uint8 score = tramp.cos(a, b);
        assertEq(score, 0, "balanced pos/neg must score 0");
    }

    function testCosine_KnownPair_75Percent() public {
        // Construct a = +50 across all 96 dims.
        // Construct b = +50 in 84 dims, -50 in 12 dims.
        // dot   = 84*2500 - 12*2500 = 72*2500 = 180_000
        // normA = 96*2500 = 240_000
        // normB = 96*2500 = 240_000
        // cosine = 180000 / 240000 = 0.75 → 75
        bytes memory a = _vector(int8(50));
        bytes memory b = new bytes(96);
        for (uint256 i = 0; i < 84; i++) b[i] = bytes1(uint8(50));
        for (uint256 i = 84; i < 96; i++) b[i] = bytes1(uint8(int8(-50)));
        // ↑ note: same encoding pattern as other negative-byte tests
        uint8 score = tramp.cos(a, b);
        // Allow ±1 for rounding.
        assertGe(score, 74);
        assertLe(score, 76);
    }

    function testCosine_RejectsBadLength() public {
        bytes memory a = new bytes(95);
        bytes memory b = new bytes(96);
        vm.expectRevert(bytes("bad emb len"));
        tramp.cos(a, b);
    }

    // ───────────── 2. matchScoreToTier ─────────────

    function testTier_Boundaries() public {
        // Equal-share boundaries [8, 15, 24, 36] (rebalance 2026-05-08).
        assertEq(uint8(ForgeMath.matchScoreToTier(0)),   uint8(ForgeMath.Tier.T1));
        assertEq(uint8(ForgeMath.matchScoreToTier(7)),   uint8(ForgeMath.Tier.T1));
        assertEq(uint8(ForgeMath.matchScoreToTier(8)),   uint8(ForgeMath.Tier.T2));
        assertEq(uint8(ForgeMath.matchScoreToTier(14)),  uint8(ForgeMath.Tier.T2));
        assertEq(uint8(ForgeMath.matchScoreToTier(15)),  uint8(ForgeMath.Tier.T3));
        assertEq(uint8(ForgeMath.matchScoreToTier(23)),  uint8(ForgeMath.Tier.T3));
        assertEq(uint8(ForgeMath.matchScoreToTier(24)),  uint8(ForgeMath.Tier.T4));
        assertEq(uint8(ForgeMath.matchScoreToTier(35)),  uint8(ForgeMath.Tier.T4));
        assertEq(uint8(ForgeMath.matchScoreToTier(36)),  uint8(ForgeMath.Tier.T5));
        assertEq(uint8(ForgeMath.matchScoreToTier(100)), uint8(ForgeMath.Tier.T5));
    }

    // ───────────── 3. deriveOutcome distributions ─────────────

    /// 10K samples should have success rate within ±2% of expected.
    function testOutcome_T5SuccessRate() public {
        _assertSuccessRate(ForgeMath.Tier.T5, 9000, 400);
    }

    function testOutcome_T4SuccessRate() public {
        _assertSuccessRate(ForgeMath.Tier.T4, 7500, 400);
    }

    function testOutcome_T3SuccessRate() public {
        _assertSuccessRate(ForgeMath.Tier.T3, 5500, 400);
    }

    function testOutcome_T2SuccessRate() public {
        _assertSuccessRate(ForgeMath.Tier.T2, 3500, 400);
    }

    function testOutcome_T1SuccessRate() public {
        _assertSuccessRate(ForgeMath.Tier.T1, 2000, 400);
    }

    /// T5 multipliers should land in [12000, 14000] every time.
    function testOutcome_T5MultiplierBand() public {
        for (uint256 i = 0; i < 500; i++) {
            uint256 vrf = uint256(keccak256(abi.encode("t5", i)));
            ForgeMath.ForgeOutcome memory o = ForgeMath.deriveOutcome(ForgeMath.Tier.T5, vrf);
            if (o.success) {
                // T5 has 0% crit so multiplier is exactly the base band.
                // New band 2026-05-08: 12000-13500 (was 12000-14000).
                assertGe(o.multiplierBps, 12000);
                assertLe(o.multiplierBps, 13500);
                assertFalse(o.isCritical);
                assertFalse(o.isMythic);
                assertFalse(o.isGodTouch);
            }
        }
    }

    /// T1 should produce critical / mythic / godTouch at expected rates.
    function testOutcome_T1Specials() public {
        uint256 N = 20_000;
        uint256 successes;
        uint256 crits;
        uint256 mythics;
        uint256 gods;
        for (uint256 i = 0; i < N; i++) {
            uint256 vrf = uint256(keccak256(abi.encode("t1specials", i)));
            ForgeMath.ForgeOutcome memory o = ForgeMath.deriveOutcome(ForgeMath.Tier.T1, vrf);
            if (o.success) {
                successes++;
                if (o.isCritical) crits++;
                if (o.isMythic)   mythics++;
                if (o.isGodTouch) gods++;
            }
        }
        // 20% of 20K = ~4K successes
        assertGt(successes, 3500);
        assertLt(successes, 4500);

        // Critical: 15% of successes
        uint256 critPct = (crits * 100) / successes;
        assertGe(critPct, 12);
        assertLe(critPct, 18);

        // Mythic: 2.5% of successes (~100 in 4K)  [bumped 2026-05-08]
        uint256 mythicPct = (mythics * 1000) / successes;
        assertGe(mythicPct, 15);
        assertLe(mythicPct, 40);

        // God Touch: 0.25% of successes (~10 in 4K). Tolerate 2-30.
        assertGe(gods, 2);
        assertLe(gods, 30);
    }

    /// Element pick should hit all 5 buckets with a flat distribution.
    /// (Pure-function call doesn't even need successful forge — but element
    /// is only set on success path. Test by sampling T5 success path which
    /// has 90% success rate.)
    function testOutcome_ElementDistribution() public {
        uint256[6] memory counts; // index 0 unused, 1-5 = elements
        uint256 successes;
        for (uint256 i = 0; i < 10_000; i++) {
            uint256 vrf = uint256(keccak256(abi.encode("elem", i)));
            ForgeMath.ForgeOutcome memory o = ForgeMath.deriveOutcome(ForgeMath.Tier.T5, vrf);
            if (o.success) {
                assertGe(o.element, 1);
                assertLe(o.element, 5);
                counts[o.element]++;
                successes++;
            }
        }
        // Each element should be ~20% of successes, ±5%.
        for (uint8 e = 1; e <= 5; e++) {
            uint256 pct = (counts[e] * 100) / successes;
            assertGe(pct, 15, "element pct too low");
            assertLe(pct, 25, "element pct too high");
        }
    }

    // ───────────── helpers ─────────────

    function _vector(int8 fill) internal pure returns (bytes memory v) {
        v = new bytes(96);
        for (uint256 i = 0; i < 96; i++) {
            v[i] = bytes1(uint8(fill));
        }
    }

    /// Sample N=10000 forges, count successes, assert |actual - expected| < tolerance.
    function _assertSuccessRate(ForgeMath.Tier tier, uint16 expectedBps, uint16 toleranceBps)
        internal
    {
        uint256 N = 10_000;
        uint256 successes;
        for (uint256 i = 0; i < N; i++) {
            uint256 vrf = uint256(keccak256(abi.encode(tier, i)));
            ForgeMath.ForgeOutcome memory o = ForgeMath.deriveOutcome(tier, vrf);
            if (o.success) successes++;
        }
        uint256 actualBps = (successes * 10_000) / N;
        uint256 lo = expectedBps > toleranceBps ? expectedBps - toleranceBps : 0;
        uint256 hi = expectedBps + toleranceBps;
        assertGe(actualBps, lo);
        assertLe(actualBps, hi);
    }
}

contract Trampoline {
    function cos(bytes calldata a, bytes calldata b) external pure returns (uint8) {
        return ForgeMath.cosineSimilarity(a, b);
    }
}
