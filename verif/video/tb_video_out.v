// Testbench for rtl/video/video_out.v (+ tmds_encoder, + hdmi_phy_gowin with Gowin's
// OSER10/ELVDS_OBUF/CLKDIV simulation models when PHY=1). verif/video/run.sh runs:
//   PHY=1: reduced timing (64x12), the TMDS lanes deserialized from the OSER10 outputs and
//          decoded: bit order, word alignment, encoding, p/n, clock lane.
//   PHY=0: the real 640x480@60 timing, words taken from the encoders directly.
// Both: syncs, counts, colour bars, then framebuffer frames through a model DMA on a separate
// 42 MHz clock (line requests, line buffer, ready handshake), one deliberately late line
// (exactly one underflow, shown black), video disabled (black), then text mode: a model text
// buffer with start row 3, every pixel against the font ROM and the VGA palette.
`timescale 1ps / 1ps
`default_nettype none

module tb_video_out;
  parameter PHY = 1;
  parameter FONT_FILE = "font8x16.hex";

  localparam HA = PHY ? 64 : 640, HF = PHY ? 4 : 16, HS = PHY ? 8 : 96, HB = PHY ? 8 : 48;
  localparam VA = PHY ? 18 : 480, VF = PHY ? 2 : 10, VS = 2, VB = PHY ? 3 : 33;
  localparam HT = HA + HF + HS + HB, VT = VA + VF + VS + VB;
  // model DMA latency in system cycles: normal, and for the one late line (window = 960 px
  // = 1600 cycles at 640x480, 104 px = 173 cycles at the reduced timing)
  localparam DMA_NORMAL = PHY ? 60 : 800;
  localparam DMA_LATE   = PHY ? 250 : 2400;
  localparam LATE_LINE  = PHY ? 5 : 100;

  GSR GSR (.GSRI(1'b1));

  // ---------------------------------------------------------------- clocks and reset
  reg fclk = 1'b0, sclk = 1'b0;
  always #3968 fclk = !fclk;            // 126 MHz
  always #11905 sclk = !sclk;           // 42 MHz
  wire pclk;
  reg  pll_lock = 1'b0;
  initial #100000 pll_lock = 1'b1;
  CLKDIV #(.DIV_MODE("5"), .GSREN("false")) div (
      .HCLKIN(fclk), .RESETN(pll_lock), .CALIB(1'b0), .CLKOUT(pclk));
  reg [3:0] prst = 4'hF;
  always @(posedge pclk) prst <= {prst[2:0], 1'b0};
  wire rst = prst[3];

  // ---------------------------------------------------------------- DUT
  reg         en = 1'b0, test = 1'b1, text = 1'b0;
  reg  [ 4:0] tstart = 5'd0;
  reg  [12:0] cursor = 13'd0;
  reg         blink = 1'b0;               // the frame's cursor phase (BLINK=0: every frame)
  integer     cur_px = 0;                 // cursor pixels checked
  reg  [31:0] tbm [0:1199];               // model text buffer
  reg  [31:0] tb_dat;
  wire [10:0] tb_adr;
  reg  [ 7:0] tfont [0:4095];
  integer     ti;
  initial begin
    $readmemh(FONT_FILE, tfont);
    for (ti = 0; ti < 1200; ti = ti + 1)
      tbm[ti] = {8'(ti * 7 + 3), 8'(ti * 13 + 33), 8'(ti * 5 + 1), 8'(ti * 11 + 40)};
  end
  always @(posedge pclk) tb_dat <= tbm[tb_adr];
  wire        req_tog, uf_tog, frame_tog, vblank;
  wire [ 9:0] req_line, lb_adr;
  reg         rdy_tog = 1'b0;
  reg  [ 9:0] rdy_line = 10'd0;
  reg  [31:0] lb [0:1023];
  reg  [31:0] lb_dat;
  wire [ 9:0] t0, t1, t2;

  video_out #(.FONT_FILE(FONT_FILE), .BLINK(0), .H_ACTIVE(HA), .H_FP(HF), .H_SYNC(HS), .H_BP(HB),
              .V_ACTIVE(VA), .V_FP(VF), .V_SYNC(VS), .V_BP(VB)) dut (
      .i_clk(pclk), .i_rst(rst), .i_en(en), .i_test(test), .i_text(text), .i_tstart(tstart),
      .i_cursor(cursor), .o_tb_adr(tb_adr), .i_tb_dat(tb_dat),
      .o_req_tog(req_tog), .o_req_line(req_line), .i_rdy_tog(rdy_tog), .i_rdy_line(rdy_line),
      .o_lb_adr(lb_adr), .i_lb_dat(lb_dat),
      .o_underflow_tog(uf_tog), .o_frame_tog(frame_tog), .o_vblank(vblank),
      .o_tmds0(t0), .o_tmds1(t1), .o_tmds2(t2));
  always @(posedge pclk) lb_dat <= lb[lb_adr];

  // framebuffer pattern
  function [15:0] fbpix(input integer x, input integer y);
    fbpix = {y[6:0], x[8:0]} ^ 16'hA5C3;
  endfunction

  // ---------------------------------------------------------------- model DMA (42 MHz)
  reg [2:0] req_s = 3'd0;
  reg [9:0] q_line [0:7];
  integer   q_due  [0:7];
  integer   q_head = 0, q_tail = 0, scyc = 0, i;
  always @(posedge sclk) begin
    scyc <= scyc + 1;
    req_s <= {req_s[1:0], req_tog};
    if (req_s[2] != req_s[1]) begin
      q_line[q_tail % 8] = req_line;
      q_due[q_tail % 8]  = scyc + ((req_line == LATE_LINE && late_armed) ? DMA_LATE : DMA_NORMAL);
      if (req_line == LATE_LINE && late_armed) begin
        late_armed = 0;
        late_done  = 1;
      end
      q_tail = q_tail + 1;
    end
    if (q_head != q_tail && q_due[q_head % 8] <= scyc) begin
      for (i = 0; i < HA / 2; i = i + 1)
        lb[{q_line[q_head % 8][0], i[8:0]}] = {fbpix(2 * i + 1, q_line[q_head % 8]), fbpix(2 * i, q_line[q_head % 8])};
      rdy_line <= q_line[q_head % 8];
      rdy_tog  <= !rdy_tog;
      q_head = q_head + 1;
    end
  end
  reg late_armed = 0, late_done = 0;

  // ---------------------------------------------------------------- word stream
  reg        w_valid;
  reg [ 9:0] w0, w1, w2;

  generate
    if (PHY) begin : g_phy
      wire       clk_p, clk_n;
      wire [2:0] d_p, d_n;
      hdmi_phy_gowin phy (
          .i_pclk(pclk), .i_fclk(fclk), .i_rst(rst),
          .i_tmds0(t0), .i_tmds1(t1), .i_tmds2(t2),
          .o_clk_p(clk_p), .o_clk_n(clk_n), .o_d_p(d_p), .o_d_n(d_n));

      // sample each bit a quarter FCLK period after the edge that launched it
      reg [9:0] sr [0:3];
      integer   nbit = 0, phase = -1, run = 0, run_phase = -1, k;
      wire [3:0] lane = {clk_p, d_p[2], d_p[1], d_p[0]};
      task sample;
        begin
          if ({clk_n, d_n} !== ~{clk_p, d_p}) begin
            $display("FAIL: n output is not the complement of p at %0t", $time);
            $finish;
          end
          for (k = 0; k < 4; k = k + 1) sr[k] = {lane[k], sr[k][9:1]};
          nbit = nbit + 1;
          if (phase < 0) begin
            // word boundary: where the clock lane holds 1111100000 (first bit first), which
            // has one phase only; lock after 3 words in a row
            if (sr[3] == 10'b0000011111) begin
              if (run_phase == nbit % 10) run = run + 1;
              else begin
                run_phase = nbit % 10;
                run = 1;
              end
              if (run == 3) phase = run_phase;
            end
          end else if (nbit % 10 == phase) begin
            if (sr[3] !== 10'b0000011111) begin
              $display("FAIL: clock lane %b at the word boundary (%0t)", sr[3], $time);
              $finish;
            end
            w0 = sr[0];
            w1 = sr[1];
            w2 = sr[2];
            check_word;
          end
        end
      endtask
      always @(posedge fclk) if (!rst) #1984 sample;
      always @(negedge fclk) if (!rst) #1984 sample;
    end else begin : g_words
      always @(posedge pclk) if (!rst) begin
        #1000;
        w0 = t0;
        w1 = t1;
        w2 = t2;
        check_word;
      end
    end
  endgenerate

  // ---------------------------------------------------------------- checker
  function [7:0] dec(input [9:0] q);
    reg [7:0] d;
    integer j;
    begin
      d = q[9] ? ~q[7:0] : q[7:0];
      dec[0] = d[0];
      for (j = 1; j < 8; j = j + 1) dec[j] = q[8] ? (d[j] ^ d[j-1]) : !(d[j] ^ d[j-1]);
    end
  endfunction
  function [1:0] ctrl(input [9:0] q);
    case (q)
      10'b1101010100: ctrl = 2'b00;
      10'b0010101011: ctrl = 2'b01;
      10'b0101010100: ctrl = 2'b10;
      default:        ctrl = 2'b11;
    endcase
  endfunction
  function [15:0] barpix(input integer x, input integer y);
    reg [15:0] b;
    integer r;
    begin
      if (x < 80) b = 16'hFFFF; else if (x < 160) b = 16'hFFE0; else if (x < 240) b = 16'h07FF;
      else if (x < 320) b = 16'h07E0; else if (x < 400) b = 16'hF81F; else if (x < 480) b = 16'hF800;
      else if (x < 560) b = 16'h001F; else b = 16'h0000;
      r = x / 20;
      if (x == 0 || x == HA - 1 || y == 0 || y == VA - 1) barpix = 16'hFFFF;
      else if (y >= 360) barpix = {r[4:0], r[4:0], r[4], r[4:0]};
      else barpix = b;
    end
  endfunction

  integer frames = 0, words = 0, x = 0, y = -1, de_px = 0, hs_run = 0, vs_words = 0;
  integer errors = 0, uf_seen = 0, black_lines = 0, mode = 0;   // 0 bars, 1 fb, 2 black, 3 text
  function [15:0] vgapal(input [3:0] c);
    case (c)
      0: vgapal = 16'h0000; 1: vgapal = 16'h0015; 2: vgapal = 16'h0540; 3: vgapal = 16'h0555;
      4: vgapal = 16'hA800; 5: vgapal = 16'hA815; 6: vgapal = 16'hAAA0; 7: vgapal = 16'hAD55;
      8: vgapal = 16'h52AA; 9: vgapal = 16'h52BF; 10: vgapal = 16'h57EA; 11: vgapal = 16'h57FF;
      12: vgapal = 16'hFAAA; 13: vgapal = 16'hFABF; 14: vgapal = 16'hFFEA; default: vgapal = 16'hFFFF;
    endcase
  endfunction
  function [15:0] textpix(input integer x, input integer y);
    integer row, w;
    reg [15:0] tc;
    reg [7:0] g;
    begin
      row  = (y / 16 + tstart) % 30;
      w    = row * 40 + x / 16;
      tc   = ((x / 8) % 2) ? tbm[w][31:16] : tbm[w][15:0];
      g    = tfont[tc[7:0] * 16 + y % 16];
      if (cursor[12] && blink && x / 8 == cursor[6:0] && y / 16 == cursor[11:7] && y % 16 >= 14) begin
        g = 8'hFF;
        cur_px = cur_px + 1;
      end
      textpix = vgapal(g[7 - x % 8] ? tc[11:8] : tc[15:12]);
    end
  endfunction
  reg     in_de = 0, was_vs = 0, line_black = 1, line_good = 1, started = 0;
  reg [1:0] c;
  reg [15:0] exp565;
  reg [ 7:0] r8, g8, b8;
  reg       uf_prev = 0;

  task fail(input [8*48-1:0] what);
    begin
      errors = errors + 1;
      if (errors < 10) $display("FAIL: %0s frame %0d x %0d y %0d (%0t)", what, frames, x, y, $time);
    end
  endtask

  task end_line;
    begin
      if (de_px != HA) fail("pixels in line");
      if (line_black && mode == 1) black_lines = black_lines + 1;
      else if (!line_good) fail("pixel mismatch");
      y = y + 1;
    end
  endtask

  task check_word;
    begin
      words = words + 1;
      if (w0 == 10'b1101010100 || w0 == 10'b0010101011 ||
          w0 == 10'b0101010100 || w0 == 10'b1010101011) begin
        // blanking: lanes 1 and 2 must send C = 00
        if (w1 != 10'b1101010100 || w2 != 10'b1101010100) fail("lane 1/2 control symbol");
        c = ctrl(w0);
        if (in_de) begin
          in_de = 0;
          end_line;
        end
        if (!c[0]) hs_run = hs_run + 1;
        else if (hs_run != 0) begin
          if (started && hs_run != HS) fail("hsync width");
          hs_run = 0;
        end
        if (!c[1]) begin
          if (!was_vs) begin                     // vsync starts: frame boundary
            if (started) begin
              if (y != VA) fail("visible lines");
              if (words != HT * VT) fail("words per frame");
              frames = frames + 1;
            end
            started = 1;
            words = 0;
            vs_words = 0;
            y = -1;
          end
          vs_words = vs_words + 1;
        end else if (was_vs && vs_words != VS * HT) fail("vsync width");
        was_vs = !c[1];
      end else begin
        if (!started) begin
          // before the first vsync: ignore
        end else begin
          if (!in_de) begin
            in_de = 1;
            x = 0;
            de_px = 0;
            line_black = 1;
            line_good = 1;
            if (y < 0) begin
              y = 0;
              mode = dut.frame_test ? 0 : dut.frame_text ? 3 : dut.frame_en ? 1 : 2;
              blink = dut.fcnt[0];
            end
          end
          b8 = dec(w0);
          g8 = dec(w1);
          r8 = dec(w2);
          exp565 = (mode == 0) ? barpix(x, y) : (mode == 1) ? fbpix(x, y) :
                   (mode == 3) ? textpix(x, y) : 16'h0000;
          if ({r8, g8, b8} != {exp565[15:11], exp565[15:13], exp565[10:5], exp565[10:9],
                               exp565[4:0], exp565[4:2]}) line_good = 0;
          if ({r8, g8, b8} != 24'd0) line_black = 0;
          x = x + 1;
          de_px = de_px + 1;
        end
      end
    end
  endtask

  // underflow toggles, counted in the pixel domain
  always @(posedge pclk) begin
    if (uf_tog != uf_prev) uf_seen = uf_seen + 1;
    uf_prev <= uf_tog;
  end

  // ---------------------------------------------------------------- sequence
  initial begin
    wait (frames == 2);
    $display("bars: %0d frames checked", frames);
    test = 0;
    en   = 1;
    wait (frames == 5);
    if (black_lines != 0) fail("framebuffer lines black");
    if (uf_seen != 0) fail("underflow with an on-time DMA");
    $display("framebuffer: frames 3-4 checked, underflows %0d", uf_seen);
    late_armed = 1;
    wait (late_done);
    wait (frames == 7);
    if (uf_seen != 1) fail("one late line, underflow count");
    if (black_lines != 1) fail("one late line, black lines");
    $display("late line: underflows %0d, black lines %0d", uf_seen, black_lines);
    en = 0;
    wait (frames == 9);
    tstart = 5'd3;
    cursor = {1'b1, 5'(VA / 16 - 1), 7'(HA / 8 - 3)};
    text = 1;
    wait (frames == 12);
    if (cur_px != 16) fail("cursor pixels (one of two frames)");
    $display("text: frames 10-11 checked, %0d cursor pixels", cur_px);
    $display("%0s PHY=%0d: %0d frames, %0d errors", errors ? "FAIL" : "PASS", PHY, frames, errors);
    $finish;
  end

  initial begin
    #(64'd2_000_000_000 * (PHY ? 1 : 150));
    $display("FAIL: timeout at frame %0d", frames);
    $finish;
  end

endmodule

`default_nettype wire
