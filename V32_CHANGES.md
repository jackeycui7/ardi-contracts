# v3 → v3.2 Upgrade — Round-Based Durability + Repair Re-Activation

## Summary

UUPS upgrade over both `ArdiNFTv3` and `EmissionDistributor`. Two semantic
shifts, plus several admin tools added on the back of them.

| | v3 (current) | v3.2 (proposed) |
|---|---|---|
| Durability decay | Time-based: `(now - lastCheckpoint) / 1 days` per token | Round-based: tied to `notifyReward` calls |
| What triggers a -1 | Wall-clock — silent, no tx | Operator's daily `notifyReward` tx |
| Eviction from earning pool | Permissionless `expireToZero` (needs keepers) | Atomic, inside `notifyReward` (no keepers) |
| Repair after expire | **BUG**: pays fee, restores durability, but never re-joins the active pool. NFT silent forever. | Fixed: `_onRepairRandomness` success path re-activates if needed. |
| Owner durability override | None | `adminSetDurability`, `adminRewindDecayRound`, `adminBumpAllDurability` |

## Files

- `src/v3/ArdiNFTv3.sol` — added `virtual` to: `effectiveDurability`,
  `repair`, `_onRepairRandomness`, `_activate`, `_deactivate`. Compile-only;
  bytecode unchanged in functions that aren't overridden.
- `src/v3/EmissionDistributor.sol` — added `virtual` to: `notifyReward`,
  `pendingFor`, `claim`, `onActivate`, `onDeactivate`, `onTransfer`. Same
  caveat.
- `src/v32/ArdiNFTv32.sol` — new implementation (extends v3).
- `src/v32/EmissionDistributorV2.sol` — new implementation (extends v3).
- `script/UpgradeV32.s.sol` — UUPS upgrade script.
- `test/v32/RoundBasedDecay.t.sol` — 10 invariant tests, all passing.

## Storage layout

Both v3 contracts have `uint256[50] private __gap`. v32 consumes a few
slots from each gap and re-declares its own gap at the new tail. UUPS
upgrade safe.

`ArdiNFTv32` adds:
```solidity
uint64 public globalDecayRound;
mapping(uint64 => uint128) public expiringPowerAt;
mapping(uint256 => uint64) public expirationRoundOf;
mapping(uint256 => bool) public v32Migrated;
uint256[46] private __v32Gap;
```

`EmissionDistributorV2` adds:
```solidity
mapping(uint64 => uint256) public accAtEndOfRound;
IArdiNFTv32 public ardiNFTv32;  // same address as ardiNFT, typed view
uint256[48] private __v32Gap;
```

## Critical migration step (post-upgrade, pre-first-notifyReward)

1. **Pause** the distributor: `EmissionDistributorV2.pause()`.
2. **Wire**: `EmissionDistributorV2.setArdiNFTv32(<ardiNFTAddr>)`.
3. **Refresh existing NFTs**: `ArdiNFTv32.migrateExisting([ids…])` in
   batches of ≤200 tokenIds. **Required**: every active pre-v32 NFT has
   `expirationRoundOf == 0` by default; without migration they would all
   be evicted on the first round bump.
   - The function refreshes `currentDurability = maxDurability` and
     registers `expirationRoundOf = 0 + maxDurability`. Idempotent — safe
     to re-run on the same tokenIds.
4. **Unpause**: `EmissionDistributorV2.unpause()`.
5. **First reward distribution**: `EmissionDistributorV2.notifyReward(amount)`.
   This atomically:
   - Distributes `amount` over current `totalActivePower`.
   - Calls `ArdiNFTv32.bumpDecayRound()` → `globalDecayRound = 1`,
     returns the power expiring at round 1.
   - Snapshots `accAtEndOfRound[1]`.
   - Subtracts expired power from `totalActivePower`.

## Invariants (covered in `test/v32/RoundBasedDecay.t.sol`)

1. **Fresh mint** at round R registers `expirationRoundOf = R + maxDurability`.
2. **`notifyReward`** atomically advances `globalDecayRound` by exactly 1.
3. **NFTs with `dura > 0`** participate in current round's distribution;
   their power IS in the denominator that round.
4. **NFTs whose `dura` reaches 0 this round** earn their final share, then
   their power is removed from the denominator before the next round.
5. **Expired NFTs** can still claim what they earned (cap snapshot in
   `accAtEndOfRound`); they cannot accrue rewards from later rounds.
6. **Repair after `expireToZero`** correctly re-activates the NFT into the
   emission pool. (v3 BUG fixed.)
7. **`migrateExisting`** is idempotent and safe to chunk.
8. **`adminRewindDecayRound`** gives every active NFT extra rounds.
9. **`adminSetDurability`** correctly re-points the expiration registry.
10. **`onlyHolder`** check on `claim` is preserved.

## Known small concerns

- **Lazy slot cleanup**: When an NFT is bump-evicted, its `s.power` slot
  in `EmissionDistributor` stays set. Reads use the cap snapshot to
  prevent over-accrual. The slot is finally cleared when the holder calls
  `claim` and then later `expireToZero`. This is fine economically
  (correctness preserved) but means the `tokens` mapping grows
  monotonically. With a 21K cap on supply, this is bounded.
- **`adminBumpAllDurability` is implemented as a global rewind**. It does
  not iterate per-NFT; it just decrements `globalDecayRound`. The effect
  is "every active NFT gets `by` extra rounds" — equivalent to per-NFT
  durability bump for currently-active NFTs. Tokens that were already
  expired DO NOT come back from this (their snapshot is permanent).
- **`adminSetMaxDurability` uses `this.adminSetDurability`** as a fallback
  when shrinking max below current. This costs one external call but
  keeps the registry consistent. Owner-only path; gas is not a concern.

## Test result

```
$ forge test --match-path "test/v32/*"
Ran 11 tests, 11 passed, 0 failed, 0 skipped
```

## Audit fixes applied (self-audit pass, 2026-05-04)

- **H-1**: `adminSetMaxDurability` previously called `this.adminSetDurability`,
  which made `msg.sender = address(this)` and tripped the `onlyOwner`
  guard, reverting every shrink call. Fixed by extracting an
  internal `_setDurability` worker; both admin paths reuse it directly.
- **M-1**: `_capAcc` returned `accRewardPerPower` for tokens with
  `expirationRoundOf == 0` (= unmigrated pre-v32 NFTs). If an
  operator notifyReward'd before completing migration, those NFTs
  could claim the entire accumulated reward against `s.rewardDebt = 0`.
  Now returns the per-power level corresponding to `s.rewardDebt`,
  so accrued exactly equals debt and pending = 0 for unmigrated
  tokens. Operator must complete migration before NFTs can earn.
- **L-1**: dropped a stray `unchecked` block around
  `--pendingRequestsCount` in the repair success path. Match v3's
  checked semantics so an underflow surfaces instead of wrapping.

L-2 (cap accounting in `pendingPool` zero-power branch) and L-3
(view-only double-count when same tokenId passed twice to
`pendingFor`) are documented but not patched — both are operator-
correctable / UI-only and don't affect on-chain solvency.

## Audit fixes applied (second pass, 2026-05-04)

- **H-2** (CRITICAL, **solvency-breaking**): repair-during-bump-eviction
  let the NFT claim more $ardi than was distributed to it. Sequence:
    1. NFT has `expR=10`, `currentDur=2`, `globalDecayRound=8`.
    2. Holder calls `repair()` — `currentDur` refreshes to maxDur, but
       `repair()` does NOT touch `expirationRoundOf`. VRF request fires.
    3. `notifyReward` fires before VRF callback. Bump consumes
       `expiringPowerAt[10]` (includes NFT's power); `totalActivePower`
       drops; `accAtEndOfRound[10]` snapshots. NFT's `s.power` slot in
       distributor is NOT cleared (no per-NFT iteration during bump).
    4. VRF callback fires (success). Pre-fix, the success path took the
       "still tracked" branch, set `expR = globalDecayRound + maxDur`
       (a future round), and left the distributor desync'd.
    5. Future `notifyReward` distributions now exclude the NFT from the
       denominator, but `_capAcc` returns full `accRewardPerPower`
       (because `globalDecayRound <= expR`). NFT claims `power × acc /
       1e18 - 0 (rewardDebt)`, which includes accrual from rounds whose
       distributions did NOT include the NFT — claim exceeds deposit,
       contract goes insolvent.

  **Fix**: `_onRepairRandomness` success path detects bump-eviction
  via `ins.activeTracked && oldExp != 0 && oldExp <= globalDecayRound`,
  and calls `_deactivate` + `_activate` to resync the distributor side.
  Both onDeactivate and onActivate are wired to handle this correctly
  (onDeactivate's `wasBumpEvicted` guard skips the totalActive
  subtraction; onActivate adds the power back). Regression test:
  `test_repairBumpEvictedDuringVRF_noLeak` confirms post-fix solvency.
