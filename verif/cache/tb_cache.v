// Unit test for rtl/soc/l1_cache.v + rtl/soc/psram_arb.v against the PSRAM IP user-interface
// model. A tiny cache (LINES lines) forces constant evictions and write-backs. Random
// byte/half/word reads and writes go to four cached 4 KB regions spread over both PSRAM
// channels and to two uncached-only 4 KB regions (one per channel, the 0x9xxx_xxxx alias);
// every read is checked against a reference memory kept in the testbench. Bus handshake as
// SERV does it: hold cyc until ack, drop it the next cycle.
// DMA=1 adds a reader on the arbiter's DMA port that streams 32-byte bursts from a channel-1
// region preloaded through the model's backdoor, as video_dma does (two reads outstanding at
// most, 8 cycles between grants), urgent for 400 cycles of every 2000; every beat is
// checked. The model's protocol checker (command spacing, write beats) must stay quiet.
// Run: verif/cache/run.sh.
`timescale 1ns/1ps
`default_nettype none

module tb_cache;
  parameter LINES = 8;
  parameter OPS   = 40000;
  parameter SEED  = 1;
  parameter DMA   = 1;

  reg clk = 0, rst = 1;
  always #5 clk = !clk;

  reg  [22:0] adr;
  reg  [31:0] dat;
  reg  [ 3:0] sel;
  reg         we, cyc = 0, unc = 0;
  wire [31:0] rdt;
  wire        ack;

  wire        calib0, calib1, cmd0, cmd_en0, cmd1, cmd_en1, rdv0, rdv1;
  wire [20:0] addr0, addr1;
  wire [31:0] wd0, wd1, rd0, rd1, hits, misses, wbs;
  wire [ 3:0] dm0, dm1;

  wire        c_req, c_we, c_gnt, c_rvalid;
  wire [22:2] c_adr;
  wire [31:0] c_wdata, c_rdata;
  wire [ 3:0] c_wmask;
  reg         d_req = 0, d_urgent = 0;
  reg  [22:2] d_adr = 0;
  wire        d_gnt, d_rvalid;
  wire [31:0] d_rdata;

  l1_cache #(.LINES(LINES)) dut (
      .i_clk(clk), .i_rst(rst), .i_adr(adr), .i_dat(dat), .i_sel(sel), .i_we(we), .i_cyc(cyc),
      .i_unc(unc), .o_rdt(rdt), .o_ack(ack),
      .o_req(c_req), .o_req_we(c_we), .o_req_adr(c_adr), .i_gnt(c_gnt),
      .o_wdata(c_wdata), .o_wmask(c_wmask), .i_rvalid(c_rvalid), .i_rdata(c_rdata),
      .o_hits(hits), .o_misses(misses), .o_writebacks(wbs));

  psram_arb arb (
      .i_clk(clk), .i_rst(rst), .i_calib(calib0 & calib1),
      .i_c_req(c_req), .i_c_we(c_we), .i_c_adr(c_adr), .o_c_gnt(c_gnt),
      .i_c_wdata(c_wdata), .i_c_wmask(c_wmask), .o_c_rvalid(c_rvalid), .o_c_rdata(c_rdata),
      .i_d_req(d_req), .i_d_urgent(d_urgent), .i_d_adr(d_adr), .o_d_gnt(d_gnt),
      .o_d_rvalid(d_rvalid), .o_d_rdata(d_rdata),
      .o_cmd0(cmd0), .o_cmd_en0(cmd_en0), .o_addr0(addr0), .o_wr_data0(wd0), .o_data_mask0(dm0),
      .i_rd_data0(rd0), .i_rd_data_valid0(rdv0),
      .o_cmd1(cmd1), .o_cmd_en1(cmd_en1), .o_addr1(addr1), .o_wr_data1(wd1), .o_data_mask1(dm1),
      .i_rd_data1(rd1), .i_rd_data_valid1(rdv1));

  psram_ui_model #(.CALIB_CYCLES(100)) psram (
      .clk(clk), .rst_n(!rst),
      .cmd0(cmd0), .cmd_en0(cmd_en0), .addr0(addr0), .wr_data0(wd0), .data_mask0(dm0),
      .rd_data0(rd0), .rd_data_valid0(rdv0), .init_calib0(calib0),
      .cmd1(cmd1), .cmd_en1(cmd_en1), .addr1(addr1), .wr_data1(wd1), .data_mask1(dm1),
      .rd_data1(rd1), .rd_data_valid1(rdv1), .init_calib1(calib1));

  // regions 0-3 cached (channel 0 low/high, channel 1 low/high), 4-5 uncached (ch 0 / 1)
  function [22:0] region_base(input [2:0] r);
    case (r)
      3'd0: region_base = 23'h00_0000;
      3'd1: region_base = 23'h3F_F000;
      3'd2: region_base = 23'h40_0000;
      3'd3: region_base = 23'h7F_F000;
      3'd4: region_base = 23'h20_0000;
      default: region_base = 23'h60_0000;
    endcase
  endfunction
  localparam [22:0] DMA_BASE = 23'h70_0000;     // channel 1, 4 KB, read by the DMA only

  reg [7:0] ref_mem[0:8*4096-1];                // {region, offset[11:0]}
  integer   i, n, errors = 0, reads = 0, writes = 0, ureads = 0, uwrites = 0;
  integer   seed;
  reg [2:0] r;
  reg [11:0] off;
  reg [1:0] size;                               // 0 byte, 1 half, 2 word
  reg [31:0] exp_w, got_w, mask;

  task bus(input [22:0] a, input w, input [31:0] d, input [3:0] s, input u);
    begin
      @(posedge clk);
      adr <= a; we <= w; dat <= d; sel <= s; unc <= u; cyc <= 1'b1;
      @(posedge clk);
      while (!ack) @(posedge clk);
      got_w = rdt;
      cyc <= 1'b0;
    end
  endtask

  // ---------------------------------------------------------------- DMA reader
  integer   cyc_n = 0, d_bursts = 0, d_beats = 0, d_errors = 0;
  integer   d_out = 0, d_gap = 0, d_q_head = 0, d_q_tail = 0, d_beat = 0;
  reg [22:2] d_q [0:3];                          // word address of each outstanding burst
  reg [ 9:0] d_next = 0;                         // word offset in the 4 KB region
  reg [31:0] d_exp;
  integer   k;
  always @(posedge clk) begin
    cyc_n <= cyc_n + 1;
    if (DMA && !rst) begin
      if (d_req && d_gnt) begin
        d_q[d_q_tail % 4] = d_adr;
        d_q_tail = d_q_tail + 1;
        d_out = d_out + 1;
        d_gap = 7;
        d_bursts = d_bursts + 1;
        d_next = d_next + 10'd8;
      end else if (d_gap > 0) d_gap = d_gap - 1;
      if (d_rvalid) begin
        for (k = 0; k < 4; k = k + 1)
          d_exp[8*k +: 8] = psram.backdoor_read_byte({d_q[d_q_head % 4] + d_beat, 2'b00} + k);
        if (d_rdata !== d_exp) begin
          d_errors = d_errors + 1;
          if (d_errors <= 5) $display("DMA MISMATCH @%06h beat %0d: got %08h expected %08h",
                                      {d_q[d_q_head % 4], 2'b00}, d_beat, d_rdata, d_exp);
        end
        d_beats = d_beats + 1;
        d_beat = d_beat + 1;
        if (d_beat == 8) begin
          d_beat = 0;
          d_q_head = d_q_head + 1;
          d_out = d_out - 1;
        end
      end
      d_req    <= (d_out < 2) && (d_gap == 0) && !(d_req && d_gnt);
      d_adr    <= DMA_BASE[22:2] + {11'd0, d_next};
      d_urgent <= (cyc_n % 2000) < 400;
    end
  end

  // watchdog: a bus access that takes more than 2000 cycles is a hang
  integer since = 0;
  always @(posedge clk) begin
    since = (cyc && !ack) ? since + 1 : 0;
    if (since > 2000) begin
      $display("FAIL: hang at %0t: adr %06h we %0d unc %0d, cache state %0d, c_req %0d c_gnt %0d, cnt0 %0d cnt1 %0d wcnt %0d, calib %0d%0d, d_req %0d d_urg %0d d_gnt %0d",
               $time, adr, we, unc, dut.state, c_req, c_gnt, arb.cnt0, arb.cnt1, arb.wcnt,
               calib0, calib1, d_req, d_urgent, d_gnt);
      $finish;
    end
  end

  initial begin
    seed = SEED;
    repeat (2) @(posedge clk);
    for (i = 0; i < 4096; i = i + 1) psram.backdoor_write_byte(DMA_BASE + i, $random(seed));
    repeat (2) @(posedge clk);
    rst = 0;
    // initialise every word of the six regions
    for (i = 0; i < 6 * 1024; i = i + 1) begin
      exp_w = $random(seed);
      r = i / 1024;
      off = {i[9:0], 2'b00};
      {ref_mem[{r, off + 12'd3}], ref_mem[{r, off + 12'd2}],
       ref_mem[{r, off + 12'd1}], ref_mem[{r, off}]} = exp_w;
      bus(region_base(r) + off, 1'b1, exp_w, 4'hF, r >= 4);
    end
    for (n = 0; n < OPS; n = n + 1) begin
      r    = {$random(seed)} % 6;
      size = ($random(seed) & 3) == 3 ? 2 : ($random(seed) & 3) == 0 ? 0 : (($random(seed) & 1) ? 1 : 2);
      off  = $random(seed);
      off  = size == 2 ? {off[11:2], 2'b00} : size == 1 ? {off[11:1], 1'b0} : off;
      mask = size == 2 ? 32'hFFFF_FFFF : size == 1 ? 32'h0000_FFFF : 32'h0000_00FF;
      if ($random(seed) & 1) begin                // write
        exp_w = $random(seed);
        for (i = 0; i <= (size == 2 ? 3 : size); i = i + 1)
          ref_mem[{r, off + i[11:0]}] = exp_w >> (8 * i);
        bus(region_base(r) + {off[11:2], 2'b00}, 1'b1, (exp_w & mask) << (8 * off[1:0]),
            (size == 2 ? 4'hF : size == 1 ? 4'h3 : 4'h1) << off[1:0], r >= 4);
        if (r >= 4) uwrites = uwrites + 1; else writes = writes + 1;
      end else begin                               // read
        bus(region_base(r) + {off[11:2], 2'b00}, 1'b0, 32'd0, 4'hF, r >= 4);
        exp_w = {ref_mem[{r, off[11:2], 2'b11}], ref_mem[{r, off[11:2], 2'b10}],
                 ref_mem[{r, off[11:2], 2'b01}], ref_mem[{r, off[11:2], 2'b00}]};
        if (r >= 4) ureads = ureads + 1; else reads = reads + 1;
        if (got_w !== exp_w) begin
          errors = errors + 1;
          if (errors <= 5) $display("MISMATCH op %0d @%06h%s: got %08h expected %08h", n,
                                    region_base(r) + {off[11:2], 2'b00}, r >= 4 ? " (uncached)" : "",
                                    got_w, exp_w);
        end
      end
    end
    repeat (40) @(posedge clk);
    $display("cache: %0d reads, %0d writes; uncached: %0d reads, %0d writes; %0d errors; hits %0d misses %0d writebacks %0d",
             reads, writes, ureads, uwrites, errors, hits, misses, wbs);
    if (DMA)
      $display("dma: %0d bursts, %0d beats, %0d errors in %0d cycles (%0.1f cycles/burst)",
               d_bursts, d_beats, d_errors, cyc_n, 1.0 * cyc_n / (d_bursts > 0 ? d_bursts : 1));
    $display("%s: model protocol errors %0d",
             (errors || d_errors || psram.error_count || (DMA && d_bursts == 0)) ? "FAIL" : "PASS",
             psram.error_count);
    $finish;
  end
endmodule
