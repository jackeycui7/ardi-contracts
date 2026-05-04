#!/usr/bin/env python3
"""Print vault leaf + Merkle proof for one word_id from a vault json.

Usage: proof_for_word.py <vault.json> <word_id>
Output: leaf, proof[], root, plus the (power, lang, maxDur, element) tuple.
"""
import sys, json, random
from pathlib import Path

ELEMENT_ID = {"metal": 1, "wood": 2, "water": 3, "fire": 4, "earth": 5}
LANG_ID = {"en": 0, "zh": 1, "ja": 2, "ko": 3, "fr": 4, "de": 5}

def keccak256(data):
    try:
        from Crypto.Hash import keccak
        h = keccak.new(digest_bits=256); h.update(data); return h.digest()
    except ImportError:
        from eth_hash.auto import keccak as ek
        return ek(data)

def vault_leaf(word_id, word, power, lang_id, max_dur, element):
    buf = b""
    buf += word_id.to_bytes(32, "big")
    buf += keccak256(word.encode())
    buf += power.to_bytes(2, "big")
    buf += bytes([lang_id, max_dur, element])
    return keccak256(buf)

def pair_hash(a, b):
    lo, hi = (a, b) if a <= b else (b, a)
    return keccak256(lo + hi)

def main():
    vault_path = Path(sys.argv[1])
    target = int(sys.argv[2])
    entries = json.loads(vault_path.read_text())

    leaves = []
    for e in entries:
        leaves.append(vault_leaf(
            word_id=e["id"],
            word=e["word"],
            power=e["power"],
            lang_id=LANG_ID[e["language"]],
            max_dur=e["max_durability"],
            element=ELEMENT_ID[e["element"]],
        ))

    # Build layers; track sibling for target
    layer = leaves[:]
    proofs = [[] for _ in entries]
    while len(layer) > 1:
        nxt = []
        for i in range(0, len(layer), 2):
            if i + 1 < len(layer):
                nxt.append(pair_hash(layer[i], layer[i + 1]))
            else:
                nxt.append(layer[i])
        # sibling pass for proofs
        # Recompute proofs using current `layer` indices
        # But we need to track index per entry through layers; cleaner second-pass impl
        layer = nxt
    # Simpler: redo with sibling tracking
    layer2 = leaves[:]
    layers = [layer2]
    while len(layer2) > 1:
        nxt = []
        for i in range(0, len(layer2), 2):
            if i + 1 < len(layer2):
                nxt.append(pair_hash(layer2[i], layer2[i + 1]))
            else:
                nxt.append(layer2[i])
        layer2 = nxt
        layers.append(layer2)
    root = layers[-1][0]

    proof = []
    idx = target
    for ly in layers[:-1]:
        sib = idx + 1 if idx % 2 == 0 else idx - 1
        if sib < len(ly):
            proof.append(ly[sib])
        idx //= 2

    e = entries[target]
    print(f"word_id:        {target}")
    print(f"word:           {e['word']}")
    print(f"wordHash:       0x{keccak256(e['word'].encode()).hex()}")
    print(f"power:          {e['power']}")
    print(f"languageId:     {LANG_ID[e['language']]}")
    print(f"maxDurability:  {e['max_durability']}")
    print(f"element:        {ELEMENT_ID[e['element']]} ({e['element']})")
    print(f"leaf:           0x{leaves[target].hex()}")
    print(f"root:           0x{root.hex()}")
    print(f"proof[{len(proof)}]:")
    for p in proof:
        print(f"  0x{p.hex()}")

if __name__ == "__main__":
    main()
