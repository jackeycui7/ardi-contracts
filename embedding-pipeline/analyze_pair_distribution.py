#!/usr/bin/env python3
"""
Compute the full pairwise matchScore distribution across all 21K word
embeddings. Replicates the on-chain ForgeMath cosineSimilarity exactly:

    scaled  = (dot² × 10000) // (||A|| × ||B||)
    score   = isqrt(scaled)        # uint8, 0..100

Note: the contract uses dot² so SIGN is lost — negative cosine becomes
positive, just like absolute value × 100.

Outputs:
- Tier counts + percentages
- Histogram (0-5, 5-10, …, 95-100)
- Sample high-scoring pairs
- Sample T3+ pairs (so we can see if they actually exist)
"""
import json
import os
import numpy as np
from pathlib import Path

ART = Path(__file__).parent / "artifacts"

print("loading embeddings…")
with open(ART / "embeddings.json") as f:
    raw = json.load(f)
with open(ART / "word_to_id.json") as f:
    word_to_id = json.load(f)
id_to_word = {int(v): k for k, v in word_to_id.items()}

n = len(raw)
assert n == 21000, f"expected 21000 entries, got {n}"

# raw[id] = "0x" + 192 hex chars (96 bytes int8)
emb = np.zeros((n, 96), dtype=np.int8)
for k, v in raw.items():
    i = int(k)
    b = bytes.fromhex(v[2:] if v.startswith("0x") else v)
    assert len(b) == 96
    arr = np.frombuffer(b, dtype=np.int8)
    emb[i] = arr

print(f"loaded {n} × 96 int8 embeddings, total {emb.nbytes//1024} KB")

# Compute in CHUNKS to keep memory bounded. Full 21000×21000 float64 is
# ~3.5GB per array; we'd OOM on 15GB box (5GB free). Chunk = 1500 rows ×
# 21000 cols × float32 = 126MB per buffer.
A32 = emb.astype(np.float32)              # full embeddings as float32: 8MB
norms = np.sqrt((A32 * A32).sum(axis=1))  # shape (n,) float32
norms = np.where(norms == 0, 1.0, norms)

CHUNK = 1500
print(f"computing 21000×21000 in chunks of {CHUNK} rows…")

# Reserve uint8 result for upper-triangle scores AND row indexing
# Final flat array of all upper-triangle scores: n*(n-1)/2 = 220M bytes.
# Also keep top-K tracking + tier counts streaming.

import heapq
K_TOP = 50
top_heap: list = []        # min-heap of (score, i, j); pop smallest if full
tier_counts = np.zeros(5, dtype=np.int64)  # T1..T5
hist_5pt = np.zeros(21, dtype=np.int64)    # bins of 5 from 0..100 (last incl 100)
total_pairs = 0
all_t3plus: list = []      # (score, i, j) — keep up to 5000 for sampling

def update_tiers(scores_chunk):
    """scores_chunk is a 1D uint8 array of pair scores."""
    tier_counts[4] += int((scores_chunk >= 81).sum())
    tier_counts[3] += int(((scores_chunk >= 61) & (scores_chunk < 81)).sum())
    tier_counts[2] += int(((scores_chunk >= 41) & (scores_chunk < 61)).sum())
    tier_counts[1] += int(((scores_chunk >= 21) & (scores_chunk < 41)).sum())
    tier_counts[0] += int((scores_chunk < 21).sum())
    for b in range(20):
        lo, hi = b*5, (b+1)*5
        hist_5pt[b] += int(((scores_chunk >= lo) & (scores_chunk < hi)).sum())
    hist_5pt[20] += int((scores_chunk == 100).sum())

import time
t_start = time.time()
for r0 in range(0, n, CHUNK):
    r1 = min(r0 + CHUNK, n)
    block_rows = A32[r0:r1]                          # (chunk, 96)
    # Compute dot product of these rows against all rows.
    dot_block = block_rows @ A32.T                   # (chunk, n) float32
    # Cosine = dot / (norms[i] * norms[j])
    # Contract uses dot² × 10000 / (normA*normB), then sqrt → match
    # absolute cosine × 100. So |cos| × 100 directly.
    cos_block = dot_block / (norms[r0:r1, None] * norms[None, :])
    # Clamp [-1, 1] (small float drift)
    np.clip(cos_block, -1.0, 1.0, out=cos_block)
    score_block = (np.abs(cos_block) * 100.0).astype(np.int32)
    np.clip(score_block, 0, 100, out=score_block)
    score_block = score_block.astype(np.uint8)

    # Extract upper triangle of this row band: cols j > i for each row i in [r0, r1).
    for ri, gi in enumerate(range(r0, r1)):
        # cols > gi
        sub = score_block[ri, gi+1:]
        if sub.size == 0: continue
        update_tiers(sub)
        total_pairs += int(sub.size)
        # top-K
        # Find indices where score is high (>=81) and add to heap.
        if sub.size:
            high_local = np.where(sub >= 60)[0]      # take T4+ candidates
            for li in high_local:
                s = int(sub[li]); j = gi + 1 + int(li)
                if len(top_heap) < K_TOP:
                    heapq.heappush(top_heap, (s, gi, j))
                elif s > top_heap[0][0]:
                    heapq.heapreplace(top_heap, (s, gi, j))
            # T3+ samples (cap at 5000)
            t3_local = np.where(sub >= 41)[0]
            for li in t3_local:
                if len(all_t3plus) >= 5000: break
                all_t3plus.append((int(sub[li]), gi, gi + 1 + int(li)))
    if (r0 // CHUNK) % 2 == 0:
        elapsed = time.time() - t_start
        pct = (r1 / n) * 100
        print(f"  rows 0-{r1} ({pct:.0f}%) — {elapsed:.1f}s — {total_pairs:,} pairs so far")

print(f"\ncompleted {total_pairs:,} pairs in {time.time()-t_start:.1f}s")
flat = None  # free reference

# Reuse `counts` dict pattern below.
counts = {
    "T1": int(tier_counts[0]),
    "T2": int(tier_counts[1]),
    "T3": int(tier_counts[2]),
    "T4": int(tier_counts[3]),
    "T5": int(tier_counts[4]),
}
total = total_pairs

def tier_of(s):
    if s >= 81: return "T5"
    if s >= 61: return "T4"
    if s >= 41: return "T3"
    if s >= 21: return "T2"
    return "T1"

print()
print("=" * 60)
print(f"Pairwise matchScore distribution ({total:,} pairs)")
print("=" * 60)
print(f"{'Tier':<5} {'Score range':<13} {'Count':>15} {'Share':>10}")
print(f"{'T5':<5} {'81-100':<13} {counts['T5']:>15,} {100*counts['T5']/total:>9.4f}%")
print(f"{'T4':<5} {'61-80':<13} {counts['T4']:>15,} {100*counts['T4']/total:>9.4f}%")
print(f"{'T3':<5} {'41-60':<13} {counts['T3']:>15,} {100*counts['T3']/total:>9.4f}%")
print(f"{'T2':<5} {'21-40':<13} {counts['T2']:>15,} {100*counts['T2']/total:>9.4f}%")
print(f"{'T1':<5} {'0-20':<13} {counts['T1']:>15,} {100*counts['T1']/total:>9.4f}%")
print()

# Fine histogram
print("Fine histogram (5-point bins):")
print(f"{'bin':>10} {'count':>15} {'share':>10}")
total_h = total
for b in range(21):
    lo, hi = b*5, (b*5 + 5) if b < 20 else 101
    c = int(hist_5pt[b])
    pct = 100*c/total_h if total_h else 0
    bar = "█" * min(int(800 * c / total_h) if total_h else 0, 80)
    print(f"  {lo:>3}-{hi-1:<3}  {c:>15,} {pct:>9.4f}% {bar}")
print()

# Top-K pairs
top_sorted = sorted(top_heap, reverse=True)
print()
print("=" * 60)
print(f"Top {len(top_sorted)} highest-scoring pairs (T4+ candidates kept):")
print("=" * 60)
for s, i, j in top_sorted:
    tier = tier_of(s)
    print(f"  [{tier}] {s:>3}  {id_to_word.get(i, '?'):<22s} ↔ {id_to_word.get(j, '?')}")

# T3+ random samples
print()
print(f"Captured T3+ samples: {len(all_t3plus)} (capped at 5000)")
if all_t3plus:
    rng = np.random.default_rng(42)
    sample_n = min(20, len(all_t3plus))
    pick = rng.choice(len(all_t3plus), size=sample_n, replace=False)
    print(f"\nRandom {sample_n} T3+ samples:")
    for k in pick:
        s, i, j = all_t3plus[k]
        tier = tier_of(s)
        print(f"  [{tier}] {s:>3}  {id_to_word.get(i, '?'):<22s} ↔ {id_to_word.get(j, '?')}")
