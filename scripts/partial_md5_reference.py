#!/usr/bin/env python3
"""Independent reference of KOReader util.partialMD5 (hashlib only).

Usage:
  partial_md5_reference.py FILE...        print "<hash>  <file>"
  partial_md5_reference.py --vectors      print Swift test vectors for deterministic files

NOTE: KOReader computes lshift(1024, 2*-1) with LuaJIT bit.lshift, which masks the shift
count to 5 bits: 1024 << 30 == 0 (mod 2^32). So the first sample is at offset 0, not 256.
"""
import hashlib
import sys

STEP = SIZE = 1024


def offsets():
    for i in range(-1, 11):
        shift = (2 * i) & 31  # LuaJIT bit.lshift masks the count to 5 bits (-2 -> 30)
        yield (STEP << shift) & 0xFFFFFFFF


def partial_md5_bytes(data: bytes) -> str:
    h = hashlib.md5()
    for off in offsets():
        sample = data[off:off + SIZE]
        if not sample:
            break
        h.update(sample)
    return h.hexdigest()


def partial_md5_file(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for off in offsets():
            f.seek(off)
            sample = f.read(SIZE)
            if not sample:
                break
            h.update(sample)
    return h.hexdigest()


def gen(n: int) -> bytes:
    """Deterministic pseudo-random bytes; MUST match `generate(count:)` in IdentityTests.swift
    (xorshift32 seeded 0x12345678, one byte per step = low byte of state >> 8)."""
    out = bytearray(n)
    s = 0x12345678
    for k in range(n):
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        out[k] = (s >> 8) & 0xFF
    return bytes(out)


SIZES = [0, 100, 255, 256, 1024, 1025, 5000, 70000, 1_048_576, 20_000_000]

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--vectors":
        for n in SIZES:
            print(f'        ({n}, "{partial_md5_bytes(gen(n))}"),')
    else:
        for p in sys.argv[1:]:
            print(f"{partial_md5_file(p)}  {p}")
