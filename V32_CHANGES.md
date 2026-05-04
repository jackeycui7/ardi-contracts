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
| Reward delivery | Operator pre-funds distributor; `claim` does `safeTransfer`. | **Mint-on-claim**: distributor never holds tokens; `claim` calls external `rewardMinter.batchMint`. |
| Pending attribution on transfer | Settles to `from`'s `pendingOf` mapping. | **Reward-follows-NFT**: pending stays on the tokenId; new owner inherits everything unclaimed. |

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
IArdiNFTv32 public ardiNFTv32;       // same address as ardiNFT, typed view
IRewardMinter public rewardMinter;   // external batch-mint contract
mapping(uint256 => uint256) public unclaimedByToken;  // reward parked on NFTs
uint256[46] private __v32Gap;
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
- **⚠ `adminRewindDecayRound` / `adminBumpAllDurability` state-drift caveat**.
  Rewinding the round counter makes `effectiveDurability` of every NFT
  larger (they appear "more alive"). However, NFTs that were
  bump-evicted in the rewound rounds are NOT automatically returned to
  `totalActivePower` on the distributor side — the eviction was
  push-based when `notifyReward` originally fired. Result: those NFTs
  display dura > 0 but earn nothing on subsequent `notifyReward`. To
  fully undo a `notifyReward` mistake, owner must rewind AND manually
  re-activate evicted NFTs (e.g. via `adminSetDurability(tid,
  maxDurability)` per token, which re-registers them in
  `expiringPowerAt` and via the override path also flows back into the
  distributor). For a launch-day operator mistake this is the cost of
  recovery; design the runbook accordingly. **Recommendation**: only use
  rewind in the same tx as a reverted notifyReward, before any NFT has
  hit dura=0 — otherwise plan for per-NFT cleanup.
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

## Audit fixes applied (third pass, 2026-05-04)

- **L-4**: `migrateExisting` previously only short-circuited on the
  `v32Migrated` flag and the `!ins.activeTracked` check. If owner
  passed a tokenId that was minted POST-upgrade (already auto-
  registered via `_activate`), the function would re-register it,
  doubling its entry in `expiringPowerAt[expR]`. On expiration that
  bucket would over-subtract from `totalActivePower`, diluting other
  holders' rewards. Fix: skip when `expirationRoundOf[tid] != 0`.
- **L-5**: `_activate` had no v32-side idempotency. Today every call
  path arrives in a clean (expR == 0) state, but a future upgrade
  could break that invariant and silently double-credit
  `expiringPowerAt`. Defense-in-depth: early return if
  `expirationRoundOf[tokenId] != 0`. No semantic change for current
  call sites.

Test count 12 → 14 (added `test_migrateExisting_idempotent_for_postUpgradeMinted`
and `test_activate_idempotent_on_v32_side`).

## Audit fixes applied (fourth pass, 2026-05-04 — distribution model)

External auditor recommendation: replace pre-funded transfer model with
**mint-on-claim**, and replace **address-attributed** pending-on-transfer
with **NFT-attributed** (reward follows the NFT, not the seller).

### Why this is safer than v3 distribution

1. **Operator key blast radius shrinks**. v3 operator must hold ≥24M $ardi
   and approve the distributor; if the operator EOA leaks, attacker drains
   approved balance. v3.2 operator only needs the right to call
   `notifyReward(amount)` — an attacker calling notifyReward cannot mint
   tokens (only the external `rewardMinter` can), so the worst case is
   "spam notifyReward(0) to advance rounds and burn everyone's dura". A
   bad outcome but not a token-theft outcome.
2. **Distributor solvency invariant disappears**. The contract no longer
   needs to hold $ardi backing claims; mint happens on demand. There's no
   "operator forgot to fund" failure mode where claims revert on
   insufficient balance.
3. **Marketplace UX matches user mental model**. Buyers of high-power
   ardi NFTs expect to inherit any unclaimed reward; settle-on-transfer
   surprised buyers who didn't realize the reward got stranded with the
   seller.

### What changed in EmissionDistributorV2

- **`notifyReward(amount)`** no longer calls `safeTransferFrom`. It is now
  a pure account update (round bump + `accRewardPerPower` update). The
  contract holds no $ardi balance during normal operation.
- **`claim(tokenIds)`** now (a) verifies ownership via `IERC721.ownerOf`
  (ground truth, not the cached `s.holder`), (b) sums per-token pending
  using cap-aware accumulator, (c) drains `unclaimedByToken[tid]`, and
  (d) calls `rewardMinter.batchMint([msg.sender], [total])` to mint the
  reward fresh.
- **`onTransfer(tokenId, from, to)`** does NOT settle pending to `from`.
  It just rotates the cached `s.holder = to`. `s.rewardDebt` is
  untouched, so the new owner's first claim collects everything
  accumulated since the previous claim — including the pre-transfer share.
  Deactivated NFTs (s.power == 0) are now allowed to transfer (no-op
  hook); their parked reward in `unclaimedByToken[tid]` follows the NFT.
- **`onDeactivate(tokenId, holder)`** parks the final settled `owed`
  into `unclaimedByToken[tokenId]` instead of `pendingOf[holder]`. The
  parked reward stays with the NFT and is claimable by any future owner.
- **`pendingFor(holder, tokenIds)`** drops the `pendingOf[holder]` base
  and stops checking `ownerOf` (a view should not revert on garbage
  input). Sums per-token active accrual + parked. Auth lives in `claim`.
- **New owner-only `setRewardMinter(address)`** — binds the external
  minter contract. Distributor must be granted MERKLE_ROLE on the
  underlying $ardi minter for `batchMint` calls to succeed.

### What stays the same

- The accRewardPerPower / round / `_capAcc` math is unchanged; the H-2
  solvency fix from the second audit pass still applies.
- `pendingOf[address]` mapping in the base v3 contract still exists in
  storage (we cannot remove parent state) but is no longer written to or
  read from. Pre-upgrade balances are zero (no notifyReward fired in v3),
  so there is no migration concern.
- All admin overrides (`adminSetDurability` et al) work as before.

### Trust assumptions on `rewardMinter`

- Must implement `batchMint(address[], uint256[])` per `IRewardMinter`
  with semantics "for each i, mint amounts[i] of $ardi to recipients[i]".
- Must hold MINTER/MERKLE_ROLE on the $ardi token contract.
- May internally remap recipients (e.g. `IAWPRegistry.resolveRecipients`).
  Distributor passes the claimer's address verbatim; the minter contract
  is the one resolving. Document this for users so claims arriving at a
  remapped address aren't a surprise.
- A malicious or paused minter can DoS `claim` (revert), but cannot
  produce phantom rewards on the distributor side. Distributor's pending
  state is preserved on revert (no state changes outlive a failed mint).

### Storage layout impact

Two new slots taken from `__v32Gap`: `rewardMinter` (1) and
`unclaimedByToken` mapping (1). `__v32Gap` size 48 → 46. Storage layout
remains UUPS-upgrade-compatible — no existing slots touched, no
ordering shuffled.

### Tests added (count 14 → 17 18, all passing)

- `test_transferCarriesUnclaimedReward_toNewOwner` — A accrues 300, transfers, B accrues 200, B claims 500, A revert.
- `test_transferCarriesUnclaimedReward_afterExpiration` — NFT bump-evicted at dura=0, transferred while dead, new owner claims earned reward, no post-expiry leak.
- `test_repairBumpEvictedDuringVRF_noLeak` — H-2 regression rewritten for mint-on-claim: claim mints exactly pendingFor, no over-mint.
