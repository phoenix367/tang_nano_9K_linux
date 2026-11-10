#!/usr/bin/env python3
"""Summarize a sim/soc cycle profile (PC_PROF=1 sim/soc/run.sh) by kernel function.

  python3 sim/soc/profile.py <soc_tag.pcprof> <System.map> [--mmu] [--top N]

The profile holds physical PCs. Kernel text is mapped back to virtual addresses with the
linear map (--mmu: VA = PA - 0x80000000 + 0xC0000000; without --mmu, VA = PA) and resolved
with System.map. PCs below 0x1000 are the boot ROM (stage 2: also the SBI shim); PCs in RAM
outside the kernel image are user space (no symbols: physical pages).
"""
import bisect
import sys


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    mmu = "--mmu" in sys.argv
    top = 40
    if "--top" in sys.argv:
        top = int(sys.argv[sys.argv.index("--top") + 1])
        args = [a for a in args if a != str(top)]
    syms = []
    for line in open(args[1]):
        f = line.split()
        if len(f) >= 3 and f[1] in "tTwW":
            syms.append((int(f[0], 16), f[2]))
    syms.sort()
    addrs = [a for a, _ in syms]
    text_end = max(a for a, n in syms if n in ("_etext", "etext")) if any(
        n in ("_etext", "etext") for _, n in syms) else addrs[-1]
    off = 0xC0000000 - 0x80000000 if mmu else 0

    by_func, total, fetches = {}, 0, 0
    for line in open(args[0]):
        pc, cyc, n = line.split()
        pc, cyc, n = int(pc, 16), int(cyc), int(n)
        total += cyc
        fetches += n
        va = pc + off if pc >= 0x80000000 else pc
        if pc < 0x1000:
            name = "[boot ROM / SBI shim]"
        elif addrs[0] <= va <= text_end:
            name = syms[bisect.bisect_right(addrs, va) - 1][1]
        elif pc >= 0x80000000:
            name = "[user space]"
        else:
            name = f"[other {pc:#x}]"
        c, k = by_func.get(name, (0, 0))
        by_func[name] = (c + cyc, k + n)
    print(f"{total / 1e6:.1f}M cycles, {fetches / 1e6:.2f}M instructions, CPI {total / fetches:.1f}")
    print(f"{'cycles%':>8} {'Mcycles':>8} {'Minstr':>7} {'CPI':>5}  function")
    for name, (c, k) in sorted(by_func.items(), key=lambda kv: -kv[1][0])[:top]:
        print(f"{100 * c / total:7.1f}% {c / 1e6:8.1f} {k / 1e6:7.2f} {c / max(k, 1):5.1f}  {name}")


if __name__ == "__main__":
    main()
