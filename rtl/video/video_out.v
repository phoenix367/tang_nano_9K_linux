// Pixel side of the video controller (doc/video_plan.md): 640x480@60 timing; test pattern,
// framebuffer pixels from a line buffer, or text mode; RGB565 -> 888, three TMDS encoders.
// Runs on the pixel clock (25.2 MHz = 126 MHz / 5: 800 x 525 x 60 Hz).
//
// Line fetch handshake with the DMA (system clock domain, video_dma.v):
//   - At the first blank pixel of every line v (active or not), line n = v + 2 (mod 525) is
//     requested if it is visible and the frame is enabled: o_req_line = n, o_req_tog toggles.
//     The line buffer half n[0] was last read by line n - 2, whose active part just ended;
//     line n starts 960 pixel clocks later (the DMA's window).
//   - The DMA answers with i_rdy_line = n and a toggle of i_rdy_tog once the line is in the
//     buffer. At the start of each visible line the line must be there; otherwise it is shown
//     black and o_underflow_tog toggles.
//   o_req_line / i_rdy_line change only together with their toggles and are read two or more
//   cycles after the synchronized toggle edge, so they need no synchronizer of their own.
//   i_en / i_test / i_text, i_tstart and i_cursor are quasi-static values from the register
//   block: synchronized here and applied per frame (sampled when line 0 is requested).
// Text mode (i_text): 80 x 30 cells of 8 x 16 pixels. Cell = {attribute, character} (the
//   Linux VT's layout): CP437 glyph from the font ROM, foreground attr[3:0] and background
//   attr[7:4] from the 16-colour VGA palette. Screen row r shows text-buffer row
//   (r + i_tstart) mod 30 (hardware scrolling). i_cursor = {enable, row, col} in screen
//   coordinates: an underline (glyph rows 14-15) blinking at ~2 Hz. Text buffer: 1200 words
//   of two cells (cell c of a row in half c[0] of word row * 40 + c / 2), registered read.
// Line buffer: 2 halves x 320 words; pixel x of a line is halfword x[0] of word x[9:1]
// (little-endian RGB565, the Linux "r5g6b5" layout). Registered read: data one cycle later.
//
// Pipeline: counters -> stage 0 (x, y, de, syncs; line-buffer and text-buffer addresses)
// -> stage 1 (line-buffer data, text cell; glyph address) -> stage 2 (pixel) -> TMDS
// (registered). o_tmds*[0] is the first bit on the wire.
`default_nettype none

module video_out #(
    parameter H_ACTIVE = 640, H_FP = 16, H_SYNC = 96, H_BP = 48,
    parameter V_ACTIVE = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33,
    parameter FONT_FILE = "font8x16.hex",
    parameter BLINK = 4                  // cursor blink: frame counter bit (4: ~1.9 Hz)
) (
    input  wire        i_clk,
    input  wire        i_rst,
    // control (system clock domain levels)
    input  wire        i_en,             // show the framebuffer (else black)
    input  wire        i_test,           // colour bars (overrides the others)
    input  wire        i_text,           // text mode (overrides i_en)
    input  wire [ 4:0] i_tstart,         // text: first buffer row on screen, 0..29
    input  wire [12:0] i_cursor,         // text: {enable, row[4:0], col[6:0]}
    // line fetch handshake (see above)
    output reg         o_req_tog,
    output reg  [ 9:0] o_req_line,
    input  wire        i_rdy_tog,
    input  wire [ 9:0] i_rdy_line,
    // line buffer read port
    output wire [ 9:0] o_lb_adr,         // {half, word}
    input  wire [31:0] i_lb_dat,
    // text buffer read port
    output reg  [10:0] o_tb_adr,         // word, 0..1199
    input  wire [31:0] i_tb_dat,
    // status
    output reg         o_underflow_tog,  // a visible line was not fetched in time
    output reg         o_frame_tog,      // toggles at every frame start
    output reg         o_vblank,
    // TMDS words: lane 0 = blue + syncs, 1 = green, 2 = red
    output wire [ 9:0] o_tmds0,
    output wire [ 9:0] o_tmds1,
    output wire [ 9:0] o_tmds2,
    // the pixel stream before encoding (simulation frame dumps)
    output wire        o_dbg_de,
    output wire        o_dbg_hs,
    output wire        o_dbg_vs,
    output wire [15:0] o_dbg_px
);

  localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
  localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525

  // ---------------------------------------------------------------- CDC inputs
  reg [1:0] en_s, test_s, text_s;
  reg [2:0] rdy_s;
  reg [4:0] tstart_s1, tstart_s2;
  reg [12:0] cursor_s1, cursor_s2;
  always @(posedge i_clk) begin
    en_s   <= {en_s[0], i_en};
    test_s <= {test_s[0], i_test};
    text_s <= {text_s[0], i_text};
    rdy_s  <= {rdy_s[1:0], i_rdy_tog};
    {tstart_s2, tstart_s1} <= {tstart_s1, i_tstart};
    {cursor_s2, cursor_s1} <= {cursor_s1, i_cursor};
  end
  wire fb_on = en_s[1] & !test_s[1] & !text_s[1];

  // ---------------------------------------------------------------- counters
  reg [9:0] h, v;
  wire      h_last = h == H_TOTAL - 1;
  wire      v_last = v == V_TOTAL - 1;
  wire [9:0] v_next = v_last ? 10'd0 : v + 10'd1;
  // line requested at the first blank pixel of line v: v + 2 (mod V_TOTAL)
  wire [9:0] n_req  = (v >= V_TOTAL - 2) ? v + 10'd2 - V_TOTAL[9:0] : v + 10'd2;

  reg       frame_en;            // this frame shows the framebuffer
  reg       frame_test;          // this frame shows the colour bars
  reg       frame_text;          // this frame shows the text buffer
  reg [4:0] tstart;
  reg [12:0] cursor;
  reg [5:0] fcnt;                // frames (cursor blink)
  reg [9:0] rdy_line;            // last line the DMA reported
  reg       line_ok;             // the current line is in its buffer

  always @(posedge i_clk) begin
    if (rdy_s[2] != rdy_s[1]) rdy_line <= i_rdy_line;
    if (h_last) begin
      h <= 10'd0;
      v <= v_next;
      line_ok <= rdy_line == v_next;
      if (frame_en & (v_next < V_ACTIVE) & (rdy_line != v_next))
        o_underflow_tog <= !o_underflow_tog;
      if (v_last) begin
        o_frame_tog <= !o_frame_tog;
        fcnt <= fcnt + 6'd1;
      end
    end else h <= h + 10'd1;
    if (h == H_ACTIVE) begin
      if (n_req == 10'd0) begin
        frame_en   <= fb_on;
        frame_test <= test_s[1];
        frame_text <= text_s[1] & !test_s[1];
        tstart     <= (tstart_s2 < 5'd30) ? tstart_s2 : 5'd0;
        cursor     <= cursor_s2;
      end
      if ((n_req < V_ACTIVE) & ((n_req == 10'd0) ? fb_on : frame_en)) begin
        o_req_line <= n_req;
        o_req_tog  <= !o_req_tog;
      end
    end
    if (i_rst) begin
      h <= 10'd0;
      v <= 10'd0;
      frame_en <= 1'b0;
      frame_test <= 1'b1;
      frame_text <= 1'b0;
      tstart <= 5'd0;
      cursor <= 13'd0;
      fcnt <= 6'd0;
      line_ok <= 1'b0;
      rdy_line <= 10'h3FF;
      o_req_tog <= 1'b0;
      o_req_line <= 10'd0;
      o_underflow_tog <= 1'b0;
      o_frame_tog <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- stage 0
  reg [9:0] x0, y0;
  reg       de0, hs0, vs0;
  // test pattern helpers: 32-step ramp, one step per 20 pixels
  reg [4:0] ramp0, rsub0;
  always @(posedge i_clk) begin
    x0  <= h;
    y0  <= v;
    de0 <= (h < H_ACTIVE) & (v < V_ACTIVE);
    hs0 <= !((h >= H_ACTIVE + H_FP) & (h < H_ACTIVE + H_FP + H_SYNC));   // negative syncs
    vs0 <= !((v >= V_ACTIVE + V_FP) & (v < V_ACTIVE + V_FP + V_SYNC));
    o_vblank <= v >= V_ACTIVE;
    if (h == 10'd0) begin
      ramp0 <= 5'd0;
      rsub0 <= 5'd0;
    end else if (rsub0 == 5'd19) begin
      rsub0 <= 5'd0;
      ramp0 <= ramp0 + 5'd1;
    end else rsub0 <= rsub0 + 5'd1;
    o_tb_adr <= {tb_row, 5'd0} + {2'd0, tb_row, 3'd0} + {5'd0, h[9:4]};   // row * 40 + col / 2
  end
  assign o_lb_adr = {y0[0], x0[9:1]};
  // text buffer row of the counters' screen row, (v / 16 + tstart) mod 30
  wire [5:0] tb_row_s = {1'b0, v[8:4]} + {1'b0, tstart};
  wire [5:0] tb_row   = (tb_row_s >= 6'd30) ? tb_row_s - 6'd30 : tb_row_s;

  // ---------------------------------------------------------------- stage 1
  reg [9:0] x1, y1;
  reg       de1, hs1, vs1, half1;
  reg [4:0] ramp1;
  always @(posedge i_clk) begin
    {x1, y1, de1, hs1, vs1, half1, ramp1} <= {x0, y0, de0, hs0, vs0, x0[0], ramp0};
  end
  wire [15:0] cell1 = x1[3] ? i_tb_dat[31:16] : i_tb_dat[15:0];

  // font ROM: glyph g row r at {g, r}, bit 7 = leftmost pixel (registered read)
  reg [7:0] font[0:4095];
  initial $readmemh(FONT_FILE, font);
  reg [7:0] glyph2;
  always @(posedge i_clk) glyph2 <= font[{cell1[7:0], y1[3:0]}];

  // colour bars (8 x 80 pixels) over a grey ramp in the bottom quarter, white border
  reg [15:0] bar;
  always @(*) begin
    case (1'b1)
      x1 < 10'd80:  bar = 16'hFFFF;   // white
      x1 < 10'd160: bar = 16'hFFE0;   // yellow
      x1 < 10'd240: bar = 16'h07FF;   // cyan
      x1 < 10'd320: bar = 16'h07E0;   // green
      x1 < 10'd400: bar = 16'hF81F;   // magenta
      x1 < 10'd480: bar = 16'hF800;   // red
      x1 < 10'd560: bar = 16'h001F;   // blue
      default:      bar = 16'h0000;   // black
    endcase
  end
  wire        border = (x1 == 10'd0) | (x1 == H_ACTIVE - 1) | (y1 == 10'd0) | (y1 == V_ACTIVE - 1);
  wire [15:0] grey   = {ramp1, ramp1, ramp1[4], ramp1};
  wire [15:0] test_px = border ? 16'hFFFF : (y1 >= 10'd360) ? grey : bar;
  wire [15:0] fb_px   = half1 ? i_lb_dat[31:16] : i_lb_dat[15:0];

  // ---------------------------------------------------------------- stage 2
  reg [9:0]  x2, y2;
  reg        de2, hs2, vs2;
  reg [15:0] test_px2, fb_px2;
  reg [7:0]  attr2;
  always @(posedge i_clk) begin
    {x2, y2, de2, hs2, vs2} <= {x1, y1, de1, hs1, vs1};
    test_px2 <= test_px;
    fb_px2   <= fb_px;
    attr2    <= cell1[15:8];
  end

  // VGA 16-colour palette in RGB565
  function [15:0] vga(input [3:0] c);
    case (c)
      4'd0:  vga = 16'h0000; 4'd1:  vga = 16'h0015; 4'd2:  vga = 16'h0540; 4'd3:  vga = 16'h0555;
      4'd4:  vga = 16'hA800; 4'd5:  vga = 16'hA815; 4'd6:  vga = 16'hAAA0; 4'd7:  vga = 16'hAD55;
      4'd8:  vga = 16'h52AA; 4'd9:  vga = 16'h52BF; 4'd10: vga = 16'h57EA; 4'd11: vga = 16'h57FF;
      4'd12: vga = 16'hFAAA; 4'd13: vga = 16'hFABF; 4'd14: vga = 16'hFFEA; default: vga = 16'hFFFF;
    endcase
  endfunction
  wire        on_cursor = cursor[12] & fcnt[BLINK] & (x2[9:3] == cursor[6:0]) &
                          (y2[8:4] == cursor[11:7]) & (y2[3:1] == 3'b111);
  wire        ink       = glyph2[~x2[2:0]] | on_cursor;
  wire [15:0] text_px   = vga(ink ? attr2[3:0] : attr2[7:4]);
  wire [15:0] px = frame_test ? test_px2 : frame_text ? text_px :
                   (frame_en & line_ok) ? fb_px2 : 16'h0000;

  assign {o_dbg_de, o_dbg_hs, o_dbg_vs, o_dbg_px} = {de2, hs2, vs2, px};

  // RGB565 -> 888 by bit replication
  wire [7:0] r8 = {px[15:11], px[15:13]};
  wire [7:0] g8 = {px[10:5],  px[10:9]};
  wire [7:0] b8 = {px[4:0],   px[4:2]};

  tmds_encoder enc0 (.i_clk(i_clk), .i_rst(i_rst), .i_de(de2), .i_d(b8), .i_c({vs2, hs2}), .o_q(o_tmds0));
  tmds_encoder enc1 (.i_clk(i_clk), .i_rst(i_rst), .i_de(de2), .i_d(g8), .i_c(2'b00),      .o_q(o_tmds1));
  tmds_encoder enc2 (.i_clk(i_clk), .i_rst(i_rst), .i_de(de2), .i_d(r8), .i_c(2'b00),      .o_q(o_tmds2));

endmodule

`default_nettype wire
