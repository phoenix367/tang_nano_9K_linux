#!/usr/bin/env python3
"""Reference ISS for the QERV-Linux CPU (SERV with LINUX=1 + MDU + AMO unit).

Runs a raw binary loaded at 0x80000000 and records what the M1 testbench traces: the
sequence of fetched PCs (an interrupted instruction is fetched, then the handler) and every
memory write (word address, byte enables, data), including the write half of AMOs and
successful SCs.

Machine model (see doc/stage1_plan.md, M1):
  * RV32IMA + Zicsr + Zifencei; fence, fence.i, wfi are no-ops.
  * M and U modes. CSRs: mstatus (MIE, MPIE, MPP in {00,11}; a write's bit 11 decides MPP),
    mie (MTIE only), mip (MTIP, read-only), mtvec, mscratch, mepc, mcause (bits 31 and 3:0),
    mtval. Every other CSR reads 0 and ignores writes.
  * Traps: ecall 8 (U) / 11 (M), ebreak 3, misaligned load 4 / store and AMO 6 (mtval =
    address). Entry: MPIE<-MIE, MIE<-0, MPP<-mode, mode<-M, pc<-mtvec. mret: MIE<-MPIE,
    MPIE<-1, mode<-MPP, MPP<-U.
  * Timer interrupt (cause 0x80000007) before an instruction when mtip & MTIE &
    (MIE | mode == U). A store to MTIP_ADR sets mtip to bit 0 of the data.
  * LR sets a reservation on the word; SC succeeds (rd=0, write) only if it is valid for the
    same word; every SC clears it.
  * A store to HALT_ADR ends the run.

usage: iss.py <program.bin> <out.json> [max_instructions]
"""
import json
import sys

MASK = 0xFFFFFFFF
BASE = 0x80000000
MTIP_ADR = 0x8000FFF8
HALT_ADR = 0x8000FFFC


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class Trap(Exception):
    def __init__(self, cause, tval=0):
        self.cause, self.tval = cause, tval


class ISS:
    def __init__(self, image, memsize=0x10000):
        self.mem = bytearray(memsize)
        self.mem[:len(image)] = image
        self.size = memsize
        self.x = [0] * 32
        self.pc = BASE
        self.mode_m = 1
        self.mie = self.mpie = 0
        self.mpp = 1
        self.mtie = 0
        self.mtip = 0
        self.csr = {0x305: 0, 0x340: 0, 0x341: 0, 0x342: 0, 0x343: 0}
        self.res = None
        self.fetches = []
        self.stores = []
        self.halt = None

    # ------------------------------------------------------------- memory
    def ld(self, adr, n):
        a = adr % self.size
        return int.from_bytes(self.mem[a:a + n], "little")

    def st(self, adr, n, val):
        lane = adr & 3
        sel = ((1 << n) - 1) << lane
        data = (val & ((1 << (8 * n)) - 1)) << (8 * lane)
        self.stores.append((adr & ~3 & MASK, sel, data))
        a = adr % self.size
        self.mem[a:a + n] = (val & ((1 << (8 * n)) - 1)).to_bytes(n, "little")
        if adr == MTIP_ADR:
            self.mtip = val & 1
        if adr == HALT_ADR:
            self.halt = val & MASK

    # ------------------------------------------------------------- CSRs
    def csr_read(self, c):
        if c == 0x300:
            return (self.mie << 3) | (self.mpie << 7) | ((3 if self.mpp else 0) << 11)
        if c == 0x304:
            return self.mtie << 7
        if c == 0x344:
            return self.mtip << 7
        if c == 0x342:
            return self.csr[c] & 0x8000000F
        return self.csr.get(c, 0)

    def csr_write(self, c, v):
        v &= MASK
        if c == 0x300:
            self.mie, self.mpie, self.mpp = (v >> 3) & 1, (v >> 7) & 1, (v >> 11) & 1
        elif c == 0x304:
            self.mtie = (v >> 7) & 1
        elif c == 0x342:
            self.csr[c] = v & 0x8000000F
        elif c in self.csr:
            self.csr[c] = v

    def take_trap(self, cause, tval, epc):
        self.csr[0x341] = epc
        self.csr[0x342] = cause & 0x8000000F
        if cause in (4, 6):
            self.csr[0x343] = tval
        self.mpie, self.mie = self.mie, 0
        self.mpp, self.mode_m = self.mode_m, 1
        self.pc = self.csr[0x305] & ~3

    # ------------------------------------------------------------- execute
    def step(self):
        pc = self.pc
        if self.mtip and self.mtie and (self.mie or not self.mode_m):
            self.fetches.append((pc, "irq"))
            self.take_trap(0x80000007, 0, pc)
            return
        ins = self.ld(pc, 4)
        self.fetches.append((pc, f"{ins:08x}"))
        try:
            npc = self.execute(pc, ins)
        except Trap as t:
            self.take_trap(t.cause, t.tval, pc)
            return
        self.pc = npc & MASK

    def execute(self, pc, ins):
        op, rd, f3 = ins & 0x7F, (ins >> 7) & 31, (ins >> 12) & 7
        rs1, rs2, f7 = (ins >> 15) & 31, (ins >> 20) & 31, ins >> 25
        x = self.x
        a, b = x[rs1], x[rs2]
        imm_i = sx(ins >> 20, 12)
        imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
        imm_b = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) |
                   (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
        imm_j = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) |
                   (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
        npc, res = pc + 4, None
        if op == 0x37:
            res = ins & 0xFFFFF000
        elif op == 0x17:
            res = pc + (ins & 0xFFFFF000)
        elif op == 0x6F:
            res, npc = pc + 4, pc + imm_j
        elif op == 0x67:
            res, npc = pc + 4, (a + imm_i) & ~1
        elif op == 0x63:
            take = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                    6: a < b, 7: a >= b}[f3]
            if take:
                npc = pc + imm_b
        elif op == 0x03:
            adr = (a + imm_i) & MASK
            n = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            if adr % n:
                raise Trap(4, adr)
            v = self.ld(adr, n)
            res = sx(v, 8 * n) if f3 < 4 else v
        elif op == 0x23:
            adr = (a + imm_s) & MASK
            n = {0: 1, 1: 2, 2: 4}[f3]
            if adr % n:
                raise Trap(6, adr)
            self.st(adr, n, b)
        elif op == 0x13:
            sh = rs2
            res = {0: a + imm_i, 2: int(s32(a) < imm_i), 3: int(a < (imm_i & MASK)),
                   4: a ^ imm_i, 6: a | imm_i, 7: a & imm_i, 1: a << sh,
                   5: (s32(a) >> sh) if f7 & 0x20 else (a >> sh)}[f3]
        elif op == 0x33:
            if f7 == 1:
                res = self.muldiv(f3, a, b)
            else:
                sh = b & 31
                res = {0: (a - b) if f7 & 0x20 else (a + b), 1: a << sh,
                       2: int(s32(a) < s32(b)), 3: int(a < b), 4: a ^ b,
                       5: (s32(a) >> sh) if f7 & 0x20 else (a >> sh), 6: a | b, 7: a & b}[f3]
        elif op == 0x2F:
            res = self.amo(ins, a, b)
        elif op == 0x0F:
            pass                                   # fence / fence.i
        elif op == 0x73:
            if f3 == 0:
                if ins == 0x00000073:
                    raise Trap(11 if self.mode_m else 8)
                if ins == 0x00100073:
                    raise Trap(3)
                if ins == 0x30200073:
                    npc = self.csr[0x341] & ~3
                    self.mie, self.mpie = self.mpie, 1
                    self.mode_m, self.mpp = self.mpp, 0
                elif ins == 0x10500073:
                    pass                           # wfi
                else:
                    raise RuntimeError(f"unknown system insn {ins:#010x} at {pc:#x}")
            else:
                c = ins >> 20
                src = rs1 if f3 & 4 else a
                old = self.csr_read(c)
                kind = f3 & 3
                if kind == 1:
                    self.csr_write(c, src)
                elif kind == 2 and rs1 != 0:
                    self.csr_write(c, old | src)
                elif kind == 3 and rs1 != 0:
                    self.csr_write(c, old & ~src)
                res = old
        else:
            raise RuntimeError(f"unknown opcode {ins:#010x} at {pc:#x}")
        if res is not None and rd != 0:
            x[rd] = res & MASK
        return npc

    @staticmethod
    def muldiv(f3, a, b):
        sa, sb = s32(a), s32(b)
        if f3 == 0:
            return a * b
        if f3 == 1:
            return (sa * sb) >> 32
        if f3 == 2:
            return (sa * b) >> 32
        if f3 == 3:
            return (a * b) >> 32
        if f3 == 4:
            if b == 0:
                return -1
            if sa == -(1 << 31) and sb == -1:
                return sa
            q = abs(sa) // abs(sb)
            return -q if (sa < 0) != (sb < 0) else q
        if f3 == 5:
            return MASK if b == 0 else a // b
        if f3 == 6:
            if b == 0:
                return sa
            if sa == -(1 << 31) and sb == -1:
                return 0
            r = abs(sa) % abs(sb)
            return -r if sa < 0 else r
        return a if b == 0 else a % b

    def amo(self, ins, adr, src):
        f5 = ins >> 27
        if adr & 3:
            raise Trap(6, adr)
        word = adr >> 2
        if f5 == 0b00010:                          # LR
            self.res = word
            return self.ld(adr, 4)
        if f5 == 0b00011:                          # SC
            ok = self.res == word
            self.res = None
            if ok:
                self.st(adr, 4, src)
                return 0
            return 1
        old = self.ld(adr, 4)
        so, ss = s32(old), s32(src)
        new = {0b00000: old + src, 0b00001: src, 0b00100: old ^ src, 0b01000: old | src,
               0b01100: old & src, 0b10000: old if so < ss else src,
               0b10100: old if so > ss else src, 0b11000: min(old, src),
               0b11100: max(old, src)}[f5]
        self.st(adr, 4, new)
        return old


def main():
    binfile, out = sys.argv[1], sys.argv[2]
    maxi = int(sys.argv[3]) if len(sys.argv) > 3 else 1_000_000
    iss = ISS(open(binfile, "rb").read())
    while iss.halt is None and len(iss.fetches) < maxi:
        iss.step()
    with open(out, "w") as fh:
        json.dump(dict(halt=iss.halt, fetches=iss.fetches, stores=iss.stores), fh)
    print(f"ISS: {len(iss.fetches)} fetches, {len(iss.stores)} stores, "
          f"halt={'none' if iss.halt is None else hex(iss.halt)}")


if __name__ == "__main__":
    main()
