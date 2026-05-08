#!/usr/bin/env python3
import os
"""Mint 500 NFTs to a target address using real wordbank words."""
import json, subprocess, sys

PK = os.environ["PRIVATE_KEY"]  # sepolia testnet deployer
RPC = "https://sepolia.base.org"
NFT = "0x3F8eea4ab4f62BD119C820320e54dD530ebe6552"

LANG_MAP = {"en": 0, "zh": 1, "ja": 2, "ko": 3, "fr": 4, "de": 5}

def cast(args):
    out = subprocess.run(["cast"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"cast failed: {out.stderr}")
    return out.stdout.strip()

def get_nonce(addr):
    return int(cast(["nonce", addr, "--rpc-url", RPC]))

def main():
    target = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    start_id = int(sys.argv[3]) if len(sys.argv) > 3 else 1000  # avoid 0..99 (legendary) and 100 (we used)

    data = json.load(open("/root/awp_code/ardi/wordbank-riddle-bench/quiz_21000_answers.json"))
    deployer = cast(["wallet", "address", "--private-key", PK])
    nonce = get_nonce(deployer)
    print(f"deployer: {deployer}, nonce: {nonce}, target: {target}")
    print(f"will mint wordIds [{start_id}..{start_id + n - 1}] to target")

    # Pre-check: which tokenIds are already minted? Skip those.
    minted = 0
    for i in range(start_id, start_id + n + 200):  # buffer in case of skips
        if minted >= n: break
        entry = data[i]
        word = entry["word"]
        power = entry["power"]
        lang = LANG_MAP.get(entry["language"], 0)
        # element: derive from word hash for determinism (1..5, no god in admin mint)
        elem = (sum(ord(c) for c in word) % 5) + 1
        # maxDur: 1..14 weighted on rarity
        rarity = entry.get("rarity", "common")
        dur_map = {"legendary": 14, "epic": 12, "rare": 10, "uncommon": 8, "common": 6}
        maxDur = dur_map.get(rarity, 6)

        attempt = 0
        while True:
            try:
                cast(["send", NFT,
                      "adminMint(address,uint16,string,uint16,uint8,uint8,uint8)",
                      target, str(i), word, str(power), str(elem), str(maxDur), str(lang),
                      "--private-key", PK, "--rpc-url", RPC,
                      "--nonce", str(nonce), "--gas-limit", "500000"])
                break
            except RuntimeError as e:
                err = str(e).lower()
                if "tokenid taken" in err or "word taken" in err:
                    print(f"  skip wordId={i} ({word}) — already minted")
                    break
                attempt += 1
                if attempt > 3: raise
                if "nonce too low" in err:
                    nonce = get_nonce(deployer); continue
                elif "underpriced" in err:
                    import time; time.sleep(2)
                else: raise
        else:
            continue
        # only count successful (no break-into-skip)
        if attempt == 0 or attempt > 3: pass
        nonce += 1
        minted += 1
        if minted % 50 == 0:
            print(f"  minted {minted}/{n} (last: tid={i+1} word='{word}')")

    print(f"done. minted {minted} NFTs.")

if __name__ == "__main__":
    main()
