// PSRAM probe for the 16-bit HyperRAM controller (rtl/psram/hyperram_x16.v): both on-package
// dies in lockstep as one 16-bit bus at CK = 42 MHz, no CPU. Built by fpga/probe_psram16/run.sh
// with the CK phase (rPLL CLKOUTP, PSDA_SEL) and the test size as defines.
//
// The controller is set up as in the SoC (fpga/src/tang9k_top.v): CR0 = 0x8FEE (latency 3
// fixed, 16-byte wrapped bursts per die), die 0's true clock on O_psram_ck[0], die 1's on
// O_psram_ck_n[1]. The test writes the whole 8 MB in full-line commands from a 32-bit LFSR
// stream and reads it back with the reads issued back to back (as fast as o_ready allows), then
// repeats with the stream inverted (every bit 0 and 1). Afterwards it prints one line every 2 s
// on the UART (1 Mbaud, 42 clocks per bit):
//   TTTT e0=XXXXXX e1=XXXXXX s0=XXXXX s1=XXXXX L=XXXX A=X F=D:LLLLL:B:EEEE:GGGG t=XXXXXXX
// e0/e1 wrong 16-bit words per die, s0/s1 filler words per die (o_rerr: the die delivered
// fewer than 8 words in its capture window), L the bus cycle of each die's first word in the
// last read (2 hex digits per die), A its capture alignment bits, F the first wrong word (die,
// line, beat, expected, got), t the test's clock cycles (both passes, from the first
// command; 18 per command when the reads run back to back).
// History: the first version (2026-11-11, on the controller's first interface) tried both
// clock pins of both dies; only the wiring above works, at every phase from 22.5 to 157.5
// degrees (doc/psram_controller.md).
// LEDs (active low): 0 heartbeat, 1 PLL lock, 2 test done, 3 any error, 4 die 0 error,
// 5 die 1 error.
`default_nettype none

module psram16_probe_top (
    input  wire        clk_27m,
    input  wire        btn_rst_n,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire [ 5:0] led_n,
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n
);
`ifndef PROBE_TAG
  `define PROBE_TAG "sim0"
`endif
`ifndef PROBE_PSDA
  `define PROBE_PSDA "0100"
`endif
`ifndef PROBE_LINES
  `define PROBE_LINES 262144
`endif
`ifndef PROBE_INIT_US
  `define PROBE_INIT_US 160
`endif
  localparam integer LINES = `PROBE_LINES;

  // ---------------------------------------------------------------- clocks and reset
  wire clk, clk_p, pll_lock;
`ifdef PROBE_SIM
  assign clk = tb_psram16.clk;
  assign clk_p = tb_psram16.clk_p;
  assign pll_lock = 1'b1;
`else
  wire gnd = 1'b0;
  wire clkoutd_o, clkoutd3_o;
  rPLL rpll_inst (
      .CLKOUT(clk), .LOCK(pll_lock), .CLKOUTP(clk_p), .CLKOUTD(clkoutd_o),
      .CLKOUTD3(clkoutd3_o), .RESET(gnd), .RESET_P(gnd), .CLKIN(clk_27m), .CLKFB(gnd),
      .FBDSEL({6{gnd}}), .IDSEL({6{gnd}}), .ODSEL({6{gnd}}), .PSDA({4{gnd}}),
      .DUTYDA({4{gnd}}), .FDLY({4{gnd}})
  );
  defparam rpll_inst.FCLKIN = "27";
  defparam rpll_inst.DYN_IDIV_SEL = "false";
  defparam rpll_inst.IDIV_SEL = 8;            // 27 / 9 * 14 = 42 MHz, VCO 672 MHz
  defparam rpll_inst.DYN_FBDIV_SEL = "false";
  defparam rpll_inst.FBDIV_SEL = 13;
  defparam rpll_inst.DYN_ODIV_SEL = "false";
  defparam rpll_inst.ODIV_SEL = 16;
  defparam rpll_inst.PSDA_SEL = `PROBE_PSDA;  // CLKOUTP phase, 22.5 degrees per step
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
`endif

  // power-on: ~10 ms on the crystal, then the button; synchronized into clk
  reg [18:0] por = 19'd0;
  always @(posedge clk_27m) if (!por[18]) por <= por + 19'd1;
`ifdef PROBE_SIM
  wire rst_in_n = pll_lock & btn_rst_n;
`else
  wire rst_in_n = por[18] & pll_lock & btn_rst_n;
`endif
  reg [3:0] rs = 4'd0;
  always @(posedge clk or negedge rst_in_n)
    if (!rst_in_n) rs <= 4'd0; else rs <= {rs[2:0], 1'b1};
  wire rst = !rs[3];

  // ---------------------------------------------------------------- controller
  wire        init_done, ready, wnext, rvalid;
  wire [ 2:0] wbeat;
  wire [31:0] rdata;
  wire [ 1:0] rerr, ralign;
  wire [ 5:0] rlat0, rlat1;
  reg         cmd_en, cmd_we;
  reg  [17:0] line;                            // the command's line
  reg  [31:0] lw;                              // write stream
  reg         invert;                          // second pass: the stream inverted

  hyperram_x16 #(.CLK_HZ(42000000), .INIT_US(`PROBE_INIT_US), .LC(3)) ram (
      .clk(clk), .clk_p(clk_p), .rst(rst),
      .i_init(1'b0), .i_cr0(16'h8FEE), .i_ck_inv(2'b10), .o_init_done(init_done),
      .o_ready(ready), .i_cmd_en(cmd_en), .i_cmd_we(cmd_we), .i_addr({line, 3'b000}),
      .o_wnext(wnext), .o_wbeat(wbeat), .i_wdata(lw ^ {32{invert}}), .i_wmask(4'b0000),
      .i_wlast(wbeat == 3'd7),
      .o_rvalid(rvalid), .o_rdata(rdata), .o_rerr(rerr),
      .o_rlat0(rlat0), .o_rlat1(rlat1), .o_ralign(ralign), .o_dbg_rw(), .o_dbg_dq(),
      .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .IO_psram_rwds(IO_psram_rwds),
      .O_psram_reset_n(O_psram_reset_n), .IO_psram_dq(IO_psram_dq), .O_psram_cs_n(O_psram_cs_n)
  );

  // ---------------------------------------------------------------- test sequencer
  function [31:0] lfsr(input [31:0] v);      // Galois, x^32 + x^22 + x^2 + x + 1
    lfsr = {1'b0, v[31:1]} ^ (v[0] ? 32'h80200003 : 32'd0);
  endfunction
  localparam [31:0] SEED = 32'h1234_5678;

  localparam [2:0] T_INIT = 3'd0, T_WRITE = 3'd1, T_READ = 3'd2, T_DRAIN = 3'd3, T_DONE = 3'd4;
  reg  [ 2:0] ts;
  reg  [31:0] lr;                              // read: the expected stream
  reg  [20:0] rbeats;                          // read beats received in this pass
  reg  [23:0] e0, e1;
  reg  [19:0] s0, s1;
  reg         fe;                              // first error recorded
  reg  [53:0] fi;                              // {die, line[17:0], beat, expected, got}
  reg  [27:0] tcyc;
  reg         done;
  wire [31:0] x = lr ^ {32{invert}};

  always @(posedge clk) begin
    if (cmd_en && ready) begin                 // the command is taken
      cmd_en <= 1'b0;
      line   <= line + 18'd1;
    end
    if (wnext) lw <= lfsr(lw);
    if (rvalid) begin
      lr <= lfsr(lr);
      rbeats <= rbeats + 21'd1;
      if (rerr[0]) s0 <= s0 + 20'd1;
      else if (rdata[15:0] != x[15:0]) begin
        if (e0 != 24'hFFFFFF) e0 <= e0 + 24'd1;
        if (!fe) begin fe <= 1'b1; fi <= {1'b0, rbeats[20:3], rbeats[2:0], x[15:0], rdata[15:0]}; end
      end
      if (rerr[1]) s1 <= s1 + 20'd1;
      else if (rdata[31:16] != x[31:16]) begin
        if (e1 != 24'hFFFFFF) e1 <= e1 + 24'd1;
        if (!fe && !(rdata[15:0] != x[15:0] && !rerr[0])) begin
          fe <= 1'b1; fi <= {1'b1, rbeats[20:3], rbeats[2:0], x[31:16], rdata[31:16]};
        end
      end
    end
    if (!done) tcyc <= tcyc + 28'd1;
    if (rst) begin
      ts <= T_INIT; done <= 1'b0; cmd_en <= 1'b0; invert <= 1'b0; tcyc <= 28'd0;
      e0 <= 24'd0; e1 <= 24'd0; s0 <= 20'd0; s1 <= 20'd0; fe <= 1'b0; fi <= 54'd0;
    end else case (ts)
      T_INIT: if (init_done) begin
        line <= 18'd0; lw <= SEED; cmd_en <= 1'b1; cmd_we <= 1'b1; ts <= T_WRITE;
        if (!invert) tcyc <= 28'd0;            // from the first command on
      end
      // one command at a time: the next is raised after the last is taken (cmd_en Low)
      T_WRITE: if (!cmd_en) begin
        if (line == LINES[17:0]) begin
          line <= 18'd0; lr <= SEED; rbeats <= 21'd0; cmd_en <= 1'b1; cmd_we <= 1'b0;
          ts <= T_READ;
        end else cmd_en <= 1'b1;
      end
      T_READ: if (!cmd_en) begin
        if (line == LINES[17:0]) ts <= T_DRAIN;
        else cmd_en <= 1'b1;
      end
      T_DRAIN: if (rbeats == LINES * 8) begin
        if (!invert) begin invert <= 1'b1; ts <= T_INIT; end
        else begin ts <= T_DONE; done <= 1'b1; end
      end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- report
  function [7:0] hx(input [3:0] v);
    hx = v < 10 ? 8'h30 + v : 8'h57 + v;
  endfunction
  localparam integer N = 87;
  wire [8*N-1:0] msg = {`PROBE_TAG,
      " e0=", hx(e0[23:20]), hx(e0[19:16]), hx(e0[15:12]), hx(e0[11:8]), hx(e0[7:4]), hx(e0[3:0]),
      " e1=", hx(e1[23:20]), hx(e1[19:16]), hx(e1[15:12]), hx(e1[11:8]), hx(e1[7:4]), hx(e1[3:0]),
      " s0=", hx(s0[19:16]), hx(s0[15:12]), hx(s0[11:8]), hx(s0[7:4]), hx(s0[3:0]),
      " s1=", hx(s1[19:16]), hx(s1[15:12]), hx(s1[11:8]), hx(s1[7:4]), hx(s1[3:0]),
      " L=", hx({2'b00, rlat0[5:4]}), hx(rlat0[3:0]), hx({2'b00, rlat1[5:4]}), hx(rlat1[3:0]),
      " A=", hx({2'b00, ralign}),
      " F=", hx({3'b000, fi[53]}), ":", hx({2'b00, fi[52:51]}), hx(fi[50:47]), hx(fi[46:43]),
             hx(fi[42:39]), hx(fi[38:35]), ":", hx({1'b0, fi[34:32]}), ":",
             hx(fi[31:28]), hx(fi[27:24]), hx(fi[23:20]), hx(fi[19:16]), ":",
             hx(fi[15:12]), hx(fi[11:8]), hx(fi[7:4]), hx(fi[3:0]),
      " t=", hx(tcyc[27:24]), hx(tcyc[23:20]), hx(tcyc[19:16]), hx(tcyc[15:12]), hx(tcyc[11:8]),
             hx(tcyc[7:4]), hx(tcyc[3:0]), 8'h0d, 8'h0a};

  reg [8*N-1:0] snap;
  reg [ 7:0]    idx;
  reg [ 9:0]    sh;
  reg [ 3:0]    bits;
  reg [ 5:0]    div;
  reg [26:0]    gap;
  always @(posedge clk) begin
    if (rst) begin
      idx <= N[7:0]; sh <= 10'h3FF; bits <= 4'd0; div <= 6'd0; gap <= 27'd0;
    end else if (bits == 4'd0) begin
      if (idx < N[7:0]) begin
        sh <= {1'b1, snap[8*(N-1-idx) +: 8], 1'b0}; bits <= 4'd10; div <= 6'd0;
        idx <= idx + 8'd1;
      end else if (done) begin
        // the first line at once, then one every 2 s: the board's USB-UART bridge (BL702)
        // has locked up under a continuous 1 Mbaud stream that nobody read
        if (gap == 27'd0) begin snap <= msg; idx <= 8'd0; end
        gap <= (gap == 27'd84000000) ? 27'd0 : gap + 27'd1;
      end
    end else if (div == 6'd41) begin
      div <= 6'd0; sh <= {1'b1, sh[9:1]}; bits <= bits - 4'd1;
    end else
      div <= div + 6'd1;
  end
  assign uart_tx = sh[0];

  reg [24:0] beat = 25'd0;
  always @(posedge clk) beat <= beat + 25'd1;
  wire any0 = e0 != 0 || s0 != 0;
  wire any1 = e1 != 0 || s1 != 0;
  assign led_n = ~{any1, any0, any0 | any1, done, pll_lock, beat[24]};
  wire unused = uart_rx;

endmodule

`default_nettype wire
