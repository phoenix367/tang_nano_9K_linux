// PSRAM probe for a self-written controller (rtl/psram/hyperram_x16.v): both on-package dies in
// lockstep as one 16-bit bus at CK = 42 MHz, no CPU. Built by fpga/probe_psram16/run.sh with
// the CK phase (rPLL CLKOUTP, PSDA_SEL) and the test size as defines.
//
// The test runs four configurations, each from a RESET# and a CR0 write (latency 3 fixed,
// drive strength 34 ohms; 115 ohms made no difference on the board):
//   cfg bit 0: die 1's true clock on O_psram_ck_n[1] (0; what the Gowin IP does) or on
//              O_psram_ck[1] (1; what some open designs do)
//   cfg bit 1: die 0's true clock on O_psram_ck[0] (0) or on O_psram_ck_n[0] (1)
// For each it writes the whole 8 MB from a 32-bit LFSR stream and reads it back, then repeats
// with the stream inverted (every bit 0 and 1), counting wrong 16-bit words per die and reads
// where a die delivered fewer than 8 words. Afterwards it prints one line per configuration,
// every 2 s, on the UART (1 Mbaud, 42 clocks per bit):
//   TTTT cN cr=XXXX iv=X e0=XXXXXX e1=XXXXXX s0=XXXXX s1=XXXXX L=XXXX A=X F=D:LLLLL:B:EEEE:GGGG
// e0/e1 wrong words per die, s0/s1 short reads per die, L the bus cycle of each die's first
// read word, A the capture alignment bits, F the first error (die, line, beat, expected, got).
// Then trace lines for configurations 0 and 2 (die 1's clock right, die 0's both ways): the
// raw IDDR samples of their first read (line 0) for bus cycles 8..27, one hex digit of RWDS
// {d1 Q1, Q0, d0 Q1, Q0} and 4 hex digits of DQ {Q0 byte, Q1 byte} per die and cycle:
//   TTTT tN rw=<20 digits> d0=<20 x 4 digits> d1=<20 x 4 digits>
// On the board the trace keeps only every other cycle's bytes (the tools put the shift
// registers into block RAM); it still shows whether and when a die drives RWDS and DQ.
// Result on the board (2026-11-11): configuration 0 (die 0's clock on O_psram_ck[0], die 1's
// on O_psram_ck_n[1]) passes on both dies at every phase from 22.5 to 157.5 degrees.
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
  reg         init;
  reg  [15:0] cr0;
  reg  [ 1:0] inv;
  reg         req, we;
  reg  [17:0] line;
  wire        ready, wnext, rv0, rv1, rdone;
  wire [ 2:0] wbeat, rb0, rb1;
  wire [15:0] rd0, rd1;
  wire [ 1:0] rshort, ralign;
  wire [ 5:0] rlat0, rlat1;
  wire        dbg_rd;
  wire [ 5:0] dbg_c;
  wire [ 3:0] dbg_rw;
  wire [31:0] dbg_dq;
  reg  [31:0] lw;                              // write stream
  reg         invert;                          // second pass: the stream inverted

  hyperram_x16 #(.CLK_HZ(42000000), .INIT_US(`PROBE_INIT_US), .LC(3)) ram (
      .clk(clk), .clk_p(clk_p), .rst(rst),
      .i_init(init), .i_cr0(cr0), .i_ck_inv(inv), .o_ready(ready),
      .i_req(req), .i_we(we), .i_line(line),
      .o_wnext(wnext), .o_wbeat(wbeat), .i_wdata(lw ^ {32{invert}}), .i_wmask(4'b0000),
      .o_rvalid0(rv0), .o_rdata0(rd0), .o_rvalid1(rv1), .o_rdata1(rd1),
      .o_rbeat0(rb0), .o_rbeat1(rb1), .o_rdone(rdone), .o_rshort(rshort),
      .o_rlat0(rlat0), .o_rlat1(rlat1), .o_ralign(ralign),
      .o_dbg_rd(dbg_rd), .o_dbg_c(dbg_c), .o_dbg_rw(dbg_rw), .o_dbg_dq(dbg_dq),
      .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .IO_psram_rwds(IO_psram_rwds),
      .O_psram_reset_n(O_psram_reset_n), .IO_psram_dq(IO_psram_dq), .O_psram_cs_n(O_psram_cs_n)
  );

  // ---------------------------------------------------------------- test sequencer
  function [31:0] lfsr(input [31:0] v);      // Galois, x^32 + x^22 + x^2 + x + 1
    lfsr = {1'b0, v[31:1]} ^ (v[0] ? 32'h80200003 : 32'd0);
  endfunction
  localparam [31:0] SEED = 32'h1234_5678;

  localparam [3:0] T_INIT = 4'd0, T_WAITR = 4'd1, T_WREQ = 4'd2, T_WWAIT = 4'd3,
                   T_RREQ = 4'd4, T_RWAIT = 4'd5, T_NEXT = 4'd6, T_DONE = 4'd7;
  reg  [ 3:0] ts;
  reg  [ 1:0] cfg;
  reg         pass;
  reg  [31:0] lr, l0, l1;                      // read: line start, die 0 / die 1 expected
  reg  [ 3:0] lr_steps;
  // results per configuration
  reg  [23:0] e0 [0:3], e1 [0:3];
  reg  [19:0] s0 [0:3], s1 [0:3];
  reg  [ 5:0] la0 [0:3], la1 [0:3];
  reg  [ 1:0] al [0:3];
  reg         fe [0:3];                        // first error recorded
  reg  [53:0] fi [0:3];                        // {die, line[17:0], beat, expected, got}
  reg         done;
  integer     k;
  // raw trace of the first read of configurations 0 and 2, bus cycles 8..27: a shift register
  // of 20 samples {rw[3:0], dq[31:0]} each, the oldest at the top
  reg  [719:0] trf [0:1];
  reg          tr_on;
  always @(posedge clk)
    if (tr_on && !cfg[0] && dbg_rd && dbg_c >= 6'd8 && dbg_c < 6'd28)
      trf[cfg[1]] <= {trf[cfg[1]][683:0], dbg_rw, dbg_dq};

  wire [15:0] x0 = l0[15:0] ^ {16{invert}};
  wire [15:0] x1 = l1[31:16] ^ {16{invert}};

  always @(posedge clk) begin
    init <= 1'b0; req <= 1'b0;
    if (wnext) lw <= lfsr(lw);
    if (rv0) begin
      l0 <= lfsr(l0);
      if (rd0 != x0) begin
        if (e0[cfg] != 24'hFFFFFF) e0[cfg] <= e0[cfg] + 24'd1;
        if (!fe[cfg]) begin fe[cfg] <= 1'b1; fi[cfg] <= {1'b0, line, rb0, x0, rd0}; end
      end
    end
    if (rv1) begin
      l1 <= lfsr(l1);
      if (rd1 != x1) begin
        if (e1[cfg] != 24'hFFFFFF) e1[cfg] <= e1[cfg] + 24'd1;
        if (!fe[cfg]) begin fe[cfg] <= 1'b1; fi[cfg] <= {1'b1, line, rb1, x1, rd1}; end
      end
    end
    if (lr_steps != 4'd0) begin lr <= lfsr(lr); lr_steps <= lr_steps - 4'd1; end
    if (rst) begin
      ts <= T_INIT; cfg <= 2'd0; done <= 1'b0;
      for (k = 0; k < 4; k = k + 1) begin
        e0[k] <= 24'd0; e1[k] <= 24'd0; s0[k] <= 20'd0; s1[k] <= 20'd0; fe[k] <= 1'b0;
        fi[k] <= 54'd0; la0[k] <= 6'd0; la1[k] <= 6'd0; al[k] <= 2'd0;
      end
      lr_steps <= 4'd0;
    end else case (ts)
      T_INIT: begin
        cr0  <= 16'h8FEF;                        // latency 3 fixed, legacy wrap 32 B
        inv  <= {!cfg[0], cfg[1]};
        init <= 1'b1; pass <= 1'b0; ts <= T_WAITR;
      end
      T_WAITR: if (ready && !init) begin
        line <= 18'd0; lw <= SEED; invert <= pass; ts <= T_WREQ;
      end
      T_WREQ: if (ready) begin req <= 1'b1; we <= 1'b1; ts <= T_WWAIT; end
      T_WWAIT: if (!req && ready) begin
        if (line == LINES - 1) begin line <= 18'd0; lr <= SEED; ts <= T_RREQ; end
        else begin line <= line + 18'd1; req <= 1'b1; end
      end
      T_RREQ: if (ready && lr_steps == 4'd0) begin
        req <= 1'b1; we <= 1'b0; l0 <= lr; l1 <= lr; lr_steps <= 4'd8; ts <= T_RWAIT;
        tr_on <= !pass && line == 18'd0;
      end
      T_RWAIT: if (rdone) begin
        tr_on <= 1'b0;
        if (rshort[0]) s0[cfg] <= s0[cfg] + 20'd1;
        if (rshort[1]) s1[cfg] <= s1[cfg] + 20'd1;
        la0[cfg] <= rlat0; la1[cfg] <= rlat1; al[cfg] <= ralign;
        if (line == LINES - 1) ts <= T_NEXT;
        else begin line <= line + 18'd1; ts <= T_RREQ; end
      end
      T_NEXT: begin
        if (!pass) begin pass <= 1'b1; ts <= T_WAITR; end
        else if (cfg != 2'd3) begin cfg <= cfg + 2'd1; ts <= T_INIT; end
        else begin ts <= T_DONE; done <= 1'b1; end
      end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- report
  function [7:0] hx(input [3:0] v);
    hx = v < 10 ? 8'h30 + v : 8'h57 + v;
  endfunction
  reg  [ 2:0] rc;                              // 0..3 result lines, 4..5 trace lines
  wire [53:0] f = fi[rc[1:0]];
  localparam integer N = 93;
  wire [8*N-1:0] msg = {`PROBE_TAG, " c", hx({2'b00, rc[1:0]}),
      " cr=", "8fef", " iv=", hx({2'b00, !rc[0], rc[1]}),
      " e0=", hx(e0[rc[1:0]][23:20]), hx(e0[rc[1:0]][19:16]), hx(e0[rc[1:0]][15:12]), hx(e0[rc[1:0]][11:8]),
              hx(e0[rc[1:0]][7:4]), hx(e0[rc[1:0]][3:0]),
      " e1=", hx(e1[rc[1:0]][23:20]), hx(e1[rc[1:0]][19:16]), hx(e1[rc[1:0]][15:12]), hx(e1[rc[1:0]][11:8]),
              hx(e1[rc[1:0]][7:4]), hx(e1[rc[1:0]][3:0]),
      " s0=", hx(s0[rc[1:0]][19:16]), hx(s0[rc[1:0]][15:12]), hx(s0[rc[1:0]][11:8]), hx(s0[rc[1:0]][7:4]),
              hx(s0[rc[1:0]][3:0]),
      " s1=", hx(s1[rc[1:0]][19:16]), hx(s1[rc[1:0]][15:12]), hx(s1[rc[1:0]][11:8]), hx(s1[rc[1:0]][7:4]),
              hx(s1[rc[1:0]][3:0]),
      " L=", hx({2'b00, la0[rc[1:0]][5:4]}), hx(la0[rc[1:0]][3:0]), hx({2'b00, la1[rc[1:0]][5:4]}),
             hx(la1[rc[1:0]][3:0]),
      " A=", hx({2'b00, al[rc[1:0]]}),
      " F=", hx({3'b000, f[53]}), ":", hx({2'b00, f[52:51]}), hx(f[50:47]), hx(f[46:43]),
             hx(f[42:39]), hx(f[38:35]), ":", hx({1'b0, f[34:32]}), ":",
             hx(f[31:28]), hx(f[27:24]), hx(f[23:20]), hx(f[19:16]), ":",
             hx(f[15:12]), hx(f[11:8]), hx(f[7:4]), hx(f[3:0]), 8'h0d, 8'h0a};

  // trace line: "TTTT tN rw=" 20 digits " d0=" 20 x {Q0 byte, Q1 byte} " d1=" the same
  localparam integer N2 = 201;
  wire [719:0] tr = trf[rc[0]];
  reg  [8*N2-1:0] msg2;
  integer j;
  always @* begin
    msg2 = {N2{8'h20}};
    msg2[8*N2-1 -: 88] = {`PROBE_TAG, " t", hx({2'b00, rc[0], 1'b0}), " rw="};
    msg2[8*(N2-31)-1 -: 32] = " d0=";
    msg2[8*(N2-115)-1 -: 32] = " d1=";
    for (j = 0; j < 20; j = j + 1) begin
      msg2[8*(N2-1-(11+j)) +: 8]      = hx(tr[719-36*j -: 4]);                 // rw
      msg2[8*(N2-1-(35+4*j)) +: 8]    = hx(tr[719-36*j-4-24 -: 4]);            // d0 Q0 hi
      msg2[8*(N2-1-(35+4*j+1)) +: 8]  = hx(tr[719-36*j-4-28 -: 4]);            // d0 Q0 lo
      msg2[8*(N2-1-(35+4*j+2)) +: 8]  = hx(tr[719-36*j-4-16 -: 4]);            // d0 Q1 hi
      msg2[8*(N2-1-(35+4*j+3)) +: 8]  = hx(tr[719-36*j-4-20 -: 4]);            // d0 Q1 lo
      msg2[8*(N2-1-(119+4*j)) +: 8]   = hx(tr[719-36*j-4-8 -: 4]);             // d1 Q0 hi
      msg2[8*(N2-1-(119+4*j+1)) +: 8] = hx(tr[719-36*j-4-12 -: 4]);            // d1 Q0 lo
      msg2[8*(N2-1-(119+4*j+2)) +: 8] = hx(tr[719-36*j-4 -: 4]);               // d1 Q1 hi
      msg2[8*(N2-1-(119+4*j+3)) +: 8] = hx(tr[719-36*j-4-4 -: 4]);             // d1 Q1 lo
    end
    msg2[15:0] = {8'h0d, 8'h0a};
  end

  reg [8*N2-1:0] snap;
  reg [ 7:0]    len;
  reg [ 7:0]    idx;
  reg [ 9:0]    sh;
  reg [ 3:0]    bits;
  reg [ 5:0]    div;
  reg [26:0]    gap;
  always @(posedge clk) begin
    if (rst) begin
      idx <= 8'd0; len <= 8'd0; sh <= 10'h3FF; bits <= 4'd0; div <= 6'd0; gap <= 27'd0;
      rc <= 3'd0;
    end else if (bits == 4'd0) begin
      if (idx < len) begin
        sh <= {1'b1, snap[8*(N2-1-idx) +: 8], 1'b0}; bits <= 4'd10; div <= 6'd0;
        idx <= idx + 8'd1;
      end else if (done) begin
        if (gap == 27'd0) begin
          // left-aligned in snap: a result line is N characters, a trace line N2
          if (rc[2]) begin snap <= msg2; len <= N2; end
          else begin snap <= {msg, {(8*(N2-N)){1'b0}}}; len <= N; end
          idx <= 8'd0;
        end
        // 10 ms per line, then 2 s of silence after the round: the board's USB-UART bridge
        // (BL702) has locked up under a continuous 1 Mbaud stream that nobody read
        gap <= gap + 27'd1;
        if (gap == ((rc == 3'd5) ? 27'd84000000 : 27'd420000)) begin
          gap <= 27'd0; rc <= (rc == 3'd5) ? 3'd0 : rc + 3'd1;
        end
      end
    end else if (div == 6'd41) begin
      div <= 6'd0; sh <= {1'b1, sh[9:1]}; bits <= bits - 4'd1;
    end else
      div <= div + 6'd1;
  end
  assign uart_tx = sh[0];

  reg [24:0] beat = 25'd0;
  always @(posedge clk) beat <= beat + 25'd1;
  wire any0 = e0[0] != 0 || e0[1] != 0 || e0[2] != 0 || e0[3] != 0;
  wire any1 = e1[0] != 0 || e1[1] != 0 || e1[2] != 0 || e1[3] != 0;
  assign led_n = ~{any1, any0, any0 | any1, done, pll_lock, beat[24]};
  wire unused = uart_rx;

endmodule

`default_nettype wire
