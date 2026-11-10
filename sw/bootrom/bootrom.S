# QERV SoC boot ROM (0x00000000, reset vector).
#
# Prints a banner and a "> " prompt, then serves single-byte commands on the UART. Binary
# arguments are 32-bit little-endian. Commands are not echoed; each one ends with a new "> ".
#
#   l <addr> <len> <len bytes>   load into memory; replies "ok <hash>" (hash: h = h*33 + byte,
#                                h0 = 5381, 32 bits, as sw/tools/qerv_boot.py computes it).
#                                Nothing is printed until all bytes are in: the RX FIFO is
#                                only 16 bytes.
#   c <addr> <len>               hash memory: "ok <hash>", same hash as l
#   m <addr> <len>               memory test (word-aligned): address-in-data, then inverted,
#                                then byte stores over the first 64 KB. '.' per 512 KB.
#                                Prints "ok", or "FAIL n=<errors> @<addr> got <x> exp <y>".
#   b                            boot from RAM: a0 = 0, a1 = DTB_ADDR, jump to 0x80000000
#   B                            boot from RAM in S-mode under the SBI shim below (stage-2 MMU
#                                kernel, doc/stage2_plan.md); needs the stage-2 CPU
#   f                            copy Image + DTB from the SPI flash (sw/mkflash.py layout),
#                                then boot (in S-mode if header flag bit 0 is set)
#   q / r                        SYSCON poweroff / reboot
#   s                            status: the 7 SYSCON status words (soc_top.v): PSRAM calib
#                                bits, commands and read beats per channel, cache misses and
#                                write-backs. Touches no PSRAM.
#
# m, c, b and f first wait up to 0.5 s for both PSRAM channels to calibrate, else print
# "psram not calibrated" and the status. l does not check (its data would be read as
# commands): run s first.
#
# If no command arrives within AUTOBOOT_US of the first prompt and the flash holds an image,
# it boots from flash ("autoboot"); otherwise it keeps waiting. The kernel is entered as the
# RISC-V boot protocol (and the mini-rv32ima emulator) expects: a0 = hart id, a1 = DTB.
#
# Flash layout: 0x0000 header {magic "QRVL", image_len, dtb_len, flags}, 0x1000 DTB,
# 0x2000 Image. flags bit 0: boot the kernel in S-mode (B) instead of M-mode (b).
#
# RNG seed: before entering the kernel (b, B, f) the boot ROM looks in the DTB for the
# /chosen rng-seed property marked "QRNGSEED" (64 bytes) and folds into it the uninitialized
# PSRAM page 0x807FE000 (noise after a cold power-up) and mtime. Linux hashes it and credits
# it (add_bootloader_randomness), so its crng is ready at once; unseeded, every random number
# drawn during boot ran a full entropy extraction (~1.3 s of the boot).
#
# SBI v0.1 shim (M-mode, for the S-mode kernel): mtvec = sbi_trap, stack at the top of the
# reserved page SBI_STACK - 4 KB (the DT keeps Linux out of it). Delegated to S: misaligned
# accesses, breakpoints, user ecalls, page faults, the S timer interrupt. Calls (a7 = EID,
# legacy): 0 set_timer(a0 = low, a1 = high), 1 console_putchar(a0), 2 console_getchar,
# 8 shutdown; anything else returns SBI_ERR_NOT_SUPPORTED, so Linux sees SBI v0.1. The M
# timer interrupt is handed to S: clear MTIE, set STIP; set_timer clears STIP and sets MTIE.
#
# Registers: s0 = UART, s1 = 1 while autoboot is still armed, s2 = autoboot start (mtime).

#define UART      0x10000000
#define UART_LSR  5
#define LSR_DR    0x01
#define LSR_THRE  0x20
#define MTIME     0x1100BFF8
#define SYSCON    0x11100000
#define FLASH     0x20000000
#define MAGIC     0x4c565251          /* "QRVL" little-endian */
#define RAM_BASE  0x80000000
#define DTB_ADDR  0x807FF000          /* top 4 KB of the 8 MB PSRAM */
#define SBI_STACK 0x807FF000          /* grows down into 0x807FE000-0x807FEFFF */
#define MTIMECMP  0x11004000
#ifndef AUTOBOOT_US
#define AUTOBOOT_US 2000000
#endif

    .section .text
    .globl _start
_start:
    li    s0, UART
    la    a0, msg_banner
    jal   puts
    li    s1, 1
    li    t0, MTIME
    lw    s2, 0(t0)

prompt:
    la    a0, msg_prompt
    jal   puts
wait_cmd:
    lbu   t0, UART_LSR(s0)
    andi  t0, t0, LSR_DR
    bnez  t0, got_cmd
    beqz  s1, wait_cmd
    li    t0, MTIME
    lw    t0, 0(t0)
    sub   t0, t0, s2
    li    t1, AUTOBOOT_US
    bltu  t0, t1, wait_cmd
    li    s1, 0                       # autoboot: once, and only with a flash image
    li    t0, FLASH
    lw    t0, 0(t0)
    li    t1, MAGIC
    bne   t0, t1, wait_cmd
    la    a0, msg_autoboot
    jal   puts
    j     cmd_flash

got_cmd:
    li    s1, 0
    lbu   t0, 0(s0)
    li    t1, 'l'
    beq   t0, t1, cmd_load
    li    t1, 'm'
    beq   t0, t1, cmd_memtest
    li    t1, 'c'
    beq   t0, t1, cmd_hash
    li    t1, 'b'
    beq   t0, t1, boot
    li    t1, 'B'
    beq   t0, t1, cmd_boot_s
    li    t1, 'f'
    beq   t0, t1, cmd_flash
    li    t1, 'q'
    li    t2, 0x5555
    beq   t0, t1, 1f
    li    t1, 'r'
    li    t2, 0x7777
    beq   t0, t1, 1f
    li    t1, 's'
    beq   t0, t1, cmd_status
    la    a0, msg_what
    jal   puts
    j     prompt
1:  li    t1, SYSCON
    sw    t2, 0(t1)
    j     prompt

# ---------------------------------------------------------------- l: load
cmd_load:
    jal   get32
    mv    s3, a0                      # address
    jal   get32
    add   s4, s3, a0                  # end
    li    s5, 5381                    # hash
1:  bgeu  s3, s4, 3f
2:  lbu   t0, UART_LSR(s0)
    andi  t0, t0, LSR_DR
    beqz  t0, 2b
    lbu   t1, 0(s0)
    sb    t1, 0(s3)
    slli  t2, s5, 5
    add   s5, s5, t2
    add   s5, s5, t1
    addi  s3, s3, 1
    j     1b
3:
print_hash:
    la    a0, msg_ok
    jal   puts
    mv    a0, s5
    jal   puthex
    la    a0, msg_crlf
    jal   puts
    j     prompt

# ---------------------------------------------------------------- c: hash memory
cmd_hash:
    jal   psram_ready
    jal   get32
    mv    s3, a0
    jal   get32
    add   s4, s3, a0
    li    s5, 5381
1:  bgeu  s3, s4, print_hash
    lbu   t1, 0(s3)
    slli  t2, s5, 5
    add   s5, s5, t2
    add   s5, s5, t1
    addi  s3, s3, 1
    j     1b

# ---------------------------------------------------------------- m: memory test
# s3 = start, s4 = end, s5 = pattern, s6 = errors, s7/s8/s9 = first failure addr/got/exp
cmd_memtest:
    jal   psram_ready
    jal   get32
    andi  s3, a0, -4
    jal   get32
    andi  a0, a0, -4
    add   s4, s3, a0
    la    a0, msg_memtest
    jal   puts
    li    s6, 0
    li    s5, 0                       # pass 1: data = address
    jal   mt_words
    bnez  s6, mt_fail
    li    s5, -1                      # pass 2: data = ~address
    jal   mt_words
    bnez  s6, mt_fail
    jal   mt_bytes                    # pass 3: byte lanes
    bnez  s6, mt_fail
    la    a0, msg_ok
    jal   puts
    la    a0, msg_crlf
    jal   puts
    j     prompt
mt_fail:
    la    a0, msg_fail
    jal   puts
    mv    a0, s6
    jal   puthex
    la    a0, msg_at
    jal   puts
    mv    a0, s7
    jal   puthex
    la    a0, msg_got
    jal   puts
    mv    a0, s8
    jal   puthex
    la    a0, msg_exp
    jal   puts
    mv    a0, s9
    jal   puthex
    la    a0, msg_crlf
    jal   puts
    j     prompt

# mt_words: write [s3, s4) with addr ^ s5, then read and check; 'w'/'r' then '.' per 512 KB
mt_words:
    mv    s10, ra
    li    a0, 'w'
    jal   putc
    mv    t3, s3
1:  bgeu  t3, s4, 2f
    xor   t0, t3, s5
    sw    t0, 0(t3)
    addi  t3, t3, 4
    jal   mt_dot
    j     1b
2:  li    a0, 'r'
    jal   putc
    mv    t3, s3
3:  bgeu  t3, s4, 5f
    lw    t0, 0(t3)
    xor   t1, t3, s5
    beq   t0, t1, 4f
    jal   mt_error
4:  addi  t3, t3, 4
    jal   mt_dot
    j     3b
5:  mv    ra, s10
    ret

# mt_bytes: over [s3, min(s4, s3 + 64 KB)) store byte (addr & 0xFF) ^ 0xA5, read back words
mt_bytes:
    mv    s10, ra
    li    a0, 'b'
    jal   putc
    li    t0, 0x10000
    add   t4, s3, t0
    bleu  t4, s4, 1f
    mv    t4, s4
1:  mv    t3, s3
2:  bgeu  t3, t4, 3f
    xori  t0, t3, 0xA5
    sb    t0, 0(t3)
    addi  t3, t3, 1
    j     2b
3:  mv    t3, s3
    li    t5, 0x03020100
    li    t6, 0xA5A5A5A5
4:  bgeu  t3, t4, 6f
    lw    t0, 0(t3)
    andi  t1, t3, 0xFF                # bytes a, a+1, a+2, a+3 (a is a multiple of 4)
    slli  t2, t1, 8
    or    t1, t1, t2
    slli  t2, t1, 16
    or    t1, t1, t2
    add   t1, t1, t5
    xor   t1, t1, t6
    beq   t0, t1, 5f
    jal   mt_error
5:  addi  t3, t3, 4
    j     4b
6:  mv    ra, s10
    ret

# mt_error: t3 = address, t0 = got, t1 = expected (keeps t3)
mt_error:
    bnez  s6, 1f
    mv    s7, t3
    mv    s8, t0
    mv    s9, t1
1:  addi  s6, s6, 1
    ret

# mt_dot: '.' when t3 is on a 512 KB boundary (keeps t3; called with the return in ra)
mt_dot:
    li    t0, 0x7FFFF
    and   t0, t3, t0
    bnez  t0, 1f
    li    t0, '.'
2:  lbu   t1, UART_LSR(s0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 2b
    sb    t0, 0(s0)
1:  ret

# ---------------------------------------------------------------- f: boot from flash
cmd_flash:
    jal   psram_ready
    li    s3, FLASH
    lw    t0, 0(s3)
    li    t1, MAGIC
    beq   t0, t1, 1f
    la    a0, msg_noimage
    jal   puts
    j     prompt
1:  la    a0, msg_copy
    jal   puts
    li    a0, FLASH + 0x1000          # DTB
    li    a1, DTB_ADDR
    lw    a2, 8(s3)
    jal   copy
    li    a0, FLASH + 0x2000          # Image
    li    a1, RAM_BASE
    lw    a2, 4(s3)
    jal   copy
    la    a0, msg_done
    jal   puts
    lw    t0, 12(s3)                  # header flags
    andi  t0, t0, 1
    bnez  t0, boot_s

# ---------------------------------------------------------------- b: boot
boot:
    jal   psram_ready
    jal   seed_dtb
    la    a0, msg_boot
    jal   puts
    li    a0, 0
    li    a1, DTB_ADDR
    li    t0, RAM_BASE
    jr    t0

# ---------------------------------------------------------------- B: boot S-mode
cmd_boot_s:
    jal   psram_ready
boot_s:
    jal   seed_dtb
    la    a0, msg_boot_s
    jal   puts
    la    t0, sbi_trap
    csrw  mtvec, t0
    li    t0, SBI_STACK
    csrw  mscratch, t0
    li    t0, 0xB159                  # misaligned, breakpoint, U ecall, page faults
    csrw  medeleg, t0
    li    t0, 0x20                    # S timer
    csrw  mideleg, t0
    csrw  mie, zero
    csrw  satp, zero
    li    t0, 0x1888
    csrc  mstatus, t0                 # MPP, MPIE, MIE = 0
    li    t0, 0x0800
    csrs  mstatus, t0                 # MPP = S
    li    t0, RAM_BASE
    csrw  mepc, t0
    li    a0, 0
    li    a1, DTB_ADDR
    mret

# ---------------------------------------------------------------- SBI v0.1 shim
    .balign 4
sbi_trap:
    csrrw sp, mscratch, sp
    addi  sp, sp, -16
    sw    t0, 0(sp)
    sw    t1, 4(sp)
    csrr  t0, mcause
    bltz  t0, sbi_irq
    li    t1, 9                       # ecall from S
    bne   t0, t1, sbi_bad
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    li    t0, UART
    beqz  a7, sbi_set_timer
    li    t1, 1
    beq   a7, t1, sbi_putchar
    li    t1, 2
    beq   a7, t1, sbi_getchar
    li    t1, 8
    beq   a7, t1, sbi_shutdown
    li    a0, -2                      # SBI_ERR_NOT_SUPPORTED
    li    a1, 0
    j     sbi_ret
sbi_set_timer:
    li    t0, MTIMECMP
    li    t1, -1
    sw    t1, 4(t0)                   # no early match while the halves change
    sw    a0, 0(t0)
    sw    a1, 4(t0)
    li    t1, 0x20
    csrc  mip, t1                     # STIP
    li    t1, 0x80
    csrs  mie, t1                     # MTIE
    li    a0, 0
    j     sbi_ret
sbi_putchar:
1:  lbu   t1, UART_LSR(t0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 1b
    sb    a0, 0(t0)
    li    a0, 0
    j     sbi_ret
sbi_getchar:
    lbu   t1, UART_LSR(t0)
    andi  t1, t1, LSR_DR
    li    a0, -1
    beqz  t1, sbi_ret
    lbu   a0, 0(t0)
    j     sbi_ret
sbi_shutdown:
    li    t0, SYSCON
    li    t1, 0x5555
    sw    t1, 0(t0)
1:  j     1b
sbi_irq:                              # M timer: hand it to S
    li    t1, 0x80
    csrc  mie, t1
    li    t1, 0x20
    csrs  mip, t1
sbi_ret:
    lw    t0, 0(sp)
    lw    t1, 4(sp)
    addi  sp, sp, 16
    csrrw sp, mscratch, sp
    mret
sbi_bad:                              # unexpected trap into M: report and stop
    li    s0, UART
    la    a0, msg_mtrap
    jal   puts
    csrr  a0, mcause
    jal   puthex
    li    a0, ' '
    jal   putc
    csrr  a0, mepc
    jal   puthex
    li    a0, ' '
    jal   putc
    csrr  a0, mtval
    jal   puthex
    la    a0, msg_crlf
    jal   puts
1:  j     1b

# seed_dtb: fill the DT rng-seed marked "QRNGSEED" (16 words) with the uninitialized PSRAM
# page 0x807FE000 folded to 16 words, and mtime. Uses t0-t6 and a6.
seed_dtb:
    li    t0, DTB_ADDR
    li    t1, DTB_ADDR + 4096 - 64
    li    t2, 0x474E5251              # "QRNG"
    li    t4, 0x44454553              # "SEED"
1:  bgeu  t0, t1, 9f                  # no marked seed: nothing to do
    lw    t3, 0(t0)
    bne   t3, t2, 2f
    lw    t3, 4(t0)
    beq   t3, t4, 3f
2:  addi  t0, t0, 4
    j     1b
3:  li    t1, 0x807FE000
    li    t2, 0x807FF000
    li    t5, 0
4:  lw    t3, 0(t1)                   # seed[k] = rotl(seed[k], 7) ^ page word
    add   t4, t0, t5
    lw    t6, 0(t4)
    slli  a6, t6, 7
    srli  t6, t6, 25
    or    t6, t6, a6
    xor   t6, t6, t3
    sw    t6, 0(t4)
    addi  t5, t5, 4
    andi  t5, t5, 63
    addi  t1, t1, 4
    bltu  t1, t2, 4b
    li    t1, MTIME
    lw    t3, 0(t1)
    lw    t4, 0(t0)
    xor   t4, t4, t3
    sw    t4, 0(t0)
9:  ret

# copy(a0 = src, a1 = dst, a2 = bytes): word copy, '.' every 64 KB
copy:
    addi  a2, a2, 3
    andi  a2, a2, -4
    add   a3, a0, a2
    li    a4, 0xFFFF
1:  bgeu  a0, a3, 3f
    lw    t0, 0(a0)
    sw    t0, 0(a1)
    addi  a0, a0, 4
    addi  a1, a1, 4
    and   t1, a0, a4
    bnez  t1, 1b
2:  lbu   t1, UART_LSR(s0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 2b
    li    t1, '.'
    sb    t1, 0(s0)
    j     1b
3:  ret

# ---------------------------------------------------------------- s: status
cmd_status:
    la    a0, msg_status
    jal   puts
    li    s3, SYSCON
    addi  s4, s3, 28
1:  lw    a0, 0(s3)
    jal   puthex
    li    a0, ' '
    jal   putc
    addi  s3, s3, 4
    bne   s3, s4, 1b
    la    a0, msg_crlf
    jal   puts
    j     prompt

# psram_ready: return once SYSCON status bits 1:0 (calib1, calib0) are both set; after 0.5 s
# without them print the status and go back to the prompt (does not return)
psram_ready:
    li    t3, MTIME
    lw    t4, 0(t3)
1:  li    t0, SYSCON
    lw    t0, 0(t0)
    andi  t0, t0, 3
    li    t1, 3
    bne   t0, t1, 2f
    ret
2:  lw    t0, 0(t3)
    sub   t0, t0, t4
    li    t1, 500000
    bltu  t0, t1, 1b
    la    a0, msg_nocalib
    jal   puts
    j     cmd_status

# ---------------------------------------------------------------- UART helpers
# get32: a0 = next 4 bytes, little-endian (blocking)
get32:
    li    a0, 0
    li    t2, 0
1:  lbu   t0, UART_LSR(s0)
    andi  t0, t0, LSR_DR
    beqz  t0, 1b
    lbu   t0, 0(s0)
    sll   t0, t0, t2
    or    a0, a0, t0
    addi  t2, t2, 8
    li    t1, 32
    bne   t2, t1, 1b
    ret

# putc(a0 = char)
putc:
1:  lbu   t1, UART_LSR(s0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 1b
    sb    a0, 0(s0)
    ret

# puts(a0 = string)
puts:
1:  lbu   t0, 0(a0)
    beqz  t0, 3f
2:  lbu   t1, UART_LSR(s0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 2b
    sb    t0, 0(s0)
    addi  a0, a0, 1
    j     1b
3:  ret

# puthex(a0 = value): 8 hex digits
puthex:
    li    t2, 28
1:  srl   t0, a0, t2
    andi  t0, t0, 15
    addi  t0, t0, '0'
    li    t1, '9'
    bleu  t0, t1, 2f
    addi  t0, t0, 'a' - '9' - 1
2:  lbu   t1, UART_LSR(s0)
    andi  t1, t1, LSR_THRE
    beqz  t1, 2b
    sb    t0, 0(s0)
    addi  t2, t2, -4
    bgez  t2, 1b
    ret

msg_banner:   .asciz "\r\nQERV boot ROM\r\n"
msg_prompt:   .asciz "> "
msg_what:     .asciz "?\r\n"
msg_ok:       .asciz "ok "
msg_crlf:     .asciz "\r\n"
msg_memtest:  .asciz "memtest "
msg_fail:     .asciz " FAIL n="
msg_at:       .asciz " @"
msg_got:      .asciz " got "
msg_exp:      .asciz " exp "
msg_autoboot: .asciz "autoboot\r\n"
msg_noimage:  .asciz "no flash image\r\n"
msg_copy:     .asciz "flash image: copying"
msg_done:     .asciz " done\r\n"
msg_boot:     .asciz "boot\r\n"
msg_boot_s:   .asciz "boot S\r\n"
msg_mtrap:    .asciz "\r\nM trap: "
msg_status:   .asciz "status "
msg_nocalib:  .asciz "psram not calibrated\r\n"
