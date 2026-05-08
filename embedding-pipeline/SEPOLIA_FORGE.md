# Forge Testnet — Base Sepolia (2026-05-07)

## Deployed contracts

| Contract | Address |
|---|---|
| ArdiNFTv4Testnet (proxy) | `0x3F8eea4ab4f62BD119C820320e54dD530ebe6552` |
| ArdiNFTv4Testnet (impl) | `0x3C46a1a6cfF8067974e8f86F80a01a1B6e17f5A0` |
| EmbeddingStore (sealed) | `0x4dB1D4aB5A538F76A9B5b2181241d07a138eF15e` |
| MockRandomness | `0x33a9233301856245f49b2C3eC1c917b2f108741B` |
| Test aARDI token | `0xa3E9C2E1503f21521Eb631f7d8A60ff9764C4bC9` |
| Owner / oracle / treasury | `0xe573A307dE971C92C532309F3D86F48d1628c7c5` |

PK at `/root/.ardi-secrets/sepolia-deployer.txt`.

## Test wordbank (20 words, ids 0-19)

```
0  fire     5  water    10 forest   15 stone
1  flame    6  ocean    11 tree     16 mountain
2  ember    7  river    12 leaf     17 iron
3  spark    8  ice      13 seed     18 silver
4  blaze    9  steam    14 moss     19 gold
```

## Smoke test run (passed 2026-05-07)

forge fire(tid=1, wid=0) + flame(tid=2, wid=1):
- matchScore = **83** → T5 Twins
- VRF roll: success, multBps = 13423 (×1.343)
- newPower = (50 + 60) × 1.343 = **147** ✓
- newDur = min(8 + 7, 30) = **15** ✓
- newElement = 1 (metal, by VRF — unrelated to parents)
- Burned: tid 1 + tid 2
- Minted: tid 21001 = "blaze"
- 20K tAARDI burnt to 0xdead

## Try a forge (cli)

Need: deployer PK + at least 2 NFTs owned by you.

```bash
PK=<your sepolia pk>
RPC=https://sepolia.base.org
NFT=0x3F8eea4ab4f62BD119C820320e54dD530ebe6552
RAND=0x33a9233301856245f49b2C3eC1c917b2f108741B

A_TID=6;  A_WID=5    # water
B_TID=7;  B_WID=6    # ocean

DEPLOYER=$(cast wallet address --private-key $PK)
NONCE=$(cast nonce $DEPLOYER --rpc-url $RPC)
FORGE_NONCE=$(cast call $NFT "forgeNonceOf(address)(uint256)" $DEPLOYER --rpc-url $RPC | tr -d ' ')

# 1. Sign forge intent
DIGEST=$(cast keccak $(cast abi-encode --packed \
    "f(string,uint256,address,address,uint256,uint256,uint16,uint16,uint256)" \
    "ARDI_FORGE_V4" 84532 $NFT $DEPLOYER $A_TID $B_TID $A_WID $B_WID $FORGE_NONCE))
SIG=$(cast wallet sign --private-key $PK $DIGEST)

# 2. Call forge() — returns reqId
TX=$(cast send $NFT "forge(uint256,uint256,uint16,uint16,bytes)" \
    $A_TID $B_TID $A_WID $B_WID $SIG \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000 --json | jq -r .transactionHash)
NONCE=$((NONCE+1))
sleep 4
REQ_ID=$(cast receipt $TX --rpc-url $RPC --json | jq -r '.logs[] | select(.address|ascii_downcase=="'$(echo $NFT | tr A-Z a-z)'") | select(.topics[0]=="0x63067c924f4f6db65f4ab22c62c7821ee841b43a0f324e12510bd567f53a383f") | .topics[2]' | head -1)
echo "reqId: $((16#${REQ_ID#0x}))"

# 3. Mock-fulfill VRF (auto on real Chainlink, manual here)
cast send $RAND "fulfill(uint256)" $((16#${REQ_ID#0x})) \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000
NONCE=$((NONCE+1))

# 4. Read outcome
cast call $NFT "pendingForge(uint256)" $((16#${REQ_ID#0x})) --rpc-url $RPC

# 5. If success: oracle delivers new word + embedding (96 bytes), signs, calls completeForge
NEW_WORD="abyss"   # pick any word not yet on chain
NEW_EMB=$(python3 -c "print('0x' + '00' * 96)")  # mock embedding for testnet
COMPLETE_DIGEST=$(cast keccak $(cast abi-encode --packed \
    "f(string,uint256,address,uint256,string,bytes)" \
    "ARDI_FORGE_COMPLETE_V4" 84532 $NFT $((16#${REQ_ID#0x})) "$NEW_WORD" $NEW_EMB))
COMPLETE_SIG=$(cast wallet sign --private-key $PK $COMPLETE_DIGEST)

cast send $NFT "completeForge(uint256,string,bytes,bytes)" \
    $((16#${REQ_ID#0x})) "$NEW_WORD" $NEW_EMB $COMPLETE_SIG \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000
```

## Tier expectations (matchScore → tier)

| Score | Tier | Success | Mult |
|---|---|---|---|
| 81-100 | T5 Twins | 90% | 1.2-1.4× |
| 61-80 | T4 Similar | 75% | 1.3-1.5× |
| 41-60 | T3 Related | 55% | 1.7-2.0× (1% crit ×1.5) |
| 21-40 | T2 Distant | 35% | 2.2-3.0× (5% crit ×1.5) |
| 0-20 | T1 Wild | 20% | 3.5-5.5× (15% crit ×2, 1% mythic, 0.1% god touch) |

Test pairs by similarity (rough estimates):
- fire+flame, water+ocean → T5
- fire+ember, ocean+river → T4 likely
- fire+water → T3 likely
- iron+leaf → T2 likely
- gold+silence → T1 likely (semantically unrelated)

## What testnet skips (do later for mainnet)

- Real Chainlink VRF subscription (using MockRandomness with manual fulfill)
- EmbeddingStore.addForgedWord (testnet skips storing embeddings of forged words)
- Coord-rs LLM oracle (testnet manually crafts new word + sig with `cast wallet sign`)
- Emission distributor integration (testnet has none)
- Post-forge embedding registration (mock zeros for now)

## Next steps

1. **You play with it**: try a few forges across tier boundaries to feel the system
2. **Tomorrow**: write the mainnet surgical clone (v322-storage-compatible) to upgrade the live ArdiNFT proxy without burn-and-swap
3. **Coord-rs**: rewrite ardi-fusion oracle to drop power/lang/element signing, only do newWord + lore
4. **Frontend**: forge UI on ardinals-demo-next
