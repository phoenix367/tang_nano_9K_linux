#!/usr/bin/env python3
"""Attribute a boot_trace PC histogram (-P) to kernel functions.

    python3 perf/boot_trace/profile.py results/tang9k_m8_u0.3.hist \
        [--map /mnt/data/build/tang9k_linux/br-tang9k/build/linux-6.18.7/System.map] [-n 40]

Kernel text is resolved through System.map. Executed addresses outside kernel text are user
programs (binfmt_flat loads them at runtime-chosen addresses), summed as "<user>".
"""
import argparse
import bisect
import os
from collections import Counter

DEFAULT_MAP = os.path.join(os.environ.get("WORK", "/mnt/data/build/tang9k_linux"),
                           "br-tang9k/build/linux-6.18.7/System.map")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hist")
    ap.add_argument("--map", default=DEFAULT_MAP)
    ap.add_argument("-n", type=int, default=40)
    a = ap.parse_args()

    syms, marks = [], {}
    for line in open(a.map):
        addr, typ, name = line.split()[:3]
        marks[name] = int(addr, 16)
        if typ in "tTwW":
            syms.append((int(addr, 16), name))
    syms.sort()
    addrs = [s[0] for s in syms]
    # Kernel code = [first text symbol, end of init text); everything else executed is user.
    text_lo = addrs[0]
    text_hi = max(marks.get("_etext", 0), marks.get("_einittext", 0)) or addrs[-1] + 4096

    per_fn, total = Counter(), 0
    for line in open(a.hist):
        pc_s, cnt_s = line.split()
        pc, cnt = int(pc_s, 16), int(cnt_s)
        total += cnt
        if text_lo <= pc < text_hi:
            i = bisect.bisect_right(addrs, pc) - 1
            per_fn[syms[i][1] if i >= 0 else "<?>"] += cnt
        else:
            per_fn["<user>"] += cnt

    print(f"{total / 1e6:.1f}M instructions")
    print(f"{'M instr':>8} {'%':>6}  function")
    for name, cnt in per_fn.most_common(a.n):
        print(f"{cnt / 1e6:8.2f} {100 * cnt / total:6.2f}  {name}")


if __name__ == "__main__":
    main()
