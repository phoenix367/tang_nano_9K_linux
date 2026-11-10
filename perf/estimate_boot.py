#!/usr/bin/env python3
"""Estimate Linux boot time on SERV/QERV from a boot trace and measured cycle costs.

    python3 perf/estimate_boot.py perf/boot_trace/results/<run>.json [more runs...]
        [--cpi perf/serv_cpi/results.json] [--mhz 27 50] [--t0-ns 200 300 450]
        [--icache 8192:32:1] [--dcache 8192:32:1] [--ucache 16384:32:1]

Model (all assumptions are printed with the result):
  core cycles   = sum over instruction classes of count x cycles(class), with cycles from
                  perf/serv_cpi (ideal memory: every fetch/load/store hits, at the
                  servant_ram ack latency). Shift cost is interpolated from the measured
                  shift amounts using the trace's shift-amount histogram.
  miss cycles   = (I-misses + D-misses + D-writebacks) x line-fill time, where
                  line fill = t0 + line_bytes / 270 MB/s (Gowin PSRAM HS IP, x8 DDR at
                  135 MHz). t0 = command + initial latency + IP/CDC overhead, swept.
  traps         = interrupt entries cost one ecall each (ecall/mret themselves are counted
                  as instructions).
  hit latency   = --wait extra cycles per bus transaction (BSRAM cache with registered tag
                  compare ~ 1), on top of servant_ram's 1-cycle ack.
  MMIO          = one load/store plus MMIO_EXTRA cycles each.
  A extension   = SERV has none. LR = lw, SC = sw, AMO = lw + add + sw (what a
                  read-modify-write in the serial datapath would at least cost).
  idle          = WFI time from the trace, added as wall time.
"""
import argparse
import json
import sys

MMIO_EXTRA = 8
PSRAM_BYTES_PER_NS = 0.270  # 270 MB/s

# trace class -> cpi key (when the names differ) or a list of keys summed
ALIASES = {
    "lr": ["lw"],
    "sc": ["sw"],
    "amo": ["lw", "add", "sw"],
    "fence_i": ["fence_i", "fence"],
    "system_other": ["csrrw"],
    "csr": ["csrrs", "csrrw"],
    "illegal": ["ecall_entry"],
    "ecall": ["ecall_entry"],
    "ebreak": ["ebreak_entry"],
}
SHIFT_CLASSES = ["slli", "srli", "srai", "sll", "srl", "sra"]


def load(path):
    with open(path) as f:
        return json.load(f)


def cpi_lookup(cpi, key):
    v = cpi.get(key)
    return float(v) if isinstance(v, (int, float)) else None


def class_cycles(cpi, cls):
    v = cpi_lookup(cpi, cls)
    if v is not None:
        return v, None
    alt = ALIASES.get(cls)
    if alt:
        if cls in ("amo",):
            parts = [cpi_lookup(cpi, a) for a in alt]
            if None not in parts:
                return sum(parts), f"{cls} modelled as {'+'.join(alt)}"
        else:
            for a in alt:
                v = cpi_lookup(cpi, a)
                if v is not None:
                    return v, f"{cls} modelled as {a}"
    return None, f"no cycle cost for {cls}"


def shift_cycles(cpi, cls, amount):
    """Interpolate the measured cost of shift class `cls` at `amount`."""
    pts = {}
    for k, v in cpi.items():
        if k.startswith(cls + "_") and isinstance(v, (int, float)):
            try:
                pts[int(k.split("_")[-1])] = float(v)
            except ValueError:
                pass
    if not pts:
        return None
    xs = sorted(pts)
    if amount <= xs[0]:
        return pts[xs[0]]
    if amount >= xs[-1]:
        return pts[xs[-1]]
    for a, b in zip(xs, xs[1:]):
        if a <= amount <= b:
            return pts[a] + (pts[b] - pts[a]) * (amount - a) / (b - a)
    return None


def pick_cache(trace, side, spec):
    size, line, ways = (int(x) for x in spec.split(":"))
    for c in trace["caches"]:
        if c["side"] == side and c["size"] == size and c["line"] == line and c["ways"] == ways:
            return c
    sys.exit(f"cache {side} {spec} not in trace")


def estimate(trace, cpi, mhz, t0_ns, icache, dcache, wait, ucache=None):
    notes = set()
    core = 0.0
    for cls, n in trace["classes"].items():
        if not n:
            continue
        if cls in SHIFT_CLASSES:
            hist = trace["shift_amounts"][cls]
            cyc = 0.0
            for amt, cnt in enumerate(hist):
                c = shift_cycles(cpi, cls, amt)
                if c is None:
                    c, note = class_cycles(cpi, cls)
                    if c is None:
                        sys.exit(note)
                cyc += cnt * c
            core += cyc
            continue
        c, note = class_cycles(cpi, cls)
        if note:
            notes.add(note)
        if c is None:
            sys.exit(f"{note} (count {n})")
        core += n * c
    interrupts = max(0, trace["trap_entries"] - trace["exceptions"])
    core += interrupts * class_cycles(cpi, "ecall")[0]
    # Cache-hit latency above servant_ram's 1 cycle: +1 cycle per extra wait state on every
    # bus transaction (one fetch per instruction, plus the data access), per perf/serv_cpi.
    c = trace["classes"]
    mem_ops = sum(c[k] for k in ("lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw", "fence",
                                 "fence_i", "lr", "sc")) + 2 * c["amo"]
    core += wait * (trace["instret"] + mem_ops)
    lw, sw = cpi_lookup(cpi, "lw"), cpi_lookup(cpi, "sw")
    core += trace["mmio_loads"] * (lw + MMIO_EXTRA) + trace["mmio_stores"] * (sw + MMIO_EXTRA)

    if ucache:
        uc = pick_cache(trace, "U", ucache)
        miss_ns = (uc["misses"] + uc["writebacks"]) * (t0_ns + uc["line"] / PSRAM_BYTES_PER_NS)
    else:
        ic, dc = pick_cache(trace, "I", icache), pick_cache(trace, "D", dcache)
        fill = {side: t0_ns + c["line"] / PSRAM_BYTES_PER_NS for side, c in (("I", ic), ("D", dc))}
        miss_ns = ic["misses"] * fill["I"] + (dc["misses"] + dc["writebacks"]) * fill["D"]
    core_s = core / (mhz * 1e6)
    miss_s = miss_ns * 1e-9
    idle_s = trace["idle_us"] * 1e-6
    total = core_s + miss_s + idle_s
    return {
        "cpi_ideal": core / trace["instret"],
        "core_s": core_s, "miss_s": miss_s, "idle_s": idle_s, "total_s": total,
        "us_per_instr": total * 1e6 / trace["instret"],
        "notes": sorted(notes),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--cpi", default="perf/serv_cpi/results.json")
    ap.add_argument("--mhz", type=float, nargs="+", default=[27.0, 50.0])
    ap.add_argument("--t0-ns", type=float, nargs="+", default=[200.0, 300.0, 450.0])
    ap.add_argument("--icache", default="8192:32:1")
    ap.add_argument("--dcache", default="8192:32:1")
    ap.add_argument("--ucache", default=None,
                    help="use one unified cache (size:line:ways) instead of --icache/--dcache")
    ap.add_argument("--wait", type=int, default=1,
                    help="cache-hit wait states beyond servant_ram's 1-cycle ack (default 1)")
    a = ap.parse_args()

    cpis = load(a.cpi)
    widths = [k for k in cpis if k.startswith("W") and isinstance(cpis[k], dict)]
    caches = f"unified {a.ucache}" if a.ucache else f"I$ {a.icache}, D$ {a.dcache}"
    print(f"{caches} (size:line:ways), {a.wait} extra hit wait state(s); "
          f"PSRAM line fill = t0 + line/270MB/s")
    for path in a.traces:
        tr = load(path)
        print(f"\n{path}: {tr['instret'] / 1e6:.1f}M instructions to '{tr['end_reason']}', "
              f"idle {tr['idle_us'] / 1e6:.2f} s, traced at {tr['us_per_instr']} us/instr")
        print(f"  {'core':4} {'MHz':>5} {'t0 ns':>6} {'CPI(hit)':>8} {'core s':>7} {'miss s':>7} "
              f"{'total s':>8} {'us/instr':>8}")
        all_notes = set()
        for w in widths:
            for mhz in a.mhz:
                for t0 in a.t0_ns:
                    r = estimate(tr, cpis[w], mhz, t0, a.icache, a.dcache, a.wait, a.ucache)
                    all_notes.update(r["notes"])
                    print(f"  {w:4} {mhz:5.0f} {t0:6.0f} {r['cpi_ideal']:8.1f} {r['core_s']:7.1f} "
                          f"{r['miss_s']:7.1f} {r['total_s']:8.1f} {r['us_per_instr']:8.2f}")
        for n in sorted(all_notes):
            print(f"  note: {n}")


if __name__ == "__main__":
    main()
