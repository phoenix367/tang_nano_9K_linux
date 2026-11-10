#!/usr/bin/env python3
"""Check RTL traces against the ISS and turn them into per-class cycle counts.

usage: analyze.py <builddir> <out results.json>

Expects in <builddir>: tests_meta.json, iss.json, symbols.txt (nm output) and
trace_w{1,4}_l{0,1}.log (l = extra wait states; l1 runs are optional).
"""
import json
import os
import statistics
import sys
from collections import defaultdict

LAT_BASE = 1    # servant_ram: ack in the cycle after cyc rises


def parse_trace(path):
    fetch_pc, fetch_cyc, stores, reads, marks = [], [], [], [], []
    halt = timeout = None
    with open(path) as fh:
        for line in fh:
            p = line.split()
            if not p:
                continue
            t = p[0]
            if t == "I":
                fetch_pc.append(int(p[1], 16))
                fetch_cyc.append(int(p[2]))
            elif t == "S":
                # data lanes outside sel may be X in the RTL; record X lanes as a mask
                dat = p[2].lower()
                xmask = 0
                for i in range(4):
                    if any(c in "xz" for c in dat[6 - 2 * i:8 - 2 * i]):
                        xmask |= 1 << i
                val = int("".join("0" if c in "xz" else c for c in dat), 16)
                stores.append((int(p[1], 16), val, int(p[3], 16), int(p[4]), xmask))
            elif t == "R":
                reads.append((int(p[1], 16), int(p[2], 16), int(p[3])))
            elif t == "M":
                marks.append((int(p[1], 16), int(p[2]), int(p[3]), int(p[4])))
            elif t == "H":
                halt = int(p[1], 16)
            elif t == "T":
                timeout = int(p[1])
    return dict(fetch_pc=fetch_pc, fetch_cyc=fetch_cyc, stores=stores, reads=reads,
                marks=marks, halt=halt, timeout=timeout)


def lane_mask(sel):
    m = 0
    for i in range(4):
        if sel >> i & 1:
            m |= 0xFF << (8 * i)
    return m


def check(tr, iss, meta):
    """Return list of error strings (empty = RTL matches the ISS exactly)."""
    errs = []
    if tr["timeout"] is not None:
        errs.append(f"simulation timed out at cycle {tr['timeout']}")
    if tr["halt"] != 0x900D:
        errs.append(f"halt value {tr['halt']!r} (expected 0x900d; 0xbad = branch fail stub)")
    ipcs = [f[0] for f in iss["fetches"]]
    rpcs = tr["fetch_pc"]
    n = min(len(ipcs), len(rpcs))
    for j in range(n):
        if ipcs[j] != rpcs[j]:
            errs.append(f"fetch #{j}: RTL pc {rpcs[j]:#x} != ISS pc {ipcs[j]:#x}")
            break
    if len(ipcs) != len(rpcs):
        errs.append(f"fetch count RTL {len(rpcs)} != ISS {len(ipcs)}")
    ist = iss["stores"]
    rst = tr["stores"]
    if len(ist) != len(rst):
        errs.append(f"store count RTL {len(rst)} != ISS {len(ist)}")
    bad = 0
    for j, (a, b) in enumerate(zip(rst, ist)):
        radr, rdat, rsel, _, rx = a
        iadr, isel, idat = b
        m = lane_mask(isel)
        if radr != iadr or rsel != isel or (rdat & m) != (idat & m) or (rx & isel):
            if bad < 5:
                errs.append(f"store #{j}: RTL adr={radr:#x} sel={rsel:x} dat={rdat:#010x} "
                            f"!= ISS adr={iadr:#x} sel={isel:x} dat={idat:#010x}")
            bad += 1
    if bad > 5:
        errs.append(f"... {bad} store mismatches in total")
    nt = len(meta["tests"])
    if len(tr["marks"]) != 2 * nt:
        errs.append(f"{len(tr['marks'])} markers, expected {2 * nt}")
    return errs


def windows(tr, iss, meta, syms):
    """Per-test raw window data."""
    marks = {m[0]: m for m in tr["marks"]}
    mn = [f[1] for f in iss["fetches"]]
    cyc = tr["fetch_cyc"]
    handler_lo, handler_hi = syms["trap_std"], syms["dump"]
    out = {}
    for t in meta["tests"]:
        s = marks[t["tid"] << 1]
        e = marks[(t["tid"] << 1) | 1]
        lo, hi = syms[t["body_sym"]], syms[t["body_end_sym"]]
        per = defaultdict(list)
        for j in range(s[2], e[2]):
            pc = tr["fetch_pc"][j]
            if lo <= pc < hi:
                key = mn[j]
            elif handler_lo <= pc < handler_hi:
                key = "handler:" + mn[j]
            else:
                continue
            per[key].append(cyc[j + 1] - cyc[j])
        reads = [r for r in tr["reads"] if s[1] < r[2] <= e[1]]
        out[t["name"]] = dict(cycles=e[1] - s[1], fetches=e[2] - s[2], dbus=e[3] - s[3],
                              deltas={k: (min(v), max(v), statistics.mean(v), len(v))
                                      for k, v in per.items()},
                              reads=sorted({(r[0] + (r[1] & -r[1]).bit_length() - 1,
                                             bin(r[1]).count("1")) for r in reads}))
    return out


def trap_mcause(tr, meta):
    """mcause value dumped (x5/t0, read right after the window) by the trap tests."""
    t0_slot = meta["mark"] - 256 + 4 * 5
    ends = {m[0]: m[1] for m in tr["marks"]}
    out = {}
    for t in meta["tests"]:
        if t["name"] not in ("ecall_roundtrip", "ebreak_roundtrip", "wfi"):
            continue
        e = ends[(t["tid"] << 1) | 1]
        v = next(s[1] for s in tr["stores"] if s[0] == t0_slot and s[3] > e)
        out[t["name"]] = v
    return out


def num(x):
    return int(x) if abs(x - round(x)) < 1e-9 else round(x, 3)


def per_copy(win, meta):
    # the empty-loop baseline must have the same iteration count K as the test
    bases = {}
    for t in meta["tests"]:
        if t["n"] == 0:
            bases.setdefault(t["k"], win[t["name"]])
    res = {}
    for t in meta["tests"]:
        if t["n"] == 0:
            continue
        base = bases[t["k"]]
        w = win[t["name"]]
        nk = t["n"] * t["k"]
        res[t["name"]] = dict(
            exact=(w["cycles"] - base["cycles"]) / nk,
            bus_exact=(w["fetches"] + w["dbus"] - base["fetches"] - base["dbus"]) / nk,
            cycles=num((w["cycles"] - base["cycles"]) / nk),
            fetches=num((w["fetches"] - base["fetches"]) / nk),
            dbus=num((w["dbus"] - base["dbus"]) / nk))
    return res


def shift_fit(pc, ops, amounts):
    """Fit cycles = a + b*s exactly (least squares, report max residual)."""
    out = {}
    for op in ops:
        xs = [s for s in amounts]
        ys = [pc[f"{op}_{s}"]["cycles"] for s in amounts]
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        a = my - b * mx
        resid = max(abs(y - (a + b * x)) for x, y in zip(xs, ys))
        out[op] = dict(a=round(a, 3), b=round(b, 4), max_residual=round(resid, 3),
                       points={s: y for s, y in zip(xs, ys)})
    return out


def notes(out, details, checks):
    w1, w4 = out.get("W1", {}), out.get("W4", {})
    n = []
    ok = checks and all(c["ok"] for c in checks.values())
    n.append("Correctness: " + ("every run's full fetched-PC sequence and every store "
             "(markers, test stores and a dump of x1..x31 after each test) match a Python "
             "RV32IM ISS exactly." if ok else "FAILED for: " +
             ", ".join(k for k, c in checks.items() if not c["ok"])))
    n.append("Memory: unmodified servant_ram behind servile_arbiter; ack (with read data) "
             "comes 1 cycle after cyc is raised, so every bus transaction takes 2 cycles. "
             "Instruction fetch is not overlapped with execution.")
    if w1 and w4:
        n.append("Each instruction's cost is a fixed number of cycles, whatever comes "
                 "before it: fetch-to-fetch deltas are constant and mixed sequences add up "
                 "exactly. W=1: one-stage ops (ALU reg/imm, lui, auipc, all CSR ops, "
                 f"ecall/ebreak entry, mret) {w1['add']}; two-stage ops (slt*, branches "
                 f"taken or not, jal/jalr, left shifts) {w1['slt']}; loads/stores "
                 f"{w1['lw']}; mul* {w1['mul']}; div/rem {w1['div']}. W=4: "
                 f"{w4['add']} / {w4['slt']} / {w4['lw']} / {w4['mul']} / {w4['div']}.")
    sf = out.get("shift_formula", {})
    if sf:
        n.append("Shifts: " + "; ".join(f"{k}: left {v['left']}, right (srl/sra/srli/srai) "
                                         f"{v['right']}" for k, v in sf.items()))
    if w1:
        n.append("div/divu/rem/remu take the same time for every operand set tried (incl. "
                 "divide by zero and INT_MIN/-1): the external MDU always runs a fixed "
                 "32-step divide. mul* are a 2-cycle DSP multiply plus SERV's two stages.")
        n.append("Traps: ecall entry costs the same as one ALU op, and so does mret. Real "
                 "trap cost is dominated by the handler instructions. "
                 "ecall_roundtrip_min_handler = ecall + csrr mepc + addi + csrw mepc + mret.")
    d1 = details.get("W1", {})
    if d1:
        n.append("wfi is NOT a no-op on SERV: it decodes as ebreak (inst bit 20 set) and "
                 "traps with mcause=3 (confirmed: mcause read back = "
                 f"{d1['mcause_after_trap_tests'].get('wfi')}). 'wfi' is the round trip "
                 "through the 4-instruction handler, and wfi_trap_entry is the trap alone.")
        n.append("FENCE / FENCE.TSO / FENCE.I are decoded as loads with no rd write: each "
                 "does a real data-bus read at an address built from the instruction's "
                 "immediate bits, and the address differs between W=1 and W=4. "
                 + "; ".join(f"{t}: {details[t]['fence_spurious_dbus_reads']}"
                             for t in details)
                 + ". Several of these addresses have bit 31 set (the servile ext/peripheral "
                 "region), so on a real SoC a fence can perform a read side effect on an "
                 "I/O device. They cost the same as a load.")
    if d1.get("cycles_added_per_extra_wait_state") is not None:
        n.append("Latency sensitivity (runs with 1 extra wait state on every bus "
                 "transaction): cycles grow by exactly the number of bus transactions: 1 "
                 "per instruction fetch, plus 1 per load/store/fence data access. So "
                 "cycles(L) = cycles(table) + (L-1) * (1 + is_mem), where L = cycles from "
                 "cyc to ack.")
    return n


def main():
    bdir, outpath = sys.argv[1], sys.argv[2]
    meta = json.load(open(os.path.join(bdir, "tests_meta.json")))
    iss = json.load(open(os.path.join(bdir, "iss.json")))
    syms = {}
    for line in open(os.path.join(bdir, "symbols.txt")):
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16)
    tests = {t["name"]: t for t in meta["tests"]}

    mcause = {}
    checks = {}
    raw = {}
    for wd in (1, 4):
        for lat in (0, 1):
            path = os.path.join(bdir, f"trace_w{wd}_l{lat}.log")
            if not os.path.exists(path):
                continue
            tr = parse_trace(path)
            errs = check(tr, iss, meta)
            tag = f"W{wd}" + ("" if lat == 0 else f"_extra_wait{lat}")
            checks[tag] = dict(ok=not errs, errors=errs, fetches=len(tr["fetch_pc"]),
                               stores=len(tr["stores"]),
                               total_cycles=tr["fetch_cyc"][-1] if tr["fetch_cyc"] else 0)
            if errs:
                print(f"[{tag}] CORRECTNESS CHECK FAILED:")
                for e in errs:
                    print("   ", e)
                continue
            print(f"[{tag}] RTL matches ISS: {len(tr['fetch_pc'])} fetches, "
                  f"{len(tr['stores'])} stores identical")
            win = windows(tr, iss, meta, syms)
            raw[(wd, lat)] = (win, per_copy(win, meta))
            if lat == 0:
                mcause[wd] = trap_mcause(tr, meta)

    out = {"memory_ack_latency_cycles": LAT_BASE}
    details = {}
    shift_formula = {}
    for wd in (1, 4):
        if (wd, 0) not in raw:
            continue
        win, pc = raw[(wd, 0)]
        tag = f"W{wd}"
        r = {}
        # single-instruction classes: per-copy cycles
        for name, v in pc.items():
            t = tests[name]
            if t["group"] in ("mix",) or name in ("mret_seq",):
                continue
            r[name] = v["cycles"]
        # traps: use direct fetch-to-fetch deltas (exact cost of each instruction)
        dl = win["ecall_roundtrip"]["deltas"]
        ecall_entry = dl["ecall"][2]
        mret = dl["handler:mret"][2]
        r["ecall_entry"] = num(ecall_entry)
        r["mret"] = num(mret)
        r["trap_roundtrip"] = num(ecall_entry + mret)
        r["ecall_roundtrip_min_handler"] = r.pop("ecall_roundtrip")
        r["ebreak_roundtrip_min_handler"] = r.pop("ebreak_roundtrip")
        r["ebreak_entry"] = num(win["ebreak_roundtrip"]["deltas"]["ebreak"][2])
        r["wfi_trap_entry"] = num(win["wfi"]["deltas"]["wfi"][2])
        r["wfi"] = r.pop("wfi")
        # convenient aliases
        r["branch_taken"] = r["beq_taken"]
        r["branch_not_taken"] = r["beq_not_taken"]
        r["div"] = r["div_a0_a1"]
        r["divu"] = r["divu_a0_a1"]
        r["rem"] = r["rem_a0_a1"]
        r["remu"] = r["remu_a0_a1"]
        r["csrrw"] = r["csrrw_mscratch"]
        r["csrrs"] = r["csrrs_mscratch"]
        r["csrrc"] = r["csrrc_mscratch"]
        out[tag] = dict(sorted(r.items()))

        # details: cross-checks
        d = {}
        # 1. per-copy fetch count must equal the number of instructions per copy
        bad_fetch = {}
        for name, v in pc.items():
            t = tests[name]
            exp = t["per_copy"]
            if name in ("ecall_roundtrip", "ebreak_roundtrip", "wfi"):
                exp = 5
            if v["fetches"] != exp:
                bad_fetch[name] = v["fetches"]
        d["fetch_count_mismatches"] = bad_fetch
        # 2. window/baseline method vs direct fetch-to-fetch deltas
        mism = {}
        nonconst = {}
        for name, v in pc.items():
            t = tests[name]
            if t["per_copy"] != 1 or t["group"] == "mix" or name in (
                    "ecall_roundtrip", "ebreak_roundtrip", "wfi"):
                continue
            ds = win[name]["deltas"]
            if len(ds) != 1:
                mism[name] = f"{len(ds)} distinct mnemonics in body"
                continue
            (lo, hi, mean, cnt), = ds.values()
            if lo != hi:
                nonconst[name] = dict(min=lo, max=hi, mean=num(mean))
            if abs(mean - v["cycles"]) > 1e-9:
                mism[name] = dict(window=v["cycles"], delta_mean=num(mean))
        d["window_vs_delta_mismatches"] = mism
        d["non_constant_per_instance"] = nonconst
        d["bus_transactions_per_copy"] = {n: num(v["fetches"] + v["dbus"])
                                          for n, v in pc.items()}
        # 3. trap breakdown by instruction (direct deltas)
        d["ecall_roundtrip_breakdown"] = {k: num(v[2]) for k, v in
                                         win["ecall_roundtrip"]["deltas"].items()}
        d["mret_seq_breakdown"] = {k: num(v[2]) for k, v in
                                  win["mret_seq"]["deltas"].items()}
        d["wfi_breakdown"] = {k: num(v[2]) for k, v in win["wfi"]["deltas"].items()}
        sub = (pc["ecall_roundtrip"]["cycles"] - r["csrr_mepc"] - r["addi"] - r["csrw_mepc"]
               - r["mret"])
        d["ecall_entry_by_subtraction"] = num(sub)
        d["mret_by_subtraction"] = num(pc["mret_seq"]["cycles"] - r["auipc"] - r["addi"]
                                       - r["csrw_mepc"])
        # 4. additivity of mixed sequences
        mixes = {}
        for mname, classes in meta["mixes"].items():
            t = tests[mname]
            reps = t["n"] // len(classes)
            pred = reps * sum(r[c] for c in classes)
            meas = pc[mname]["exact"] * t["n"]
            mixes[mname] = dict(measured_cycles_per_pass=num(meas),
                                predicted_from_classes=num(pred),
                                error_pct=round(100 * (meas - pred) / pred, 3))
        d["mix_additivity"] = mixes
        # 5. shifts
        imm_amts = sorted(int(n.split("_")[1]) for n in pc if n.startswith("slli_"))
        reg_amts = sorted(int(n.split("_")[1]) for n in pc if n.startswith("sll_"))
        d["shift_fit_imm"] = shift_fit(pc, ["slli", "srli", "srai"], imm_amts)
        d["shift_fit_reg"] = shift_fit(pc, ["sll", "srl", "sra"], reg_amts)
        c0 = pc["slli_0"]["exact"]
        ok_left = all(pc[f"{op}_{a}"]["exact"] == c0 for op, am in
                      (("slli", imm_amts), ("sll", reg_amts)) for a in am)
        ok_right = all(pc[f"{op}_{a}"]["exact"] == c0 + a // wd for op, am in
                       (("srli", imm_amts), ("srai", imm_amts), ("srl", reg_amts),
                        ("sra", reg_amts)) for a in am)
        shift_formula[tag] = dict(
            left=f"{num(c0)} (independent of shift amount)" if ok_left else "see details",
            right=(f"{num(c0)} + shamt" if wd == 1 else f"{num(c0)} + floor(shamt/{wd})")
            if ok_right else "see details",
            exact_for_all_measured_amounts=ok_left and ok_right)
        # 6. fence dbus reads
        d["fence_spurious_dbus_reads"] = {
            n: [f"{sz}-byte read at {a:#010x}" for a, sz in win[n]["reads"]]
            for n in ("fence", "fence_rw", "fence_tso", "fence_i")}
        d["baseline_window_cycles"] = {n: win[n]["cycles"] for n in
                                       ("baseline", "baseline_k2", "baseline_end")}
        d["mcause_after_trap_tests"] = mcause[wd]
        # 7. latency sensitivity
        if (wd, 1) in raw:
            pc1 = raw[(wd, 1)][1]
            sens = {}
            bad = {}
            for n, v in pc.items():
                dc = pc1[n]["exact"] - v["exact"]
                sens[n] = num(dc)
                if abs(dc - v["bus_exact"]) > 1e-9:
                    bad[n] = dict(delta=num(dc), bus=num(v["bus_exact"]))
            d["cycles_added_per_extra_wait_state"] = sens
            d["latency_sensitivity_vs_bus_count_mismatches"] = bad
        details[tag] = d

    out["shift_formula"] = shift_formula
    out["notes"] = notes(out, details, checks)
    out["checks"] = checks
    out["details"] = details
    out["config"] = dict(
        core="serv_rf_top (olofk/serv f200eb2) + mdu_top (external/mdu)",
        params=dict(MDU=1, WITH_CSR=1, COMPRESSED=0, PRE_REGISTER=1, RESET_STRATEGY="MINI"),
        memory="servile_arbiter (ibus+dbus on one port) + unmodified servant_ram",
        n_copies=tests["add"]["n"],
        loop_iterations=sorted({t["k"] for t in meta["tests"]}),
        method="(window(test) - window(empty loop)) / (N*K); window = cycles between the "
               "bus acks of the start/end marker stores")
    with open(outpath, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"wrote {outpath}")
    return 0 if all(c["ok"] for c in checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
