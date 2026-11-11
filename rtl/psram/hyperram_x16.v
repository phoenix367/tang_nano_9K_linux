// HyperRAM controller for the GW1NR-9's on-package PSRAM (doc/psram_controller.md): both
// W955D8MBYA dies in lockstep as one 16-bit DDR bus (die 0 on DQ[7:0], die 1 on DQ[15:8]),
// clocked 1:1 with the fabric. One command moves up to one 32-byte line; the SoC's psram_arb
// shares it between the L1 cache and the video DMA.
//
// Clocking: CK runs at the fabric clock. Every output (CS#, DQ, RWDS, output enables) leaves
// through an ODDR on clk; CK leaves through an ODDR on clk_p, the same clock delayed by the
// rPLL's CLKOUTP phase, so CK's edges fall inside the DQ eyes for writes. Reads are captured
// by IDDRs on clk. No calibration.
// Phase window on the board (fpga/probe_psram16, both dies, full 8 MB, 2026-11-11): 22.5 to
// 157.5 degrees pass, 0 fails (CK edges on the data transitions; even the CR0 write is lost).
// 90 degrees is the middle. The datasheet's worst-case tCKD (5.5 ns) would end the window
// near 95 degrees (the die model does); the real dies are faster. From 90 degrees on, a read
// word falls within one IDDR cycle instead of straddling two, which the capture handles
// either way.
//
// Pins (as the Gowin IP drives them): die 0's true clock is O_psram_ck[0], die 1's is
// O_psram_ck_n[1] (i_ck_inv = 2'b10); the other pin of each die carries the complement.
//
// Protocol (fixed latency LC, so both dies always take 2 x LC clocks; CR0 = 0x8FEE: latency 3,
// fixed, legacy wrapped bursts of 16 bytes per die = one 32-byte line in all):
//   bus cycles 0..2     CS# Low, the 48-bit command-address, 2 bytes per die and cycle
//   bus cycles 3..D0-1  latency (D0 = 2 + 2*LC: data on clock 3 + 2*LC); a write drives
//                       RWDS Low from D0-1 (the preamble)
//   bus cycles D0..     the data words, one 16-bit word per die and cycle: 8 for a read; a
//                       write ends after the beat flagged i_wlast (at most 8)
//   then                CS# High and CK stopped for two cycles (tRWR 36 ns), and the next
//                       command may start: a full line takes D0 + 8 + 2 = 18 cycles
// The burst wraps inside the 32-byte line from the addressed word (as the Gowin IP's did), so
// an uncached word read gets its word as beat 0. A register write (CR0, both dies, at init)
// has zero latency: its data is bus cycle 3.
//
// Command interface: o_ready says a command is taken this cycle (i_cmd_en, i_cmd_we,
// i_addr). Write beat k is asked for one cycle ahead (o_wnext, o_wbeat = k); i_wdata, i_wmask
// (1 = byte not written) and i_wlast (no enabled byte follows) are read combinationally in
// that cycle. A read returns 8 beats in order on o_rvalid/o_rdata, {die 1 word, die 0 word},
// 13 to 22 cycles after the command; they may still be arriving when the next command starts.
//
// Read capture: words are found from RWDS, not counted. The die drives RWDS High with the
// first byte of each word and Low with the second, so a word is a sample pair whose RWDS
// reads 1 then 0, within one IDDR cycle (Q0, Q1) or straddling two (previous Q1, Q0). Each die
// is captured on its own into an 8-word FIFO, and a beat leaves when both FIFOs hold a word.
// Capture is armed from bus cycle D0 (the command phase, when the die drives RWDS High and
// then Low, is over) for 16 cycles (the last word comes on bus cycle 20, the next read can
// arm on 25); a die that has not delivered 8 words by then gets filler
// words with o_rerr set, so a reader never waits forever.
`default_nettype none

module hyperram_x16 #(
    parameter integer CLK_HZ  = 42000000,
    parameter integer INIT_US = 160,        // RESET# High to the first access (tVCS 150 us)
    parameter integer LC      = 3           // initial latency; CR0[7:4] must select it
) (
    input  wire        clk,
    input  wire        clk_p,               // clk delayed by the CK phase
    input  wire        rst,
    // configuration, taken by i_init (and once after rst)
    input  wire        i_init,
    input  wire [15:0] i_cr0,               // written to both dies (fixed latency LC)
    input  wire [ 1:0] i_ck_inv,            // die d: true clock on O_psram_ck_n[d]
    output reg         o_init_done,
    // commands
    output wire        o_ready,
    input  wire        i_cmd_en,
    input  wire        i_cmd_we,
    input  wire [22:2] i_addr,              // byte address bits 22:2 (a 32-bit word)
    output wire        o_wnext,
    output wire [ 2:0] o_wbeat,
    input  wire [31:0] i_wdata,
    input  wire [ 3:0] i_wmask,             // 1 = byte not written
    input  wire        i_wlast,
    output reg         o_rvalid,
    output reg  [31:0] o_rdata,
    output reg  [ 1:0] o_rerr,              // with o_rvalid: die d's word is a filler
    // diagnostics: bus cycle of each die's first word in the last read, its alignment
    output reg  [ 5:0] o_rlat0,
    output reg  [ 5:0] o_rlat1,
    output reg  [ 1:0] o_ralign,
    output wire [ 3:0] o_dbg_rw,            // this cycle's IDDR samples {d1 Q1, Q0, d0 Q1, Q0}
    output wire [31:0] o_dbg_dq,            // {d1 Q1, Q0, d0 Q1, Q0}
    // the PSRAM
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n
);
  localparam integer D0      = 2 + 2 * LC;             // first data bus cycle
  localparam integer END     = D0 + 8;                 // CS# High after a full burst
  localparam integer WINDOW  = 16;                     // capture cycles from D0 (to 22)
  localparam integer RST_CYC = CLK_HZ / 1000000 * 2;   // RESET# Low: 2 us (tRP 200 ns)
  localparam integer INI_CYC = CLK_HZ / 1000000 * INIT_US;

  // ---------------------------------------------------------------- sequencer
  localparam [2:0] S_RST = 3'd0, S_WAIT = 3'd1, S_IDLE = 3'd2, S_ACC = 3'd3, S_GAP = 3'd4;
  reg  [ 2:0] st;
  reg  [23:0] tmr;
  reg  [ 4:0] c;                 // bus cycle of the access in progress (registers hold it)
  reg         cfg_acc;           // the access is the CR0 write
  reg         we_q, wdone;
  reg  [47:0] ca;                // command-address, sent MSB first
  reg  [15:0] cr0_q;
  reg  [ 1:0] inv_q;
  reg         init_req;
  reg         reset_n_q;

  // bus registers: what the ODDRs send in the current bus cycle
  reg         cs_n_q = 1'b1, ck_en_q = 1'b0, dq_oe_q = 1'b0, rwds_oe_q = 1'b0;
  reg  [15:0] dq_r_q, dq_f_q;    // byte lanes {die 1, die 0} on the rising / falling half
  reg  [ 1:0] rwds_r_q, rwds_f_q;

  wire [ 4:0] nc     = c + 5'd1;                       // the bus cycle being prepared
  wire        n_data = !cfg_acc && (nc >= D0) && (nc < END);
  assign o_ready = (st == S_IDLE) && !init_req;
  assign o_wnext = (st == S_ACC) && we_q && n_data && !wdone;
  wire [ 4:0] nbeat  = nc - D0[4:0];                   // data beat of bus cycle nc
  assign o_wbeat = nbeat[2:0];

  // command-address: CA[47] R/W#, [46] register space, [45] burst type (0 = wrapped),
  // [44:16] A[31:3], [15:3] reserved, [2:0] A[2:0]. Each die gets the same 16-bit word index,
  // the host word index addr[22:2].
  function [47:0] mk_ca(input rd, input [22:2] a);
    mk_ca = {rd, 1'b0, 1'b0, 11'd0, a[22:5], 13'd0, a[4:2]};
  endfunction
  // Register write to CR0 (linear, register space): CA[24], as in the W957D8 datasheet's map
  // and zf3's controller. A write with CA[16] (takayuki-nagata's reading of the W955 map) has
  // no effect on the board: the dies kept their default 2 x 6 latency (probe, 2026-11-11).
  localparam [47:0] CA_CR0 = 48'h60_00_01_00_00_00;

  // first bus cycle of an access, set from the idle state
  task begin_access(input cfg, input we, input [47:0] cav);
    begin
      st <= S_ACC; c <= 5'd0; cfg_acc <= cfg; we_q <= we; wdone <= 1'b0; ca <= cav;
      cs_n_q <= 1'b0; ck_en_q <= 1'b1; dq_oe_q <= 1'b1; rwds_oe_q <= 1'b0;
      dq_r_q <= {2{cav[47:40]}}; dq_f_q <= {2{cav[39:32]}};
      rwds_r_q <= 2'b00; rwds_f_q <= 2'b00;
    end
  endtask

  always @(posedge clk) begin
    if (i_init) init_req <= 1'b1;
    if (rst) begin
      st <= S_RST; tmr <= 24'd0; o_init_done <= 1'b0; init_req <= 1'b0; reset_n_q <= 1'b0;
      cs_n_q <= 1'b1; ck_en_q <= 1'b0; dq_oe_q <= 1'b0; rwds_oe_q <= 1'b0;
      cr0_q <= i_cr0; inv_q <= i_ck_inv; c <= 5'd0; cfg_acc <= 1'b0; we_q <= 1'b0;
    end else case (st)
      S_RST: begin                                    // RESET# Low
        reset_n_q <= 1'b0; o_init_done <= 1'b0; init_req <= 1'b0;
        cr0_q <= i_cr0; inv_q <= i_ck_inv;
        tmr <= tmr + 24'd1;
        if (tmr == RST_CYC) begin tmr <= 24'd0; st <= S_WAIT; end
      end
      S_WAIT: begin                                   // tVCS, then the CR0 write
        reset_n_q <= 1'b1;
        tmr <= tmr + 24'd1;
        if (tmr == INI_CYC) begin_access(1'b1, 1'b1, CA_CR0);
      end
      S_IDLE: begin
        if (init_req) begin st <= S_RST; tmr <= 24'd0; end
        else if (i_cmd_en) begin_access(1'b0, i_cmd_we, mk_ca(!i_cmd_we, i_addr));
      end
      S_ACC: begin
        c <= nc;
        // registers for bus cycle nc
        ck_en_q <= 1'b0; dq_oe_q <= 1'b0; rwds_oe_q <= 1'b0;
        dq_r_q  <= 16'd0; dq_f_q <= 16'd0; rwds_r_q <= 2'b00; rwds_f_q <= 2'b00;
        if (nc <= 5'd2) begin                          // command-address
          ck_en_q <= 1'b1; dq_oe_q <= 1'b1;
          dq_r_q  <= {2{ca[47 - 16*nc -: 8]}};
          dq_f_q  <= {2{ca[39 - 16*nc -: 8]}};
        end else if (cfg_acc) begin
          if (nc == 5'd3) begin                        // CR0 data, zero latency
            ck_en_q <= 1'b1; dq_oe_q <= 1'b1;
            dq_r_q  <= {2{cr0_q[15:8]}}; dq_f_q <= {2{cr0_q[7:0]}};
          end else begin                               // CS# High: init done
            cs_n_q <= 1'b1; st <= S_GAP; init_req <= 1'b0; o_init_done <= 1'b1;
          end
        end else if (we_q) begin
          if (wdone || nc == END) begin cs_n_q <= 1'b1; st <= S_GAP; end
          else begin
            ck_en_q <= 1'b1; dq_oe_q <= 1'b1;
            if (nc >= D0 - 1) rwds_oe_q <= 1'b1;       // preamble Low, then the masks
            if (n_data) begin
              // word k of die d: upper byte on the rising half, lower on the falling half
              dq_r_q   <= {i_wdata[31:24], i_wdata[15:8]};
              dq_f_q   <= {i_wdata[23:16], i_wdata[7:0]};
              rwds_r_q <= {i_wmask[3], i_wmask[1]};
              rwds_f_q <= {i_wmask[2], i_wmask[0]};
              if (i_wlast) wdone <= 1'b1;
            end
          end
        end else begin                                 // read
          if (nc == END) begin cs_n_q <= 1'b1; st <= S_GAP; end
          else ck_en_q <= 1'b1;
        end
      end
      S_GAP: st <= S_IDLE;                             // CS# High one more cycle (tRWR)
      default: st <= S_RST;
    endcase
  end

  // ---------------------------------------------------------------- read capture
  wire [15:0] dq_q0, dq_q1;      // IDDR: Q0 sampled at the earlier edge, Q1 at the later
  wire [ 1:0] rw_q0, rw_q1;
  reg  [15:0] dq_pq1;
  reg  [ 1:0] rw_pq1;
  assign o_dbg_rw = {rw_q1[1], rw_q0[1], rw_q1[0], rw_q0[0]};
  assign o_dbg_dq = {dq_q1[15:8], dq_q0[15:8], dq_q1[7:0], dq_q0[7:0]};

  // A read arms the capture when its bus cycle D0 is being prepared; reads start at least 18
  // cycles apart, so one window closes before the next opens.
  wire        arm = (st == S_ACC) && !we_q && !cfg_acc && (nc == D0);
  reg  [ 4:0] win;               // capture cycles left (0 = closed)
  reg  [ 5:0] rcyc;              // bus cycle of the read being captured (diagnostics)
  reg  [ 3:0] need0, need1;      // words still expected per die
  // per-die FIFOs of {filler, word}
  reg  [16:0] f0 [0:7], f1 [0:7];
  reg  [ 2:0] w0, w1, rp;
  reg  [ 3:0] n0, n1;            // words held
  reg         push0, push1;
  reg  [16:0] in0, in1;

  always @(*) begin
    push0 = 1'b0; push1 = 1'b0; in0 = 17'd0; in1 = 17'd0;
    if (win != 5'd0 && need0 != 4'd0) begin
      if (rw_pq1[0] && !rw_q0[0])     begin push0 = 1'b1; in0 = {1'b0, dq_pq1[7:0], dq_q0[7:0]}; end
      else if (rw_q0[0] && !rw_q1[0]) begin push0 = 1'b1; in0 = {1'b0, dq_q0[7:0], dq_q1[7:0]}; end
      else if (win == 5'd1)           begin push0 = 1'b1; in0 = {1'b1, 16'hDEAD}; end
    end
    if (win != 5'd0 && need1 != 4'd0) begin
      if (rw_pq1[1] && !rw_q0[1])     begin push1 = 1'b1; in1 = {1'b0, dq_pq1[15:8], dq_q0[15:8]}; end
      else if (rw_q0[1] && !rw_q1[1]) begin push1 = 1'b1; in1 = {1'b0, dq_q0[15:8], dq_q1[15:8]}; end
      else if (win == 5'd1)           begin push1 = 1'b1; in1 = {1'b1, 16'hDEAD}; end
    end
  end
  wire pop = (n0 != 4'd0) && (n1 != 4'd0);

  always @(posedge clk) begin
    dq_pq1 <= dq_q1; rw_pq1 <= rw_q1;
    o_rvalid <= 1'b0;
    if (arm) begin
      win <= WINDOW[4:0]; rcyc <= D0[5:0]; need0 <= 4'd8; need1 <= 4'd8;
    end else begin
      if (win > 5'd1) win <= win - 5'd1;
      // the last window cycle keeps filling one word per die and cycle until 8 are there
      else if (win == 5'd1 && need0 <= 4'd1 && need1 <= 4'd1) win <= 5'd0;
      rcyc <= rcyc + 6'd1;
      if (push0) begin
        f0[w0] <= in0; w0 <= w0 + 3'd1; need0 <= need0 - 4'd1;
        if (need0 == 4'd8) begin o_rlat0 <= rcyc; o_ralign[0] <= rw_pq1[0] && !rw_q0[0]; end
      end
      if (push1) begin
        f1[w1] <= in1; w1 <= w1 + 3'd1; need1 <= need1 - 4'd1;
        if (need1 == 4'd8) begin o_rlat1 <= rcyc; o_ralign[1] <= rw_pq1[1] && !rw_q0[1]; end
      end
    end
    n0 <= n0 + {3'd0, push0 & !arm} - {3'd0, pop};
    n1 <= n1 + {3'd0, push1 & !arm} - {3'd0, pop};
    if (pop) begin
      o_rvalid <= 1'b1;
      o_rdata  <= {f1[rp][15:0], f0[rp][15:0]};
      o_rerr   <= {f1[rp][16], f0[rp][16]};
      rp <= rp + 3'd1;
    end
    if (rst) begin
      win <= 5'd0; need0 <= 4'd0; need1 <= 4'd0; w0 <= 3'd0; w1 <= 3'd0; rp <= 3'd0;
      n0 <= 4'd0; n1 <= 4'd0; o_rvalid <= 1'b0; o_ralign <= 2'b00;
    end
  end

  // ---------------------------------------------------------------- I/O cells
  // The clk ODDRs sample their inputs at the clk edge after the register changes; the CK ODDR
  // on clk_p would sample ck_en_q only phase later, a cycle early. Its inputs come from the
  // falling edge instead, sampled at the clk_p edge phase after the clk ODDRs' (budget
  // T/2 + phase; the phase must lie between 0 and 180 degrees).
  reg [1:0] ck_d0_n = 2'b00, ck_d1_n = 2'b00;
  always @(negedge clk) begin
    ck_d0_n <= {2{ck_en_q}} ^ inv_q;
    ck_d1_n <= inv_q;
  end
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_dq
      wire o, oe_n;
      ODDR odq (.CLK(clk), .D0(dq_r_q[i]), .D1(dq_f_q[i]), .TX(!dq_oe_q), .Q0(o), .Q1(oe_n));
      assign IO_psram_dq[i] = oe_n ? 1'bz : o;
      IDDR idq (.CLK(clk), .D(IO_psram_dq[i]), .Q0(dq_q0[i]), .Q1(dq_q1[i]));
    end
    for (i = 0; i < 2; i = i + 1) begin : g_die
      wire rw_o, rw_oe_n, cs_o, ck_o;
      ODDR orw (.CLK(clk), .D0(rwds_r_q[i]), .D1(rwds_f_q[i]), .TX(!rwds_oe_q), .Q0(rw_o),
                .Q1(rw_oe_n));
      assign IO_psram_rwds[i] = rw_oe_n ? 1'bz : rw_o;
      IDDR irw (.CLK(clk), .D(IO_psram_rwds[i]), .Q0(rw_q0[i]), .Q1(rw_q1[i]));
      ODDR #(.INIT(1'b1)) ocs (.CLK(clk), .D0(cs_n_q), .D1(cs_n_q), .TX(1'b0), .Q0(cs_o),
                               .Q1());
      assign O_psram_cs_n[i] = cs_o;
      // CK: High in the first half of each enabled clk_p cycle; inverted for a die whose
      // true clock is the _n pin. The two pins of a die are driven complementary. Die 1's
      // pins (IOL23A/B) are a differential pair, driven through ELVDS_OBUF as the Gowin IP
      // does; die 0's (IOL8A, IOL7A) are not, so they get one ODDR each. (An ELVDS_OBUF there
      // made the placer move the pair to package pins 85/86: die 0 had no clock.)
      ODDR ock (.CLK(clk_p), .D0(ck_d0_n[i]), .D1(ck_d1_n[i]), .TX(1'b0), .Q0(ck_o),
                .Q1());
      if (i == 1) begin : g_diff
        ELVDS_OBUF ckb (.I(ck_o), .O(O_psram_ck[i]), .OB(O_psram_ck_n[i]));
      end else begin : g_se
        wire ckn_o;
        ODDR ockn (.CLK(clk_p), .D0(!ck_d0_n[i]), .D1(!ck_d1_n[i]), .TX(1'b0), .Q0(ckn_o),
                   .Q1());
        assign O_psram_ck[i]   = ck_o;
        assign O_psram_ck_n[i] = ckn_o;
      end
      assign O_psram_reset_n[i] = reset_n_q;
    end
  endgenerate

endmodule

`default_nettype wire
