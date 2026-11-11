# Zicbom on the stage-2 CPU (SMODE=1). cbo.inval/clean/flush leave on the data bus as a
# cache-block operation (o_dbus_cmo, op 00 inval / 01 clean / 10 flush) at the physical word
# address of rs1: no immediate, no misalignment trap, no register written. They are
# translated like a load (R needed, D not) and fault as a store (cause 15, tval = the
# virtual address). cbo.zero (Zicboz) is a no-op, like fence and fence.i.
#
# The testbench records each CMO in RAM: CMO_ADR = its physical word address, CMO_ADR + 4 =
# (count << 2) | op (verif/qerv/tb/qerv_tb.v, modelled by iss.py). Self-checking (a failing
# check stores its test id to HALT_ADR; 0 = pass) and in lockstep with iss.py --smode.
#
# Memory as in s2_mmu.S: code/data at 0x80000000 (an identity megapage, S only, so S code
# can read CMO_ADR), PT1 0x80008000, PT0 0x80009000, PA_A 0x8000A000, PA_B 0x8000B000.
#   VA(0) PA_A RW U A D   VA(1) PA_B R U A   VA(3) invalid   VA(4) PA_A RW U, A=0
#   VA(5) PA_A RW U A, D=0   VA(6) PA_A W only (reserved)   VA(7) PA_A RW A D, S only

#define HALT_ADR  0x8000FFFC
#define CMO_ADR   0x8000FFE8
#define PT1   0x80008000
#define PT0   0x80009000
#define PA_A  0x8000A000
#define PA_B  0x8000B000
#define V 0x01
#define R 0x02
#define W 0x04
#define X 0x08
#define U 0x10
#define A 0x40
#define D 0x80
#define PTE(pa, f)       (((pa) >> 2) | (f))
#define VA(n)            (0x40000000 + (n) * 0x1000)

#define CBO_INVAL(r)     .insn i 0x0F, 2, x0, r, 0
#define CBO_CLEAN(r)     .insn i 0x0F, 2, x0, r, 1
#define CBO_FLUSH(r)     .insn i 0x0F, 2, x0, r, 2
#define CBO_ZERO(r)      .insn i 0x0F, 2, x0, r, 4

#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
/* the last CMO recorded: physical word address, count, op */
#define CMO_IS(adr, n, op) li t0, CMO_ADR; lw a3, 0(t0); lw a4, 4(t0); CHECK(a3, adr); CHECK(a4, ((n) << 2) | (op))
#define RESUME(label)    la s1, label
#define TO_S(label)      li t0, 0x1800; csrc mstatus, t0; li t0, 0x0800; csrs mstatus, t0; la t0, label; csrw mepc, t0; mret
#define LOADM            la t0, m_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0)
#define LOADS            la t0, s_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0)
#define SET_PT0(n, v)    li t0, PT0 + 4 * (n); li t1, v; sw t1, 0(t0)
#define SUM_ON           li t0, 0x40000; csrs mstatus, t0
#define SUM_OFF          li t0, 0x40000; csrc mstatus, t0
/* in S: a CMO at va must fault (store page fault) without being recorded */
#define S_FAULT(op, va)  RESUME(3f); TO_S(1f); 1: li a0, va; 2: op(a0); j fail; 3: LOADM; CHECK(a0, 15); CHECK(a2, va); la t0, 2b; bne a1, t0, fail

    .section .text
    .globl _start
_start:
    la    t0, mhandler
    csrw  mtvec, t0
    la    t0, shandler
    csrw  stvec, t0
    csrw  mie, zero
    csrw  mstatus, zero
    csrw  medeleg, zero
    csrw  mideleg, zero
    csrw  satp, zero

    li    t0, PT1
    li    t1, 2048
1:  sw    zero, 0(t0)
    addi  t0, t0, 4
    addi  t1, t1, -1
    bnez  t1, 1b
    li    t0, PT1 + 4 * 0x200
    li    t1, PTE(0x80000000, V | R | W | X | A | D)
    sw    t1, 0(t0)
    li    t0, PT1 + 4 * 0x100
    li    t1, PTE(PT0, V)
    sw    t1, 0(t0)
    SET_PT0(0, PTE(PA_A, V | R | W | U | A | D))
    SET_PT0(1, PTE(PA_B, V | R | U | A))
    SET_PT0(4, PTE(PA_A, V | R | W | U))
    SET_PT0(5, PTE(PA_A, V | R | W | U | A))
    SET_PT0(6, PTE(PA_A, V | W | U | A | D))
    SET_PT0(7, PTE(PA_A, V | R | W | A | D))

# ---------------------------------------------------------------- 1: M mode, the three ops
    TEST(1)
    li    a0, PA_A + 7            # any byte of the block, no misalignment trap
    CBO_CLEAN(a0)
    CMO_IS(PA_A + 4, 1, 1)
    li    a0, PA_A + 0x23
    CBO_FLUSH(a0)
    CMO_IS(PA_A + 0x20, 2, 2)
    li    a0, PA_B
    CBO_INVAL(a0)
    CMO_IS(PA_B, 3, 0)

# ---------------------------------------------------------------- 2: no-ops and rd
    TEST(2)
    li    a0, PA_A
    CBO_ZERO(a0)                  # Zicboz is not implemented: a no-op
    fence
    fence.i
    CMO_IS(PA_B, 3, 0)
    li    a5, 0x5A
    .insn i 0x0F, 2, a5, a0, 1    # cbo.clean with rd != 0 (reserved): rd is not written
    CHECK(a5, 0x5A)
    CMO_IS(PA_A, 4, 1)
    li    a0, 0x10000000          # an I/O address is still a CMO on the bus (the SoC acks it)
    CBO_FLUSH(a0)
    CMO_IS(0x10000000, 5, 2)

# ---------------------------------------------------------------- 3: S mode, translated
    TEST(3)
    li    t0, 0x80000000 | (PT1 >> 12)
    csrw  satp, t0
    sfence.vma
    SUM_ON
    RESUME(3f)
    TO_S(1f)
1:  li    a0, VA(0) + 0x45
    CBO_FLUSH(a0)
    CMO_IS(PA_A + 0x44, 6, 2)
    li    a0, VA(1) + 8           # read-only page: allowed
    CBO_CLEAN(a0)
    CMO_IS(PA_B + 8, 7, 1)
    li    a0, VA(5) + 0x100       # D = 0: allowed (no store permission needed)
    CBO_INVAL(a0)
    CMO_IS(PA_A + 0x100, 8, 0)
    li    a0, VA(7) + 0x200       # S-only page
    CBO_FLUSH(a0)
    CMO_IS(PA_A + 0x200, 9, 2)
    li    a0, 0x8000B010          # the identity megapage
    CBO_CLEAN(a0)
    CMO_IS(PA_B + 0x10, 10, 1)
    ecall
3:  LOADM
    CHECK(a0, 9)                  # ecall from S

# ---------------------------------------------------------------- 4: S mode faults (cause 15)
    TEST(4)
    S_FAULT(CBO_CLEAN, VA(3) + 0x13)     # invalid PTE
    S_FAULT(CBO_FLUSH, VA(4) + 0x20)     # A = 0
    S_FAULT(CBO_INVAL, VA(6))            # W without R (reserved)
    SUM_OFF
    S_FAULT(CBO_FLUSH, VA(0) + 4)        # U page from S without SUM
    SUM_ON
    CMO_IS(PA_B + 0x10, 10, 1)           # none of them reached the bus

# ---------------------------------------------------------------- 5: a delegated fault
    TEST(5)
    li    t0, 1 << 15
    csrw  medeleg, t0
    RESUME(3f)
    TO_S(1f)
1:  li    a0, VA(3)
    CBO_INVAL(a0)
    j     fail
3:  LOADS
    CHECK(a0, 15)
    CHECK(a2, VA(3))
    csrw  medeleg, zero
    csrw  satp, zero
    sfence.vma
    CMO_IS(PA_B + 0x10, 10, 1)

# ---------------------------------------------------------------- done
    li    t0, HALT_ADR
    sw    zero, 0(t0)
1:  j     1b

fail:
    li    t0, HALT_ADR
    sw    s0, 0(t0)
1:  j     1b

# ---------------------------------------------------------------- trap handlers
    .balign 4
mhandler:
    la    t4, m_rec
    csrr  t3, mcause
    sw    t3, 0(t4)
    csrr  t5, mepc
    sw    t5, 4(t4)
    li    t5, 0                  # tval only for page faults (undefined after ecall)
    sltiu t6, t3, 12
    bnez  t6, 1f
    csrr  t5, mtval
1:  sw    t5, 8(t4)
    li    t5, 0x1800
    csrs  mstatus, t5
    li    t5, 0x80
    csrc  mstatus, t5
    csrw  mepc, s1
    mret

    .balign 4
shandler:
    la    t4, s_rec
    csrr  t3, scause
    sw    t3, 0(t4)
    csrr  t5, sepc
    sw    t5, 4(t4)
    li    t5, 0
    sltiu t6, t3, 12
    bnez  t6, 1f
    csrr  t5, stval
1:  sw    t5, 8(t4)
    ecall

    .section .data
    .balign 16
m_rec:     .word 0, 0, 0, 0
s_rec:     .word 0, 0, 0, 0
