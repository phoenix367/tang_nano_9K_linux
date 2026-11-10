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

With --smode, the stage-2 model (SERV LINUX=1 + SMODE=1, doc/stage2_plan.md):
  * U/S/M. mstatus SIE/MIE/SPIE/MPIE/SPP/MPP/SUM/MXR (MPP=10 reads and acts as 11);
    sstatus is its S view. mie/sie: MTIE, STIE; mip/sip: MTIP (testbench), STIP (writable in
    mip). medeleg bits 0,3,4,6,8,12,13,15; mideleg bit 5. scause like mcause. stvec,
    sscratch, sepc, stval. satp MODE + PPN[19:0]. time/timeh = the testbench mtime (stores
    to MTIME_ADR / +4).
  * Interrupts are level-sensitive, before an instruction: MTI (mtip & MTIE & (priv < M |
    MIE)) first, then STI (STIP & STIE & (delegated ? priv == U | priv == S & SIE : priv < M |
    MIE)). ecall cause 8 + priv. A trap goes to S if priv < M and the cause is delegated.
  * sret: priv <- SPP, SIE <- SPIE, SPIE <- 1, SPP <- U. sfence.vma and wfi are no-ops.
  * The tval CSR is only defined for misaligned accesses and page faults here (the RTL
    writes some value on every trap), so tests must not read it after other traps.
  * SV32 when satp.MODE = 1 and priv < M (no MPRV), without a TLB (the RTL's TLB is
    invisible as long as software runs sfence.vma after changing PTEs). Svade: A = 0, or a
    store/AMO/SC with D = 0, is a page fault; PTEs are never written. Faults: fetch 12, load
    and LR 13, store/AMO/SC 15, tval = the virtual address. Misaligned checks come first.
    Fetches and stores are recorded with physical addresses (what the testbench sees).

usage: iss.py <program.bin> <out.json> [max_instructions] [--smode]
"""
import json
import sys

MASK = 0xFFFFFFFF
BASE = 0x80000000
MTIP_ADR = 0x8000FFF8
HALT_ADR = 0x8000FFFC
MTIME_ADR = 0x8000FFF0


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class PageFault(Exception):
    pass


class Trap(Exception):
    def __init__(self, cause, tval=0):
        self.cause, self.tval = cause, tval


class ISS:
    def __init__(self, image, memsize=0x10000, smode=False):
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
        self.smode = smode
        if smode:
            self.priv = 3
            self.sie = self.spie = self.spp = self.sum = self.mxr = 0
            self.mpp = 0
            self.stie = self.stip = self.mideleg5 = 0
            self.medeleg = 0
            self.satp = 0
            self.mtime = 0
            self.csr.update({0x105: 0, 0x140: 0, 0x141: 0, 0x142: 0, 0x143: 0})

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
        if adr == HALT_ADR or adr == getattr(self, "tohost", None):
            self.halt = val & MASK
        if adr == MTIME_ADR:
            self.mtime = (self.mtime & ~MASK) | (val & MASK)
        if adr == MTIME_ADR + 4:
            self.mtime = (self.mtime & MASK) | ((val & MASK) << 32)

    # ------------------------------------------------------------- CSRs
    def csr_read(self, c):
        if self.smode:
            return self.csr_read_s(c)
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
        if self.smode:
            return self.csr_write_s(c, v)
        if c == 0x300:
            self.mie, self.mpie, self.mpp = (v >> 3) & 1, (v >> 7) & 1, (v >> 11) & 1
        elif c == 0x304:
            self.mtie = (v >> 7) & 1
        elif c == 0x342:
            self.csr[c] = v & 0x8000000F
        elif c in self.csr:
            self.csr[c] = v

    # ------------------------------------------------------------- SV32
    def xlate(self, va, acc):
        """Physical address for va; acc is 'x', 'r' or 'w'. Raises Trap on a page fault."""
        va &= MASK
        if not self.smode or not (self.satp >> 31) or self.priv == 3:
            return va
        cause = {"x": 12, "r": 13, "w": 15}[acc]
        vpn = [(va >> 12) & 0x3FF, (va >> 22) & 0x3FF]
        table = (self.satp & 0xFFFFF) << 12
        for lvl in (1, 0):
            pte = self.ld(table + 4 * vpn[lvl], 4)
            v, r, w, x = pte & 1, (pte >> 1) & 1, (pte >> 2) & 1, (pte >> 3) & 1
            if not v or (w and not r):
                raise Trap(cause, va)
            if r or x:
                break
            if lvl == 0:
                raise Trap(cause, va)
            table = ((pte >> 10) & 0xFFFFF) << 12
        u, a, d = (pte >> 4) & 1, (pte >> 6) & 1, (pte >> 7) & 1
        if not a or (lvl == 1 and (pte >> 10) & 0x3FF):
            raise Trap(cause, va)
        if acc == "x":
            ok = x and (u if self.priv == 0 else not u)
        else:
            u_ok = u if self.priv == 0 else (not u or self.sum)
            ok = u_ok and ((r or (self.mxr and x)) if acc == "r" else (w and d))
        if not ok:
            raise Trap(cause, va)
        ppn = ((((pte >> 20) & 0x3FF) << 10) | vpn[0]) if lvl == 1 else (pte >> 10) & 0xFFFFF
        return (ppn << 12) | (va & 0xFFF)

    # ------------------------------------------------------------- SMODE CSRs and traps
    def mstatus_s(self):
        return ((self.sie << 1) | (self.mie << 3) | (self.spie << 5) | (self.mpie << 7) |
                (self.spp << 8) | (self.mpp << 11) | (self.sum << 18) | (self.mxr << 19))

    def csr_read_s(self, c):
        if c == 0x300:
            return self.mstatus_s()
        if c == 0x100:
            return self.mstatus_s() & 0x000C0122
        if c == 0x304:
            return (self.mtie << 7) | (self.stie << 5)
        if c == 0x104:
            return (self.stie & self.mideleg5) << 5
        if c == 0x344:
            return (self.mtip << 7) | (self.stip << 5)
        if c == 0x144:
            return (self.stip & self.mideleg5) << 5
        if c in (0x342, 0x142):
            return self.csr[c] & 0x8000000F
        if c == 0x302:
            return self.medeleg & 0xB159
        if c == 0x303:
            return self.mideleg5 << 5
        if c == 0x180:
            return self.satp & 0x800FFFFF
        if c == 0xC01:
            return self.mtime & MASK
        if c == 0xC81:
            return self.mtime >> 32
        return self.csr.get(c, 0)

    def csr_write_s(self, c, v):
        if c in (0x300, 0x100):
            self.sie, self.spie, self.spp = (v >> 1) & 1, (v >> 5) & 1, (v >> 8) & 1
            self.sum, self.mxr = (v >> 18) & 1, (v >> 19) & 1
            if c == 0x300:
                self.mie, self.mpie = (v >> 3) & 1, (v >> 7) & 1
                self.mpp = 3 if (v >> 11) & 3 == 2 else (v >> 11) & 3
        elif c == 0x304:
            self.mtie, self.stie = (v >> 7) & 1, (v >> 5) & 1
        elif c == 0x104:
            if self.mideleg5:
                self.stie = (v >> 5) & 1
        elif c == 0x344:
            self.stip = (v >> 5) & 1
        elif c in (0x342, 0x142):
            self.csr[c] = v & 0x8000000F
        elif c == 0x302:
            self.medeleg = v & 0xB159
        elif c == 0x303:
            self.mideleg5 = (v >> 5) & 1
        elif c == 0x180:
            self.satp = v & 0x800FFFFF
        elif c in self.csr:
            self.csr[c] = v

    def take_trap_s(self, cause, tval, epc):
        intr = cause >> 31
        code = cause & 0xF
        deleg = (code == 5 and self.mideleg5) if intr else (self.medeleg >> code) & 1
        if self.priv != 3 and deleg:
            self.csr[0x141] = epc
            self.csr[0x142] = cause & 0x8000000F
            if code in (0, 4, 6, 12, 13, 15) and not intr:
                self.csr[0x143] = tval & MASK
            self.spie, self.sie = self.sie, 0
            self.spp, self.priv = 1 if self.priv == 1 else 0, 1
            self.pc = self.csr[0x105] & ~3
        else:
            self.csr[0x341] = epc
            self.csr[0x342] = cause & 0x8000000F
            if code in (0, 4, 6, 12, 13, 15) and not intr:
                self.csr[0x343] = tval & MASK
            self.mpie, self.mie = self.mie, 0
            self.mpp, self.priv = self.priv, 3
            self.pc = self.csr[0x305] & ~3

    def pending_irq_s(self):
        mti = self.mtip and self.mtie and (self.priv != 3 or self.mie)
        if self.mideleg5:
            sen = self.priv == 0 or (self.priv == 1 and self.sie)
        else:
            sen = self.priv != 3 or self.mie
        sti = self.stip and self.stie and sen
        return 0x80000007 if mti else 0x80000005 if sti else None

    def take_trap(self, cause, tval, epc):
        if self.smode:
            return self.take_trap_s(cause, tval, epc)
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
        irq = self.pending_irq_s() if self.smode else \
            (0x80000007 if self.mtip and self.mtie and (self.mie or not self.mode_m) else None)
        if irq is not None:
            try:                                   # the fetch still happens unless it faults
                self.fetches.append((self.xlate(pc, "x"), "irq"))
            except Trap:
                pass
            self.take_trap(irq, 0, pc)
            return
        try:
            ppc = self.xlate(pc, "x")
        except Trap as t:
            self.take_trap(t.cause, t.tval, pc)
            return
        ins = self.ld(ppc, 4)
        self.fetches.append((ppc, f"{ins:08x}"))
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
            v = self.ld(self.xlate(adr, "r"), n)
            res = sx(v, 8 * n) if f3 < 4 else v
        elif op == 0x23:
            adr = (a + imm_s) & MASK
            n = {0: 1, 1: 2, 2: 4}[f3]
            if adr % n:
                raise Trap(6, adr)
            self.st(self.xlate(adr, "w"), n, b)
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
            if f3 == 0 and self.smode:
                if ins == 0x00000073:
                    raise Trap(8 + self.priv)
                if ins == 0x00100073:
                    raise Trap(3)
                if ins == 0x30200073:
                    npc = self.csr[0x341] & ~3
                    self.mie, self.mpie = self.mpie, 1
                    self.priv, self.mpp = self.mpp, 0
                elif ins == 0x10200073:
                    npc = self.csr[0x141] & ~3
                    self.sie, self.spie = self.spie, 1
                    self.priv, self.spp = self.spp, 0
                elif ins == 0x10500073 or (ins >> 25) == 0x09 and (ins & 0x7FFF) == 0x73:
                    pass                           # wfi, sfence.vma
                else:
                    raise RuntimeError(f"unknown system insn {ins:#010x} at {pc:#x}")
            elif f3 == 0:
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
        adr = self.xlate(adr, "r" if f5 == 0b00010 else "w")
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
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    binfile, out = args[0], args[1]
    maxi = int(args[2]) if len(args) > 2 else 1_000_000
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    iss = ISS(open(binfile, "rb").read(), smode="--smode" in sys.argv,
              memsize=int(opts.get("memsize", "65536"), 0))
    if "tohost" in opts:                       # riscv-tests: a store there ends the run
        iss.tohost = int(opts["tohost"], 16)
    while iss.halt is None and len(iss.fetches) < maxi:
        iss.step()
    with open(out, "w") as fh:
        json.dump(dict(halt=iss.halt, fetches=iss.fetches, stores=iss.stores), fh)
    print(f"ISS: {len(iss.fetches)} fetches, {len(iss.stores)} stores, "
          f"halt={'none' if iss.halt is None else hex(iss.halt)}")


if __name__ == "__main__":
    main()
