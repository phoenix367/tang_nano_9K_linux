// Random traffic on the 16-bit HyperRAM controller's command interface, checked against a
// reference memory:
//   MODEL = 0: rtl/psram/hyperram_x16.v with two W955D8MBYA die models (verif/psram16/model)
//              and rtl/sim/gowin_io_sim.v for the Gowin I/O primitives (or Gowin's own
//              models, with GOWIN_PRIM defined)
//   MODEL = 1: rtl/sim/hyperram_x16_model.v, the cycle model the cache/video/SoC simulations use
// Operations, issued back to back as soon as o_ready allows: full-line writes (some bytes
// masked), single-word writes ending after beat 0 (i_wlast, as the cache's uncached alias),
// full-line reads and word reads at any word of the line (the burst wraps from it). Every read
// beat is compared; no beat may come back as a filler (o_rerr). Reports cycles per operation
// and the read timing, and for MODEL = 0 the die models' protocol errors (must be 0).
`timescale 1ns / 1ps
`default_nettype none

module tb_hyperram;
  parameter integer MODEL    = 0;
  parameter integer OPS      = 2000;
  parameter integer SEED     = 1;
  parameter real    PHASE_NS = 5.952;            // CK behind clk (90 degrees at 42 MHz)
  localparam real   HALF     = 11.905;

`ifdef GOWIN_PRIM
  GSR GSR (.GSRI(1'b1));                         // Gowin's primitive models need it
`endif

  reg clk = 1'b0, clk_p = 1'b0;
  always #(HALF) clk = !clk;
  always @(clk) clk_p <= #(PHASE_NS) clk;
  reg rst = 1'b1;

  wire        init_done, ready, wnext, rvalid;
  wire [ 2:0] wbeat;
  wire [31:0] rdata;
  wire [ 1:0] rerr;
  reg         cmd_en = 1'b0, cmd_we = 1'b0;
  reg  [22:2] cmd_adr = 21'd0;
  reg  [31:0] wdata;
  reg  [ 3:0] wmask;
  reg         wlast;
  wire [31:0] perr0, perr1;                      // the die models' protocol errors

  generate
    if (MODEL) begin : g_model
      hyperram_x16_model #(.INIT_CYCLES(500)) dut (
          .clk(clk), .rst(rst), .o_init_done(init_done), .o_ready(ready),
          .i_cmd_en(cmd_en), .i_cmd_we(cmd_we), .i_addr(cmd_adr), .o_wnext(wnext),
          .o_wbeat(wbeat), .i_wdata(wdata), .i_wmask(wmask), .i_wlast(wlast),
          .o_rvalid(rvalid), .o_rdata(rdata), .o_rerr(rerr));
      assign perr0 = 32'd0;
      assign perr1 = 32'd0;
    end else begin : g_rtl
      wire [ 1:0] ck, ck_n, rwds, reset_n, cs_n;
      wire [15:0] dq;
      hyperram_x16 #(.CLK_HZ(42000000), .INIT_US(160), .LC(3)) dut (
          .clk(clk), .clk_p(clk_p), .rst(rst), .i_init(1'b0), .i_cr0(16'h8FEE),
          .i_ck_inv(2'b10), .o_init_done(init_done), .o_ready(ready),
          .i_cmd_en(cmd_en), .i_cmd_we(cmd_we), .i_addr(cmd_adr), .o_wnext(wnext),
          .o_wbeat(wbeat), .i_wdata(wdata), .i_wmask(wmask), .i_wlast(wlast),
          .o_rvalid(rvalid), .o_rdata(rdata), .o_rerr(rerr),
          .o_rlat0(), .o_rlat1(), .o_ralign(), .o_dbg_rw(), .o_dbg_dq(),
          .O_psram_ck(ck), .O_psram_ck_n(ck_n), .IO_psram_rwds(rwds),
          .O_psram_reset_n(reset_n), .IO_psram_dq(dq), .O_psram_cs_n(cs_n));
      // the configuration's GSR (ODDR INIT values) is not simulated: CS# High, CK Low first
      reg pwr = 1'b0;
      initial #100 pwr = 1'b1;
      wire ck0 = pwr & ck[0], ck1 = pwr & ck_n[1];    // the true clock pins (as on the board)
      wire [1:0] cs_d = pwr ? cs_n : 2'b11;
      w955d8mbya_die #(.DIE(0)) die0 (.ck(ck0), .ck_n(!ck0), .cs_n(cs_d[0]),
                                      .reset_n(reset_n[0]), .dq(dq[7:0]), .rwds(rwds[0]));
      w955d8mbya_die #(.DIE(1)) die1 (.ck(ck1), .ck_n(!ck1), .cs_n(cs_d[1]),
                                      .reset_n(reset_n[1]), .dq(dq[15:8]), .rwds(rwds[1]));
      assign perr0 = die0.error_count;
      assign perr1 = die1.error_count;
    end
  endgenerate

  // reference memory: 4 regions of 1 KB, at the bottom, middle, top and a row boundary
  function [22:0] region_base(input [1:0] r);
    case (r)
      2'd0: region_base = 23'h00_0000;
      2'd1: region_base = 23'h3F_FE00;                // straddles 4 MB
      2'd2: region_base = 23'h55_5400;
      default: region_base = 23'h7F_FC00;             // the top
    endcase
  endfunction
  reg [7:0] ref_mem [0:4095];                          // {region, offset[9:0]}

  // write beats of the operation in progress
  reg [31:0] wb [0:7];
  reg [ 3:0] wm [0:7];
  reg [ 2:0] wl;                                       // last beat
  always @(*) begin
    wdata = wb[wbeat]; wmask = wm[wbeat]; wlast = (wbeat == wl);
  end

  // reads in flight: expected beats
  reg  [31:0] exp_q [0:15];
  reg  [ 3:0] exp_wr = 4'd0, exp_rd = 4'd0;
  integer errors = 0, beats = 0, fillers = 0, first_lat = -1;
  integer t_cmd;
  always @(posedge clk) if (rvalid) begin
    if (rerr != 2'b00) fillers = fillers + 1;
    if (rdata !== exp_q[exp_rd]) begin
      errors = errors + 1;
      if (errors <= 10)
        $display("%t ERROR read beat %0d: got %08h expected %08h", $time, beats,
                 rdata, exp_q[exp_rd]);
    end
    exp_rd = exp_rd + 4'd1; beats = beats + 1;
  end

  integer op, k, b, seed, r, cycles0, n_wr = 0, n_rd = 0, n_ww = 0, n_wr1 = 0;
  reg [9:0] off;
  reg [22:0] base;
  reg [31:0] w;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task issue(input we, input [22:2] a);
    begin
      while (!ready) @(posedge clk);
      #1 cmd_en = 1'b1; cmd_we = we; cmd_adr = a;
      @(posedge clk);
      #1 cmd_en = 1'b0;
    end
  endtask

  initial begin
    seed = SEED;
    repeat (4) @(posedge clk);
    #1 rst = 1'b0;
    // fill the regions through full-line writes, as the reference
    while (!init_done) @(posedge clk);
    for (r = 0; r < 4; r = r + 1)
      for (k = 0; k < 1024; k = k + 32) begin
        while (!ready) @(posedge clk);
        for (b = 0; b < 8; b = b + 1) begin
          w = $random(seed); wb[b] = w; wm[b] = 4'b0000;
          {ref_mem[{r[1:0], k[9:0]} + 4*b + 3], ref_mem[{r[1:0], k[9:0]} + 4*b + 2],
           ref_mem[{r[1:0], k[9:0]} + 4*b + 1], ref_mem[{r[1:0], k[9:0]} + 4*b]} = w;
        end
        wl = 3'd7;
        issue(1'b1, (region_base(r) + k) >> 2);
      end
    cycles0 = cyc;
    for (op = 0; op < OPS; op = op + 1) begin
      while (!ready) @(posedge clk);                   // the previous write has taken its beats
      r = $random(seed) & 3;
      off = $random(seed);
      base = region_base(r);
      case ($random(seed) & 3)
        0: begin                                       // full-line write, some bytes masked
          off[4:0] = 5'd0;
          for (b = 0; b < 8; b = b + 1) begin
            w = $random(seed); wb[b] = w;
            wm[b] = (($random(seed) & 3) == 0) ? ($random(seed) & 4'hF) : 4'b0000;
            for (k = 0; k < 4; k = k + 1)
              if (!wm[b][k]) ref_mem[{r[1:0], off} + 4*b + k] = w[8*k +: 8];
          end
          wl = 3'd7; n_wr = n_wr + 1;
          issue(1'b1, (base + off) >> 2);
        end
        1: begin                                       // one word, the burst ends after it
          off[1:0] = 2'd0;
          w = $random(seed); wb[0] = w; wm[0] = $random(seed) & 4'hF;
          for (b = 1; b < 8; b = b + 1) begin wb[b] = 32'hX; wm[b] = 4'hF; end
          for (k = 0; k < 4; k = k + 1)
            if (!wm[0][k]) ref_mem[{r[1:0], off} + k] = w[8*k +: 8];
          wl = 3'd0; n_wr1 = n_wr1 + 1;
          issue(1'b1, (base + off) >> 2);
        end
        default: begin                                 // read from any word: wraps in the line
          off[1:0] = 2'd0;
          for (b = 0; b < 8; b = b + 1) begin
            k = {off[9:5], 5'd0} + ((off[4:2] + b) % 8) * 4;
            exp_q[exp_wr] = {ref_mem[{r[1:0], 10'd0} + k + 3], ref_mem[{r[1:0], 10'd0} + k + 2],
                             ref_mem[{r[1:0], 10'd0} + k + 1], ref_mem[{r[1:0], 10'd0} + k]};
            exp_wr = exp_wr + 4'd1;
          end
          n_rd = n_rd + 1;
          t_cmd = cyc;
          issue(1'b0, (base + off) >> 2);
          if (first_lat < 0) begin
            while (!rvalid) @(posedge clk);
            first_lat = cyc - t_cmd;
          end
        end
      endcase
    end
    while (exp_rd != exp_wr) @(posedge clk);
    repeat (40) @(posedge clk);
    $display("%0s: %0d ops (%0d line writes, %0d word writes, %0d reads) in %0d cycles, %0d read beats",
             MODEL ? "model" : "rtl", OPS, n_wr, n_wr1, n_rd, cyc - cycles0, beats);
    $display("first read: beat 0 %0d cycles after the command", first_lat);
    if (!MODEL) $display("die model protocol errors: %0d, %0d", perr0, perr1);
    if (errors == 0 && fillers == 0 && beats == 8 * n_rd && perr0 == 0 && perr1 == 0)
      $display("PASS");
    else
      $display("FAIL: %0d wrong beats, %0d fillers, %0d of %0d beats", errors, fillers, beats, 8 * n_rd);
    $finish;
  end

  initial begin
    #(400_000_000);
    $display("FAIL: timeout");
    $finish;
  end
endmodule

`default_nettype wire
