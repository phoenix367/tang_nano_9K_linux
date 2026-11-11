# Bare-metal check of the Zicbom cache-block operations on the whole SoC (CPU, cache, PSRAM),
# for the SoC simulation and the board. Booted by the ROM like a kernel (b / B, loaded at
# 0x80000000). The uncached alias (cached address + 0x10000000) is the PSRAM as a DMA device
# sees it:
#   1 cbo.clean writes a dirty line back (rs1 anywhere in the block)
#   2 ... and keeps it cached and clean: a PSRAM change is not seen through the cache, and an
#     eviction does not write the line again
#   3 cbo.flush writes the line back and drops it
#   4 cbo.inval drops a dirty line without writing it back (a device's data survives)
#   5 a CMO on the uncached alias or an I/O address does nothing (and does not hang)
#   6 flushing an 8 KB range of dirty lines writes back one burst per line (SYSCON counter),
#     and every word reaches PSRAM; after an inval of the range the CPU sees new PSRAM data
# Prints "cbo test: PASS" or "cbo test: FAIL <n>" and powers off (the simulation ends).
# Build: sw/tests/build.sh. Simulation: IMAGE=... sim/soc/run.sh (see build.sh).

#define UART      0x10000000
#define UART_LSR  5
#define SYSCON    0x11100000
#define SYS_WBS   0x11100018          /* SYSCON word 6: cache write-backs */
#define UNC       0x10000000          /* cached + UNC = the uncached alias */
#define B         0x80102000          /* test line (cache index 256: away from the code) */
#define B_ALIAS   (B + 16384)         /* same cache index, other tag: evicts B */
#define RANGE     0x80108800          /* 8 KB, cache indices 64..319: clear of the code's */
#define RANGE_LEN 8192

#define CBO_INVAL(r)     .insn i 0x0F, 2, x0, r, 0
#define CBO_CLEAN(r)     .insn i 0x0F, 2, x0, r, 1
#define CBO_FLUSH(r)     .insn i 0x0F, 2, x0, r, 2
#define TEST(n)          li s0, n
#define EXPECT(reg, val) li t6, val; bne reg, t6, fail
/* a word through the cache / straight in PSRAM */
#define LDC(reg)         li t0, B; lw reg, 0(t0)
#define STC(val)         li t0, B; li t1, val; sw t1, 0(t0)
#define LDU(reg)         li t0, B + UNC; lw reg, 0(t0)
#define STU(val)         li t0, B + UNC; li t1, val; sw t1, 0(t0)

    .section .text
    .globl _start
_start:
    li    s1, UART
    # 1: clean writes back
    TEST(1)
    STU(0x11111111)
    li    a0, B
    CBO_FLUSH(a0)                 # start with B not cached
    STC(0x22222222)               # miss, fill, now dirty
    LDU(a1)
    EXPECT(a1, 0x11111111)        # PSRAM still has the old word
    li    a0, B + 5
    CBO_CLEAN(a0)
    LDU(a1)
    EXPECT(a1, 0x22222222)

    # 2: the cleaned line stays cached and clean
    TEST(2)
    STU(0x33333333)
    LDC(a1)
    EXPECT(a1, 0x22222222)        # still the cached copy
    li    t0, B_ALIAS
    lw    a1, 0(t0)               # evicts B: no write-back if it is clean
    LDU(a1)
    EXPECT(a1, 0x33333333)
    LDC(a1)
    EXPECT(a1, 0x33333333)        # refilled from PSRAM

    # 3: flush writes back and drops
    TEST(3)
    STC(0x44444444)
    li    a0, B + 0x1F
    CBO_FLUSH(a0)
    LDU(a1)
    EXPECT(a1, 0x44444444)
    STU(0x55555555)
    LDC(a1)
    EXPECT(a1, 0x55555555)        # not cached any more

    # 4: inval drops a dirty line without writing it back
    TEST(4)
    STC(0x66666666)               # dirty (B is cached after test 3's load)
    STU(0x77777777)               # a device writes the PSRAM
    li    a0, B
    CBO_INVAL(a0)
    LDC(a1)
    EXPECT(a1, 0x77777777)
    LDU(a1)
    EXPECT(a1, 0x77777777)

    # 5: no-ops outside the cached window
    TEST(5)
    li    a0, B + UNC
    CBO_FLUSH(a0)
    CBO_INVAL(a0)
    li    a0, UART
    CBO_INVAL(a0)                 # must not read (pop) the UART
    li    a0, SYSCON
    CBO_FLUSH(a0)
    LDC(a1)
    EXPECT(a1, 0x77777777)

    # 6: an 8 KB range
    TEST(6)
    li    t0, RANGE
    li    t1, RANGE_LEN / 4
    li    t2, 0x9E3779B9
    mv    t3, t2
1:  sw    t3, 0(t0)               # every line dirty (the range fits in the cache)
    add   t3, t3, t2
    addi  t0, t0, 4
    addi  t1, t1, -1
    bnez  t1, 1b
    li    t0, SYS_WBS
    lw    s2, 0(t0)
    li    t0, RANGE
    li    t1, RANGE + RANGE_LEN
2:  CBO_FLUSH(t0)
    addi  t0, t0, 32
    bltu  t0, t1, 2b
    li    t0, SYS_WBS
    lw    s3, 0(t0)
    sub   s3, s3, s2
    TEST(7)
    EXPECT(s3, RANGE_LEN / 32)    # one write-back per line
    TEST(8)
    li    t0, RANGE + UNC
    li    t1, RANGE_LEN / 4
    mv    t3, t2
3:  lw    a1, 0(t0)               # every word in PSRAM
    bne   a1, t3, fail
    xori  a2, a1, -1
    sw    a2, 0(t0)               # new PSRAM data: ~word
    add   t3, t3, t2
    addi  t0, t0, 4
    addi  t1, t1, -1
    bnez  t1, 3b
    TEST(9)
    li    t0, RANGE
    li    t1, RANGE_LEN / 4
    mv    t3, t2
4:  lw    a1, 0(t0)               # flushed lines are gone: the CPU reads the new data
    xori  a2, t3, -1
    bne   a1, a2, fail
    add   t3, t3, t2
    addi  t0, t0, 4
    addi  t1, t1, -1
    bnez  t1, 4b

    la    a0, msg_pass
    jal   puts
    j     off

fail:
    la    a0, msg_fail
    jal   puts
    addi  a0, s0, '0'
    jal   putc
    li    a0, '\n'
    jal   putc
off:
    li    t0, UART                # wait for the last byte (TEMT) before powering off
1:  lbu   t1, UART_LSR(t0)
    andi  t1, t1, 0x40
    beqz  t1, 1b
    li    t0, SYSCON
    li    t1, 0x5555
    sw    t1, 0(t0)
2:  j     2b

putc:
1:  lbu   t0, UART_LSR(s1)
    andi  t0, t0, 0x20
    beqz  t0, 1b
    sb    a0, 0(s1)
    ret

puts:
    mv    t2, ra
    mv    t3, a0
1:  lbu   a0, 0(t3)
    beqz  a0, 2f
    jal   putc
    addi  t3, t3, 1
    j     1b
2:  mv    ra, t2
    ret

msg_pass:  .asciz "cbo test: PASS\n"
msg_fail:  .asciz "cbo test: FAIL "
