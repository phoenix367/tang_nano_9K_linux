#!/usr/bin/env python3
"""Generate the SERV CPI micro-benchmark program.

Every test runs N copies of the instruction under test inside a loop executed K times.
The window is bracketed by two stores to MARK (gp); the testbench timestamps their bus
acks. A baseline test (N = 0, same K) gives the loop + marker overhead, so

    cycles per copy = (window(test) - window(baseline with the same K)) / (N * K)

After each window all GPRs are dumped (stores) so the testbench trace can be checked
against the reference ISS (iss.py) store-by-store and fetch-by-fetch.

Outputs (in OUTDIR): serv_cpi_tests.S and tests_meta.json.
"""
import json
import os
import sys

MARK = 0x3FFF0           # timing markers; HALT is MARK + 4; register dump at MARK - 256
STORE_AREA = 0x31000
N_DEFAULT = 64
K_DEFAULT = 4

DST = ["t0", "t1", "t2", "t3", "t4", "t5"]


def d(i):
    """Rotating destination register."""
    return DST[i % len(DST)]


# Default operand values loaded before every test (outside the timed window).
DEFAULT_REGS = [
    ("a0", 0x87654321), ("a1", 0x12345678), ("a2", 0), ("a3", 0x01010101),
    ("a4", 8), ("a5", 11),
]
ZERO_REGS = ["ra", "sp", "t0", "t1", "t2", "t3", "t4", "t5", "s1", "s2"]

tests = []


def T(name, body, setup=(), post=(), n=N_DEFAULT, k=K_DEFAULT, group="", per_copy=1,
      note=""):
    tests.append(dict(name=name, body=body, setup=list(setup), post=list(post), n=n, k=k,
                      group=group, per_copy=per_copy, note=note))


def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


# ----------------------------------------------------------------------------- baseline
T("baseline", lambda i, L: [], n=0, group="baseline")
T("baseline_k2", lambda i, L: [], n=0, k=2, group="baseline")

# ----------------------------------------------------------------------------- integer ALU
T("add", lambda i, L: ["add a2, a2, a3"], group="alu")
T("sub", lambda i, L: ["sub a2, a2, a3"], group="alu")
T("addi", lambda i, L: ["addi a2, a2, 291"], group="alu")
T("and", lambda i, L: [f"and {d(i)}, a0, a1"], group="alu")
T("or", lambda i, L: [f"or {d(i)}, a0, a1"], group="alu")
T("xor", lambda i, L: [f"xor {d(i)}, a0, a1"], group="alu")
T("andi", lambda i, L: [f"andi {d(i)}, a0, {0x5a5 - i}"], group="alu")
T("ori", lambda i, L: [f"ori {d(i)}, a0, {0x5a5 - i}"], group="alu")
T("xori", lambda i, L: [f"xori {d(i)}, a0, {0x5a5 - i}"], group="alu")
T("slt", lambda i, L: [f"slt {d(i)}, a0, a1"], group="alu")
T("sltu", lambda i, L: [f"sltu {d(i)}, a0, a1"], group="alu")
T("slti", lambda i, L: [f"slti {d(i)}, a0, {i - 32}"], group="alu")
T("sltiu", lambda i, L: [f"sltiu {d(i)}, a1, {i - 32}"], group="alu")
T("lui", lambda i, L: [f"lui {d(i)}, {(0x12345 + 0x111 * i) & 0xFFFFF}"], group="alu")
T("auipc", lambda i, L: [f"auipc {d(i)}, {i}"], group="alu")

# ----------------------------------------------------------------------------- shifts
SH_IMM = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 15, 16, 24, 31]
SH_REG = [0, 1, 2, 4, 8, 16, 31]
for op in ["slli", "srli", "srai"]:
    for s in SH_IMM:
        T(f"{op}_{s}", (lambda op, s: lambda i, L: [f"{op} {d(i)}, a0, {s}"])(op, s),
          group="shift")
for op in ["sll", "srl", "sra"]:
    for s in SH_REG:
        T(f"{op}_{s}", (lambda op: lambda i, L: [f"{op} {d(i)}, a0, a1"])(op),
          setup=[f"li a1, {s}"], group="shift")

# ----------------------------------------------------------------------------- branches
BR_SETUP = ["li a0, 5", "li a1, 7", "li a2, 5"]
for op, a, b in [("beq", "a0", "a2"), ("bne", "a0", "a1"), ("blt", "a0", "a1"),
                 ("bge", "a1", "a0"), ("bltu", "a0", "a1"), ("bgeu", "a1", "a0")]:
    # taken: every copy branches to the next instruction
    T(f"{op}_taken",
      (lambda op, a, b: lambda i, L: [f"{op} {a}, {b}, {L(f'n{i}')}", f"{L(f'n{i}')}:"])(op, a, b),
      setup=BR_SETUP, group="branch")
for op, a, b in [("beq", "a0", "a1"), ("bne", "a0", "a2"), ("blt", "a1", "a0"),
                 ("bge", "a0", "a1"), ("bltu", "a1", "a0"), ("bgeu", "a0", "a1")]:
    # not taken: target is the per-test fail stub
    T(f"{op}_not_taken",
      (lambda op, a, b: lambda i, L: [f"{op} {a}, {b}, {L('fail')}"])(op, a, b),
      setup=BR_SETUP, group="branch")
T("jal", lambda i, L: [f"jal ra, {L(f'n{i}')}", f"{L(f'n{i}')}:"], group="jump")
T("jal_x0", lambda i, L: [f"jal zero, {L(f'n{i}')}", f"{L(f'n{i}')}:"], group="jump",
  note="j (no link)")
T("jalr", lambda i, L: [f"jalr ra, {4 * (i + 1)}(s1)"],
  setup=["la s1, {body}"], group="jump", note="jalr ra, off(rs1): call through register")
T("jalr_x0", lambda i, L: [f"jalr zero, {4 * (i + 1)}(s1)"],
  setup=["la s1, {body}"], group="jump", note="jr / ret form")

# ----------------------------------------------------------------------------- loads/stores
LD_SETUP = ["la s1, load_data"]
T("lw", lambda i, L: [f"lw {d(i)}, {4 * i}(s1)"], setup=LD_SETUP, group="load")
T("lh", lambda i, L: [f"lh {d(i)}, {2 * i}(s1)"], setup=LD_SETUP, group="load",
  note="byte offsets 0/2 alternate")
T("lhu", lambda i, L: [f"lhu {d(i)}, {2 * i}(s1)"], setup=LD_SETUP, group="load")
T("lb", lambda i, L: [f"lb {d(i)}, {i}(s1)"], setup=LD_SETUP, group="load",
  note="byte offsets 0..3 cycle")
T("lbu", lambda i, L: [f"lbu {d(i)}, {i}(s1)"], setup=LD_SETUP, group="load")
T("lb_off3", lambda i, L: [f"lb {d(i)}, {4 * i + 3}(s1)"], setup=LD_SETUP, group="load")
T("lh_off2", lambda i, L: [f"lh {d(i)}, {4 * i + 2}(s1)"], setup=LD_SETUP, group="load")
ST_SETUP = [f"li s1, {STORE_AREA}"]
T("sw", lambda i, L: [f"sw a0, {4 * i}(s1)"], setup=ST_SETUP, group="store")
T("sh", lambda i, L: [f"sh a0, {2 * i}(s1)"], setup=ST_SETUP, group="store")
T("sb", lambda i, L: [f"sb a0, {i}(s1)"], setup=ST_SETUP, group="store")

# ----------------------------------------------------------------------------- M extension
for op in ["mul", "mulh", "mulhu", "mulhsu"]:
    T(op, (lambda op: lambda i, L: [f"{op} {d(i)}, a0, a1"])(op), group="mdu")
T("mul_small", lambda i, L: [f"mul {d(i)}, a0, a1"], setup=["li a0, 3", "li a1, 5"],
  group="mdu", note="mul with tiny operands")
DIV_SETS = [
    ("big_small", 1000000007, 13),
    ("small_big", 13, 1000000007),
    ("neg_pos", -1000000007, 13),
    ("neg_neg", -1000000007, -13),
    ("by_zero", 12345, 0),
    ("overflow", -0x80000000, -1),
    ("zero_dividend", 0, 7),
    ("max_by_1", -1, 1),
    ("a0_a1", 0x87654321, 0x12345678),
]
for op in ["div", "divu", "rem", "remu"]:
    for sname, x, y in DIV_SETS:
        T(f"{op}_{sname}", (lambda op: lambda i, L: [f"{op} {d(i)}, a0, a1"])(op),
          setup=[f"li a0, {s32(x)}", f"li a1, {s32(y)}"], k=2, group="mdu")

# ----------------------------------------------------------------------------- CSRs
T("csrrw_mscratch", lambda i, L: [f"csrrw {d(i)}, mscratch, a0"], group="csr")
T("csrrs_mscratch", lambda i, L: [f"csrrs {d(i)}, mscratch, a1"], group="csr")
T("csrrc_mscratch", lambda i, L: [f"csrrc {d(i)}, mscratch, a1"], group="csr")
T("csrrwi_mscratch", lambda i, L: [f"csrrwi {d(i)}, mscratch, {i % 32}"], group="csr")
T("csrrsi_mscratch", lambda i, L: [f"csrrsi {d(i)}, mscratch, {i % 32}"], group="csr")
T("csrrci_mscratch", lambda i, L: [f"csrrci {d(i)}, mscratch, {i % 32}"], group="csr")
T("csrr_mscratch", lambda i, L: [f"csrr {d(i)}, mscratch"], group="csr")
T("csrr_mcause", lambda i, L: [f"csrr {d(i)}, mcause"], setup=["csrw mcause, a5"],
  group="csr")
T("csrr_mepc", lambda i, L: [f"csrr {d(i)}, mepc"], setup=["csrw mepc, a0"], group="csr")
T("csrw_mepc", lambda i, L: ["csrw mepc, a0"], group="csr")
T("csrr_mstatus", lambda i, L: [f"csrr {d(i)}, mstatus"], group="csr")
T("csrrs_mstatus", lambda i, L: [f"csrrs {d(i)}, mstatus, a4"], group="csr",
  note="sets MIE (timer IRQ input is tied low)")
T("csrrc_mstatus", lambda i, L: [f"csrrc {d(i)}, mstatus, a4"], group="csr")
T("csrrsi_mstatus", lambda i, L: [f"csrrsi {d(i)}, mstatus, 8"], group="csr")
T("csrrci_mstatus", lambda i, L: [f"csrrci {d(i)}, mstatus, 8"], group="csr")

# ----------------------------------------------------------------------------- traps
# trap_std handler: csrr t6,mepc ; addi t6,t6,4 ; csrw mepc,t6 ; mret
T("ecall_roundtrip", lambda i, L: ["ecall"], post=["csrr t0, mcause", "csrr t1, mepc"],
  group="trap", note="per copy: ecall + 4-instruction handler (csrr/addi/csrw mepc, mret)")
T("ebreak_roundtrip", lambda i, L: ["ebreak"], post=["csrr t0, mcause", "csrr t1, mepc"],
  group="trap", note="per copy: ebreak + same handler")
T("mret_seq", lambda i, L: ["auipc t6, 0", "addi t6, t6, 16", "csrw mepc, t6", "mret"],
  per_copy=4, group="trap", note="per copy: auipc + addi + csrw mepc + mret")

# ----------------------------------------------------------------------------- misc
T("fence", lambda i, L: ["fence"], group="misc", note="fence iorw,iorw (0x0ff0000f)")
T("fence_rw", lambda i, L: ["fence rw, rw"], group="misc", note="0x0330000f (smp_mb)")
T("fence_tso", lambda i, L: [".word 0x8330000f"], group="misc", note="fence.tso")
T("fence_i", lambda i, L: ["fence.i"], group="misc")
T("wfi", lambda i, L: ["wfi"], post=["csrr t0, mcause", "csrr t1, mepc"], group="misc",
  note="SERV decodes wfi as ebreak (op20=1): traps to trap_std")
T("nop", lambda i, L: ["nop"], group="alu", note="addi x0,x0,0")

# ----------------------------------------------------------------------------- mixes
MIX_A = ["add a2, a2, a3", "lw t0, 0(s1)", "sw a0, 4(s1)", "slli t1, a0, 5",
         "beq a0, a1, {fail}", "mul t2, a0, a1", "srli t3, a0, 7", "jal zero, {next}",
         "csrr t4, mscratch", "divu t5, a0, a1"]
MIX_A_CLASSES = ["add", "lw", "sw", "slli_5", "beq_not_taken", "mul", "srli_7", "jal_x0",
                 "csrr_mscratch", "divu_a0_a1"]
MIX_B = ["lui t0, 0x12345", "addi t0, t0, 0x678", "sll t1, a0, a4", "sra t2, a0, a4",
         "lbu t3, 3(s1)", "sh a0, 8(s1)", "bne a0, a0, {fail}", "bgeu a0, a1, {next}",
         "rem t4, a0, a1", "mulhu t5, a0, a1", "csrrw t4, mscratch, a0", "jal ra, {next}"]
MIX_B_CLASSES = ["lui", "addi", "sll_8", "sra_8", "lbu", "sh", "bne_not_taken",
                 "bgeu_taken", "rem_a0_a1", "mulhu", "csrrw_mscratch", "jal"]


def mix(seq):
    def body(i, L):
        line = seq[i % len(seq)]
        out = [line.format(fail=L("fail"), next=L(f"n{i}"))]
        if "{next}" in line:
            out.append(f"{L(f'n{i}')}:")
        return out
    return body


T("mix_a", mix(MIX_A), setup=ST_SETUP, n=len(MIX_A) * 6, k=2, group="mix",
  note="additivity check: " + ",".join(MIX_A_CLASSES))
T("mix_b", mix(MIX_B), setup=ST_SETUP, n=len(MIX_B) * 5, k=2, group="mix",
  note="additivity check: " + ",".join(MIX_B_CLASSES))
T("baseline_end", lambda i, L: [], n=0, group="baseline")

MIXES = {"mix_a": MIX_A_CLASSES, "mix_b": MIX_B_CLASSES}


# ----------------------------------------------------------------------------- emit
def emit(outdir):
    a = []
    w = a.append
    w("# GENERATED by perf/serv_cpi/gen_tests.py -- do not edit")
    w("    .option norvc")
    w("    .section .text.start, \"ax\"")
    w("    .globl _start")
    w("_start:")
    for r in range(1, 32):
        w(f"    li x{r}, 0")
    for c in ["mstatus", "mie", "mcause", "mepc", "mscratch", "mtval"]:
        w(f"    csrw {c}, zero")
    w("    la t0, trap_std")
    w("    csrw mtvec, t0")
    w(f"    li gp, {MARK}")
    w("    j tests")
    w("")
    w("    .balign 4")
    w("trap_std:")
    w("    csrr t6, mepc")
    w("    addi t6, t6, 4")
    w("    csrw mepc, t6")
    w("    mret")
    w("")
    w("# dump x1..x31 to MARK-256.. ; return through tp")
    w("dump:")
    for r in range(1, 32):
        w(f"    sw x{r}, {-256 + 4 * r}(gp)")
    w("    jalr zero, 0(tp)")
    w("")
    w("fail:")
    w("    li t0, 0xbad")
    w("    sw t0, 4(gp)")
    w("1:  j 1b")
    w("")
    w("tests:")
    meta = []
    for tid, t in enumerate(tests):
        pfx = f"T{tid}"

        def L(s, pfx=pfx):
            return f".L{pfx}_{s}"

        w(f"# ---- test {tid}: {t['name']}")
        w(f"{pfx}:")
        for r, v in DEFAULT_REGS:
            w(f"    li {r}, {s32(v)}")
        for r in ZERO_REGS:
            w(f"    li {r}, 0")
        for line in t["setup"]:
            w("    " + line.format(body=f"{pfx}_body"))
        w(f"    li s0, {t['k']}")
        w(f"    li a6, {tid << 1}")
        w(f"    li a7, {(tid << 1) | 1}")
        w("    sw a6, 0(gp)")
        w(f"{pfx}_body:")
        for i in range(t["n"]):
            for line in t["body"](i, L):
                w(line if line.endswith(":") else "    " + line)
        w(f"{pfx}_body_end:")
        w("    addi s0, s0, -1")
        w(f"    bnez s0, {pfx}_body")
        w("    sw a7, 0(gp)")
        for line in t["post"]:
            w("    " + line)
        w("    jal tp, dump")
        w(f"    j {L('next')}")
        w(f"{L('fail')}:")
        w("    j fail")
        w(f"{L('next')}:")
        meta.append(dict(tid=tid, name=t["name"], n=t["n"], k=t["k"], group=t["group"],
                         per_copy=t["per_copy"], note=t["note"],
                         body_sym=f"{pfx}_body", body_end_sym=f"{pfx}_body_end"))
    w("# ---- all done")
    w("    li t0, 0x900d")
    w("    sw t0, 4(gp)")
    w("1:  j 1b")
    w("")
    w("    .data")
    w("    .balign 4")
    w("    .globl load_data")
    w("load_data:")
    for i in range(256):
        w(f"    .word {(0x9E3779B9 * (i + 1)) & 0xFFFFFFFF:#010x}")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "serv_cpi_tests.S"), "w") as fh:
        fh.write("\n".join(a) + "\n")
    with open(os.path.join(outdir, "tests_meta.json"), "w") as fh:
        json.dump(dict(mark=MARK, halt=MARK + 4, tests=meta, mixes=MIXES), fh, indent=1)
    print(f"generated {len(tests)} tests into {outdir}")


if __name__ == "__main__":
    emit(sys.argv[1] if len(sys.argv) > 1 else "build")
