#!/usr/bin/env python3
"""Compare a qerv_tb trace with an iss.py run: fetch sequence and stores must be identical
(store data compared on the enabled byte lanes only), and the program must halt with 0.

usage: compare.py <iss.json> <trace.log> <label>
"""
import json
import sys


def lanes(dat, sel):
    return dat & sum(0xFF << (8 * i) for i in range(4) if sel >> i & 1)


def main():
    iss = json.load(open(sys.argv[1]))
    label = sys.argv[3]
    pcs, stores, halt = [], [], None
    for line in open(sys.argv[2]):
        f = line.split()
        if f[0] == "I":
            pcs.append(int(f[1], 16))
        elif f[0] == "S":
            adr, dat, sel = int(f[1], 16), int(f[2], 16), int(f[3], 16)
            stores.append((adr, sel, lanes(dat, sel)))
    ref_pcs = [p for p, _ in iss["fetches"]]
    ref_st = [(a, s, lanes(d, s)) for a, s, d in iss["stores"]]
    errors = []
    for i, (r, p) in enumerate(zip(ref_pcs, pcs)):
        if r != p:
            errors.append(f"fetch #{i}: ISS {r:#010x} ({iss['fetches'][i][1]}) RTL {p:#010x}")
            break
    if len(ref_pcs) != len(pcs) and not errors:
        errors.append(f"fetch count: ISS {len(ref_pcs)} RTL {len(pcs)}")
    for i, (r, s) in enumerate(zip(ref_st, stores)):
        if r != s:
            errors.append("store #%d: ISS %08x/%x/%08x RTL %08x/%x/%08x" % ((i,) + r + s))
            break
    if len(ref_st) != len(stores) and not errors:
        errors.append(f"store count: ISS {len(ref_st)} RTL {len(stores)}")
    if iss["halt"] != 0:
        errors.append(f"ISS halted with {iss['halt']} (self-check failed or no halt)")
    if "HALT value=00000000" not in label:
        errors.append("RTL did not halt with 0")
    ok = not errors
    print(f"{'PASS' if ok else 'FAIL'} {label} | {len(pcs)} fetches, {len(stores)} stores")
    for e in errors:
        print("   ", e)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
