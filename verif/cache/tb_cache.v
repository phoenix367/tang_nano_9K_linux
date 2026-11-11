// Unit test for rtl/soc/l1_cache.v + rtl/soc/psram_arb.v against the PSRAM controller's cycle
// model (rtl/sim/hyperram_x16_model.v). A tiny cache (LINES lines) forces constant evictions
// and write-backs. Random byte/half/word reads and writes go to four cached 4 KB regions
// spread over the 8 MB (both sides of 4 MB, the top) and to two uncached-only 4 KB regions
// (the 0x9xxx_xxxx alias);
// every read is checked against a reference memory kept in the testbench. Bus handshake as
// SERV does it: hold cyc until ack, drop it the next cycle.
// DMA=1 adds a reader on the arbiter's DMA port that streams 32-byte bursts from a 4 KB
// region preloaded through the model's backdoor, as video_dma does (two reads outstanding at
// most, 8 cycles between grants), urgent for 400 cycles of every 2000; every beat is
// checked. The model's protocol check (no command while it is not ready) must stay quiet.
// CMO=1 mixes in cache-block operations (Zicbom: inval/clean/flush) on any byte of a block,
// cached or uncached. Besides the CPU view (ref_mem) the checks use the PSRAM itself (the
// model's backdoor): after clean/flush the block in PSRAM equals ref_mem, and the write-back
// was granted before the ack (so a later DMA read sees it). Before an inval the testbench
// writes new "device" data into the PSRAM block, as a DMA write would; after it, PSRAM still
// holds that data (nothing written back over it) and the CPU sees it. A block that was not
// dirty must already match in PSRAM. The line's tag ends valid and clean (clean) or invalid
// (flush/inval), and is left alone on a miss or the uncached alias.
// Run: verif/cache/run.sh.
`timescale 1ns/1ps
`default_nettype none

module tb_cache;
  parameter LINES = 8;
  parameter OPS   = 40000;
  parameter SEED  = 1;
  parameter DMA   = 1;
  parameter CMO   = 1;
  localparam IW = $clog2(LINES), TW = 23 - 5 - IW;

  reg clk = 0, rst = 1;
  always #5 clk = !clk;

  reg  [22:0] adr;
  reg  [31:0] dat;
  reg  [ 3:0] sel;
  reg         we, cyc = 0, unc = 0, cmo = 0;
  reg  [ 1:0] cmo_op = 0;
  wire [31:0] rdt;
  wire        ack;

  wire        p_init, p_ready, p_cmd_en, p_cmd_we, p_wnext, p_wlast, p_rvalid;
  wire [22:2] p_adr;
  wire [ 2:0] p_wbeat;
  wire [31:0] p_wdata, p_rdata, hits, misses, wbs;
  wire [ 3:0] p_wmask;
  wire [ 1:0] p_rerr;

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
      .i_unc(unc), .i_cmo(cmo), .i_cmo_op(cmo_op), .o_rdt(rdt), .o_ack(ack),
      .o_req(c_req), .o_req_we(c_we), .o_req_adr(c_adr), .i_gnt(c_gnt),
      .o_wdata(c_wdata), .o_wmask(c_wmask), .i_rvalid(c_rvalid), .i_rdata(c_rdata),
      .o_hits(hits), .o_misses(misses), .o_writebacks(wbs));

  psram_arb arb (
      .i_clk(clk), .i_rst(rst),
      .i_c_req(c_req), .i_c_we(c_we), .i_c_adr(c_adr), .o_c_gnt(c_gnt),
      .i_c_wdata(c_wdata), .i_c_wmask(c_wmask), .o_c_rvalid(c_rvalid), .o_c_rdata(c_rdata),
      .i_d_req(d_req), .i_d_urgent(d_urgent), .i_d_adr(d_adr), .o_d_gnt(d_gnt),
      .o_d_rvalid(d_rvalid), .o_d_rdata(d_rdata),
      .i_ready(p_ready), .o_cmd_en(p_cmd_en), .o_cmd_we(p_cmd_we), .o_cmd_adr(p_adr),
      .i_wnext(p_wnext), .i_wbeat(p_wbeat), .o_wdata(p_wdata), .o_wmask(p_wmask),
      .o_wlast(p_wlast), .i_rvalid(p_rvalid), .i_rdata(p_rdata));

  hyperram_x16_model #(.INIT_CYCLES(100)) psram (
      .clk(clk), .rst(rst), .o_init_done(p_init), .o_ready(p_ready),
      .i_cmd_en(p_cmd_en), .i_cmd_we(p_cmd_we), .i_addr(p_adr), .o_wnext(p_wnext),
      .o_wbeat(p_wbeat), .i_wdata(p_wdata), .i_wmask(p_wmask), .i_wlast(p_wlast),
      .o_rvalid(p_rvalid), .o_rdata(p_rdata), .o_rerr(p_rerr));

  // regions 0-3 cached (either side of 4 MB, the top), 4-5 uncached
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
  localparam [22:0] DMA_BASE = 23'h70_0000;     // 4 KB, read by the DMA only

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
      adr <= a; we <= w; dat <= d; sel <= s; unc <= u; cyc <= 1'b1; cmo <= 1'b0;
      @(posedge clk);
      while (!ack) @(posedge clk);
      got_w = rdt;
      cyc <= 1'b0;
    end
  endtask

  // ---------------------------------------------------------------- cache-block operations
  integer   n_cmos = 0, cmo_res = 0, cmo_dirty = 0;
  reg [ 1:0] op;
  reg [22:0] blk;
  reg [TW+1:0] t_before, t_after;
  reg        resident;
  reg [ 7:0] pb;
  reg [ 7:0] dev[0:31];                         // inval: what a device wrote to the block
  integer    wr_grants = 0, wr_before;
  always @(posedge clk) if (c_req & c_we & c_gnt) wr_grants = wr_grants + 1;
  reg [ 2:0] last_r = 0;                        // the last cached access, which CMOs favour
  reg [11:0] last_off = 0;
  task cmo_check(input [8*48-1:0] what);
    begin
      errors = errors + 1;
      if (errors <= 5) $display("CMO %0d op %0d @%06h%s: %0s", n_cmos, op, blk,
                                r >= 4 ? " (uncached)" : "", what);
    end
  endtask
  task do_cmo;
    integer j;
    begin
      r   = {$random(seed)} % 6;
      off = $random(seed);
      if (($random(seed) & 3) != 0) begin        // mostly the block just used: likely resident
        r   = last_r;
        off = {last_off[11:5], off[4:0]};
      end
      op  = {$random(seed)} % 3;                 // 0 inval, 1 clean, 2 flush
      blk = region_base(r) + {off[11:5], 5'd0};
      t_before = dut.tag_ram[blk[5 +: IW]];
      resident = t_before[TW+1] && (t_before[TW-1:0] == blk[22 -: TW]);
      n_cmos = n_cmos + 1;
      // a write-back from the last access may still be in the controller (its beats are
      // buffered and written 9..16 cycles after the grant): let it finish first
      while (psram.busy || p_cmd_en) @(posedge clk);
      if (resident && r < 4) cmo_res = cmo_res + 1;
      if (resident && r < 4 && t_before[TW]) cmo_dirty = cmo_dirty + 1;
      if (r < 4)
        for (j = 0; j < 32; j = j + 1) begin
          pb = psram.backdoor_read_byte(blk + j);
          if (!(resident && t_before[TW]) && pb !== ref_mem[{r, off[11:5], j[4:0]}]) begin
            cmo_check("PSRAM differs for a block that is not dirty");
            j = 32;
          end
        end
      if (r < 4 && op == 2'd0)
        for (j = 0; j < 32; j = j + 1) begin
          dev[j] = $random(seed);
          psram.backdoor_write_byte(blk + j, dev[j]);
        end
      wr_before = wr_grants;
      @(posedge clk);
      adr <= region_base(r) + off; we <= 1'b0; sel <= 4'hF; unc <= r >= 4; cyc <= 1'b1;
      cmo <= 1'b1; cmo_op <= op;
      @(posedge clk);
      while (!ack) @(posedge clk);
      cyc <= 1'b0; cmo <= 1'b0;
      if (wr_grants - wr_before != ((r < 4 && resident && t_before[TW] && op != 2'd0) ? 1 : 0))
        cmo_check("write-back count at the ack");
      // the write-back was granted before the ack (checked above); the controller writes its
      // beats 9..16 cycles after the grant, ahead of any later command, so a DMA read after
      // the ack sees them. The backdoor looks once that write is done.
      repeat (2) @(posedge clk);
      while (psram.busy || p_cmd_en) @(posedge clk);
      t_after = dut.tag_ram[blk[5 +: IW]];
      if (r >= 4 || !resident) begin
        if (t_after !== t_before) cmo_check("touched a line it does not hold");
      end else if (op == 2'd1) begin
        if (t_after !== {1'b1, 1'b0, t_before[TW-1:0]}) cmo_check("clean: line not valid and clean");
      end else if (t_after[TW+1] !== 1'b0) cmo_check("line still valid");
      if (r < 4)
        for (j = 0; j < 32; j = j + 1) begin
          pb = psram.backdoor_read_byte(blk + j);
          if (pb !== (op == 2'd0 ? dev[j] : ref_mem[{r, off[11:5], j[4:0]}])) begin
            cmo_check(op == 2'd0 ? "inval: the device's data was overwritten" :
                                   "PSRAM differs after clean/flush");
            j = 32;
          end
          if (op == 2'd0) ref_mem[{r, off[11:5], j[4:0]}] = dev[j];   // the CPU sees it now
        end
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
      $display("FAIL: hang at %0t: adr %06h we %0d unc %0d, cache state %0d, c_req %0d c_gnt %0d, ready %0d cmd %0d, init %0d, d_req %0d d_urg %0d d_gnt %0d",
               $time, adr, we, unc, dut.state, c_req, c_gnt, p_ready, p_cmd_en, p_init,
               d_req, d_urgent, d_gnt);
      $finish;
    end
  end

  initial begin
    seed = SEED;
    repeat (2) @(posedge clk);
    for (i = 0; i < 4096; i = i + 1) psram.backdoor_write_byte(DMA_BASE + i, $random(seed));
    // PSRAM under the cached regions starts random, so an inval of a line that was never
    // written back has something other than zeros to fall back to
    for (r = 0; r < 4; r = r + 1)
      for (i = 0; i < 4096; i = i + 1) psram.backdoor_write_byte(region_base(r) + i, $random(seed));
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
      if (CMO && ({$random(seed)} % 8) == 0) begin
        do_cmo;
      end else begin
      r    = {$random(seed)} % 6;
      size = ($random(seed) & 3) == 3 ? 2 : ($random(seed) & 3) == 0 ? 0 : (($random(seed) & 1) ? 1 : 2);
      off  = $random(seed);
      off  = size == 2 ? {off[11:2], 2'b00} : size == 1 ? {off[11:1], 1'b0} : off;
      mask = size == 2 ? 32'hFFFF_FFFF : size == 1 ? 32'h0000_FFFF : 32'h0000_00FF;
      if (r < 4) {last_r, last_off} = {r, off};
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
    end
    repeat (40) @(posedge clk);
    $display("cache: %0d reads, %0d writes; uncached: %0d reads, %0d writes; %0d errors; hits %0d misses %0d writebacks %0d",
             reads, writes, ureads, uwrites, errors, hits, misses, wbs);
    if (CMO)
      $display("cmo: %0d operations, %0d on a resident line (%0d dirty)", n_cmos, cmo_res, cmo_dirty);
    if (DMA)
      $display("dma: %0d bursts, %0d beats, %0d errors in %0d cycles (%0.1f cycles/burst)",
               d_bursts, d_beats, d_errors, cyc_n, 1.0 * cyc_n / (d_bursts > 0 ? d_bursts : 1));
    $display("%s: model protocol errors %0d",
             (errors || d_errors || psram.error_count || (DMA && d_bursts == 0) ||
              (CMO && cmo_dirty == 0)) ? "FAIL" : "PASS",
             psram.error_count);
    $finish;
  end
endmodule
