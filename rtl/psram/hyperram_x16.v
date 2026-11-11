// HyperRAM controller for the GW1NR-9's on-package PSRAM: both W955D8MBYA dies in lockstep as
// one 16-bit DDR bus (die 0 on DQ[7:0], die 1 on DQ[15:8]), clocked 1:1 with the fabric.
//
// Clocking: CK runs at the fabric clock. Every output (CS#, DQ, RWDS, output enables) leaves
// through an ODDR on clk; CK leaves through an ODDR on clk_p, the same clock delayed by the
// rPLL's CLKOUTP phase, so CK's edges fall inside the DQ eyes for writes. Reads are captured
// by IDDRs on clk. No calibration.
// Phase window on the board (fpga/probe_psram16, both dies, full 8 MB, 2026-11-11): 22.5 to
// 157.5 degrees pass, 0 fails (CK edges on the data transitions; even the CR0 write is lost).
// 90 degrees is the middle. The datasheet's worst-case tCKD (5.5 ns) would end the window
// near 95 degrees (the die model does); the real dies are faster. From 90 degrees on, a read
// word falls within one IDDR cycle instead of straddling two (o_ralign), which the RWDS-based
// capture below handles either way.
//
// Read words are found from RWDS, not counted: the die drives RWDS High with the first byte
// of each 16-bit word and Low with the second, so a word is a sample pair whose RWDS reads
// 1 then 0. The pair may sit in one IDDR cycle (Q0, Q1) or straddle two (previous Q1, Q0);
// both are handled, and the variant is reported (o_ralign). The capture is armed only after
// the command phase, during which the die drives RWDS High (latency) and then Low.
//
// Protocol (W955D8MBYA; fixed latency, so both dies always take 2 x LC clocks):
// Pins (as the Gowin IP drives them): die 0's true clock is O_psram_ck[0], die 1's is
// O_psram_ck_n[1] (i_ck_inv = 2'b10); the other pin of each die carries the complement.
//   bus cycle -1        CS# Low, CK stopped (CS# setup without a clock edge)
//   bus cycles 0..2     the 48-bit command-address, 2 bytes per cycle, CK running
//   bus cycles 3..D0-1  latency (D0 = 2 + 2*LC: data on clock 3 + 2*LC); for writes the
//                       host drives RWDS Low from cycle D0-1 (the preamble)
//   bus cycles D0..D0+7 eight 16-bit words per die = one 32-byte line in all
//   bus cycle  D0+8     CS# High, CK stopped; one more idle cycle (tRWR)
// A register write (CR0, both dies, at init) has zero latency: its data is bus cycle 3.
//
// User side: one 32-byte line per request; beat k is {die 1 word k, die 0 word k}. Writes ask
// for each beat one cycle ahead (o_wnext/o_wbeat; i_wdata/i_wmask are read combinationally in
// that cycle). Reads return each die's words as they are captured (o_rvalid0/1), then pulse
// o_rdone with o_rshort set for a die that delivered fewer than 8 words.
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
    input  wire [15:0] i_cr0,               // written to both dies (fixed latency, LC)
    input  wire [ 1:0] i_ck_inv,            // die d: CK leaves inverted on O_psram_ck[d], so
                                            // its true clock is on O_psram_ck_n[d]
    output reg         o_ready,
    // one 32-byte line per request
    input  wire        i_req,               // taken when o_ready
    input  wire        i_we,
    input  wire [17:0] i_line,              // line index in the 8 MB
    output wire        o_wnext,
    output wire [ 2:0] o_wbeat,
    input  wire [31:0] i_wdata,
    input  wire [ 3:0] i_wmask,             // 1 = byte not written
    output reg         o_rvalid0,
    output reg  [15:0] o_rdata0,
    output reg         o_rvalid1,
    output reg  [15:0] o_rdata1,
    output reg  [ 2:0] o_rbeat0,
    output reg  [ 2:0] o_rbeat1,
    output reg         o_rdone,
    output reg  [ 1:0] o_rshort,
    output reg  [ 5:0] o_rlat0,             // diagnostics: bus cycle of die d's first word
    output reg  [ 5:0] o_rlat1,
    output reg  [ 1:0] o_ralign,            // die d's words straddled two IDDR cycles
    // raw capture, for probes: the IDDR samples of this cycle and the bus cycle of the read
    output wire        o_dbg_rd,
    output wire [ 5:0] o_dbg_c,
    output wire [ 3:0] o_dbg_rw,            // {die 1 Q1, Q0, die 0 Q1, Q0}
    output wire [31:0] o_dbg_dq,            // {die 1 Q1, Q0, die 0 Q1, Q0}
    // the PSRAM
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n
);
  localparam integer D0      = 2 + 2 * LC;             // first data bus cycle
  localparam integer END     = D0 + 8;                 // CS# High
  localparam integer RDONE   = END + 12;               // capture pipeline drained (with margin)
  localparam integer RST_CYC = CLK_HZ / 1000000 * 2;   // RESET# Low: 2 us (tRP 200 ns)
  localparam integer INI_CYC = CLK_HZ / 1000000 * INIT_US;

  // ---------------------------------------------------------------- sequencer
  localparam [2:0] S_RST = 3'd0, S_WAIT = 3'd1, S_CFG = 3'd2, S_IDLE = 3'd3, S_ACC = 3'd4,
                   S_GAP = 3'd5;
  reg  [ 2:0] st;
  reg  [23:0] tmr;
  reg  [ 5:0] c;                 // bus cycle of the access in progress (registers hold it)
  reg         cfg_acc;           // the access is the CR0 write
  reg         we_q;
  reg  [47:0] ca;                // command-address, sent MSB first
  reg  [15:0] cr0_q;
  reg  [ 1:0] inv_q;
  reg         init_req;
  reg         reset_n_q;

  // bus registers: what the ODDRs send in the current bus cycle
  reg         cs_n_q = 1'b1, ck_en_q = 1'b0, dq_oe_q = 1'b0, rwds_oe_q = 1'b0;
  reg  [15:0] dq_r_q, dq_f_q;    // byte lanes {die 1, die 0} on the rising / falling half
  reg  [ 1:0] rwds_r_q, rwds_f_q;

  // what bus cycle c + 1 needs (computed from the current c)
  wire [ 5:0] nc = c + 6'd1;
  wire        n_ca   = (nc <= 6'd2);
  wire        n_data = !cfg_acc && (nc >= D0) && (nc < END);
  wire [ 2:0] n_beat = nc - D0;
  assign o_wnext = (st == S_ACC) && we_q && n_data;
  assign o_wbeat = n_beat;

  // command-address: CA[47] R/W#, [46] register space, [45] burst type (0 = wrapped),
  // [44:16] A[31:3], [15:3] reserved, [2:0] A[2:0]. Each die gets the same address: its
  // 16-bit word index is line*8 + beat, so A[20:3] = line and A[2:0] = 0.
  function [47:0] mk_ca(input rd, input reg_space, input [17:0] line);
    mk_ca = {rd, reg_space, 1'b0, 11'd0, line[17:0], 13'd0, 3'b000};
  endfunction
  // Register write to CR0 (linear, register space): CA[24], as in the W957D8 datasheet's map
  // and zf3's controller. A write with CA[16] (takayuki-nagata's reading of the W955 map) has
  // no effect on the board: the dies kept their default 2 x 6 latency (probe, 2026-11-11).
  localparam [47:0] CA_CR0 = 48'h60_00_01_00_00_00;

  always @(posedge clk) begin
    o_rdone <= 1'b0;
    if (i_init) init_req <= 1'b1;
    if (rst) begin
      st <= S_RST; tmr <= 24'd0; o_ready <= 1'b0; init_req <= 1'b0; reset_n_q <= 1'b0;
      cs_n_q <= 1'b1; ck_en_q <= 1'b0; dq_oe_q <= 1'b0; rwds_oe_q <= 1'b0;
      cr0_q <= i_cr0; inv_q <= i_ck_inv;
    end else case (st)
      S_RST: begin                                    // RESET# Low
        reset_n_q <= 1'b0; o_ready <= 1'b0; init_req <= 1'b0;
        cr0_q <= i_cr0; inv_q <= i_ck_inv;
        tmr <= tmr + 24'd1;
        if (tmr == RST_CYC) begin tmr <= 24'd0; st <= S_WAIT; end
      end
      S_WAIT: begin                                   // tVCS
        reset_n_q <= 1'b1;
        tmr <= tmr + 24'd1;
        if (tmr == INI_CYC) begin
          st <= S_ACC; cfg_acc <= 1'b1; we_q <= 1'b1; ca <= CA_CR0;
          c <= 6'h3F; cs_n_q <= 1'b0;                 // bus cycle -1
        end
      end
      S_IDLE: begin
        if (init_req) begin st <= S_RST; tmr <= 24'd0; end
        else if (i_req) begin
          o_ready <= 1'b0; st <= S_ACC; cfg_acc <= 1'b0; we_q <= i_we;
          ca <= mk_ca(!i_we, 1'b0, i_line);
          c <= 6'h3F; cs_n_q <= 1'b0;
        end
      end
      S_ACC: begin
        c <= nc;
        // registers for bus cycle nc
        ck_en_q   <= 1'b0; dq_oe_q <= 1'b0; rwds_oe_q <= 1'b0;
        dq_r_q    <= 16'd0; dq_f_q <= 16'd0; rwds_r_q <= 2'b00; rwds_f_q <= 2'b00;
        if (n_ca) begin
          ck_en_q <= 1'b1; dq_oe_q <= 1'b1;
          dq_r_q  <= {2{ca[47 - 16*nc -: 8]}};
          dq_f_q  <= {2{ca[39 - 16*nc -: 8]}};
        end else if (cfg_acc) begin
          if (nc == 6'd3) begin                        // CR0 data, zero latency
            ck_en_q <= 1'b1; dq_oe_q <= 1'b1;
            dq_r_q  <= {2{cr0_q[15:8]}}; dq_f_q <= {2{cr0_q[7:0]}};
          end else if (nc == 6'd4) cs_n_q <= 1'b1;
          else if (nc == 6'd6) begin st <= S_GAP; init_req <= 1'b0; end
        end else if (nc < END) begin
          ck_en_q <= 1'b1;
          if (we_q) begin
            dq_oe_q <= 1'b1;
            if (nc >= D0 - 1) begin rwds_oe_q <= 1'b1; rwds_r_q <= 2'b00; rwds_f_q <= 2'b00; end
            if (n_data) begin
              // word k of die d: upper byte on the rising half, lower on the falling half
              dq_r_q   <= {i_wdata[31:24], i_wdata[15:8]};
              dq_f_q   <= {i_wdata[23:16], i_wdata[7:0]};
              rwds_r_q <= {i_wmask[3], i_wmask[1]};
              rwds_f_q <= {i_wmask[2], i_wmask[0]};
            end
          end
        end else if (nc == END) cs_n_q <= 1'b1;
        else if (we_q ? (nc == END + 1) : (nc == RDONE)) begin
          st <= S_GAP;
          if (!we_q) o_rdone <= 1'b1;
        end
      end
      S_GAP: begin                                    // CS# High one more cycle (tRWR)
        st <= S_IDLE; o_ready <= !init_req;
      end
      default: st <= S_RST;
    endcase
    if (i_init) o_ready <= 1'b0;                     // not ready from the request on
  end

  // ---------------------------------------------------------------- read capture
  wire [15:0] dq_q0, dq_q1;      // IDDR: Q0 sampled at the earlier edge, Q1 at the later
  wire [ 1:0] rw_q0, rw_q1;
  reg  [15:0] dq_pq1;
  reg  [ 1:0] rw_pq1;
  reg  [ 3:0] cnt0, cnt1;        // words delivered per die
  wire        arm = (st == S_ACC) && !we_q && !cfg_acc && (c >= D0) && (c < RDONE);
  assign o_dbg_rd = (st == S_ACC) && !we_q && !cfg_acc;
  assign o_dbg_c  = c;
  assign o_dbg_rw = {rw_q1[1], rw_q0[1], rw_q1[0], rw_q0[0]};
  assign o_dbg_dq = {dq_q1[15:8], dq_q0[15:8], dq_q1[7:0], dq_q0[7:0]};

  always @(posedge clk) begin
    dq_pq1 <= dq_q1; rw_pq1 <= rw_q1;
    o_rvalid0 <= 1'b0; o_rvalid1 <= 1'b0;
    if (st == S_ACC && c == 6'h3F) begin cnt0 <= 4'd0; cnt1 <= 4'd0; end
    if (arm && cnt0 < 4'd8) begin
      if (rw_pq1[0] && !rw_q0[0]) begin              // straddling: previous Q1, this Q0
        o_rvalid0 <= 1'b1; o_rdata0 <= {dq_pq1[7:0], dq_q0[7:0]};
        o_rbeat0 <= cnt0[2:0]; cnt0 <= cnt0 + 4'd1;
        if (cnt0 == 4'd0) begin o_rlat0 <= c; o_ralign[0] <= 1'b1; end
      end else if (rw_q0[0] && !rw_q1[0]) begin      // within this cycle
        o_rvalid0 <= 1'b1; o_rdata0 <= {dq_q0[7:0], dq_q1[7:0]};
        o_rbeat0 <= cnt0[2:0]; cnt0 <= cnt0 + 4'd1;
        if (cnt0 == 4'd0) begin o_rlat0 <= c; o_ralign[0] <= 1'b0; end
      end
    end
    if (arm && cnt1 < 4'd8) begin
      if (rw_pq1[1] && !rw_q0[1]) begin
        o_rvalid1 <= 1'b1; o_rdata1 <= {dq_pq1[15:8], dq_q0[15:8]};
        o_rbeat1 <= cnt1[2:0]; cnt1 <= cnt1 + 4'd1;
        if (cnt1 == 4'd0) begin o_rlat1 <= c; o_ralign[1] <= 1'b1; end
      end else if (rw_q0[1] && !rw_q1[1]) begin
        o_rvalid1 <= 1'b1; o_rdata1 <= {dq_q0[15:8], dq_q1[15:8]};
        o_rbeat1 <= cnt1[2:0]; cnt1 <= cnt1 + 4'd1;
        if (cnt1 == 4'd0) begin o_rlat1 <= c; o_ralign[1] <= 1'b0; end
      end
    end
    if (st == S_ACC && !we_q && !cfg_acc && c == RDONE - 1)
      o_rshort <= {cnt1 < 4'd8, cnt0 < 4'd8};
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
