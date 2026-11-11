// rPLL for the QERV SoC: 27 MHz crystal -> the SoC clock and the PSRAM's CK clock.
// Written by hand from the IDE's generated rPLL (tang_nano_9K_ov7670 src/gowin_rpll), with
// static dividers and phase:
//   CLKOUT  = FCLKIN * (FBDIV_SEL + 1) / (IDIV_SEL + 1) = 27 * 14 / 9 = 42 MHz: the SoC clock
//   CLKOUTP = CLKOUT delayed by PSDA_SEL x 22.5 degrees = 90 degrees: the PSRAM controller's
//             CK (rtl/psram/hyperram_x16.v; the board passes 22.5 to 157.5 degrees)
//   PFD     = 27 / 9 = 3 MHz
//   VCO     = CLKOUT * ODIV_SEL = 42 * 16 = 672 MHz (400-1200 MHz)
// (Until 2026-11 it made memory_clk = 84 MHz for Gowin's PSRAM IP, whose clk_out was the SoC
// clock.) If this changes, also change the -multiply_by/-divide_by and -phase in
// tang9k_soc.sdc and CPU_HZ in fpga/build.sh.
module Gowin_rPLL (clkout, clkoutp, lock, clkin);

output clkout;
output clkoutp;
output lock;
input clkin;

wire clkoutd_o;
wire clkoutd3_o;
wire gw_gnd;

assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.IDIV_SEL = 8;
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.FBDIV_SEL = 13;
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.ODIV_SEL = 16;
defparam rpll_inst.PSDA_SEL = "0100";
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW1NR-9C";

endmodule //Gowin_rPLL
