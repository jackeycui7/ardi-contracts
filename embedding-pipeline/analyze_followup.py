#!/usr/bin/env python3
"""
Follow-up analysis after analyze_pair_distribution.py:

a) Equal-share tier rebucketing — find score boundaries that give each
   tier ~20% real probability, vs the current [0,20,40,60,80] which
   produces 55% T1 / 33% T2 / 6% T3 / 3% T4 / 3% T5 imbalance.

b) Filtered subset analysis — drop short words (≤3 chars) and
   non-Latin-only words to see how much "multilingual noise" is
   inflating the high-score bands.

c) Levenshtein duplicate detection — for every T5 (score ≥ 81) pair,
   compute edit distance between the two words. Pairs with edit
   distance ≤ 2 are likely "same word in different language/casing"
   and should be considered for dedup.
"""
import json
import time
import unicodedata
from pathlib import Path

import numpy as np

ART = Path(__file__).parent / "artifacts"

print("loading…")
with open(ART / "embeddings.json") as f:
    raw = json.load(f)
with open(ART / "word_to_id.json") as f:
    word_to_id = json.load(f)

# word_to_id maps lowercase NFC-normalized word → id. For display we want
# id → original word. Reload from quiz_21000_answers.json which has the
# original-case forms.
QUIZ = Path("/root/awp_code/ardi/wordbank-riddle-bench/quiz_21000_answers.json")
with open(QUIZ) as f:
    quiz = json.load(f)
id_to_word = {int(e["id"]): e["word"] for e in quiz}
print(f"id_to_word: {len(id_to_word)} entries")

n = 21000
emb = np.zeros((n, 96), dtype=np.int8)
for k, v in raw.items():
    i = int(k)
    emb[i] = np.frombuffer(bytes.fromhex(v[2:] if v.startswith("0x") else v), dtype=np.int8)

A32 = emb.astype(np.float32)
norms = np.sqrt((A32 * A32).sum(axis=1))
norms = np.where(norms == 0, 1.0, norms)

# ───────────────────────────────────────────────
# (a) + (b): full + filtered pairwise score histograms
# ───────────────────────────────────────────────

def is_latin_only(w: str) -> bool:
    """Return True if word consists only of ASCII a-z plus apostrophes/hyphens."""
    return all(ord(c) < 128 and (c.isalpha() or c in "'-") for c in w)

# Build filtered id set: word length ≥ 4 AND latin-only
filtered_ids = []
for i in range(n):
    w = id_to_word.get(i, "")
    if len(w) >= 4 and is_latin_only(w):
        filtered_ids.append(i)
filtered_ids = np.array(filtered_ids, dtype=np.int64)
print(f"\nfiltered subset: {len(filtered_ids)} words (≥4 chars, latin-only)")

def compute_distribution(ids_to_use, label):
    """Compute pairwise score histogram for the given id subset, in 1-point bins."""
    print(f"\n=== {label} ({len(ids_to_use)} words) ===")
    sub_emb = A32[ids_to_use]
    sub_norms = norms[ids_to_use]
    m = len(ids_to_use)
    hist = np.zeros(101, dtype=np.int64)
    total = 0
    CHUNK = 1500
    t = time.time()
    for r0 in range(0, m, CHUNK):
        r1 = min(r0 + CHUNK, m)
        block = sub_emb[r0:r1]
        dot_block = block @ sub_emb.T
        cos_block = dot_block / (sub_norms[r0:r1, None] * sub_norms[None, :])
        np.clip(cos_block, -1.0, 1.0, out=cos_block)
        score_block = (np.abs(cos_block) * 100.0).astype(np.int32)
        np.clip(score_block, 0, 100, out=score_block)
        for ri, gi in enumerate(range(r0, r1)):
            sub = score_block[ri, gi+1:]
            if sub.size == 0: continue
            counts = np.bincount(sub, minlength=101)
            hist += counts.astype(np.int64)
            total += int(sub.size)
    print(f"  computed {total:,} pairs in {time.time()-t:.1f}s")
    return hist, total


# Full distribution we already have from previous run; recompute briefly
# for sanity / equal-share calc.
hist_full, total_full = compute_distribution(np.arange(n), "FULL 21000")
hist_filt, total_filt = compute_distribution(filtered_ids, "FILTERED")


def show_tier_split(hist, total, label, boundaries):
    """Show counts and shares per tier given the score boundaries."""
    print(f"\n  {label} — boundaries {boundaries}:")
    cum = np.cumsum(hist)
    last = 0
    for tier, lo, hi in [("T1", 0, boundaries[0]), ("T2", boundaries[0], boundaries[1]),
                        ("T3", boundaries[1], boundaries[2]), ("T4", boundaries[2], boundaries[3]),
                        ("T5", boundaries[3], 101)]:
        c = int(hist[lo:hi].sum())
        pct = 100*c/total if total else 0
        print(f"    {tier} [{lo:>3}, {hi-1:>3}]  {c:>15,}  {pct:>7.3f}%")


# Current boundaries: 21, 41, 61, 81 (T1 < 21, T2 21-40, etc)
CURRENT = (21, 41, 61, 81)

print()
print("=" * 72)
print("(a) EQUAL-SHARE REBUCKETING")
print("=" * 72)

# Compute boundaries that give each tier 20%.
def equal_share_boundaries(hist, total, n_tiers=5):
    """Find score thresholds that split into n_tiers equal-count buckets."""
    cum = np.cumsum(hist)
    targets = [int(total * (i+1) / n_tiers) for i in range(n_tiers - 1)]
    boundaries = []
    for tgt in targets:
        # Find smallest score s such that cum[s] >= tgt
        idx = int(np.searchsorted(cum, tgt))
        boundaries.append(idx + 1)  # boundary is "T_next starts at this score"
    return tuple(boundaries)

eq_full = equal_share_boundaries(hist_full, total_full)
eq_filt = equal_share_boundaries(hist_filt, total_filt)

print(f"\nFULL 21000 corpus: equal-share boundaries = {eq_full}")
show_tier_split(hist_full, total_full, "  with current  ", CURRENT)
show_tier_split(hist_full, total_full, "  with new      ", eq_full)

print(f"\nFILTERED ({len(filtered_ids)} latin-only ≥4chr): boundaries = {eq_filt}")
show_tier_split(hist_filt, total_filt, "  with current  ", CURRENT)
show_tier_split(hist_filt, total_filt, "  with new      ", eq_filt)


# ───────────────────────────────────────────────
# (c) Levenshtein duplicate analysis on T5 pairs
# ───────────────────────────────────────────────

print()
print("=" * 72)
print("(c) LEVENSHTEIN DUPLICATE ANALYSIS on T5 pairs")
print("=" * 72)

def lev(a, b, max_d=None):
    """Bog-standard Levenshtein with optional early termination."""
    if abs(len(a) - len(b)) > (max_d or 99): return max_d + 1 if max_d else 99
    if len(a) < len(b): a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0]*len(b)
        row_min = i
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
            if cur[j] < row_min: row_min = cur[j]
        if max_d is not None and row_min > max_d: return max_d + 1
        prev = cur
    return prev[-1]

def nfc_strip(s: str) -> str:
    """Lowercase + NFKD-decomposed + strip diacritics for cross-lang comparison."""
    s = s.lower()
    return "".join(c for c in unicodedata.normalize("NFKD", s)
                   if not unicodedata.combining(c))

# Find T5 pairs from full corpus by re-scanning (just collect, don't store
# all in memory). Cap collection at 20K pairs.
print("\nscanning T5 (≥81) pairs in full corpus…")
t5_pairs = []
CAP = 20000
CHUNK = 1500
t = time.time()
for r0 in range(0, n, CHUNK):
    if len(t5_pairs) >= CAP: break
    r1 = min(r0 + CHUNK, n)
    block = A32[r0:r1]
    dot_block = block @ A32.T
    cos_block = dot_block / (norms[r0:r1, None] * norms[None, :])
    np.clip(cos_block, -1.0, 1.0, out=cos_block)
    score_block = (np.abs(cos_block) * 100.0).astype(np.int32)
    np.clip(score_block, 0, 100, out=score_block)
    for ri, gi in enumerate(range(r0, r1)):
        if len(t5_pairs) >= CAP: break
        sub = score_block[ri, gi+1:]
        hi_idx = np.where(sub >= 81)[0]
        for li in hi_idx:
            j = gi + 1 + int(li)
            t5_pairs.append((int(sub[li]), gi, j))
            if len(t5_pairs) >= CAP: break
print(f"  collected {len(t5_pairs):,} T5 pairs in {time.time()-t:.1f}s")

# Now classify each T5 pair: is it a "near-duplicate" (after NFC strip + lev≤2)?
near_dup = 0
exact_after_strip = 0
multi_lang = 0
genuine = 0
sample_genuine = []
sample_dups = []

for s, i, j in t5_pairs:
    wi = id_to_word.get(i, "")
    wj = id_to_word.get(j, "")
    si = nfc_strip(wi); sj = nfc_strip(wj)
    if si == sj:
        exact_after_strip += 1
        if len(sample_dups) < 15: sample_dups.append((s, wi, wj, "exact-strip"))
    elif lev(si, sj, 2) <= 2:
        near_dup += 1
        if len(sample_dups) < 15: sample_dups.append((s, wi, wj, f"lev≤2"))
    else:
        # Different visible word but same embedding cluster.
        # Check if they appear to be different language/script by ASCII vs non-ASCII.
        ascii_i = all(ord(c) < 128 for c in wi)
        ascii_j = all(ord(c) < 128 for c in wj)
        if ascii_i != ascii_j:
            multi_lang += 1
        genuine += 1
        if len(sample_genuine) < 25: sample_genuine.append((s, wi, wj))

print(f"\nT5 pair breakdown ({len(t5_pairs):,} sampled):")
print(f"  exact after NFC-strip:  {exact_after_strip:>6,}  ({100*exact_after_strip/len(t5_pairs):.2f}%)")
print(f"  near-dup (lev ≤ 2):     {near_dup:>6,}  ({100*near_dup/len(t5_pairs):.2f}%)")
print(f"  genuine pairs:          {genuine:>6,}  ({100*genuine/len(t5_pairs):.2f}%)")
print(f"    of which multi-lang:  {multi_lang:>6,}  ({100*multi_lang/len(t5_pairs):.2f}%)")

print(f"\nsample 'duplicate' T5 pairs:")
for s, wi, wj, why in sample_dups:
    print(f"  [{why:>11}] {s:>3}  {wi:<22s} ↔ {wj}")

print(f"\nsample GENUINE T5 pairs:")
for s, wi, wj in sample_genuine:
    print(f"  {s:>3}  {wi:<22s} ↔ {wj}")
