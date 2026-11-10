// CLINT (SiFive layout) for the QERV SoC: msip @0x0000, mtimecmp @0x4000/0x4004,
// mtime @0xBFF8/0xBFFC. mtime counts at 1 MHz (DT timebase-frequency = 1000000, same as the
// mini-rv32ima emulator) from a CLK_HZ prescaler, or by one per i_tick pulse when
// EXT_TICK = 1 (simulation: tie time to retired instructions to compare with the emulator).
// mtip = mtime >= mtimecmp. msip is storage only (single hart, no software interrupt line).
`default_nettype none

module clint #(
    parameter CLK_HZ   = 27000000,
    parameter EXT_TICK = 0
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_tick,
    input  wire [15:2] i_adr,
    input  wire [31:0] i_dat,
    input  wire [ 3:0] i_sel,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    output wire        o_mtip
);

  localparam integer DIV_I = CLK_HZ / 1000000;
  localparam [15:0]  DIV   = DIV_I[15:0];

  reg [63:0] mtime, mtimecmp;
  reg        msip;
  reg [15:0] pre;

  assign o_mtip = mtime >= mtimecmp;

  wire       access = i_cyc & !o_ack;
  wire [13:0] a = i_adr[15:2];
  localparam [13:0] A_MSIP = 14'h0000, A_CMPL = 14'h1000, A_CMPH = 14'h1001,
                    A_TIML = 14'h2FFE, A_TIMH = 14'h2FFF;

  function [31:0] merge(input [31:0] old, input [31:0] new_v, input [3:0] sel);
    merge = {sel[3] ? new_v[31:24] : old[31:24], sel[2] ? new_v[23:16] : old[23:16],
             sel[1] ? new_v[15:8] : old[15:8], sel[0] ? new_v[7:0] : old[7:0]};
  endfunction

  wire last = pre == DIV - 16'd1;
  wire tick = EXT_TICK ? i_tick : last;

  always @(posedge i_clk) begin
    o_ack <= i_cyc & !o_ack;
    pre   <= last ? 16'd0 : pre + 16'd1;
    if (tick) mtime <= mtime + 64'd1;

    case (a)
      A_MSIP: o_rdt <= {31'd0, msip};
      A_CMPL: o_rdt <= mtimecmp[31:0];
      A_CMPH: o_rdt <= mtimecmp[63:32];
      A_TIML: o_rdt <= mtime[31:0];
      A_TIMH: o_rdt <= mtime[63:32];
      default: o_rdt <= 32'd0;
    endcase

    if (access & i_we)
      case (a)
        A_MSIP: if (i_sel[0]) msip <= i_dat[0];
        A_CMPL: mtimecmp[31:0] <= merge(mtimecmp[31:0], i_dat, i_sel);
        A_CMPH: mtimecmp[63:32] <= merge(mtimecmp[63:32], i_dat, i_sel);
        A_TIML: mtime[31:0] <= merge(mtime[31:0], i_dat, i_sel);
        A_TIMH: mtime[63:32] <= merge(mtime[63:32], i_dat, i_sel);
        default: ;
      endcase

    if (i_rst) begin
      o_ack    <= 1'b0;
      pre      <= 16'd0;
      mtime    <= 64'd0;
      mtimecmp <= {64{1'b1}};
      msip     <= 1'b0;
    end
  end

endmodule

`default_nettype wire
