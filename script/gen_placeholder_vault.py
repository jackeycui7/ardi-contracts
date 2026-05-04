#!/usr/bin/env python3
"""
Generate a small placeholder vault JSON + Merkle root for v3 dry-run.

Output:
  - placeholder_vault.json   (riddle entries, server-readable format)
  - placeholder_root.txt     (0x-prefixed Merkle root, paste into env)

Each entry has the v3 fields:
  id, word, language, riddle, power, rarity, max_durability, element

Element is one of: metal/wood/water/fire/earth (matches vault.rs::element_id).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

LANGS = ["en"]
ELEMENTS = ["metal", "wood", "water", "fire", "earth"]
ELEMENT_ID = {"metal": 1, "wood": 2, "water": 3, "fire": 4, "earth": 5}
LANG_ID = {"en": 0, "zh": 1, "ja": 2, "ko": 3, "fr": 4, "de": 5}

# ~100 simple english test words
WORDS = (
    "fire water earth metal wood stone river tree leaf rock sand cloud rain "
    "snow wind dust mud lake hill cave moon star sun sky dawn dusk frost "
    "flame ash iron gold silver coal pearl shell coral reef wave tide ocean "
    "valley peak ridge plain desert forest meadow grove orchard field farm "
    "wheat corn rice grain herb spice salt sugar honey wax milk bread egg "
    "fish bird wolf bear deer fox owl hawk eagle dove crow horse cow goat "
    "sheep pig dog cat lion tiger snake frog bee ant bug worm leaf root "
    "branch trunk seed bloom petal thorn"
).split()


def keccak256(data: bytes) -> bytes:
    """Solidity-compatible keccak256."""
    try:
        from Crypto.Hash import keccak
        h = keccak.new(digest_bits=256)
        h.update(data)
        return h.digest()
    except ImportError:
        # Fallback: use eth_hash if available
        try:
            from eth_hash.auto import keccak as ek
            return ek(data)
        except ImportError:
            raise SystemExit(
                "Need pycryptodome (`pip install pycryptodome`) or eth-hash"
            )


def vault_leaf(word_id: int, word: str, power: int, lang_id: int,
               max_dur: int, element: int) -> bytes:
    """Match coord-rs/ardi-core/src/vault.rs::vault_leaf and contract leaf."""
    buf = b""
    buf += word_id.to_bytes(32, "big")
    buf += keccak256(word.encode("utf-8"))
    buf += power.to_bytes(2, "big")
    buf += bytes([lang_id])
    buf += bytes([max_dur])
    buf += bytes([element])
    return keccak256(buf)


def pair_hash(a: bytes, b: bytes) -> bytes:
    """OZ MerkleProof: sort each pair lex."""
    lo, hi = (a, b) if a <= b else (b, a)
    return keccak256(lo + hi)


def build_root(leaves: list[bytes]) -> bytes:
    if not leaves:
        return b"\x00" * 32
    layer = leaves[:]
    while len(layer) > 1:
        nxt = []
        for i in range(0, len(layer), 2):
            if i + 1 < len(layer):
                nxt.append(pair_hash(layer[i], layer[i + 1]))
            else:
                nxt.append(layer[i])
        layer = nxt
    return layer[0]


def weighted_durability(rng: random.Random) -> int:
    """1..14 weighted toward low values (mean ~5), matching plan §3."""
    # Sample from a discrete dist that approximates the plan's "mean ~5" curve.
    weights = [3, 3, 4, 4, 5, 5, 4, 3, 2, 2, 1, 1, 1, 1]  # for 1..14
    r = rng.choices(range(1, 15), weights=weights, k=1)[0]
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100, help="number of words")
    ap.add_argument("--out", type=Path, default=Path("placeholder_vault.json"))
    ap.add_argument("--root-out", type=Path, default=Path("placeholder_root.txt"))
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    words_pool = WORDS[:]
    if args.n > len(words_pool):
        # Pad by suffixing index
        words_pool += [f"word{i}" for i in range(len(words_pool), args.n)]
    chosen = words_pool[: args.n]

    entries = []
    leaves = []
    for i, w in enumerate(chosen):
        lang = "en"
        power = rng.randint(1, 100)
        max_dur = weighted_durability(rng)
        elem = rng.choice(ELEMENTS)
        rarity = "common" if power < 60 else ("rare" if power < 90 else "legendary")
        entries.append({
            "id": i,
            "word": w,
            "language": lang,
            "riddle": f"placeholder riddle for word {i}",
            "power": power,
            "rarity": rarity,
            "max_durability": max_dur,
            "element": elem,
        })
        leaves.append(vault_leaf(
            word_id=i,
            word=w,
            power=power,
            lang_id=LANG_ID[lang],
            max_dur=max_dur,
            element=ELEMENT_ID[elem],
        ))

    root = build_root(leaves)

    args.out.write_text(json.dumps(entries, indent=2, ensure_ascii=False))
    args.root_out.write_text("0x" + root.hex() + "\n")

    print(f"wrote {len(entries)} entries to {args.out}")
    print(f"vault Merkle root: 0x{root.hex()}")
    print(f"  → {args.root_out}")


if __name__ == "__main__":
    main()
