// Video line fetch (doc/video_plan.md), system clock domain. For each line request from the
// pixel side (video_out.v: toggle + line number n), reads the line's 1280 bytes from PSRAM
// as 40 bursts of 32 B through psram_arb into line-buffer half n[0], then reports the line
// (toggle + number). The framebuffer base and the start line (i_yoff, Y-wrap panning: screen
// line n shows framebuffer line (n + yoff) mod 480) are taken when line 0 is requested, so
// new values apply from the next frame on.
//
// Pacing: at most two reads outstanding and at least 8 cycles between grants (two reads
// never return beats in the same cycle, even on different channels); the arbiter keeps the
// per-channel spacing, so a line takes 40 x 19 = 760 cycles when the channel is free.
// Urgency: a line is due 960 pixel clocks after its request, but the next request comes
// after 800, so each line must be complete within WINDOW = 800 pixel clocks of its request
// (1333 system cycles at 42 MHz); otherwise requests pile up and every later line starts
// short of time. The DMA asks the arbiter for priority over the CPU only once the time left
// no longer covers the bursts still to issue (TCMD each) plus the read latency and a margin;
// until then the CPU's misses go first.
`default_nettype none

module video_dma #(
    parameter CLK_HZ = 42000000,
    parameter PIX_HZ = 25200000,
    parameter TCMD   = 19
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [22:5] i_base,            // framebuffer byte address bits 22:5
    input  wire [ 8:0] i_yoff,            // start line, 0..479
    // pixel side (video_out), other clock domain
    input  wire        i_req_tog,
    input  wire [ 9:0] i_req_line,
    output reg         o_rdy_tog,
    output reg  [ 9:0] o_rdy_line,
    // psram_arb DMA port
    output wire        o_req,
    output reg         o_urgent,
    output wire [22:2] o_adr,
    input  wire        i_gnt,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata,
    // line buffer write port: {half, word}
    output reg         o_lb_we,
    output reg  [ 9:0] o_lb_adr,
    output reg  [31:0] o_lb_dat
);

  localparam integer BURSTS = 40;                         // 640 pixels x 2 B / 32 B
  localparam integer WINDOW = 800 * (CLK_HZ / 1000) / (PIX_HZ / 1000);
  localparam integer MARGIN = 48;                         // CDC, read latency, slack
  localparam integer NEED0  = BURSTS * TCMD + MARGIN;

  reg [2:0] req_s;
  wire      req_edge = req_s[2] != req_s[1];

  reg         busy, pend;
  reg  [ 9:0] line, pend_line;
  reg  [22:5] base_l, adr;
  reg  [ 8:0] yoff_l;

  // the framebuffer line shown on screen line n
  function [9:0] fb_line(input [9:0] n, input [8:0] yo);
    reg [9:0] y;
    begin
      y = n + {1'b0, yo};
      fb_line = (y >= 10'd480) ? y - 10'd480 : y;
    end
  endfunction
  reg  [ 5:0] issued;                     // bursts granted
  reg  [ 1:0] outst;                      // reads outstanding
  reg  [ 2:0] gap;                        // cycles until the next request may go out
  reg  [ 8:0] wptr;                       // words received
  reg  [10:0] left, need;                 // cycles to the deadline / still needed

  assign o_req = busy & (issued != BURSTS) & (outst != 2'd2) & (gap == 3'd0);
  assign o_adr = {adr, 3'd0};

  wire        last_beat = i_rvalid & (wptr == BURSTS * 8 - 1);

  // start screen line n: framebuffer line y, y * 40 bursts past the base (y * 32 + y * 8)
  task start(input [9:0] n);
    reg [9:0] y;
    begin
      y      = fb_line(n, (n == 10'd0) ? i_yoff : yoff_l);
      busy   <= 1'b1;
      line   <= n;
      adr    <= ((n == 10'd0) ? i_base : base_l) + {3'd0, y, 5'd0} + {5'd0, y, 3'd0};
      if (n == 10'd0) begin
        base_l <= i_base;
        yoff_l <= i_yoff;
      end
      issued <= 6'd0;
      wptr   <= 9'd0;
      left   <= WINDOW[10:0] - 11'd4;     // the request toggle's synchronizer
      need   <= NEED0[10:0];
    end
  endtask

  always @(posedge i_clk) begin
    req_s   <= {req_s[1:0], i_req_tog};
    o_lb_we <= 1'b0;
    if (gap != 3'd0) gap <= gap - 3'd1;
    if (left != 11'd0) left <= left - 11'd1;
    o_urgent <= busy & (left <= need);

    if (o_req & i_gnt) begin
      adr    <= adr + 18'd1;
      issued <= issued + 6'd1;
      gap    <= 3'd7;
      need   <= need - TCMD[10:0];
    end
    outst <= outst + {1'b0, o_req & i_gnt} - {1'b0, i_rvalid & (wptr[2:0] == 3'd7)};

    if (i_rvalid) begin
      o_lb_we  <= 1'b1;
      o_lb_adr <= {line[0], wptr};
      o_lb_dat <= i_rdata;
      wptr     <= wptr + 9'd1;
    end
    if (last_beat) begin
      o_rdy_line <= line;
      o_rdy_tog  <= !o_rdy_tog;
      busy       <= 1'b0;
    end
    // a request that comes while a line is still being fetched (the DMA is late) waits in a
    // one-entry queue
    if (last_beat & pend) begin
      start(pend_line);
      pend <= req_edge;
      if (req_edge) pend_line <= i_req_line;
    end else if (req_edge) begin
      if (busy & !last_beat) begin
        pend      <= 1'b1;
        pend_line <= i_req_line;
      end else start(i_req_line);
    end

    if (i_rst) begin
      busy      <= 1'b0;
      pend      <= 1'b0;
      outst     <= 2'd0;
      gap       <= 3'd0;
      o_urgent  <= 1'b0;
      o_rdy_tog <= 1'b0;
      o_rdy_line <= 10'h3FF;
      o_lb_we   <= 1'b0;
    end
  end

endmodule

`default_nettype wire
