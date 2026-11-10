# M1 directed tests for the QERV-Linux CPU: what riscv-tests does not cover.
# Self-checking (a failing check stores its test id to HALT_ADR; 0 = pass) and also run in
# lockstep against verif/qerv/iss.py (fetch sequence and every store must match).
#
# Registers: s0 = current test id, s1 = where the trap handler resumes after an exception
# (in M-mode), t3-t5 belong to the handler, t6 to CHECK.

#define MTIP_ADR 0x8000FFF8
#define HALT_ADR 0x8000FFFC

#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
#define RESUME(label)    la s1, label
#define TO_USER(label)   csrw mstatus, zero; la t0, label; csrw mepc, t0; mret
#define LOAD_TRAP        la t0, tr_cause; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0); lw a3, 12(t0)

    .section .text
    .globl _start
_start:
    la    t0, handler
    csrw  mtvec, t0
    csrw  mie, zero
    csrw  mstatus, zero

# ---------------------------------------------------------------- 1: unimplemented CSRs
    TEST(1)
    li    t0, 0x1234
    csrw  mscratch, t0
    csrr  a0, mhartid
    CHECK(a0, 0)
    csrr  a0, misa
    CHECK(a0, 0)
    csrr  a0, mvendorid
    CHECK(a0, 0)
    csrr  a0, cycle
    CHECK(a0, 0)
    li    t0, -1
    csrw  pmpaddr0, t0
    csrw  pmpcfg0, t0
    csrw  satp, t0
    csrw  medeleg, t0
    csrw  mideleg, t0
    csrw  0x744, t0              # mnstatus
    csrrw a0, 0x7c0, t0          # custom: reads 0
    CHECK(a0, 0)
    csrr  a0, pmpaddr0
    CHECK(a0, 0)
    csrr  a0, mscratch           # must not have been aliased
    CHECK(a0, 0x1234)
    csrr  a0, mtvec
    la    t0, handler
    bne   a0, t0, fail
    csrr  a0, mstatus
    CHECK(a0, 0)

# ---------------------------------------------------------------- 2: mie read-back
    TEST(2)
    li    t0, -1
    csrw  mie, t0
    csrr  a0, mie
    CHECK(a0, 0x80)
    li    t0, 0x808
    csrs  mie, t0                # must keep MTIE
    csrr  a0, mie
    CHECK(a0, 0x80)
    li    t0, 0x80
    csrc  mie, t0
    csrr  a0, mie
    CHECK(a0, 0)

# ---------------------------------------------------------------- 3: mstatus MPIE / MPP
    TEST(3)
    li    t0, 0x1880
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0x1880)
    csrw  mstatus, zero
    csrr  a0, mstatus
    CHECK(a0, 0)
    li    t0, 0x0800             # MPP=01 is illegal: WARL, bit 11 decides
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0x1800)
    li    t0, 0x1000
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0)
    li    t0, 0x80
    csrs  mstatus, t0
    csrs  mstatus, zero
    csrr  a0, mstatus
    CHECK(a0, 0x80)
    csrw  mstatus, zero

# ---------------------------------------------------------------- 4: mip follows mtip
    TEST(4)
    li    t0, MTIP_ADR
    li    t1, 1
    sw    t1, 0(t0)
    csrr  a0, mip
    CHECK(a0, 0x80)
    sw    zero, 0(t0)
    csrr  a0, mip
    CHECK(a0, 0)

# ---------------------------------------------------------------- 5: mret: MIE<-MPIE, MPIE<-1, MPP<-U
    TEST(5)
    li    t0, 0x1880
    csrw  mstatus, t0
    la    t0, 1f
    csrw  mepc, t0
    mret
1:  csrr  a0, mstatus
    CHECK(a0, 0x88)
    csrw  mstatus, zero

# ---------------------------------------------------------------- 6: ecall from U -> 8
    TEST(6)
    RESUME(2f)
    TO_USER(1f)
1:  ecall
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 8)
    la    t0, 1b
    bne   a1, t0, fail
    CHECK(a2, 0)                 # MPP=U, MPIE=0, MIE=0

# ---------------------------------------------------------------- 7: ecall from M -> 11
    TEST(7)
    csrw  mstatus, zero
    RESUME(2f)
1:  ecall
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 11)
    la    t0, 1b
    bne   a1, t0, fail
    CHECK(a2, 0x1800)

# ---------------------------------------------------------------- 8: ebreak from U -> 3
    TEST(8)
    RESUME(2f)
    TO_USER(1f)
1:  ebreak
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 3)
    CHECK(a2, 0)

# ---------------------------------------------------------------- 9: misaligned load in U -> 4
    TEST(9)
    la    a4, data_amo
    addi  a4, a4, 1
    RESUME(2f)
    TO_USER(1f)
1:  lw    a5, 0(a4)
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 4)
    bne   a3, a4, fail           # mtval = address
    CHECK(a2, 0)

# ---------------------------------------------------------------- 10: misaligned AMO in M -> 6
    TEST(10)
    la    a4, data_amo
    addi  a4, a4, 2
    li    a5, 1
    RESUME(2f)
1:  amoadd.w a6, a5, (a4)
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 6)
    bne   a3, a4, fail
    CHECK(a2, 0x1800)

# ---------------------------------------------------------------- 11: misaligned store in U -> 6
    TEST(11)
    la    a4, data_amo
    addi  a4, a4, 2
    RESUME(2f)
    TO_USER(1f)
1:  sw    a5, 0(a4)
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 6)
    bne   a3, a4, fail
    CHECK(a2, 0)

# ---------------------------------------------------------------- 12: timer interrupt in M
    TEST(12)
    li    t0, 0x80
    csrw  mie, t0
    li    t0, MTIP_ADR
    li    t1, 1
    sw    t1, 0(t0)              # pending, but MIE=0: not taken
    nop
    nop
    la    s1, fail
    csrsi mstatus, 8             # the next instruction is interrupted
1:  nop
    LOAD_TRAP
    li    t0, 0x80000007
    bne   a0, t0, fail
    la    t0, 1b
    bne   a1, t0, fail
    CHECK(a2, 0x1880)            # MPP=M, MPIE=1 (MIE was 1), MIE=0
    csrr  a0, mstatus
    CHECK(a0, 0x88)              # after mret: MIE=1, MPIE=1, MPP=U
    csrw  mstatus, zero

# ---------------------------------------------------------------- 13: timer interrupt in U with MIE=0
    TEST(13)
    la    t0, tr_cause
    sw    zero, 0(t0)
    li    t0, MTIP_ADR
    li    t1, 1
    sw    t1, 0(t0)              # pending; M-mode with MIE=0: not taken
    nop
    RESUME(2f)
    TO_USER(1f)
1:  ecall                        # interrupted first (U-mode ignores MIE), then executed
    j     fail
2:  LOAD_TRAP
    CHECK(a0, 8)                 # the ecall, after the interrupt returned to U-mode
    la    t0, irq_cause
    lw    a0, 0(t0)
    lw    a1, 4(t0)
    lw    a2, 8(t0)
    li    t0, 0x80000007
    bne   a0, t0, fail
    la    t0, 1b
    bne   a1, t0, fail
    CHECK(a2, 0)                 # MPP=U, MPIE=0, MIE=0
    csrw  mie, zero

# ---------------------------------------------------------------- 14: wfi, fence, fence.i are no-ops
    TEST(14)
    la    s1, fail
    li    a0, 0
    wfi
    addi  a0, a0, 1
    fence
    fence rw, rw
    fence.i
    addi  a0, a0, 1
    CHECK(a0, 2)

# ---------------------------------------------------------------- 15: AMOs
#define AMO_CASE(insn, init, src, expect_rd, expect_mem) \
    la a4, data_amo; li t0, init; sw t0, 0(a4); li a5, src; \
    insn a6, a5, (a4); lw a7, 0(a4); \
    la t0, results; sw a6, 0(t0); sw a7, 4(t0); \
    CHECK(a6, expect_rd); CHECK(a7, expect_mem)

    TEST(15)
    AMO_CASE(amoadd.w,  0x7fffffff, 1,          0x7fffffff, 0x80000000)
    AMO_CASE(amoswap.w, 0x12345678, 0xdeadbeef, 0x12345678, 0xdeadbeef)
    AMO_CASE(amoxor.w,  0xff00ff00, 0x0ff00ff0, 0xff00ff00, 0xf0f0f0f0)
    AMO_CASE(amoor.w,   0xff00ff00, 0x0ff00ff0, 0xff00ff00, 0xfff0fff0)
    AMO_CASE(amoand.w,  0xff00ff00, 0x0ff00ff0, 0xff00ff00, 0x0f000f00)
    AMO_CASE(amomin.w,  0xfffffffb, 3,          0xfffffffb, 0xfffffffb)
    AMO_CASE(amomax.w,  0xfffffffb, 3,          0xfffffffb, 3)
    AMO_CASE(amominu.w, 0xfffffffb, 3,          0xfffffffb, 3)
    AMO_CASE(amomaxu.w, 0xfffffffb, 3,          0xfffffffb, 0xfffffffb)
    AMO_CASE(amomin.w,  0x80000000, 0x7fffffff, 0x80000000, 0x80000000)
    AMO_CASE(amomax.w,  0x80000000, 0x7fffffff, 0x80000000, 0x7fffffff)
    la    a4, data_amo           # rd = x0: memory updated, no register written
    li    t0, 10
    sw    t0, 0(a4)
    li    a5, 5
    li    a6, 0x55
    amoadd.w x0, a5, (a4)
    lw    a7, 0(a4)
    CHECK(a7, 15)
    CHECK(a6, 0x55)

# ---------------------------------------------------------------- 16: LR/SC
    TEST(16)
    la    a4, data_amo
    la    a3, data_amo2
    li    t0, 100
    sw    t0, 0(a4)
    li    a5, 7
    sc.w  a6, a5, (a4)           # no reservation: fails
    CHECK(a6, 1)
    lw    a7, 0(a4)
    CHECK(a7, 100)
    lr.w  a0, (a4)
    CHECK(a0, 100)
    sc.w  a6, a5, (a4)           # succeeds
    CHECK(a6, 0)
    lw    a7, 0(a4)
    CHECK(a7, 7)
    li    a5, 9
    sc.w  a6, a5, (a4)           # reservation consumed: fails
    CHECK(a6, 1)
    lw    a7, 0(a4)
    CHECK(a7, 7)
    lr.w  a0, (a4)
    sc.w  a6, a5, (a3)           # other address: fails, clears the reservation
    CHECK(a6, 1)
    sc.w  a6, a5, (a4)
    CHECK(a6, 1)
    lr.w  a0, (a4)               # lr / sc / lr / sc
    addi  a0, a0, 1
    sc.w  a6, a0, (a4)
    CHECK(a6, 0)
    lr.w  a0, (a4)
    CHECK(a0, 8)

# ---------------------------------------------------------------- 17: interrupts on CSR instructions
# SERV takes an interrupt by running the fetched instruction's cycle as a trap; a CSR write
# to mstatus/mie must not happen then (found by booting Linux on the SoC: an interrupt on
# "csrr a5, mstatus" cleared MIE before it was saved into MPIE). The interrupted instruction
# re-executes after mret, so the end state must equal plain execution.
    TEST(17)
    li    t0, 0x80
    csrw  mie, t0
    csrw  mstatus, zero
    csrsi mstatus, 8             # MIE=1, nothing pending yet
    la    s1, fail
    li    t0, MTIP_ADR
    li    t1, 1
    li    t2, 0x80
    sw    t1, 0(t0)              # pending: the next instruction is interrupted
    csrr  a0, mstatus            # interrupted, then re-executed after mret
    CHECK(a0, 0x88)              # MIE restored to 1, MPIE=1, MPP=U
    sw    t1, 0(t0)
    csrw  mie, t2                # interrupted, then re-executed
    csrr  a0, mie
    CHECK(a0, 0x80)
    csrr  a0, mstatus
    CHECK(a0, 0x88)
    sw    t1, 0(t0)
    csrci mstatus, 8             # interrupted, re-executed: MIE ends 0
    csrr  a0, mstatus
    CHECK(a0, 0x80)
    la    t0, irq_cause
    lw    a0, 0(t0)
    li    t0, 0x80000007
    bne   a0, t0, fail
    csrw  mie, zero

# ---------------------------------------------------------------- done
    li    t0, HALT_ADR
    sw    zero, 0(t0)
1:  j     1b

fail:
    li    t0, HALT_ADR
    sw    s0, 0(t0)
1:  j     1b

# ---------------------------------------------------------------- trap handler
# Records mcause/mepc/mstatus (and mtval for misaligned) in tr_cause..+12. Interrupts:
# record in irq_cause too, clear mtip, return to mepc. Exceptions: return to s1 in M-mode.
    .balign 4
handler:
    csrr  t3, mcause
    la    t4, tr_cause
    sw    t3, 0(t4)
    csrr  t5, mepc
    sw    t5, 4(t4)
    csrr  t5, mstatus
    sw    t5, 8(t4)
    bltz  t3, 3f
    li    t5, 4
    beq   t3, t5, 1f
    li    t5, 6
    beq   t3, t5, 1f
    j     2f
1:  csrr  t5, mtval
    sw    t5, 12(t4)
2:  li    t5, 0x1800
    csrs  mstatus, t5
    csrw  mepc, s1
    mret
3:  la    t4, irq_cause
    sw    t3, 0(t4)
    csrr  t5, mepc
    sw    t5, 4(t4)
    csrr  t5, mstatus
    sw    t5, 8(t4)
    li    t5, MTIP_ADR
    sw    zero, 0(t5)
    mret

    .section .data
    .balign 16
tr_cause:  .word 0, 0, 0, 0
irq_cause: .word 0, 0, 0, 0
results:   .word 0, 0
    .balign 16
data_amo:  .word 0, 0
data_amo2: .word 0, 0
