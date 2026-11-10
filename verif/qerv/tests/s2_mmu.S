# S2-M2 directed tests for the SV32 MMU (stage-2 CPU, SMODE=1). Self-checking (a failing
# check stores its test id to HALT_ADR; 0 = pass) and run in lockstep against
# verif/qerv/iss.py --smode, which walks the page tables on every access (no TLB): the
# program runs sfence.vma after every PTE change, as software must.
#
# Memory (the testbench RAM is 64 KB, aliased; physical = 0x8000xxxx):
#   code/data at 0x80000000, root table PT1 at 0x80008000, level-0 table PT0 at 0x80009000,
#   pages PA_A 0x8000A000, PA_B 0x8000B000.
# Virtual map:
#   0x80000000  4 MB megapage, identity, RWX AD, S only (code, handlers, data, tables)
#   0x40000000+ 4 KB pages through PT0 (VPN1 0x100):
#     [0] PA_A  RW U A D        [1] PA_B  R U A          [2] user_page  X U A
#     [3] invalid               [4] PA_A  RW U, A=0      [5] PA_A  RW U A, D=0
#     [6] PA_A  W only (reserved)   [7] PA_A RW A D, S only   [8] PA_A RW U A D (sfence test)
#   0x40400000  megapage whose PPN[0] != 0 (misaligned superpage)
#   0x40800000  pointer to PT1 itself, so its level-0 PTE (PT1[vpn0]) is a pointer: fault
#
# Registers: s0 = test id, s1 = M resume label, t3-t5 handlers, t6 CHECK.
# The M handler records cause/epc/tval (m_rec) and resumes at s1 in M with MIE=0. The S
# handler records scause/sepc/stval (s_rec) and ecalls to M.

#define MTIP_ADR  0x8000FFF8
#define HALT_ADR  0x8000FFFC
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

#define TEST(n)          li s0, n
#define CHECK(reg, val)  li t6, val; bne reg, t6, fail
#define RESUME(label)    la s1, label
#define TO_S(label)      li t0, 0x1800; csrc mstatus, t0; li t0, 0x0800; csrs mstatus, t0; la t0, label; csrw mepc, t0; mret
#define TO_U(label)      li t0, 0x1800; csrc mstatus, t0; la t0, label; csrw mepc, t0; mret
#define LOADM            la t0, m_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0)
#define LOADS            la t0, s_rec; lw a0, 0(t0); lw a1, 4(t0); lw a2, 8(t0)
#define SET_PT0(n, v)    li t0, PT0 + 4 * (n); li t1, v; sw t1, 0(t0)
#define SUM_ON           li t0, 0x40000; csrs mstatus, t0
#define SUM_OFF          li t0, 0x40000; csrc mstatus, t0
#define UVA(reg, label)  la reg, label; la t2, user_page; sub reg, reg, t2; li t2, 0x40002000; add reg, reg, t2

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

    # page tables: clear PT1 and PT0, then fill
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
    li    t0, PT1 + 4 * 0x101
    li    t1, PTE(0x80001000, V | R | W | A | D)      # PPN[0] = 1: misaligned superpage
    sw    t1, 0(t0)
    li    t0, PT1 + 4 * 0x102
    li    t1, PTE(PT1, V)
    sw    t1, 0(t0)
    SET_PT0(0, PTE(PA_A, V | R | W | U | A | D))
    SET_PT0(1, PTE(PA_B, V | R | U | A))
    la    t1, user_page
    srli  t1, t1, 2
    ori   t1, t1, V | X | U | A
    li    t0, PT0 + 8
    sw    t1, 0(t0)
    SET_PT0(4, PTE(PA_A, V | R | W | U))
    SET_PT0(5, PTE(PA_A, V | R | W | U | A))
    SET_PT0(6, PTE(PA_A, V | W | U | A | D))
    SET_PT0(7, PTE(PA_A, V | R | W | A | D))
    SET_PT0(8, PTE(PA_A, V | R | W | U | A | D))
    # data: PA_A[0] = 0x11111111, PA_B[0] = 0x22222222
    li    t0, PA_A
    li    t1, 0x11111111
    sw    t1, 0(t0)
    li    t0, PA_B
    li    t1, 0x22222222
    sw    t1, 0(t0)

# ---------------------------------------------------------------- 1: translation off / M bypass
    TEST(1)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, PA_A                # satp = 0: S uses physical addresses
    lw    a0, 0(t0)
    ecall
3:  LOADM
    CHECK(a0, 9)
    li    t0, 0x80000000 | (PT1 >> 12)
    csrw  satp, t0
    sfence.vma
    li    t0, PA_B                # M is never translated
    lw    a0, 0(t0)
    CHECK(a0, 0x22222222)
    li    t0, VA(0)               # ... so a VA is just an address (aliases into RAM)
    lw    a0, 0(t0)

# ---------------------------------------------------------------- 2: S loads/stores, SUM
    TEST(2)
    SUM_ON
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(0)
    lw    a0, 0(t0)
    li    t1, 0x11111111
    bne   a0, t1, 9f
    li    t1, 0x33333333
    sw    t1, 4(t0)
    li    t0, VA(1)
    lw    a0, 0(t0)
    li    t1, 0x22222222
    bne   a0, t1, 9f
    ecall
9:  j     fail
3:  LOADM
    CHECK(a0, 9)
    li    t0, PA_A
    lw    a0, 4(t0)
    CHECK(a0, 0x33333333)
    SUM_OFF                       # S load from a U page without SUM: 13, not delegated
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(0)
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40000000)         # mtval = VA
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(7)               # S-only page without SUM: fine
    lw    a0, 0(t0)
    ecall
3:  LOADM
    CHECK(a0, 9)

# ---------------------------------------------------------------- 3: write permission, A, D
    TEST(3)
    SUM_ON
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(1)               # read-only page
4:  sw    t0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 15)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40001000)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(4) + 8           # A = 0: even a load faults
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)
    CHECK(a2, 0x40004008)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(5)               # D = 0: load fine, store faults
    lw    a0, 0(t0)
    li    t1, 0x11111111
    bne   a0, t1, 9f
4:  sw    a0, 12(t0)
9:  j     fail
3:  LOADM
    CHECK(a0, 15)
    CHECK(a2, 0x4000500C)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(6)               # W without R is reserved
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(3)               # invalid
4:  sb    a0, 1(t0)
    j     fail
3:  LOADM
    CHECK(a0, 15)
    CHECK(a2, 0x40003001)

# ---------------------------------------------------------------- 4: fetch faults
    TEST(4)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(2)               # S never executes a U page
    jr    t0
    j     fail
3:  LOADM
    CHECK(a0, 12)
    CHECK(a1, 0x40002000)         # mepc = the faulting pc
    CHECK(a2, 0x40002000)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(3)               # invalid
    jr    t0
    j     fail
3:  LOADM
    CHECK(a0, 12)
    CHECK(a1, 0x40003000)

# ---------------------------------------------------------------- 5: U mode
    TEST(5)
    li    t0, 0x40000000 + 0x2000
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0
    RESUME(3f)
    mret                          # user_page: loads VA(0), stores, ecall
3:  LOADM
    CHECK(a0, 8)
    UVA(t1, user_ecall)
    bne   a1, t1, fail
    li    t0, PA_A
    lw    a0, 8(t0)
    CHECK(a0, 0x11111111)
    UVA(t0, user_s_load)
    csrw  mepc, t0
    RESUME(3f)
    mret                          # U load from the S-only page: 13
3:  LOADM
    CHECK(a0, 13)
    CHECK(a2, 0x40007000)
    UVA(t0, user_x_load)
    csrw  mepc, t0
    RESUME(3f)
    mret                          # U load from its own X-only code page: 13
3:  LOADM
    CHECK(a0, 13)
    CHECK(a2, 0x40002000)

# ---------------------------------------------------------------- 6: MXR
    TEST(6)
    SUM_ON
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(2)               # X-only page, MXR = 0: 13
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)
    li    t0, 0x80000
    csrs  mstatus, t0             # MXR
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(2)
    lw    a0, 0(t0)
    la    t1, user_page
    lw    t1, 0(t1)
    bne   a0, t1, 9f
    ecall
9:  j     fail
3:  LOADM
    CHECK(a0, 9)
    li    t0, 0x80000
    csrc  mstatus, t0

# ---------------------------------------------------------------- 7: bad superpage, non-leaf at level 0
    TEST(7)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, 0x40400000
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, 0x40900000          # VPN1 0x102 -> PT1, VPN0 0x100 -> PT1[0x100]: a pointer
4:  lw    a0, 0(t0)
    j     fail
3:  LOADM
    CHECK(a0, 13)

# ---------------------------------------------------------------- 8: sfence.vma after a PTE change
    TEST(8)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(8)
    lw    a0, 0(t0)               # PA_A, now in the TLB
    li    t1, 0x11111111
    bne   a0, t1, 9f
    li    t2, PT0 + 4 * 8
    li    t1, PTE(PA_B, V | R | W | U | A | D)
    sw    t1, 0(t2)
    sfence.vma
    lw    a0, 0(t0)               # PA_B
    li    t1, 0x22222222
    bne   a0, t1, 9f
    sw    zero, 0(t2)             # invalid
    sfence.vma t0
4:  lw    a0, 0(t0)
9:  j     fail
3:  LOADM
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail

# ---------------------------------------------------------------- 9: LR/SC/AMO permissions
    TEST(9)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(1)               # read-only: LR works
    lr.w  a0, (t0)
    li    t1, 0x22222222
    bne   a0, t1, 9f
4:  sc.w  a1, a0, (t0)            # SC is a store: 15
9:  j     fail
3:  LOADM
    CHECK(a0, 15)
    la    t0, 4b
    bne   a1, t0, fail
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(1)
4:  amoadd.w a0, t0, (t0)         # 15
    j     fail
3:  LOADM
    CHECK(a0, 15)
    CHECK(a2, 0x40001000)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(0)               # RW: AMO and LR/SC through the MMU
    li    t1, 5
    amoadd.w a0, t1, (t0)
    lr.w  a1, (t0)
    addi  a1, a1, 1
    sc.w  a2, a1, (t0)
    bnez  a2, 9f
    ecall
9:  j     fail
3:  LOADM
    CHECK(a0, 9)
    li    t0, PA_A
    lw    a0, 0(t0)
    CHECK(a0, 0x11111117)

# ---------------------------------------------------------------- 11: micro-TLB, same page
# Each case makes an access that fills the micro-TLB entry for a page, then a second access to
# the same page that its cached flags must refuse under a different SUM / MXR / privilege /
# access type (sv32_mmu.v rechecks them on every fast-path access).
    TEST(11)
    SUM_ON
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(0)
    lw    a0, 0(t0)               # U page from S with SUM: fine
    li    t1, 0x40000
    csrc  sstatus, t1             # SUM off
4:  lw    a0, 0(t0)               # 13
    j     fail
3:  LOADM
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40000000)
    SUM_ON
    li    t0, 0x80000
    csrs  mstatus, t0             # MXR
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(2)
    lw    a0, 0(t0)               # X-only page with MXR: fine
    li    t1, 0x80000
    csrc  sstatus, t1             # MXR off
4:  lw    a0, 0(t0)               # 13
    j     fail
3:  LOADM
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40002000)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(5)
    lw    a0, 0(t0)               # D = 0: loads are fine
4:  sw    a0, 4(t0)               # store: 15
    j     fail
3:  LOADM
    CHECK(a0, 15)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40005004)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(1)
    lw    a0, 0(t0)               # read-only page
4:  amoadd.w a0, a0, (t0)         # AMO = store: 15
    j     fail
3:  LOADM
    CHECK(a0, 15)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40001000)
    SUM_OFF
    UVA(t0, user_page)
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0
    RESUME(3f)
    mret                          # U: load and store VA(0), ecall
3:  LOADM
    CHECK(a0, 8)
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(0)
4:  lw    a0, 0(t0)               # same page from S without SUM: 13
    j     fail
3:  LOADM
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(7)
    lw    a0, 0(t0)               # S-only page from S: fine
    ecall
3:  LOADM
    CHECK(a0, 9)
    UVA(t0, user_s_load)
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0
    RESUME(3f)
    mret                          # same page from U: 13
3:  LOADM
    CHECK(a0, 13)
    CHECK(a2, 0x40007000)
    UVA(t0, user_ecall)
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0
    RESUME(3f)
    mret                          # U runs its page
3:  LOADM
    CHECK(a0, 8)
    li    t0, 0x1800
    csrc  mstatus, t0
    li    t0, 0x0800
    csrs  mstatus, t0
    UVA(t0, user_ecall)
    csrw  mepc, t0
    RESUME(3f)
    mret                          # S fetch from the same U page: 12
3:  LOADM
    CHECK(a0, 12)
    UVA(t0, user_ecall)
    bne   a1, t0, fail
    bne   a2, t0, fail
    RESUME(3f)
    TO_S(1f)
1:  ecall                         # S runs this page
3:  LOADM
    CHECK(a0, 9)
    RESUME(3f)
    TO_U(1f)
1:  nop                           # U fetch from the same S page: 12
    j     fail
3:  LOADM
    CHECK(a0, 12)
    la    t0, 1b
    bne   a1, t0, fail
    # sfence.vma must also clear the micro-TLB: M remaps the page (untranslated, so the entry
    # filled by S stays), then S fences and loads the same page with no access in between
    SUM_ON
    SET_PT0(8, PTE(PA_A, V | R | W | U | A | D))
    sfence.vma
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(8)
    lw    a0, 0(t0)               # PA_A, fills the micro-TLB
    ecall
3:  SET_PT0(8, PTE(PA_B, V | R | W | U | A | D))
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(8)
    sfence.vma
    lw    a0, 0(t0)               # PA_B
    li    t1, 0x22222222
    bne   a0, t1, 9f
    ecall
9:  j     fail
3:  LOADM
    CHECK(a0, 9)

# ---------------------------------------------------------------- 10: page faults delegated to S
    TEST(10)
    li    t0, (1 << 12) | (1 << 13) | (1 << 15)
    csrw  medeleg, t0
    RESUME(3f)
    TO_S(1f)
1:  li    t0, VA(3)
4:  lw    a0, 4(t0)
    j     fail
3:  LOADS
    CHECK(a0, 13)
    la    t0, 4b
    bne   a1, t0, fail
    CHECK(a2, 0x40003004)
    RESUME(3f)
    TO_U(1f)                      # U fetch fault from code it may not run (S page): 12
1:  nop
    j     fail
3:  LOADS
    CHECK(a0, 12)
    la    t0, 1b
    bne   a1, t0, fail
    bne   a2, t0, fail
    csrw  medeleg, zero
    csrw  satp, zero
    sfence.vma

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

# ---------------------------------------------------------------- user page (VA 0x40002000, X U)
    .balign 4096
user_page:
    li    t0, VA(0)
    lw    a0, 0(t0)
    sw    a0, 8(t0)
user_ecall:
    ecall
user_s_load:
    li    t0, VA(7)
    lw    a0, 0(t0)
    ecall
user_x_load:
    li    t0, VA(2)
    lw    a0, 0(t0)
    ecall
    .balign 4096

    .section .data
    .balign 16
m_rec:     .word 0, 0, 0, 0
s_rec:     .word 0, 0, 0, 0
