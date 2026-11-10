// Build-time configuration for the KianV no-MMU core (the uLinux SoC). Listed FIRST in
// the .gprj so the macro reaches every KianV file in the same compilation unit.
// Upstream's ULX3S build uses the shift-add multiplier; the DSP one is used here to match
// the SV32 probe (the 9K's DSP blocks are otherwise idle).
`ifndef KIANV_NOMMU_CFG_V
`define KIANV_NOMMU_CFG_V
`define FPGA_MULTIPLIER
`endif
