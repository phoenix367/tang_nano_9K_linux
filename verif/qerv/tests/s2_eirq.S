# Directed tests for the supervisor external interrupt (SEI, cause 9) of the stage-2 CPU
# (SERV LINUX=1 + SMODE=1: mie/sie.SEIE, mip/sip.SEIP from the PLIC, mideleg bit 9). The
# testbench drives SEIP with a store to SEIP_ADR (as MTIP with MTIP_ADR). Self-checking (a
# failing check stores its test id to HALT_ADR; 0 = pass) and run in lockstep against
# verif/qerv/iss.py --smode.
#
# Registers: s0 = test id, s1 = where the M handler resumes (in M, MIE = 0) after an
# exception (an ecall from S or U); t3-t5 belong to the handlers, t6 to CHECK.
# Interrupt handlers log {cause, 0 = taken in M / 1 = in S} in irq_log, clear the source
# (MTIP, SEIP: a store of 0; STIP: M clears mip.STIP, S clears sie.STIE) and return.

#define SEIP_ADR  0x8000FFF4
#define MTIP_ADR  0x8000FFF8
#define HALT_ADR  0x8000FFFC

#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
#define RESUME(label)    la s1, label
#define TO_S(label)      li t0, 0x1800; csrc mstatus, t0; li t0, 0x0800; csrs mstatus, t0; la t0, label; csrw mepc, t0; mret
#define TO_U(label)      li t0, 0x1800; csrc mstatus, t0; la t0, label; csrw mepc, t0; mret
#define SEIP(v)          li t1, SEIP_ADR; li t2, v; sw t2, 0(t1)
#define MTIP(v)          li t1, MTIP_ADR; li t2, v; sw t2, 0(t1)
#define LOG_CLEAR        la t0, log_n; sw zero, 0(t0)
#define LOG_N(n)         la t0, log_n; lw a0, 0(t0); CHECK(a0, n)
#define LOG_AT(i, c, m)  la t0, irq_log; lw a0, 8*(i)(t0); CHECK(a0, c); lw a0, 8*(i)+4(t0); CHECK(a0, m)
#define NOPS             nop; nop; nop; nop

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

# ---------------------------------------------------------------- 1: CSR view of SEI
    TEST(1)
    SEIP(1)                      # MIE = 0, SEIE = 0: nothing is taken
    csrr  a0, mip
    CHECK(a0, 0x200)
    csrr  a0, sip                # not delegated: invisible in sip
    CHECK(a0, 0)
    li    t0, 0x200
    csrw  mideleg, t0
    csrr  a0, mideleg
    CHECK(a0, 0x200)
    csrr  a0, sip
    CHECK(a0, 0x200)
    csrs  sie, t0                # delegated: sie.SEIE is mie.SEIE
    csrr  a0, mie
    CHECK(a0, 0x200)
    csrw  sie, zero
    csrr  a0, mie
    CHECK(a0, 0)
    csrw  mideleg, zero
    csrs  sie, t0                # not delegated: sie.SEIE is not writable
    csrr  a0, mie
    CHECK(a0, 0)
    csrw  mip, t0                # SEIP is not writable in mip
    SEIP(0)
    csrr  a0, mip
    CHECK(a0, 0)

# ---------------------------------------------------------------- 2: SEI taken in M
    TEST(2)
    LOG_CLEAR
    li    t0, 0x200
    csrw  mie, t0                # SEIE
    SEIP(1)                      # MIE = 0 in M: not taken
    NOPS
    LOG_N(0)
    li    t0, 0x8
    csrs  mstatus, t0            # MIE: taken now
    NOPS
    csrc  mstatus, t0
    LOG_N(1)
    LOG_AT(0, 0x80000009, 0)
    csrw  mie, zero              # SEIE = 0: not taken even with MIE
    LOG_CLEAR
    SEIP(1)
    li    t0, 0x8
    csrs  mstatus, t0
    NOPS
    csrc  mstatus, t0
    LOG_N(0)
    SEIP(0)

# ---------------------------------------------------------------- 3: priority MTI > SEI > STI
    TEST(3)
    LOG_CLEAR
    MTIP(1)
    SEIP(1)
    li    t0, 0x20
    csrs  mip, t0                # STIP
    li    t0, 0x2A0
    csrw  mie, t0                # SEIE, MTIE, STIE
    li    t0, 0x8
    csrs  mstatus, t0            # MIE: all three, highest first
    NOPS
    csrc  mstatus, t0
    LOG_N(3)
    LOG_AT(0, 0x80000007, 0)
    LOG_AT(1, 0x80000009, 0)
    LOG_AT(2, 0x80000005, 0)
    csrw  mie, zero

# ---------------------------------------------------------------- 4: delegated SEI in S and U
    TEST(4)
    LOG_CLEAR
    li    t0, 0x200
    csrw  mideleg, t0
    csrw  mie, t0                # SEIE
    RESUME(3f)
    TO_S(1f)
1:  li    t0, 0x2
    csrs  sstatus, t0            # SIE
    SEIP(1)                      # taken in S
    NOPS
    csrc  sstatus, t0            # SIE = 0: a delegated SEI waits in S ...
    SEIP(1)
    NOPS
    ecall                        # ... and in M; back in M at 3f
3:  LOG_N(1)
    LOG_AT(0, 0x80000009, 1)
    csrr  a0, mip                # still pending, held off in M
    CHECK(a0, 0x200)
    RESUME(3f)
    TO_U(1f)                     # in U it is taken whatever SIE
1:  NOPS
    ecall
3:  LOG_N(2)
    LOG_AT(1, 0x80000009, 1)

# ---------------------------------------------------------------- 5: undelegated SEI from S
    TEST(5)
    LOG_CLEAR
    csrw  mideleg, zero
    RESUME(3f)
    TO_S(1f)
1:  SEIP(1)                      # taken in M, whatever SIE (priv < M)
    NOPS
    ecall
3:  LOG_N(1)
    LOG_AT(0, 0x80000009, 0)
    csrw  mie, zero

# ---------------------------------------------------------------- done
    li    t0, HALT_ADR
    sw    zero, 0(t0)
1:  j     1b

fail:
    li    t0, HALT_ADR
    sw    s0, 0(t0)
1:  j     1b

# ---------------------------------------------------------------- trap handlers
# LOG(m): irq_log[log_n] = {t3 = cause, m}; log_n++ (t4, t5 only: t6 belongs to CHECK, which
# an interrupt may split)
#define LOG(m)  la t4, log_n; lw t5, 0(t4); addi t5, t5, 1; sw t5, 0(t4); slli t5, t5, 3; \
                la t4, irq_log - 8; add t4, t4, t5; sw t3, 0(t4); li t5, m; sw t5, 4(t4)

    .balign 4
mhandler:
    csrr  t3, mcause
    bltz  t3, 3f
    li    t5, 0x1800             # an exception (ecall): resume at s1 in M ...
    csrs  mstatus, t5
    li    t5, 0x80
    csrc  mstatus, t5            # ... with MIE = 0
    csrw  mepc, s1
    mret
3:  LOG(0)
    andi  t5, t3, 0xF
    li    t4, 7
    beq   t5, t4, 4f
    li    t4, 9
    beq   t5, t4, 5f
    li    t5, 0x20               # STI
    csrc  mip, t5
    mret
4:  li    t5, MTIP_ADR
    sw    zero, 0(t5)
    mret
5:  li    t5, SEIP_ADR
    sw    zero, 0(t5)
    mret

    .balign 4
shandler:
    csrr  t3, scause
    bltz  t3, 3f
    ecall                        # exceptions go on to M
3:  LOG(1)
    andi  t5, t3, 0xF
    li    t4, 9
    beq   t5, t4, 5f
    li    t5, 0x20               # STI: S cannot clear STIP, disable STIE
    csrc  sie, t5
    sret
5:  li    t5, SEIP_ADR
    sw    zero, 0(t5)
    sret

    .section .data
    .balign 16
log_n:     .word 0
irq_log:   .word 0, 0, 0, 0, 0, 0, 0, 0
