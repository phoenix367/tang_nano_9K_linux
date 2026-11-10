/* Bare-metal layout for the SERV CPI bench: 256 KiB RAM from address 0 (servant_ram). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x40000
}

SECTIONS
{
  . = 0x00000000;
  .text : { *(.text.start) *(.text) *(.text.*) } > RAM
  .data 0x00030000 : { *(.data) *(.data.*) *(.rodata) *(.rodata.*) } > RAM
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note.gnu.build-id) }
}
