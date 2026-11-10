// PSRAM command arbiter and IP register stage (doc/video_plan.md). Two masters share the
// two channels of the Gowin PSRAM HS 2ch IP:
//   C: the L1 cache (line fills, write-backs, uncached word accesses): reads and writes
//   D: the video DMA: reads only
// Rules from the IP (rtl/sim/psram_ui_model.v): commands on one channel are >= TCMD cycles
// apart; a write's 8 data beats are on wr_data/data_mask from the command cycle on; a
// read's 8 beats come back flagged by rd_data_valid, in order.
//
// Grant (combinational, in the cycle a master asks): the cache goes first; the DMA gets a
// channel the cache is not taking, or goes first while it flags i_d_urgent (its line
// deadline is near). Both channels' wr_data/data_mask carry the cache's single write
// stream, so a write is not granted within 8 cycles of another write on either channel.
// All IP inputs are registered here: a granted command reaches the IP on the next edge, and
// write beat k (i_c_wdata/i_c_wmask k cycles after the grant) on edge k after that.
//
// Read beats go to the master whose read is the oldest outstanding on that channel (a read
// 19 cycles after another may be issued while that one's beats still arrive, so up to two).
// Each master keeps its own reads from returning beats in the same cycle on both channels
// (the cache has one read at a time; the DMA spaces its reads).
`default_nettype none

module psram_arb #(
    parameter TCMD = 19
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_calib,           // init_calib0 & init_calib1
    // cache: byte address bits 22:2 (bit 22 = channel); a line burst is 32 B aligned
    input  wire        i_c_req,
    input  wire        i_c_we,
    input  wire [22:2] i_c_adr,
    output wire        o_c_gnt,
    input  wire [31:0] i_c_wdata,
    input  wire [ 3:0] i_c_wmask,         // data_mask: 1 = byte not written
    output wire        o_c_rvalid,
    output wire [31:0] o_c_rdata,
    // video DMA (reads)
    input  wire        i_d_req,
    input  wire        i_d_urgent,
    input  wire [22:2] i_d_adr,
    output wire        o_d_gnt,
    output wire        o_d_rvalid,
    output wire [31:0] o_d_rdata,
    // PSRAM IP user interface
    output reg         o_cmd0,
    output reg         o_cmd_en0,
    output reg  [20:0] o_addr0,
    output reg  [31:0] o_wr_data0,
    output reg  [ 3:0] o_data_mask0,
    input  wire [31:0] i_rd_data0,
    input  wire        i_rd_data_valid0,
    output reg         o_cmd1,
    output reg         o_cmd_en1,
    output reg  [20:0] o_addr1,
    output reg  [31:0] o_wr_data1,
    output reg  [ 3:0] o_data_mask1,
    input  wire [31:0] i_rd_data1,
    input  wire        i_rd_data_valid1
);

  reg [4:0] cnt0, cnt1;                   // cycles until the channel takes a command
  reg [2:0] wcnt;                         // cycles until the write stream is free
  wire      free0 = i_calib & (cnt0 == 5'd0);
  wire      free1 = i_calib & (cnt1 == 5'd0);

  wire c_ch = i_c_adr[22];
  wire d_ch = i_d_adr[22];
  wire same = c_ch == d_ch;
  assign o_c_gnt = i_c_req & (c_ch ? free1 : free0) & !(i_c_we & (wcnt != 3'd0)) &
                   !(i_d_req & i_d_urgent & same);
  assign o_d_gnt = i_d_req & (d_ch ? free1 : free0) & !(o_c_gnt & same);

  wire c0 = o_c_gnt & !c_ch, c1 = o_c_gnt & c_ch;
  wire d0 = o_d_gnt & !d_ch, d1 = o_d_gnt & d_ch;

  // read owners per channel: q[0] = oldest outstanding read (1 = DMA), n = how many
  reg [1:0] q0, q1, n0, n1;
  reg [2:0] beat0, beat1;
  wire      rd0 = (c0 & !i_c_we) | d0;    // a read is issued now
  wire      rd1 = (c1 & !i_c_we) | d1;
  wire      done0 = i_rd_data_valid0 & (beat0 == 3'd7);
  wire      done1 = i_rd_data_valid1 & (beat1 == 3'd7);

  assign o_c_rvalid = (i_rd_data_valid0 & !q0[0]) | (i_rd_data_valid1 & !q1[0]);
  assign o_c_rdata  = (i_rd_data_valid1 & !q1[0]) ? i_rd_data1 : i_rd_data0;
  assign o_d_rvalid = (i_rd_data_valid0 & q0[0]) | (i_rd_data_valid1 & q1[0]);
  assign o_d_rdata  = (i_rd_data_valid1 & q1[0]) ? i_rd_data1 : i_rd_data0;

  // push (owner d) at index n - done, after popping the head when done
  function [1:0] q_next(input [1:0] q, input [1:0] n, input push, input d, input pop);
    reg [1:0] r;
    reg [1:0] m;
    begin
      r = pop ? {1'b0, q[1]} : q;
      m = pop ? n - 2'd1 : n;
      if (push) r[m[0]] = d;
      q_next = r;
    end
  endfunction

  always @(posedge i_clk) begin
    cnt0 <= (c0 | d0) ? TCMD[4:0] - 5'd1 : (cnt0 != 5'd0) ? cnt0 - 5'd1 : 5'd0;
    cnt1 <= (c1 | d1) ? TCMD[4:0] - 5'd1 : (cnt1 != 5'd0) ? cnt1 - 5'd1 : 5'd0;
    wcnt <= (o_c_gnt & i_c_we) ? 3'd7 : (wcnt != 3'd0) ? wcnt - 3'd1 : 3'd0;

    q0 <= q_next(q0, n0, rd0, d0, done0);
    q1 <= q_next(q1, n1, rd1, d1, done1);
    n0 <= n0 + {1'b0, rd0} - {1'b0, done0};
    n1 <= n1 + {1'b0, rd1} - {1'b0, done1};
    if (i_rd_data_valid0) beat0 <= beat0 + 3'd1;
    if (i_rd_data_valid1) beat1 <= beat1 + 3'd1;

    o_cmd_en0 <= c0 | d0;
    o_cmd_en1 <= c1 | d1;
    if (c0 | d0) begin
      o_cmd0  <= c0 & i_c_we;
      o_addr0 <= c0 ? {i_c_adr[21:2], 1'b0} : {i_d_adr[21:2], 1'b0};
    end
    if (c1 | d1) begin
      o_cmd1  <= c1 & i_c_we;
      o_addr1 <= c1 ? {i_c_adr[21:2], 1'b0} : {i_d_adr[21:2], 1'b0};
    end
    o_wr_data0   <= i_c_wdata;
    o_wr_data1   <= i_c_wdata;
    o_data_mask0 <= i_c_wmask;
    o_data_mask1 <= i_c_wmask;

    if (i_rst) begin
      cnt0 <= 5'd0;
      cnt1 <= 5'd0;
      wcnt <= 3'd0;
      q0 <= 2'b00;
      q1 <= 2'b00;
      n0 <= 2'd0;
      n1 <= 2'd0;
      beat0 <= 3'd0;
      beat1 <= 3'd0;
      o_cmd_en0 <= 1'b0;
      o_cmd_en1 <= 1'b0;
    end
  end

endmodule

`default_nettype wire
