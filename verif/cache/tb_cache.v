// Unit test for rtl/soc/l1_cache.v against the PSRAM IP user-interface model.
// A tiny cache (LINES lines) forces constant evictions and write-backs. Random byte/half/word
// reads and writes go to four 4 KB regions spread over both PSRAM channels; every read is
// checked against a reference memory kept in the testbench. Bus handshake as SERV does it:
// hold cyc until ack, drop it the next cycle.
`timescale 1ns/1ps
`default_nettype none

module tb_cache;
  parameter LINES = 8;
  parameter OPS   = 40000;
  parameter SEED  = 1;

  reg clk = 0, rst = 1;
  always #5 clk = !clk;

  reg  [22:0] adr;
  reg  [31:0] dat;
  reg  [ 3:0] sel;
  reg         we, cyc = 0;
  wire [31:0] rdt;
  wire        ack;

  wire        calib0, calib1, cmd0, cmd_en0, cmd1, cmd_en1, rdv0, rdv1;
  wire [20:0] addr0, addr1;
  wire [31:0] wd0, wd1, rd0, rd1, hits, misses, wbs;
  wire [ 3:0] dm0, dm1;

  l1_cache #(.LINES(LINES)) dut (
      .i_clk(clk), .i_rst(rst), .i_adr(adr), .i_dat(dat), .i_sel(sel), .i_we(we), .i_cyc(cyc),
      .o_rdt(rdt), .o_ack(ack), .i_calib(calib0 & calib1),
      .o_cmd0(cmd0), .o_cmd_en0(cmd_en0), .o_addr0(addr0), .o_wr_data0(wd0), .o_data_mask0(dm0),
      .i_rd_data0(rd0), .i_rd_data_valid0(rdv0),
      .o_cmd1(cmd1), .o_cmd_en1(cmd_en1), .o_addr1(addr1), .o_wr_data1(wd1), .o_data_mask1(dm1),
      .i_rd_data1(rd1), .i_rd_data_valid1(rdv1),
      .o_hits(hits), .o_misses(misses), .o_writebacks(wbs));

  psram_ui_model #(.CALIB_CYCLES(100)) psram (
      .clk(clk), .rst_n(!rst),
      .cmd0(cmd0), .cmd_en0(cmd_en0), .addr0(addr0), .wr_data0(wd0), .data_mask0(dm0),
      .rd_data0(rd0), .rd_data_valid0(rdv0), .init_calib0(calib0),
      .cmd1(cmd1), .cmd_en1(cmd_en1), .addr1(addr1), .wr_data1(wd1), .data_mask1(dm1),
      .rd_data1(rd1), .rd_data_valid1(rdv1), .init_calib1(calib1));

  // four 4 KB regions: channel 0 low/high, channel 1 low/high
  function [22:0] region_base(input [1:0] r);
    case (r)
      2'd0: region_base = 23'h00_0000;
      2'd1: region_base = 23'h3F_F000;
      2'd2: region_base = 23'h40_0000;
      default: region_base = 23'h7F_F000;
    endcase
  endfunction

  reg [7:0] ref_mem[0:16383];                   // {region, offset[11:0]}
  integer   i, n, errors = 0, reads = 0, writes = 0;
  integer   seed;
  reg [1:0] r;
  reg [11:0] off;
  reg [1:0] size;                               // 0 byte, 1 half, 2 word
  reg [31:0] exp_w, got_w, mask;

  task bus(input [22:0] a, input w, input [31:0] d, input [3:0] s);
    begin
      @(posedge clk);
      adr <= a; we <= w; dat <= d; sel <= s; cyc <= 1'b1;
      @(posedge clk);
      while (!ack) @(posedge clk);
      got_w = rdt;
      cyc <= 1'b0;
    end
  endtask

  initial begin
    seed = SEED;
    repeat (4) @(posedge clk);
    rst = 0;
    // initialise every word of the four regions through the cache
    for (i = 0; i < 4096; i = i + 1) begin
      exp_w = $random(seed);
      r = i[11:10];
      off = {i[9:0], 2'b00};
      {ref_mem[{r, off + 12'd3}], ref_mem[{r, off + 12'd2}],
       ref_mem[{r, off + 12'd1}], ref_mem[{r, off}]} = exp_w;
      bus(region_base(r) + off, 1'b1, exp_w, 4'hF);
    end
    for (n = 0; n < OPS; n = n + 1) begin
      r    = $random(seed);
      size = ($random(seed) & 3) == 3 ? 2 : ($random(seed) & 3) == 0 ? 0 : (($random(seed) & 1) ? 1 : 2);
      off  = $random(seed);
      off  = size == 2 ? {off[11:2], 2'b00} : size == 1 ? {off[11:1], 1'b0} : off;
      mask = size == 2 ? 32'hFFFF_FFFF : size == 1 ? 32'h0000_FFFF : 32'h0000_00FF;
      if ($random(seed) & 1) begin                // write
        exp_w = $random(seed);
        for (i = 0; i <= (size == 2 ? 3 : size); i = i + 1)
          ref_mem[{r, off + i[11:0]}] = exp_w >> (8 * i);
        bus(region_base(r) + {off[11:2], 2'b00}, 1'b1, (exp_w & mask) << (8 * off[1:0]),
            (size == 2 ? 4'hF : size == 1 ? 4'h3 : 4'h1) << off[1:0]);
        writes = writes + 1;
      end else begin                               // read
        bus(region_base(r) + {off[11:2], 2'b00}, 1'b0, 32'd0, 4'hF);
        exp_w = {ref_mem[{r, off[11:2], 2'b11}], ref_mem[{r, off[11:2], 2'b10}],
                 ref_mem[{r, off[11:2], 2'b01}], ref_mem[{r, off[11:2], 2'b00}]};
        reads = reads + 1;
        if (got_w !== exp_w) begin
          errors = errors + 1;
          if (errors <= 5) $display("MISMATCH op %0d @%06h: got %08h expected %08h", n,
                                    region_base(r) + {off[11:2], 2'b00}, got_w, exp_w);
        end
      end
    end
    $display("%s: %0d reads, %0d writes, %0d errors; cache hits %0d misses %0d writebacks %0d; model protocol errors %0d",
             errors ? "FAIL" : "PASS", reads, writes, errors, hits, misses, wbs, psram.error_count);
    $finish;
  end
endmodule

`default_nettype wire
