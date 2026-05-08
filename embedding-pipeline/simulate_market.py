#!/usr/bin/env python3
"""
Market simulation v2 — with inscription influx.

Real chain has TWO flows:
  - INSCRIBE: epoch winners turn riddles into NFTs (~150-300/day at current rate)
  - FORGE:    holders combine 2 NFTs → 1 (or 0)

We simulate both happening concurrently. Each "step" = 1 day.
  - inscribe_per_day NEW NFTs added (random word_id, real power/dur)
  - forge_per_day attempts (random pair from current pool)

Horizon: 30 / 90 / 180 days. Compare:
  (a) NEW boundaries [8, 15, 24, 36] — equal-share
  (b) OLD boundaries [21, 41, 61, 81] — current
"""
import json
import numpy as np
from pathlib import Path

TIERS = ["T1", "T2", "T3", "T4", "T5"]
NEW_BOUNDARIES = [8, 15, 24, 36]   # equal-share rebucket (deployed 2026-05-08)

SUCCESS_BPS = {"T5": 9000, "T4": 7500, "T3": 5500, "T2": 3500, "T1": 2000}
# Updated 2026-05-08 to match deployed ForgeMath: T2 widened, T4 lifted, T5 tightened.
MULT_BAND = {
    "T5": (12000, 13500),
    "T4": (14000, 16000),
    "T3": (17000, 20000),
    "T2": (23000, 31000),
    "T1": (35000, 55000),
}
CRIT = {"T5": (0, 0), "T4": (0, 0), "T3": (100, 15000), "T2": (500, 15000), "T1": (1500, 20000)}
MYTHIC_BPS = 250    # was 100; bumped to compensate for T1 share dropping 55→20%
GOD_BPS = 25        # was 10; same rationale
MYTHIC_BONUS = 1.2
DUR_CAP = 30
ELEMENTS = ["metal", "wood", "water", "fire", "earth", "god"]

# Dynamic fee: forgeFee = K_FEE × dailyEmission / totalActivePower × (Pa+Pb)
# For sim purposes: tracks totalActivePower live. dailyEmission constant.
K_FEE = 7
DAILY_EMISSION = 24_000_000   # aARDI/day, real chain rate

ART = Path(__file__).parent / "artifacts"
QUIZ = Path("/root/awp_code/ardi/wordbank-riddle-bench/quiz_21000_answers.json")

print("loading…")
with open(QUIZ) as f:
    quiz = json.load(f)
id_to_entry = {int(e["id"]): e for e in quiz}
with open(ART / "embeddings.json") as f:
    raw = json.load(f)
n_words = 21000
emb = np.zeros((n_words, 96), dtype=np.int8)
for k, v in raw.items():
    emb[int(k)] = np.frombuffer(bytes.fromhex(v[2:]), dtype=np.int8)
A32 = emb.astype(np.float32)
norms = np.sqrt((A32 * A32).sum(axis=1)); norms = np.where(norms == 0, 1.0, norms)


def cosine_score(i, j):
    dot = float(A32[i] @ A32[j])
    cos = max(-1.0, min(1.0, dot / (norms[i] * norms[j])))
    return int(abs(cos) * 100)


def tier_of(s, b):
    if s >= b[3]: return "T5"
    if s >= b[2]: return "T4"
    if s >= b[1]: return "T3"
    if s >= b[0]: return "T2"
    return "T1"


def starter_nfts(rng, n=16056):
    """Seed pool from real wordbank distribution."""
    nfts = []; word_ids = []
    chosen = rng.choice(n_words, size=n, replace=False)
    for wid in chosen:
        e = id_to_entry[int(wid)]
        nfts.append({
            "power": int(e.get("power", 50) or 50),
            "dur":   int(e.get("durability", 7) or 7),
            "element": (e.get("element", "fire") or "fire").lower(),
        })
        word_ids.append(int(wid))
    return nfts, word_ids


def simulate(days, forges_per_day, inscribes_per_day, boundaries, label, seed=42):
    rng = np.random.default_rng(seed)
    nfts, wids = starter_nfts(rng)

    n_start = len(nfts)
    pwr_start = sum(x["power"] for x in nfts)
    elem_start = {e: 0 for e in ELEMENTS}
    for x in nfts: elem_start[x["element"]] += 1

    fail = succ = 0
    tier_att = {t: 0 for t in TIERS}
    tier_succ = {t: 0 for t in TIERS}
    # Per-tier value accounting (in power-day-yield units = power × dura).
    #   value_in: input NFT lifetime value lost to forge (sum_pwr × avg_input_dura)
    #   value_out: new NFT lifetime value created (success only)
    #   fee_paid: dynamic fee in same units (k × sum_pwr)
    tier_value_in = {t: 0 for t in TIERS}
    tier_value_out = {t: 0 for t in TIERS}
    tier_fee_paid = {t: 0 for t in TIERS}
    crit = mythic = god = 0
    burnt_aardi = 0
    pwr_in = pwr_out = 0
    inscribed_total = 0
    monthly_snapshots = []   # list of dicts per month
    # Track totalActivePower live for dynamic-fee computation.
    total_power = pwr_start

    # word inscription pool: ~4500 left in real wordbank, but allow re-mint for
    # sim purposes (assumes coord re-publishes inscribed-and-burnt words eventually)
    available_word_ids = list(rng.choice(n_words, size=n_words, replace=False))
    avail_idx = 0  # next inscribable word

    for day in range(days):
        # Daily inscriptions (epoch winners)
        for _ in range(inscribes_per_day):
            if avail_idx >= len(available_word_ids):
                break
            wid = available_word_ids[avail_idx]; avail_idx += 1
            e = id_to_entry[int(wid)]
            p = int(e.get("power", 50) or 50)
            nfts.append({
                "power": p,
                "dur":   int(e.get("durability", 7) or 7),
                "element": (e.get("element", "fire") or "fire").lower(),
            })
            wids.append(int(wid))
            inscribed_total += 1
            total_power += p

        # Daily forges (random pair)
        for _ in range(forges_per_day):
            if len(nfts) < 2: break
            ids = rng.choice(len(nfts), size=2, replace=False)
            i, j = sorted(ids.tolist())
            a, b = nfts[i], nfts[j]
            wA, wB = wids[i], wids[j]
            tier = tier_of(cosine_score(wA, wB), boundaries)
            tier_att[tier] += 1
            sum_pow = a["power"] + b["power"]
            sum_dura = a["dur"] + b["dur"]
            # Dynamic fee per the deployed mainnet plan.
            fee = K_FEE * DAILY_EMISSION * sum_pow // max(total_power, 1)
            burnt_aardi += fee
            pwr_in += sum_pow
            # Track value (power-days) for per-tier EV.
            value_in_units = a["power"] * a["dur"] + b["power"] * b["dur"]
            fee_units = K_FEE * sum_pow  # fee in power-day units (cancels out yield_rate)
            tier_value_in[tier] += value_in_units
            tier_fee_paid[tier] += fee_units

            if rng.random() * 10000 >= SUCCESS_BPS[tier]:
                fail += 1
                # v4 testnet behavior: only the lower-power input burns.
                burn_idx = i if a["power"] <= b["power"] else j
                burned_power = nfts[burn_idx]["power"]
                nfts.pop(burn_idx); wids.pop(burn_idx)
                total_power -= burned_power
                continue
            succ += 1; tier_succ[tier] += 1
            mn, mx = MULT_BAND[tier]
            mult = rng.integers(mn, mx + 1)
            cp, cm = CRIT[tier]
            if cp > 0 and rng.random() * 10000 < cp:
                crit += 1; mult = (mult * cm) // 10000
            is_myth = is_god = False
            if tier == "T1":
                if rng.random() * 10000 < MYTHIC_BPS: is_myth = True; mythic += 1
                if rng.random() * 10000 < GOD_BPS: is_god = True; god += 1
            new_p = (sum_pow * mult) // 10000
            if is_myth: new_p = int(new_p * MYTHIC_BONUS)
            new_d = max(1, min(sum_dura, DUR_CAP))
            new_e = "god" if is_god else ELEMENTS[rng.integers(0, 5)]
            # Track output value per tier (success path only).
            tier_value_out[tier] += new_p * new_d
            # Both inputs burn on success, replace with new NFT.
            for idx in sorted([i, j], reverse=True):
                nfts.pop(idx); wids.pop(idx)
            nfts.append({"power": new_p, "dur": new_d, "element": new_e})
            wids.append(int(rng.integers(0, n_words)))
            pwr_out += new_p
            total_power += new_p - sum_pow

        # Monthly snapshot
        if (day + 1) % 30 == 0:
            tot_p = sum(x["power"] for x in nfts)
            powers_arr = np.array([x["power"] for x in nfts]) if nfts else np.array([0])
            monthly_snapshots.append({
                "month": (day + 1) // 30,
                "n_nfts": len(nfts),
                "total_power": tot_p,
                "avg_power": tot_p / max(len(nfts), 1),
                "median_power": int(np.median(powers_arr)),
                "p90_power": int(np.percentile(powers_arr, 90)),
                "p99_power": int(np.percentile(powers_arr, 99)),
                "max_power": int(powers_arr.max()),
                "burnt_M": burnt_aardi / 1_000_000,
                "succ": succ, "fail": fail,
                "mythic": mythic, "god": god,
            })

    n_end = len(nfts)
    pwr_end = sum(x["power"] for x in nfts)
    elem_end = {e: 0 for e in ELEMENTS}
    for x in nfts: elem_end[x["element"]] += 1
    avg_p = pwr_end / max(n_end, 1)
    avg_d = sum(x["dur"] for x in nfts) / max(n_end, 1)
    return dict(
        label=label, days=days, fpd=forges_per_day, ipd=inscribes_per_day,
        boundaries=boundaries,
        n_start=n_start, n_end=n_end, inscribed=inscribed_total,
        pwr_start=pwr_start, pwr_end=pwr_end,
        avg_p_start=pwr_start/n_start, avg_p_end=avg_p, avg_d_end=avg_d,
        succ=succ, fail=fail, tier_att=tier_att, tier_succ=tier_succ,
        tier_value_in=tier_value_in, tier_value_out=tier_value_out, tier_fee_paid=tier_fee_paid,
        crit=crit, mythic=mythic, god=god,
        burnt_M=burnt_aardi/1_000_000,
        pwr_in=pwr_in, pwr_out=pwr_out, pwr_delta=pwr_out-pwr_in,
        elem_start=elem_start, elem_end=elem_end,
        monthly=monthly_snapshots,
    )


def report(r):
    print()
    print("═" * 76)
    print(f"  {r['label']}")
    print(f"  ({r['days']}d × {r['fpd']} forges/d × {r['ipd']} inscribes/d, "
          f"boundaries={r['boundaries']})")
    print("═" * 76)
    n_forges = r['succ'] + r['fail']
    print(f"  pool:   {r['n_start']:>6,} → {r['n_end']:>6,}  "
          f"(+{r['inscribed']:,} inscribed, -{n_forges:,} forge attempts)")
    print(f"  fees:   {r['burnt_M']:.1f}M aARDI burnt")
    print(f"  forges: {r['succ']:,} success / {r['fail']:,} fail "
          f"({100*r['succ']/max(n_forges,1):.1f}% overall success)")
    print()
    print(f"  per-tier (random pair):")
    total_a = sum(r['tier_att'].values())
    for t in TIERS:
        a = r['tier_att'][t]; s = r['tier_succ'][t]
        print(f"    {t}:  attempts {a:>6,}  ({100*a/max(total_a,1):>5.1f}%)   "
              f"successes {s:>5,}  ({100*s/max(a,1):>5.1f}%)")
    print()
    print(f"  power:   total {r['pwr_start']:,} → {r['pwr_end']:,}")
    print(f"           avg/NFT {r['avg_p_start']:.1f} → {r['avg_p_end']:.1f}  "
          f"(forge Δ {r['pwr_delta']:+,})")
    print(f"           avg dur {r['avg_d_end']:.1f}/30")
    print()
    print(f"  specials: crit {r['crit']:,} | mythic {r['mythic']:,} | god {r['god']:,}")
    print()
    print(f"  element distribution (after sim):")
    total_e = sum(r['elem_end'].values())
    for e in ELEMENTS:
        s_pct = 100*r['elem_start'][e]/r['n_start']
        e_pct = 100*r['elem_end'][e]/max(total_e, 1)
        delta = e_pct - s_pct
        print(f"    {e:6s}  {r['elem_end'][e]:>5,}  ({e_pct:>5.2f}%)  "
              f"Δ {delta:+.2f}pp")


def ev_table(r):
    print(f"\n  Realized EV per tier (in power-day-yield units):")
    print(f"    {'Tier':<5} {'attempts':>9} {'p_succ':>7} {'in':>11} {'fee':>10} {'out':>11} {'invested':>10} {'EV':>11} {'EV%':>7}")
    for t in TIERS:
        att = r['tier_att'][t]
        if att == 0:
            print(f"    {t:<5} {0:>9}     —")
            continue
        succ = r['tier_succ'][t]
        v_in = r['tier_value_in'][t]
        v_out = r['tier_value_out'][t]
        fee = r['tier_fee_paid'][t]
        invested = v_in + fee
        ev = v_out - invested
        ev_pct = (ev / invested * 100) if invested else 0
        sign = '+' if ev_pct >= 0 else ''
        print(f"    {t:<5} {att:>9,} {100*succ/att:>6.1f}% "
              f"{v_in:>11,} {fee:>10,} {v_out:>11,} {invested:>10,} "
              f"{ev:>+11,} {sign}{ev_pct:>6.1f}%")


def power_table(r):
    print(f"\n  Power trajectory (per-month snapshots):")
    print(f"    {'month':>6} {'NFTs':>7} {'total_pwr':>11} {'avg':>7} {'median':>7} "
          f"{'p90':>5} {'p99':>5} {'max':>6} {'mythic':>7} {'god':>4}")
    for m in r["monthly"]:
        print(f"    {m['month']:>6} {m['n_nfts']:>7,} {m['total_power']:>11,} "
              f"{m['avg_power']:>7.1f} {m['median_power']:>7} {m['p90_power']:>5} "
              f"{m['p99_power']:>5} {m['max_power']:>6} {m['mythic']:>7} {m['god']:>4}")


if __name__ == "__main__":
    # Real-world params:
    #   coord rate today: ~12K commits/epoch × ~22 winners/epoch published,
    #     5 epochs/hr × 24h = 120 epochs/day → 2640 winners possible/day
    #     but MAX_MINTS_PER_AGENT=5 caps; real inscribe rate observed ~150-300/day
    INSCRIBE_PER_DAY = 200
    FORGE_PER_DAY    = 100

    print(f"\nparams: {INSCRIBE_PER_DAY} inscribes/day, {FORGE_PER_DAY} forges/day")
    print(f"specials: mythic={MYTHIC_BPS}bps, god={GOD_BPS}bps (both T1-only)\n")

    print(f"\n{'='*76}")
    print(f"DEPLOYED VALUES (Sepolia v4 + new mainnet plan):")
    print(f"  Tier boundaries: {NEW_BOUNDARIES}")
    print(f"  Mult bands: T1 {MULT_BAND['T1']}, T2 {MULT_BAND['T2']}, T3 {MULT_BAND['T3']}, "
          f"T4 {MULT_BAND['T4']}, T5 {MULT_BAND['T5']}")
    print(f"  Mythic: {MYTHIC_BPS}bps, God: {GOD_BPS}bps (T1 only)")
    print(f"  Fee: dynamic, k={K_FEE} × dailyEmission/totalActivePower × (Pa+Pb)")
    print(f"  Durability: min(durA + durB, {DUR_CAP})")
    print(f"{'='*76}")

    for HORIZON in (90, 180, 360):
        r = simulate(HORIZON, FORGE_PER_DAY, INSCRIBE_PER_DAY, NEW_BOUNDARIES,
                     f"{HORIZON}d — final values (k={K_FEE} dynamic fee)")
        report(r); ev_table(r); power_table(r)
