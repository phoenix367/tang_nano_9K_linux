# S2-M1 directed tests for the stage-2 CPU (SERV LINUX=1 + SMODE=1): privilege levels,
# delegation, sret, S-mode CSRs, interrupts. Self-checking (a failing check stores its test
# id to HALT_ADR; 0 = pass) and run in lockstep against verif/qerv/iss.py --smode.
#
# Registers: s0 = current test id, s1 = where the M handler resumes (in M-mode) after an
# exception, t3-t5 belong to the handlers, t6 to CHECK.
# The S handler records an exception in s_rec and then ecalls to M (cause 9), so every
# exception ends in M at s1. Interrupts are recorded in irq_rec (M) / sirq_rec (S) and
# return to the interrupted instruction.

#define MTIP_ADR  0x8000FFF8
#define HALT_ADR  0x8000FFFC
#define MTIME_ADR 0x8000FFF0

#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
#define RESUME(label)    la s1, label
#define TO_S(label)      li t0, 0x1800; csrc mstatus, t0; li t0, 0x0800; csrs mstatus, t0; la t0, label; csrw mepc, t0; mret
#define TO_U(label)      li t0, 0x1800; csrc mstatus, t0; la t0, label; csrw mepc, t0; mret
#define LOADM            la t0, m_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0); lw a3, 12(t0)
#define LOADS            la t0, s_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0); lw a3, 12(t0)
#define CLEAR_IRQ        la t0, irq_rec; sw zero, 0(t0); sw zero, 4(t0); la t0, sirq_rec; sw zero, 0(t0); sw zero, 4(t0)
#define MTIP(v)          li t1, MTIP_ADR; li t2, v; sw t2, 0(t1)

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

# ---------------------------------------------------------------- 1: CSR masks and storage
    TEST(1)
    li    t0, -1
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0x000C19AA)
    csrr  a0, sstatus
    CHECK(a0, 0x000C0122)
    csrw  sstatus, zero
    csrr  a0, mstatus
    CHECK(a0, 0x00001888)
    li    t0, 0x1000             # MPP=10 is reserved: reads (and acts) as 11
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0x1800)
    li    t0, 0x0800             # MPP=01 (S)
    csrw  mstatus, t0
    csrr  a0, mstatus
    CHECK(a0, 0x0800)
    csrw  mstatus, zero
    li    t0, -1
    csrw  mie, t0
    csrr  a0, mie
    CHECK(a0, 0xA0)
    csrr  a0, sie                # STI not delegated: invisible in sie
    CHECK(a0, 0)
    csrw  mideleg, t0
    csrr  a0, mideleg
    CHECK(a0, 0x20)
    csrr  a0, sie
    CHECK(a0, 0x20)
    csrw  sie, zero
    csrr  a0, mie
    CHECK(a0, 0x80)
    csrw  mie, zero
    csrw  mip, t0                # STIP is writable in mip
    csrr  a0, mip
    CHECK(a0, 0x20)
    csrr  a0, sip
    CHECK(a0, 0x20)
    csrw  sip, zero              # ... but not in sip
    csrr  a0, sip
    CHECK(a0, 0x20)
    csrw  mip, zero
    csrw  mideleg, zero
    csrw  medeleg, t0
    csrr  a0, medeleg
    CHECK(a0, 0xB159)
    csrw  medeleg, zero
    csrw  satp, t0
    csrr  a0, satp
    CHECK(a0, 0x800FFFFF)
    csrw  satp, zero
    csrw  scause, t0
    csrr  a0, scause
    CHECK(a0, 0x8000000F)
    li    t0, 0x11
    csrw  sscratch, t0
    li    t0, 0x22
    csrw  sepc, t0
    li    t0, 0x33
    csrw  stval, t0
    li    t0, 0x44
    csrw  mscratch, t0
    li    t0, 0x55
    csrw  mepc, t0
    li    t0, 0x66
    csrw  mtval, t0
    csrr  a0, sscratch
    CHECK(a0, 0x11)
    csrr  a0, sepc
    CHECK(a0, 0x22)
    csrr  a0, stval
    CHECK(a0, 0x33)
    csrr  a0, mscratch
    CHECK(a0, 0x44)
    csrr  a0, mepc
    CHECK(a0, 0x55)
    csrr  a0, mtval
    CHECK(a0, 0x66)
    csrr  a0, stvec
    la    t0, shandler
    bne   a0, t0, fail
    csrr  a0, mtvec
    la    t0, mhandler
    bne   a0, t0, fail
    li    t0, MTIME_ADR
    li    t1, 0x89ABCDEF
    sw    t1, 0(t0)
    li    t1, 0x01234567
    sw    t1, 4(t0)
    csrr  a0, time
    CHECK(a0, 0x89ABCDEF)
    csrr  a0, timeh
    CHECK(a0, 0x01234567)
    csrr  a0, cycle
    CHECK(a0, 0)
    csrr  a0, scounteren
    CHECK(a0, 0)

# ---------------------------------------------------------------- 2: ecall cause per mode
    TEST(2)
    RESUME(2f)
    ecall                        # M: 11
2:  LOADM
    CHECK(a0, 11)
    RESUME(3f)
    TO_S(1f)
1:  ecall                        # S: 9
3:  LOADM
    CHECK(a0, 9)
    la    t0, 1b
    bne   a1, t0, fail
    li    t0, 0x1800
    and   a2, a2, t0
    CHECK(a2, 0x0800)            # MPP = S
    RESUME(4f)
    TO_U(1f)
1:  ecall                        # U: 8
4:  LOADM
    CHECK(a0, 8)
    li    t0, 0x1800
    and   a2, a2, t0
    CHECK(a2, 0)                 # MPP = U

# ---------------------------------------------------------------- 3: ecall from U to S
    TEST(3)
    li    t0, 0x100
    csrw  medeleg, t0
    RESUME(2f)
    TO_U(1f)
1:  ecall
    j     fail
2:  LOADS
    CHECK(a0, 8)
    la    t0, 1b
    bne   a1, t0, fail
    andi  a2, a2, 0x122
    CHECK(a2, 0)                 # SPP = U, SPIE = SIE = 0
    LOADM
    CHECK(a0, 9)                 # the S handler's ecall: S ecalls are never delegated
    csrw  medeleg, zero

# ---------------------------------------------------------------- 4: S trap stays in S; M never delegates
    TEST(4)
    li    t0, 0x8
    csrw  medeleg, t0            # ebreak
    li    t0, 2
    csrs  mstatus, t0            # SIE = 1
    RESUME(2f)
    TO_S(1f)
1:  ebreak
    j     fail
2:  LOADS
    CHECK(a0, 3)
    la    t0, 1b
    bne   a1, t0, fail
    andi  a2, a2, 0x122
    CHECK(a2, 0x120)             # SPP = S, SPIE = 1 (was SIE), SIE = 0
    RESUME(3f)
    ebreak                       # in M: not delegated
3:  LOADM
    CHECK(a0, 3)
    csrw  medeleg, zero
    csrw  mstatus, zero

# ---------------------------------------------------------------- 5: sret to U and to S
    TEST(5)
    RESUME(3f)
    TO_S(1f)
1:  la    t0, 2f
    csrw  sepc, t0
    li    t0, 0x100
    csrc  sstatus, t0            # SPP = U
    li    t0, 0x20
    csrs  sstatus, t0            # SPIE = 1
    sret
2:  ecall                        # from U: 8
    j     fail
3:  LOADM
    CHECK(a0, 8)
    la    t0, 2b
    bne   a1, t0, fail
    csrr  a0, sstatus
    andi  a0, a0, 0x122
    CHECK(a0, 0x22)              # SIE = SPIE (1), SPIE = 1, SPP = U
    csrw  mstatus, zero
    RESUME(3f)
    TO_S(1f)
1:  la    t0, 2f
    csrw  sepc, t0
    li    t0, 0x100
    csrs  sstatus, t0            # SPP = S
    sret
2:  ecall                        # from S: 9
    j     fail
3:  LOADM
    CHECK(a0, 9)
    la    t0, 2b
    bne   a1, t0, fail
    csrr  a0, sstatus
    andi  a0, a0, 0x100
    CHECK(a0, 0)                 # SPP cleared by sret
    csrw  mstatus, zero

# ---------------------------------------------------------------- 6: misaligned in U, delegated
    TEST(6)
    li    t0, 0x50
    csrw  medeleg, t0            # 4 and 6
    RESUME(2f)
    TO_U(1f)
1:  la    t1, data
    lw    a0, 1(t1)
    j     fail
2:  LOADS
    CHECK(a0, 4)
    la    t0, data+1
    bne   a3, t0, fail           # stval
    RESUME(2f)
    TO_U(1f)
1:  la    t1, data
    sh    a0, 3(t1)
    j     fail
2:  LOADS
    CHECK(a0, 6)
    la    t0, data+3
    bne   a3, t0, fail
    csrw  medeleg, zero

# ---------------------------------------------------------------- 7: MTI below M ignores MIE
    TEST(7)
    CLEAR_IRQ
    li    t0, 0x80
    csrw  mie, t0
    RESUME(3f)
    TO_U(1f)
1:  MTIP(1)                      # taken at the next fetch (U, MIE = 0)
5:  nop
    ecall
    j     fail
3:  la    t0, irq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000007
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 5b
    bne   a1, t1, fail
    LOADM
    CHECK(a0, 8)
    CLEAR_IRQ
    RESUME(3f)
    TO_S(1f)
1:  MTIP(1)                      # S, MIE = 0
5:  nop
    ecall
    j     fail
3:  la    t0, irq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000007
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 5b
    bne   a1, t1, fail
    lw    a2, 8(t0)
    li    t1, 0x1800
    and   a2, a2, t1
    CHECK(a2, 0x0800)            # interrupted in S
    LOADM
    CHECK(a0, 9)
    csrw  mie, zero

# ---------------------------------------------------------------- 8: delegated STI
    TEST(8)
    CLEAR_IRQ
    li    t0, 0x20
    csrw  mideleg, t0
    csrw  mie, t0                # STIE
    csrs  mip, t0                # STIP pending: never taken in M
    nop
    nop
    RESUME(3f)
    TO_S(1f)                     # SIE = 0: not taken in S
1:  nop
    nop
    li    t0, 2
    csrs  sstatus, t0            # SIE = 1: taken at the next fetch
5:  nop
    ecall
    j     fail
3:  la    t0, sirq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000005
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 5b
    bne   a1, t1, fail
    lw    a2, 8(t0)
    andi  a2, a2, 0x122
    CHECK(a2, 0x120)             # SPP = S, SPIE = 1, SIE = 0
    la    t0, irq_rec
    lw    a0, 0(t0)
    CHECK(a0, 0)                 # M saw no interrupt
    LOADM
    CHECK(a0, 9)
    CLEAR_IRQ                    # in U, STI is taken whatever SIE is
    li    t0, 0x20
    csrs  mie, t0                # the S handler cleared STIE; STIP is still set
    csrw  mstatus, zero
    RESUME(3f)
    TO_U(1f)
1:  nop
    ecall
    j     fail
3:  la    t0, sirq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000005
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 1b
    bne   a1, t1, fail
    lw    a2, 8(t0)
    andi  a2, a2, 0x100
    CHECK(a2, 0)                 # SPP = U
    LOADM
    CHECK(a0, 8)
    csrw  mip, zero
    csrw  mie, zero
    csrw  mideleg, zero

# ---------------------------------------------------------------- 9: STI not delegated goes to M
    TEST(9)
    CLEAR_IRQ
    li    t0, 0x20
    csrw  mie, t0
    csrs  mip, t0
    RESUME(3f)
    TO_S(1f)
1:  nop                          # M handler (cause 5) clears STIP
    ecall
    j     fail
3:  la    t0, irq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000005
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 1b
    bne   a1, t1, fail
    LOADM
    CHECK(a0, 9)
    csrw  mie, zero

# ---------------------------------------------------------------- 10: MTI before STI
    TEST(10)
    CLEAR_IRQ
    li    t0, 0xA0
    csrw  mie, t0
    li    t0, 0x20
    csrw  mideleg, t0
    csrs  mip, t0
    MTIP(1)
    RESUME(3f)
    TO_U(1f)
1:  nop                          # MTI, then STI, both on this fetch
    ecall
    j     fail
3:  la    t0, irq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000007
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 1b
    bne   a1, t1, fail
    la    t0, sirq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000005
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 1b
    bne   a1, t1, fail
    LOADM
    CHECK(a0, 8)
    csrw  mip, zero
    csrw  mie, zero
    csrw  mideleg, zero

# ---------------------------------------------------------------- 11: interrupt on sret
    TEST(11)
    CLEAR_IRQ
    li    t0, 0x80
    csrw  mie, t0
    RESUME(3f)
    TO_S(1f)
1:  la    t0, 2f
    csrw  sepc, t0
    li    t0, 0x100
    csrs  sstatus, t0            # SPP = S
    MTIP(1)                      # taken at the next fetch: the sret
4:  sret
2:  ecall
    j     fail
3:  la    t0, irq_rec
    lw    a0, 0(t0)
    li    t1, 0x80000007
    bne   a0, t1, fail
    lw    a1, 4(t0)
    la    t1, 4b
    bne   a1, t1, fail
    LOADM
    CHECK(a0, 9)
    la    t0, 2b
    bne   a1, t0, fail
    csrw  mie, zero
    csrw  mstatus, zero

# ---------------------------------------------------------------- 12: sfence.vma, wfi
    TEST(12)
    li    a0, 0x12345678
    sfence.vma
    sfence.vma a0
    sfence.vma a0, a0            # rs2 sets instruction bit 21 (the mret bit in old decode)
    wfi
    RESUME(3f)
    TO_S(1f)
1:  sfence.vma a0, a0
    ecall
    j     fail
3:  LOADM
    CHECK(a0, 9)
    la    t0, 1b+4
    bne   a1, t0, fail

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
    csrr  t3, mcause
    bltz  t3, 3f
    la    t4, m_rec
    sw    t3, 0(t4)
    csrr  t5, mepc
    sw    t5, 4(t4)
    csrr  t5, mstatus
    sw    t5, 8(t4)
    li    t5, 4
    beq   t3, t5, 1f
    li    t5, 6
    beq   t3, t5, 1f
    j     2f
1:  csrr  t5, mtval
    sw    t5, 12(t4)
2:  li    t5, 0x1800
    csrs  mstatus, t5            # resume in M ...
    li    t5, 0x80
    csrc  mstatus, t5            # ... with MIE = 0 (mret sets MIE from MPIE)
    csrw  mepc, s1
    mret
3:  la    t4, irq_rec
    sw    t3, 0(t4)
    csrr  t5, mepc
    sw    t5, 4(t4)
    csrr  t5, mstatus
    sw    t5, 8(t4)
    slli  t5, t3, 1
    li    t4, 10                 # STI (5) taken in M: clear STIP
    beq   t5, t4, 4f
    li    t5, MTIP_ADR
    sw    zero, 0(t5)
    mret
4:  li    t5, 0x20
    csrc  mip, t5
    mret

    .balign 4
shandler:
    csrr  t3, scause
    bltz  t3, 3f
    la    t4, s_rec
    sw    t3, 0(t4)
    csrr  t5, sepc
    sw    t5, 4(t4)
    csrr  t5, sstatus
    sw    t5, 8(t4)
    li    t5, 4
    beq   t3, t5, 1f
    li    t5, 6
    beq   t3, t5, 1f
    j     2f
1:  csrr  t5, stval
    sw    t5, 12(t4)
2:  ecall                        # to M, which resumes at s1
3:  la    t4, sirq_rec
    sw    t3, 0(t4)
    csrr  t5, sepc
    sw    t5, 4(t4)
    csrr  t5, sstatus
    sw    t5, 8(t4)
    li    t5, 0x20
    csrc  sie, t5                # S cannot clear STIP: disable STIE instead
    sret

    .section .data
    .balign 16
m_rec:     .word 0, 0, 0, 0
s_rec:     .word 0, 0, 0, 0
irq_rec:   .word 0, 0, 0, 0
sirq_rec:  .word 0, 0, 0, 0
data:      .word 0x03020100, 0x07060504
