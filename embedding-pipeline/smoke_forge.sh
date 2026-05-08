#!/bin/bash
# End-to-end forge smoke test on Sepolia.
# Forges tokenId 1 (fire) + tokenId 2 (flame) — high cosine, T5 expected.
set -euo pipefail

PK="${PRIVATE_KEY:-0x...sepolia testnet...}"
RPC=https://sepolia.base.org
DEPLOYER=$(cast wallet address --private-key $PK)
NFT=0x3F8eea4ab4f62BD119C820320e54dD530ebe6552
RAND=0x33a9233301856245f49b2C3eC1c917b2f108741B
CHAINID=84532

A_TID=1; A_WID=0    # fire
B_TID=2; B_WID=1    # flame

NONCE=$(cast nonce $DEPLOYER --rpc-url $RPC)
FORGE_NONCE=$(cast call $NFT "forgeNonceOf(address)(uint256)" $DEPLOYER --rpc-url $RPC | tr -d ' ')
echo "On-chain forge nonce for deployer: $FORGE_NONCE"

# Build the EIP-191 digest matching contract:
# keccak256(abi.encodePacked("ARDI_FORGE_V4", chainid, nft, sender, A, B, wAID, wBID, nonce))
# then to-eth-signed-message-hash, sign with PK.
DIGEST=$(cast keccak $(cast abi-encode --packed \
    "f(string,uint256,address,address,uint256,uint256,uint16,uint16,uint256)" \
    "ARDI_FORGE_V4" $CHAINID $NFT $DEPLOYER $A_TID $B_TID $A_WID $B_WID $FORGE_NONCE))
echo "Digest: $DIGEST"

# cast wallet sign with --no-hash + eth-signed-message wrapping (cast does that automatically with --message)
SIG=$(cast wallet sign --private-key $PK $DIGEST 2>&1)
echo "Sig: $SIG"

# Call forge()
echo "=== forge() ==="
cast send $NFT "forge(uint256,uint256,uint16,uint16,bytes)" \
    $A_TID $B_TID $A_WID $B_WID $SIG \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000 \
    2>&1 | tee /tmp/forge_send.log | grep -E "transactionHash|error|status" | head -3
NONCE=$((NONCE+1))

# Find reqId from event logs
REQ_ID=$(grep -oP '"data":"0x[0-9a-f]+' /tmp/forge_send.log | head -1)
# ForgeRequested event has reqId as indexed (topic 2)
TXHASH=$(grep -oP 'transactionHash\s+0x[0-9a-f]+' /tmp/forge_send.log | head -1 | awk '{print $2}')
echo "Tx: $TXHASH"

sleep 4
RECEIPT=$(cast receipt $TXHASH --rpc-url $RPC --json 2>/dev/null)
REQ_ID=$(echo $RECEIPT | python3 -c "
import json, sys
r = json.load(sys.stdin)
# ForgeRequested(holder indexed, reqId indexed, tokenIdA, tokenIdB, tier, score)
for log in r['logs']:
    if log['address'].lower() == '$NFT'.lower() and len(log['topics']) >= 3:
        print(int(log['topics'][2], 16))
        break
")
echo "reqId: $REQ_ID"

# Mock fulfill VRF
echo "=== fulfill VRF ==="
cast send $RAND "fulfill(uint256)" $REQ_ID \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000 \
    2>&1 | grep -E "transactionHash|error|revert" | head -3
NONCE=$((NONCE+1))

sleep 4
echo "=== ForgeReq state ==="
cast call $NFT "pendingForge(uint256)" $REQ_ID --rpc-url $RPC

# If success, oracle delivers completeForge with new word + embedding
F=$(cast call $NFT "pendingForge(uint256)" $REQ_ID --rpc-url $RPC)
SUCCESS_BYTE=$(echo $F | cut -c$((2 + 32*2 - 30 - 2))-$((2 + 32*2 - 30 - 1)))
echo "(rolled, success info in struct above)"

# For the smoke test, just declare new word "blaze" with a mock embedding
NEW_WORD="blaze"
NEW_WID=21001
# Use a mock embedding (just zeros for now — testnet only, mainnet would use real PCA-projected)
NEW_EMB="0x$(python3 -c 'print(\"00\" * 96)')"

# Sign the completeForge digest:
# keccak256(abi.encodePacked("ARDI_FORGE_COMPLETE_V4", chainid, nft, reqId, bytes(word), embedding))
COMPLETE_DIGEST=$(cast keccak $(cast abi-encode --packed \
    "f(string,uint256,address,uint256,string,bytes)" \
    "ARDI_FORGE_COMPLETE_V4" $CHAINID $NFT $REQ_ID "$NEW_WORD" $NEW_EMB))
COMPLETE_SIG=$(cast wallet sign --private-key $PK $COMPLETE_DIGEST 2>&1)
echo "Complete sig: $COMPLETE_SIG"

echo "=== completeForge ==="
cast send $NFT "completeForge(uint256,string,bytes,bytes)" \
    $REQ_ID "$NEW_WORD" $NEW_EMB $COMPLETE_SIG \
    --private-key $PK --rpc-url $RPC --nonce $NONCE --gas-limit 1000000 \
    2>&1 | grep -E "transactionHash|error|revert" | head -3

sleep 4
echo "=== Final state ==="
echo "balanceOf deployer: $(cast call $NFT 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC)"
NEW_TID=$((21000 + 1))
echo "New NFT (tokenId $NEW_TID):"
cast call $NFT "getInscription(uint256)" $NEW_TID --rpc-url $RPC | head -3 || echo "  (not minted)"
