#!/bin/bash
set -euo pipefail

# Upload 20 test embeddings to EmbeddingStore + seal it.
STORE=0x4dB1D4aB5A538F76A9B5b2181241d07a138eF15e
RPC=https://sepolia.base.org
PK="${PRIVATE_KEY:-0x...sepolia testnet...}"
ARTIFACTS=/root/awp_code/ardi/contracts-v2/embedding-pipeline/artifacts

# Build arrays via python: id list and embedding hex list.
read IDS EMBS <<< $(python3 -c "
import json
e = json.load(open('$ARTIFACTS/embeddings.json'))
ids = '[' + ','.join(sorted(e.keys(), key=int)) + ']'
embs = '[' + ','.join(e[k] for k in sorted(e.keys(), key=int)) + ']'
print(ids, embs)
")

# Set PCA + model hashes on store
PCA_HASH=$(python3 -c "import json,hashlib; print('0x'+hashlib.sha256(open('$ARTIFACTS/pca_basis.json','rb').read()).hexdigest())")
MODEL_HASH=$(cast keccak "all-MiniLM-L6-v2/sentence-transformers")

echo "PCA hash:   $PCA_HASH"
echo "Model hash: $MODEL_HASH"

cast send $STORE "setPcaBasisHash(bytes32)" $PCA_HASH --private-key $PK --rpc-url $RPC > /tmp/u.log
cast send $STORE "setModelHash(bytes32)" $MODEL_HASH --private-key $PK --rpc-url $RPC > /tmp/u.log

# Single-batch upload (only 20 entries)
echo "Uploading $IDS / $EMBS ..."
cast send $STORE "setBatch(uint16[],bytes[])" "$IDS" "$EMBS" \
    --private-key $PK --rpc-url $RPC --gas-limit 5000000 > /tmp/u.log
echo "  storedCount: $(cast call $STORE 'storedCount()(uint32)' --rpc-url $RPC)"

# Seal
cast send $STORE "seal()" --private-key $PK --rpc-url $RPC > /tmp/u.log
echo "  sealed: $(cast call $STORE 'sealed_()(bool)' --rpc-url $RPC)"
