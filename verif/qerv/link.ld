/* Directed tests: everything in RAM at 0x80000000 (the TB decodes only the low bits). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text) }
  . = ALIGN(16);
  .data : { *(.data) }
  .bss : { *(.bss) }
}
