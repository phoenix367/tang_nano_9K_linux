// Simulation stand-ins for the Gowin I/O primitives that rtl/psram/hyperram_x16.v uses, with
// the same cycle behaviour as Gowin's own models (IDE/simlib/gw1n/prim_sim.v), so the
// controller's tests run without a Gowin install (verif/psram16, scripts/ci.sh). Not for
// synthesis: GowinSyn has the real primitives.
//
// ODDR: D0/D1 are sampled at a rising edge and leave on the pin two edges later, D0 while CLK
//       is High, D1 while it is Low. TX (High = pin tristated) has the same pipeline and leaves
//       as Q1, the output-enable of the I/O buffer. Q0 starts at INIT.
// IDDR: Q0 is the pin sampled at a rising edge, Q1 at the falling edge after it; both are
//       presented together after the next rising edge.
`timescale 1ns / 1ps
`default_nettype none

module ODDR #(
    parameter [0:0] TXCLK_POL = 1'b0,
    parameter [0:0] INIT      = 1'b0
) (
    input  wire D0,
    input  wire D1,
    input  wire TX,
    input  wire CLK,
    output wire Q0,
    output wire Q1
);
  reg d0a = INIT, d1a = INIT, d0b = INIT, d1b = INIT, d0c = INIT, d1c = INIT;
  reg ta = 1'b0, tb = 1'b0, tc = 1'b0, td = 1'b0;
  always @(posedge CLK) begin
    d0a <= D0; d1a <= D1; d0b <= d0a; d1b <= d1a;
    d1c <= d1b;
    ta <= TX; tb <= ta; td <= tc;
  end
  always @(negedge CLK) begin
    d0c <= d0b;
    tc <= tb;
  end
  assign Q0 = CLK ? d0c : d1c;
  assign Q1 = TXCLK_POL ? tc : td;
endmodule

module IDDR #(
    parameter [0:0] Q0_INIT = 1'b0,
    parameter [0:0] Q1_INIT = 1'b0
) (
    input  wire D,
    input  wire CLK,
    output reg  Q0,
    output reg  Q1
);
  reg r = Q0_INIT, f = Q1_INIT;
  initial begin Q0 = Q0_INIT; Q1 = Q1_INIT; end
  always @(posedge CLK) begin
    r <= D; Q0 <= r; Q1 <= f;
  end
  always @(negedge CLK) f <= D;
endmodule

module ELVDS_OBUF (
    input  wire I,
    output wire O,
    output wire OB
);
  assign O  = I;
  assign OB = !I;
endmodule

`default_nettype wire
