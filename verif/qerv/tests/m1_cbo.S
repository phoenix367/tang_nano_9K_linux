# Zicbom on the stage-1 CPU (SMODE=0, no MMU): cbo.inval/clean/flush reach the bus (through
# servile_arbiter, so the CMO flag must not leak onto fetches) at the word address of rs1,
# with no immediate, no misalignment trap and no register written, in M and in U mode.
# cbo.zero is a no-op. The testbench records each CMO at CMO_ADR (address) and CMO_ADR + 4
# ((count << 2) | op); see s2_cbo.S for the stage-2 version with translation and faults.

#define HALT_ADR  0x8000FFFC
#define CMO_ADR   0x8000FFE8
#define CBO_INVAL(r)     .insn i 0x0F, 2, x0, r, 0
#define CBO_CLEAN(r)     .insn i 0x0F, 2, x0, r, 1
#define CBO_FLUSH(r)     .insn i 0x0F, 2, x0, r, 2
#define CBO_ZERO(r)      .insn i 0x0F, 2, x0, r, 4
#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
#define CMO_IS(adr, n, op) li t0, CMO_ADR; lw a3, 0(t0); lw a4, 4(t0); CHECK(a3, adr); CHECK(a4, ((n) << 2) | (op))

    .section .text
    .globl _start
_start:
    la    t0, mhandler
    csrw  mtvec, t0
    csrw  mie, zero
    csrw  mstatus, zero

    TEST(1)
    li    a0, 0x8000A003
    CBO_CLEAN(a0)
    CMO_IS(0x8000A000, 1, 1)
    li    a0, 0x8000A07E
    CBO_FLUSH(a0)
    CMO_IS(0x8000A07C, 2, 2)
    li    a0, 0x8000B000
    CBO_INVAL(a0)
    CMO_IS(0x8000B000, 3, 0)
    lw    a1, 0(a0)               # a plain load right after: not a CMO
    CMO_IS(0x8000B000, 3, 0)

    TEST(2)
    CBO_ZERO(a0)
    fence
    fence.i
    li    a5, 0x5A
    .insn i 0x0F, 2, a5, a0, 2    # rd != 0: not written
    CHECK(a5, 0x5A)
    CMO_IS(0x8000B000, 4, 2)

    TEST(3)                       # U mode
    li    t0, 0x1800
    csrc  mstatus, t0
    la    t0, 1f
    csrw  mepc, t0
    mret
1:  li    a0, 0x8000C010
    CBO_INVAL(a0)
    ecall
    CMO_IS(0x8000C010, 5, 0)

    li    t0, HALT_ADR
    sw    zero, 0(t0)
1:  j     1b

fail:
    li    t0, HALT_ADR
    sw    s0, 0(t0)
1:  j     1b

    .balign 4
mhandler:                         # back to M after the U ecall, continuing after it
    csrr  t5, mepc
    addi  t5, t5, 4
    csrw  mepc, t5
    li    t5, 0x1800
    csrs  mstatus, t5
    mret
