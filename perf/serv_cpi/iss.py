#!/usr/bin/env python3
"""Minimal RV32IM + Zicsr reference ISS for checking the SERV CPI bench.

It runs the same raw binary as the RTL and writes a reference trace with the sequence of
fetched PCs (plus a mnemonic for each) and every store (word address, byte-enable mask,
data) so analyze.py can compare it with the RTL trace.

Machine model (matches what the benchmark program relies on):
  * M-mode only. CSRs: mstatus (MIE readable/writable, MPP reads as 3), mtvec, mscratch,
    mepc, mcause (bits 31 and 3:0 implemented, like SERV), mtval, mie.
  * ecall -> mcause 11, ebreak -> mcause 3; mepc = pc; pc = mtvec & ~3.
  * mret -> pc = mepc & ~3, MIE = MPIE.
  * fence / fence.i -> architectural no-op.
  * wfi -> modeled the way SERV decodes it (as ebreak, mcause 3). The RTL comparison
    therefore confirms SERV's behaviour rather than assuming it; see results notes.

usage: iss.py <program.bin> <out.json> [mark_adr] [max_instructions]
"""
import json
import sys

MASK = 0xFFFFFFFF


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class ISS:
    def __init__(self, image, memsize=0x40000):
        self.mem = bytearray(memsize)
        self.mem[:len(image)] = image
        self.size = memsize
        self.x = [0] * 32
        self.pc = 0
        self.csr = {0x305: 0, 0x340: 0, 0x341: 0, 0x342: 0, 0x343: 0}
        self.mie_bit = 0      # mstatus.MIE
        self.mpie_bit = 0     # mstatus.MPIE
        self.mtie = 0         # mie.MTIE
        self.fetches = []     # (pc, mnemonic)
        self.stores = []      # (word_adr, sel, data)
        self.halt = None

    # ----------------------------------------------------------------- memory
    def a(self, adr):
        return adr % self.size

    def ld(self, adr, n):
        adr = self.a(adr)
        return int.from_bytes(self.mem[adr:adr + n], "little")

    def st(self, adr, n, val):
        wadr = adr & ~3 & MASK
        lane = adr & 3
        sel = ((1 << n) - 1) << lane
        data = (val & ((1 << (8 * n)) - 1)) << (8 * lane)
        self.stores.append((wadr, sel, data))
        a = self.a(adr)
        self.mem[a:a + n] = (val & ((1 << (8 * n)) - 1)).to_bytes(n, "little")
        return wadr

    # ----------------------------------------------------------------- CSRs
    def csr_read(self, c):
        if c == 0x300:
            return (self.mie_bit << 3) | (3 << 11)
        if c == 0x304:
            return self.mtie << 7
        if c == 0x342:
            return self.csr[c] & 0x8000000F
        if c in self.csr:
            return self.csr[c]
        raise RuntimeError(f"unmodeled CSR read {c:#x} at pc {self.pc:#x}")

    def csr_write(self, c, v):
        v &= MASK
        if c == 0x300:
            self.mie_bit = (v >> 3) & 1
        elif c == 0x304:
            self.mtie = (v >> 7) & 1
        elif c == 0x342:
            self.csr[c] = v & 0x8000000F
        elif c in self.csr:
            self.csr[c] = v
        else:
            raise RuntimeError(f"unmodeled CSR write {c:#x} at pc {self.pc:#x}")

    def trap(self, cause):
        self.csr[0x341] = self.pc
        self.csr[0x342] = cause
        self.mpie_bit = self.mie_bit
        self.mie_bit = 0
        return self.csr[0x305] & ~3

    # ----------------------------------------------------------------- execute
    def step(self, mark_adr):
        pc = self.pc
        ins = self.ld(pc, 4)
        op = ins & 0x7F
        rd = (ins >> 7) & 31
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 31
        rs2 = (ins >> 20) & 31
        f7 = ins >> 25
        x = self.x
        a, b = x[rs1], x[rs2]
        imm_i = sx(ins >> 20, 12)
        imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        imm_b = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) |
                   (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) |
                   (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
        npc = (pc + 4) & MASK
        res = None
        mn = "?"
        if op == 0x37:
            mn, res = "lui", imm_u
        elif op == 0x17:
            mn, res = "auipc", pc + imm_u
        elif op == 0x6F:
            mn, res, npc = "jal", pc + 4, (pc + imm_j) & MASK
        elif op == 0x67:
            mn, res, npc = "jalr", pc + 4, (a + imm_i) & ~1 & MASK
        elif op == 0x63:
            names = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
            mn = names[f3]
            take = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                    6: a < b, 7: a >= b}[f3]
            if take:
                npc = (pc + imm_b) & MASK
        elif op == 0x03:
            adr = (a + imm_i) & MASK
            mn = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[f3]
            n = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            if adr % n:
                raise RuntimeError(f"misaligned load at {pc:#x}")
            v = self.ld(adr, n)
            res = sx(v, 8 * n) if f3 < 4 else v
        elif op == 0x23:
            adr = (a + imm_s) & MASK
            mn = {0: "sb", 1: "sh", 2: "sw"}[f3]
            n = {0: 1, 1: 2, 2: 4}[f3]
            if adr % n:
                raise RuntimeError(f"misaligned store at {pc:#x}")
            self.st(adr, n, b)
            if adr == mark_adr + 4:
                self.halt = b & MASK
        elif op == 0x13:
            sh = rs2
            if f3 == 0:
                mn, res = "addi", a + imm_i
            elif f3 == 2:
                mn, res = "slti", int(s32(a) < imm_i)
            elif f3 == 3:
                mn, res = "sltiu", int(a < (imm_i & MASK))
            elif f3 == 4:
                mn, res = "xori", a ^ imm_i
            elif f3 == 6:
                mn, res = "ori", a | imm_i
            elif f3 == 7:
                mn, res = "andi", a & imm_i
            elif f3 == 1:
                mn, res = "slli", a << sh
            elif f3 == 5:
                if f7 & 0x20:
                    mn, res = "srai", s32(a) >> sh
                else:
                    mn, res = "srli", a >> sh
            if mn == "addi" and rd == 0 and rs1 == 0 and imm_i == 0:
                mn = "nop"
        elif op == 0x33:
            if f7 == 1:
                sa, sb_ = s32(a), s32(b)
                if f3 == 0:
                    mn, res = "mul", a * b
                elif f3 == 1:
                    mn, res = "mulh", (sa * sb_) >> 32
                elif f3 == 2:
                    mn, res = "mulhsu", (sa * b) >> 32
                elif f3 == 3:
                    mn, res = "mulhu", (a * b) >> 32
                elif f3 == 4:
                    mn = "div"
                    if b == 0:
                        res = -1
                    elif sa == -(1 << 31) and sb_ == -1:
                        res = sa
                    else:
                        q = abs(sa) // abs(sb_)
                        res = -q if (sa < 0) != (sb_ < 0) else q
                elif f3 == 5:
                    mn, res = "divu", (MASK if b == 0 else a // b)
                elif f3 == 6:
                    mn = "rem"
                    if b == 0:
                        res = sa
                    elif sa == -(1 << 31) and sb_ == -1:
                        res = 0
                    else:
                        r = abs(sa) % abs(sb_)
                        res = -r if sa < 0 else r
                elif f3 == 7:
                    mn, res = "remu", (a if b == 0 else a % b)
            else:
                sh = b & 31
                if f3 == 0:
                    mn, res = ("sub", a - b) if f7 & 0x20 else ("add", a + b)
                elif f3 == 1:
                    mn, res = "sll", a << sh
                elif f3 == 2:
                    mn, res = "slt", int(s32(a) < s32(b))
                elif f3 == 3:
                    mn, res = "sltu", int(a < b)
                elif f3 == 4:
                    mn, res = "xor", a ^ b
                elif f3 == 5:
                    mn, res = ("sra", s32(a) >> sh) if f7 & 0x20 else ("srl", a >> sh)
                elif f3 == 6:
                    mn, res = "or", a | b
                elif f3 == 7:
                    mn, res = "and", a & b
        elif op == 0x0F:
            mn = "fence.i" if f3 == 1 else ("fence.tso" if (ins >> 28) == 8 else "fence")
        elif op == 0x73:
            if f3 == 0:
                if ins == 0x00000073:
                    mn, npc = "ecall", self.trap(11)
                elif ins == 0x00100073:
                    mn, npc = "ebreak", self.trap(3)
                elif ins == 0x30200073:
                    mn = "mret"
                    npc = self.csr[0x341] & ~3
                    self.mie_bit = self.mpie_bit
                elif ins == 0x10500073:
                    mn, npc = "wfi", self.trap(3)   # SERV: decoded as ebreak
                else:
                    raise RuntimeError(f"unknown system insn {ins:#010x} at {pc:#x}")
            else:
                c = ins >> 20
                src = rs1 if f3 & 4 else a           # zimm or rs1 value
                old = self.csr_read(c)
                kind = f3 & 3
                mn = ["", "csrrw", "csrrs", "csrrc"][kind] + ("i" if f3 & 4 else "")
                if kind == 1:
                    self.csr_write(c, src)
                elif kind == 2 and rs1 != 0:
                    self.csr_write(c, old | src)
                elif kind == 3 and rs1 != 0:
                    self.csr_write(c, old & ~src)
                res = old
        else:
            raise RuntimeError(f"unknown opcode {ins:#010x} at {pc:#x}")
        self.fetches.append((pc, mn))
        if res is not None and rd != 0:
            x[rd] = res & MASK
        self.pc = npc

    def run(self, mark_adr, max_insns):
        while self.halt is None and len(self.fetches) < max_insns:
            self.step(mark_adr)


def main():
    binfile, out = sys.argv[1], sys.argv[2]
    mark = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x3FFF0
    maxi = int(sys.argv[4]) if len(sys.argv) > 4 else 5_000_000
    with open(binfile, "rb") as fh:
        image = fh.read()
    iss = ISS(image)
    iss.run(mark, maxi)
    with open(out, "w") as fh:
        json.dump(dict(halt=iss.halt, fetches=iss.fetches, stores=iss.stores), fh)
    print(f"ISS: {len(iss.fetches)} instructions, {len(iss.stores)} stores, "
          f"halt={iss.halt if iss.halt is None else hex(iss.halt)}")


if __name__ == "__main__":
    main()
