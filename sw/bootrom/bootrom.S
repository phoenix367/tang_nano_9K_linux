# QERV SoC boot ROM (0x00000000, reset vector).
#
# 1. Print a banner on the UART.
# 2. If the SPI flash (window at 0x20000000) starts with the stage-1 header (sw/mkflash.py),
#    copy the DTB to DTB_ADDR and the kernel Image to 0x80000000, one '.' per 64 KB.
#    Otherwise assume a testbench preloaded RAM and say so.
# 3. Enter the kernel as the RISC-V boot protocol (and the mini-rv32ima emulator) expects:
#    a0 = hart id, a1 = DTB address.
#
# Flash layout: 0x0000 header {magic "QRVL", image_len, dtb_len, 0}, 0x1000 DTB, 0x2000 Image.

#define UART      0x10000000
#define UART_LSR  5
#define LSR_THRE  0x20
#define FLASH     0x20000000
#define MAGIC     0x4c565251          /* "QRVL" little-endian */
#define RAM_BASE  0x80000000
#define DTB_ADDR  0x807FF000          /* top 4 KB of the 8 MB PSRAM */

    .section .text
    .globl _start
_start:
    li    s0, UART
    la    a0, msg_banner
    jal   puts

    li    s1, FLASH
    lw    t0, 0(s1)
    li    t1, MAGIC
    bne   t0, t1, no_image

    la    a0, msg_copy
    jal   puts
    lw    s2, 4(s1)                   # image length
    lw    s3, 8(s1)                   # dtb length
    li    a0, FLASH + 0x1000          # DTB
    li    a1, DTB_ADDR
    mv    a2, s3
    jal   copy
    li    a0, FLASH + 0x2000          # Image
    li    a1, RAM_BASE
    mv    a2, s2
    jal   copy
    la    a0, msg_done
    jal   puts
    j     boot

no_image:
    la    a0, msg_preload
    jal   puts

boot:
    li    a0, 0
    li    a1, DTB_ADDR
    li    t0, RAM_BASE
    jr    t0

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

# puts(a0 = string): polled UART output
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

msg_banner:  .asciz "\r\nQERV boot ROM\r\n"
msg_copy:    .asciz "flash image: copying"
msg_done:    .asciz " done\r\n"
msg_preload: .asciz "no flash image: using preloaded RAM\r\n"
