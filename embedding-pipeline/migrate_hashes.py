#!/usr/bin/env python3
import os
"""Push 21K word hashes into NFT.wordExists via migrateWordHashes batches."""
import json, subprocess, sys

PK = os.environ["PRIVATE_KEY"]  # sepolia testnet deployer
RPC = "https://sepolia.base.org"
NFT = "0x3F8eea4ab4f62BD119C820320e54dD530ebe6552"
BATCH = 500   # 500 SSTOREs ≈ 12M gas, well under Sepolia tx cap

def cast(args):
    out = subprocess.run(["cast"] + args, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"cast failed: {out.stderr}")
    return out.stdout.strip()

def get_nonce(addr):
    return int(cast(["nonce", addr, "--rpc-url", RPC]))

def main():
    hashes = json.load(open("/root/awp_code/ardi/contracts-v2/embedding-pipeline/word_hashes_21k.json"))
    print(f"loaded {len(hashes)} hashes")
    deployer = cast(["wallet", "address", "--private-key", PK])
    nonce = get_nonce(deployer)
    print(f"start nonce: {nonce}")

    total = (len(hashes) + BATCH - 1) // BATCH
    for i in range(total):
        chunk = hashes[i*BATCH:(i+1)*BATCH]
        arg = "[" + ",".join(chunk) + "]"
        attempt = 0
        while True:
            try:
                cast(["send", NFT, "migrateWordHashes(bytes32[])", arg,
                      "--private-key", PK, "--rpc-url", RPC,
                      "--nonce", str(nonce), "--gas-limit", "15000000"])
                break
            except RuntimeError as e:
                attempt += 1
                if attempt > 3: raise
                err = str(e).lower()
                if "nonce too low" in err:
                    nonce = get_nonce(deployer)
                elif "underpriced" in err:
                    import time; time.sleep(3)
                else: raise
        print(f"  batch {i+1}/{total} ({(i+1)*BATCH if (i+1)*BATCH<len(hashes) else len(hashes)}/{len(hashes)})")
        nonce += 1

    print("done")

if __name__ == "__main__":
    main()
