// Video controller (doc/video_plan.md): 640x480@60 RGB565 framebuffer scanout from PSRAM.
// System clock side: registers, line fetch DMA (video_dma.v, through psram_arb); pixel clock
// side: timing, pixels and TMDS (video_out.v). Between them, the line buffer (two lines,
// dual-clock block RAM) and the request/ready toggles.
//
// Registers (SYSCON words 8..10, 0x1110_0020; reads come back through syscon's status
// words, writes are decoded here):
//   0x20 CTRL    bit 0 EN: scan out the framebuffer (else black); bit 1 TEST: colour bars
//                (overrides the others); bit 2 TEXT: text mode (overrides EN; the DMA then
//                stays idle). Reset: TEST. They apply from the next frame.
//   0x24 BASE    physical byte address of the framebuffer (PSRAM, 32-byte aligned), taken
//                when a frame starts. Reset 0x8070_0000.
//   0x28 STATUS  bit 0 vblank; bit 1 underflow (a line was not fetched in time; sticky,
//                write 1 to clear); bits 31:16 frame counter.
//   0x2C YOFF    start line 0..479 (Y-wrap panning: screen line n shows framebuffer line
//                (n + YOFF) mod 480), taken when a frame starts. Reset 0. The framebuffer
//                console scrolls with it (the kernel's qervfb driver).
//   0x30 TSTART  text mode: first text-buffer row on screen, 0..29 (hardware scrolling).
//   0x34 CURSOR  text mode: bit 12 enable, bits 11:7 row, 6:0 column (screen coordinates).
// Text buffer (soc_top: 0x1180_0000, write-only): 80 x 30 cells of {attribute, character},
// 16 bits each, row-major (cell c of row r at byte 160 * r + 2 * c); byte writes work.
`default_nettype none

module video_ctrl #(
    parameter CLK_HZ    = 42000000,
    parameter FONT_FILE = "font8x16.hex"
) (
    input  wire        i_clk,
    input  wire        i_rst,
    // register writes: word 0..5 = CTRL, BASE, STATUS, YOFF, TSTART, CURSOR (i_wr: one cycle
    // per bus write)
    input  wire [ 2:0] i_adr,
    input  wire [31:0] i_dat,
    input  wire        i_wr,
    output wire [191:0] o_regs,           // {CURSOR, TSTART, YOFF, STATUS, BASE, CTRL}
    // text buffer writes (one cycle per bus write; word = two cells)
    input  wire        i_tb_we,
    input  wire [10:0] i_tb_adr,
    input  wire [31:0] i_tb_dat,
    input  wire [ 3:0] i_tb_sel,
    // psram_arb DMA port
    output wire        o_req,
    output wire        o_urgent,
    output wire [22:2] o_adr,
    input  wire        i_gnt,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata,
    // pixel clock domain
    input  wire        i_pclk,
    input  wire        i_prst,
    output wire [ 9:0] o_tmds0,
    output wire [ 9:0] o_tmds1,
    output wire [ 9:0] o_tmds2,
    output wire        o_dbg_de,
    output wire        o_dbg_hs,
    output wire        o_dbg_vs,
    output wire [15:0] o_dbg_px
);

  // ---------------------------------------------------------------- registers
  reg  [ 2:0] ctrl;
  reg  [ 4:0] tstart;
  reg  [12:0] cursor;
  reg  [31:0] base;
  reg  [ 8:0] yoff;
  reg         underflow;
  reg  [15:0] frames;
  reg  [ 1:0] vblank_s;
  reg  [ 2:0] uf_s, fr_s;
  wire        uf_tog, fr_tog, vblank;

  always @(posedge i_clk) begin
    vblank_s <= {vblank_s[0], vblank};
    uf_s     <= {uf_s[1:0], uf_tog};
    fr_s     <= {fr_s[1:0], fr_tog};
    if (fr_s[2] != fr_s[1]) frames <= frames + 16'd1;
    if (i_wr & (i_adr == 3'd2) & i_dat[1]) underflow <= 1'b0;
    if (uf_s[2] != uf_s[1]) underflow <= 1'b1;
    if (i_wr & (i_adr == 3'd0)) ctrl <= i_dat[2:0];
    if (i_wr & (i_adr == 3'd1)) base <= {i_dat[31:5], 5'd0};
    if (i_wr & (i_adr == 3'd3)) yoff <= i_dat[8:0];
    if (i_wr & (i_adr == 3'd4)) tstart <= i_dat[4:0];
    if (i_wr & (i_adr == 3'd5)) cursor <= i_dat[12:0];
    if (i_rst) begin
      ctrl      <= 3'b010;
      tstart    <= 5'd0;
      cursor    <= 13'd0;
      base      <= 32'h8070_0000;
      yoff      <= 9'd0;
      underflow <= 1'b0;
      frames    <= 16'd0;
    end
  end
  assign o_regs = {19'd0, cursor, 27'd0, tstart, 23'd0, yoff,
                   frames, 14'd0, underflow, vblank_s[1], base, 29'd0, ctrl};

  // ---------------------------------------------------------------- line fetch
  wire        req_tog, rdy_tog;
  wire [ 9:0] req_line, rdy_line;
  wire        lb_we;
  wire [ 9:0] lb_wadr, lb_radr;
  wire [31:0] lb_wdat;

  video_dma #(.CLK_HZ(CLK_HZ)) dma (
      .i_clk     (i_clk),
      .i_rst     (i_rst),
      .i_base    (base[22:5]),
      .i_yoff    (yoff),
      .i_req_tog (req_tog),
      .i_req_line(req_line),
      .o_rdy_tog (rdy_tog),
      .o_rdy_line(rdy_line),
      .o_req     (o_req),
      .o_urgent  (o_urgent),
      .o_adr     (o_adr),
      .i_gnt     (i_gnt),
      .i_rvalid  (i_rvalid),
      .i_rdata   (i_rdata),
      .o_lb_we   (lb_we),
      .o_lb_adr  (lb_wadr),
      .o_lb_dat  (lb_wdat)
  );

  // line buffer: written on i_clk, read on i_pclk (two block RAMs)
  reg [31:0] lb[0:1023];
  reg [31:0] lb_q;
  always @(posedge i_clk) if (lb_we) lb[lb_wadr] <= lb_wdat;
  always @(posedge i_pclk) lb_q <= lb[lb_radr];

  // text buffer: written on i_clk (byte lanes), read on i_pclk
  reg [31:0] tb[0:1199];
  reg [31:0] tb_q;
  wire [10:0] tb_radr;
  always @(posedge i_clk)
    if (i_tb_we) begin
      if (i_tb_sel[0]) tb[i_tb_adr][ 7: 0] <= i_tb_dat[ 7: 0];
      if (i_tb_sel[1]) tb[i_tb_adr][15: 8] <= i_tb_dat[15: 8];
      if (i_tb_sel[2]) tb[i_tb_adr][23:16] <= i_tb_dat[23:16];
      if (i_tb_sel[3]) tb[i_tb_adr][31:24] <= i_tb_dat[31:24];
    end
  always @(posedge i_pclk) tb_q <= tb[tb_radr];

  // ---------------------------------------------------------------- pixel side
  video_out #(.FONT_FILE(FONT_FILE)) vo (
      .i_clk          (i_pclk),
      .i_rst          (i_prst),
      .i_en           (ctrl[0]),
      .i_test         (ctrl[1]),
      .i_text         (ctrl[2]),
      .i_tstart       (tstart),
      .i_cursor       (cursor),
      .o_req_tog      (req_tog),
      .o_req_line     (req_line),
      .i_rdy_tog      (rdy_tog),
      .i_rdy_line     (rdy_line),
      .o_lb_adr       (lb_radr),
      .i_lb_dat       (lb_q),
      .o_tb_adr       (tb_radr),
      .i_tb_dat       (tb_q),
      .o_underflow_tog(uf_tog),
      .o_frame_tog    (fr_tog),
      .o_vblank       (vblank),
      .o_tmds0        (o_tmds0),
      .o_tmds1        (o_tmds1),
      .o_tmds2        (o_tmds2),
      .o_dbg_de       (o_dbg_de),
      .o_dbg_hs       (o_dbg_hs),
      .o_dbg_vs       (o_dbg_vs),
      .o_dbg_px       (o_dbg_px)
  );

endmodule

`default_nettype wire
