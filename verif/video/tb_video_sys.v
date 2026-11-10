// System test of the video scanout path (doc/video_plan.md): l1_cache + psram_arb +
// video_ctrl (video_dma, line buffer, video_out) + the PSRAM IP model, CPU clock 42 MHz and
// pixel clock 25.2 MHz, the real 640x480@60 timing.
//   - The framebuffer at 0x8070_0000 (channel 1) is filled through the model's backdoor;
//     the video is enabled through the CTRL register.
//   - Meanwhile a CPU-side master hammers the cache (8 lines) with random reads and writes in
//     channel 1 (constant misses and write-backs, the worst case for the DMA), checking its
//     own data.
//   - Every displayed pixel of frames 2..FRAMES-1 must equal the framebuffer; the underflow
//     flag must stay clear. The DMA's tightest deadline slack is reported.
// Run: verif/video/run_sys.sh (~3 min).
`timescale 1ps / 1ps
`default_nettype none

module tb_video_sys;
  parameter FRAMES = 4;
  parameter SEED   = 1;
  parameter YOFF   = 0;
  parameter FONT_FILE = "font8x16.hex";                   // start line (Y-wrap): screen line y shows fb line (y + YOFF) % 480

  reg sclk = 0, pclk = 0, rst = 1, prst = 1;
  always #11905 sclk = !sclk;             // 42 MHz
  always #19841 pclk = !pclk;             // 25.2 MHz

  // ---------------------------------------------------------------- DUT
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
  wire        c_req, c_we, c_gnt, c_rvalid, d_req, d_urgent, d_gnt, d_rvalid;
  wire [22:2] c_adr, d_adr;
  wire [31:0] c_wdata, c_rdata, d_rdata;
  wire [ 3:0] c_wmask;

  l1_cache #(.LINES(8)) cache (
      .i_clk(sclk), .i_rst(rst), .i_adr(adr), .i_dat(dat), .i_sel(sel), .i_we(we), .i_cyc(cyc),
      .i_unc(1'b0), .o_rdt(rdt), .o_ack(ack),
      .o_req(c_req), .o_req_we(c_we), .o_req_adr(c_adr), .i_gnt(c_gnt),
      .o_wdata(c_wdata), .o_wmask(c_wmask), .i_rvalid(c_rvalid), .i_rdata(c_rdata),
      .o_hits(hits), .o_misses(misses), .o_writebacks(wbs));

  psram_arb arb (
      .i_clk(sclk), .i_rst(rst), .i_calib(calib0 & calib1),
      .i_c_req(c_req), .i_c_we(c_we), .i_c_adr(c_adr), .o_c_gnt(c_gnt),
      .i_c_wdata(c_wdata), .i_c_wmask(c_wmask), .o_c_rvalid(c_rvalid), .o_c_rdata(c_rdata),
      .i_d_req(d_req), .i_d_urgent(d_urgent), .i_d_adr(d_adr), .o_d_gnt(d_gnt),
      .o_d_rvalid(d_rvalid), .o_d_rdata(d_rdata),
      .o_cmd0(cmd0), .o_cmd_en0(cmd_en0), .o_addr0(addr0), .o_wr_data0(wd0), .o_data_mask0(dm0),
      .i_rd_data0(rd0), .i_rd_data_valid0(rdv0),
      .o_cmd1(cmd1), .o_cmd_en1(cmd_en1), .o_addr1(addr1), .o_wr_data1(wd1), .o_data_mask1(dm1),
      .i_rd_data1(rd1), .i_rd_data_valid1(rdv1));

  psram_ui_model #(.CALIB_CYCLES(100)) psram (
      .clk(sclk), .rst_n(!rst),
      .cmd0(cmd0), .cmd_en0(cmd_en0), .addr0(addr0), .wr_data0(wd0), .data_mask0(dm0),
      .rd_data0(rd0), .rd_data_valid0(rdv0), .init_calib0(calib0),
      .cmd1(cmd1), .cmd_en1(cmd_en1), .addr1(addr1), .wr_data1(wd1), .data_mask1(dm1),
      .rd_data1(rd1), .rd_data_valid1(rdv1), .init_calib1(calib1));

  reg  [ 2:0] r_adr = 0;
  reg  [31:0] r_dat = 0;
  reg         r_wr = 0;
  wire [191:0] regs;
  wire [ 9:0] t0, t1, t2;
  wire        vde, vhs, vvs;
  wire [15:0] vpx;

  video_ctrl #(.CLK_HZ(42000000), .FONT_FILE(FONT_FILE)) video (
      .i_clk(sclk), .i_rst(rst), .i_adr(r_adr), .i_dat(r_dat), .i_wr(r_wr), .o_regs(regs),
      .i_tb_we(1'b0), .i_tb_adr(11'd0), .i_tb_dat(32'd0), .i_tb_sel(4'd0),
      .o_req(d_req), .o_urgent(d_urgent), .o_adr(d_adr), .i_gnt(d_gnt),
      .i_rvalid(d_rvalid), .i_rdata(d_rdata),
      .i_pclk(pclk), .i_prst(prst), .o_tmds0(t0), .o_tmds1(t1), .o_tmds2(t2),
      .o_dbg_de(vde), .o_dbg_hs(vhs), .o_dbg_vs(vvs), .o_dbg_px(vpx));

  function [15:0] fbpix(input integer x, input integer y);
    fbpix = {y[6:0], x[8:0]} ^ 16'h5A3C;
  endfunction

  // ---------------------------------------------------------------- pixel checker
  integer frames = 0, x = 0, y = 0, px_err = 0, px_checked = 0, lines = 0;
  reg     vs_d = 1, de_d = 0, enabled = 0;
  always @(posedge pclk) if (!prst) begin
    if (!vvs && vs_d) begin                 // vsync starts
      frames = frames + 1;
      y = 0;
    end
    if (vde) begin
      if (enabled && frames >= 2 && frames < FRAMES) begin
        px_checked = px_checked + 1;
        if (vpx !== fbpix(x, (y + YOFF) % 480)) begin
          px_err = px_err + 1;
          if (px_err <= 5) $display("PIXEL MISMATCH frame %0d x %0d y %0d: got %04h expected %04h",
                                    frames, x, y, vpx, fbpix(x, (y + YOFF) % 480));
        end
      end
      x = x + 1;
    end else if (de_d) begin
      if (frames >= 1 && x != 640) begin
        px_err = px_err + 1;
        $display("FAIL: line of %0d pixels", x);
      end
      x = 0;
      y = y + 1;
    end
    vs_d <= vvs;
    de_d <= vde;
  end

  // DMA slack: cycles left to the deadline when each line completes
  integer min_left = 99999, dma_lines = 0;
  always @(posedge sclk)
    if (video.dma.last_beat) begin
      dma_lines = dma_lines + 1;
      if (video.dma.left < min_left) min_left = video.dma.left;
    end

  // ---------------------------------------------------------------- CPU traffic
  reg [7:0] ref_mem[0:16383];               // 4 regions x 4 KB in channel 1, outside the fb
  integer   seed, n = 0, cpu_err = 0, i;
  reg [ 1:0] r;
  reg [11:0] off;
  reg [31:0] exp_w, got_w;
  function [22:0] region_base(input [1:0] q);
    region_base = 23'h40_0000 + {q, 18'd0};  // 0x40_0000, 0x44_0000, 0x48_0000, 0x4C_0000
  endfunction
  task bus(input [22:0] a, input w, input [31:0] d, input [3:0] s);
    begin
      @(posedge sclk);
      adr <= a; we <= w; dat <= d; sel <= s; cyc <= 1'b1;
      @(posedge sclk);
      while (!ack) @(posedge sclk);
      got_w = rdt;
      cyc <= 1'b0;
    end
  endtask

  initial begin
    seed = SEED;
    #1;
    for (i = 0; i < 640 * 480; i = i + 1) begin
      psram.backdoor_write_byte(23'h70_0000 + 2 * i, fbpix(i % 640, i / 640));
      psram.backdoor_write_byte(23'h70_0000 + 2 * i + 1, fbpix(i % 640, i / 640) >> 8);
    end
    repeat (4) @(posedge sclk);
    rst = 0;
    repeat (4) @(posedge pclk);
    prst = 0;
    @(posedge sclk);
    r_adr <= 3'd3; r_dat <= YOFF; r_wr <= 1'b1;      // YOFF
    @(posedge sclk);
    r_adr <= 3'd0; r_dat <= 32'd1; r_wr <= 1'b1;     // CTRL = EN
    @(posedge sclk);
    r_wr <= 1'b0;
    enabled = 1;
    for (i = 0; i < 4096; i = i + 1) begin
      exp_w = $random(seed);
      r = i / 1024;
      off = {i[9:0], 2'b00};
      {ref_mem[{r, off + 12'd3}], ref_mem[{r, off + 12'd2}],
       ref_mem[{r, off + 12'd1}], ref_mem[{r, off}]} = exp_w;
      bus(region_base(r) + off, 1'b1, exp_w, 4'hF);
    end
    while (frames < FRAMES) begin
      r = $random(seed);
      off = {$random(seed)} % 4096;
      off = {off[11:2], 2'b00};
      if ($random(seed) & 1) begin
        exp_w = $random(seed);
        {ref_mem[{r, off + 12'd3}], ref_mem[{r, off + 12'd2}],
         ref_mem[{r, off + 12'd1}], ref_mem[{r, off}]} = exp_w;
        bus(region_base(r) + off, 1'b1, exp_w, 4'hF);
      end else begin
        bus(region_base(r) + off, 1'b0, 32'd0, 4'hF);
        exp_w = {ref_mem[{r, off + 12'd3}], ref_mem[{r, off + 12'd2}],
                 ref_mem[{r, off + 12'd1}], ref_mem[{r, off}]};
        if (got_w !== exp_w) begin
          cpu_err = cpu_err + 1;
          if (cpu_err <= 5) $display("CPU MISMATCH @%06h: got %08h expected %08h",
                                     region_base(r) + off, got_w, exp_w);
        end
      end
      n = n + 1;
    end
    $display("video: %0d frames, %0d pixels checked, %0d mismatches; underflow flag %0d; %0d lines fetched, min deadline slack %0d cycles",
             frames, px_checked, px_err, regs[65], dma_lines, min_left);
    $display("cpu: %0d accesses, %0d errors, misses %0d writebacks %0d; model protocol errors %0d",
             n, cpu_err, misses, wbs, psram.error_count);
    $display("%s", (px_err || cpu_err || regs[65] || psram.error_count || px_checked == 0) ? "FAIL" : "PASS");
    $finish;
  end
endmodule

`default_nettype wire
