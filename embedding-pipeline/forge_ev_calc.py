#!/usr/bin/env python3
"""
Forge EV calculator — exact, in unified power-day-yield units.

Setup:
  Two input NFTs A, B, each with power P, durability d.
  Fee formula: forgeFee = k × dailyEmission/totalActivePower × (Pa+Pb)
  In power-day units: fee = k × (Pa+Pb) = 2P×k.

Per-tier params: success rate, mult band, crit (prob, mult), mythic (prob, bonus), god touch.
mythic adds +20% to power. god touch only changes element (no power effect).

For success path:
  base_mult = uniform(min, max)
  if crit:    final_mult = base_mult × crit_mult
  if mythic:  power_bonus = ×1.2
  newPower  = (Pa+Pb) × final_mult × (1.2 if mythic else 1.0)
  newDur    = min(dA+dB, 30)

Output value: newPower × newDur (in power-day units).

Net EV = P_success × E[output_value] - input_value - fee
"""

# ── tier params (current proposal) ─────────────────────────────────────────────
TIERS = {
    'T1': dict(p_succ=0.20, mult=(3.5, 5.5),  crit=(0.15, 2.0),  mythic_p=0.025, god_p=0.0025),
    'T2': dict(p_succ=0.35, mult=(2.3, 3.1),  crit=(0.05, 1.5),  mythic_p=0.0,   god_p=0.0),
    'T3': dict(p_succ=0.55, mult=(1.7, 2.0),  crit=(0.01, 1.5),  mythic_p=0.0,   god_p=0.0),
    'T4': dict(p_succ=0.75, mult=(1.4, 1.6),  crit=(0.0,  1.0),  mythic_p=0.0,   god_p=0.0),
    'T5': dict(p_succ=0.90, mult=(1.2, 1.35), crit=(0.0,  1.0),  mythic_p=0.0,   god_p=0.0),
}

MYTHIC_BONUS = 1.2
DUR_CAP = 30
K = 7  # fee = k × (Pa+Pb) days of yield

# ── helpers ───────────────────────────────────────────────────────────────────

def expected_mult(t):
    """Effective expected multiplier including crit + mythic power bonus."""
    mn, mx = t['mult']
    avg_base_mult = (mn + mx) / 2

    # Crit applies during success path. avg_mult after crit:
    cp, cm = t['crit']
    eff_after_crit = (1 - cp) * avg_base_mult + cp * avg_base_mult * cm

    # Mythic adds 1.2× power on top during success.
    mp = t['mythic_p']
    eff_after_mythic = (1 - mp) * eff_after_crit + mp * eff_after_crit * MYTHIC_BONUS
    return eff_after_mythic


def compute_ev(t, P, d):
    """Compute net EV in power-day units, plus % of total invested."""
    eff_mult = expected_mult(t)
    p_succ = t['p_succ']
    # input value (both NFTs lost regardless of outcome)
    input_val = 2 * P * d
    # fee in power-day units
    fee = K * 2 * P
    total_invested = input_val + fee
    # output value (only on success)
    new_dur = min(2 * d, DUR_CAP)
    new_power_avg = (2 * P) * eff_mult  # E[newPower] (mythic already factored)
    output_val = new_power_avg * new_dur
    # EV
    ev_value = p_succ * output_val - input_val - fee
    ev_pct = ev_value / total_invested
    return dict(
        eff_mult=eff_mult,
        input_val=input_val,
        fee=fee,
        total_invested=total_invested,
        output_avg=output_val,
        output_expected=p_succ * output_val,
        ev_value=ev_value,
        ev_pct=ev_pct,
    )


# ── run for various d values ──────────────────────────────────────────────────

P = 50  # representative power; doesn't matter for %, scales out

print(f"\n{'═'*84}")
print(f"  Forge EV under k={K} fee, with crit + mythic specials baked into eff_mult")
print(f"  (P=50 per NFT for value display; EV% is invariant to P)")
print(f"{'═'*84}\n")

for d in (3, 5, 7, 10, 14):
    new_d = min(2*d, DUR_CAP)
    print(f"  ── input dura = {d}  →  output dura = min({d}+{d}, {DUR_CAP}) = {new_d} ──")
    print(f"     {'Tier':<5} {'eff_mult':>9} {'input':>7} {'fee':>5} {'invested':>9} "
          f"{'E[out]':>8} {'EV value':>10} {'EV %':>7}")
    for tname, t in TIERS.items():
        r = compute_ev(t, P, d)
        sign = '+' if r['ev_pct'] >= 0 else ''
        print(f"     {tname:<5} {r['eff_mult']:>9.4f} {r['input_val']:>7.0f} {r['fee']:>5.0f} "
              f"{r['total_invested']:>9.0f} {r['output_expected']:>8.1f} {r['ev_value']:>+10.1f} "
              f"{sign}{r['ev_pct']*100:>6.1f}%")
    print()


# ── Compact tier × dura matrix ────────────────────────────────────────────────

print(f"\n{'═'*84}")
print(f"  TIER × DURA EV MATRIX  (% of total invested)")
print(f"  Row = tier, Col = input dura per NFT (assumed symmetric)")
print(f"{'═'*84}")
duras = [3, 5, 7, 9, 11, 14]
header = "  " + " " * 6 + "  ".join(f"d={d:>2}" for d in duras)
print(header)
for tname, t in TIERS.items():
    row = f"  {tname:<5}"
    for d in duras:
        r = compute_ev(t, P, d)
        sign = '+' if r['ev_pct'] >= 0 else ''
        row += f"  {sign}{r['ev_pct']*100:>5.1f}%"
    print(row)

# ── Per-tier walk-through with all components ────────────────────────────────
print(f"\n{'═'*84}")
print(f"  Per-tier breakdown (P=50 representative power, d=7 mid-life)")
print(f"{'═'*84}")
d_for_detail = 7
for tname, t in TIERS.items():
    r = compute_ev(t, P, d_for_detail)
    p = t['p_succ']
    mn, mx = t['mult']
    cp, cm = t['crit']
    mp = t['mythic_p']
    gp = t['god_p']
    print(f"\n  ── {tname} (p_succ={p*100:.0f}%, mult {mn}-{mx}, "
          f"crit {cp*100:.0f}%×{cm}, mythic {mp*100:.1f}%, god {gp*100:.2f}%) ──")
    print(f"     base avg mult            = {(mn+mx)/2:.3f}")
    print(f"     after crit boost         = {(1-cp)*(mn+mx)/2 + cp*(mn+mx)/2*cm:.3f}")
    print(f"     after mythic boost       = {r['eff_mult']:.4f}  (effective E[mult on success])")
    print(f"     input value              = 2P × d = {r['input_val']} (= 2×50×7)")
    print(f"     fee                      = 7×2P  = {r['fee']:.0f}")
    print(f"     total invested           = {r['total_invested']:.0f}")
    print(f"     output (if success)      = eff_mult × 2P × min(2d,30) = {r['eff_mult']:.3f} × 100 × 14 = {r['eff_mult']*100*14:.1f}")
    print(f"     E[output] = p × output  = {p} × {r['eff_mult']*100*14:.1f} = {r['output_expected']:.1f}")
    print(f"     EV value                 = E[output] - invested = {r['output_expected']:.1f} - {r['total_invested']:.0f} = {r['ev_value']:+.1f}")
    print(f"     EV %                     = EV / invested = {r['ev_pct']*100:+.2f}%")

# ── what dura makes each tier break-even? ─────────────────────────────────────

print(f"\n{'─'*84}")
print(f"  Break-even input dura (EV = 0) per tier:")
print(f"  Solve: P_succ × eff_mult × 2P × min(2d,30) = 2Pd + 14P")
print(f"     → assuming 2d < 30:  P_succ × eff_mult × 2d = d + 7")
print(f"     → d = 7 / (P_succ × eff_mult × 2 - 1)  if denom > 0, else infinite")
print(f"{'─'*84}")
for tname, t in TIERS.items():
    eff_mult = expected_mult(t)
    p = t['p_succ']
    denom = p * eff_mult * 2 - 1
    if denom <= 0:
        be = "∞ (always EV-)"
    else:
        be = f"{7/denom:.2f}"
    # Verify by plugging in
    print(f"    {tname}: eff_mult={eff_mult:.4f}, p_succ={p}, "
          f"break-even d ≈ {be}")
