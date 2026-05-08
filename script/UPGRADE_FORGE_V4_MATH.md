# Upgrade ArdiNFTv4Testnet — ForgeMath rebalance

## Changes shipped

### Tier boundaries (matchScoreToTier)

```
Old: [21, 41, 61, 81]   (equal-width, 55/34/6/2/3% distribution)
New: [ 8, 15, 24, 36]   (equal-share, ~20/20/21/20/19%)
```

### Mult bands (_tierMultBand)

```
Tier   Old (bps)        New (bps)        Change
T1    35000-55000      35000-55000      unchanged
T2    22000-30000      23000-31000      +0.1× shift
T3    17000-20000      17000-20000      unchanged
T4    13000-15000      14000-16000      +0.1× shift
T5    12000-14000      12000-13500      tightened upper bound
```

### T1 specials (deriveOutcome)

```
Mythic prob:    100 bps (1%)  → 250 bps (2.5%)
God Touch prob:  10 bps (0.1%) → 25 bps (0.25%)
```
Compensates for T1's share of total forges dropping 55% → 20%.

### Unchanged

- Success rates (90/75/55/35/20%)
- Crit (T1 15%×2.0, T2 5%×1.5, T3 1%×1.5, T4/T5 none)
- Mythic +20% power bonus
- God Touch element override
- Element pool (1-5)
- Durability formula `min(durA + durB, 30)`
- Fee model (still static `forgeBaseFee`; dynamic k=7 in next upgrade)

## Deploy

```bash
cd /root/awp_code/ardi/contracts-v2
PROXY=0x3F8eea4ab4f62BD119C820320e54dD530ebe6552
DEPLOYER_PK=$(cat /root/.ardi-secrets/sepolia-deployer.txt | grep "Private key" | awk '{print $NF}')

PROXY=$PROXY DEPLOYER_PK=$DEPLOYER_PK \
  forge script script/UpgradeForgeV4Math.s.sol:UpgradeForgeV4Math \
    --rpc-url https://sepolia.base.org --broadcast
```

## Verify post-upgrade

```bash
RPC=https://sepolia.base.org
NFT=0x3F8eea4ab4f62BD119C820320e54dD530ebe6552

# new impl in slot
cast storage $NFT 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC

# spot-check tier boundaries via fresh preview call (need a forge oracle preview round-trip)
# tier of score=8 should be T2 now (was T1)
# tier of score=36 should be T5 now (was T2)
```

## Rollback

```bash
# Old impl: 0x72F9057ad08d3c1C175419a93E8ea7eccdeE1a2D (re-forge upgrade)
cast send $PROXY "upgradeToAndCall(address,bytes)" \
  0x72F9057ad08d3c1C175419a93E8ea7eccdeE1a2D 0x \
  --private-key $DEPLOYER_PK --rpc-url $RPC
```
