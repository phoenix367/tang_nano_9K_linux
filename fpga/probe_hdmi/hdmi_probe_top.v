// HDMI probe (doc/video_plan.md, V0): colour bars at 640x480@60 with no CPU or memory, to
// check the video rPLL, CLKDIV, OSER10/ELVDS outputs, pins and a monitor's lock before the
// video path goes into the SoC. Build and load: fpga/probe_hdmi/run.sh.
// LEDs (active low): 0 heartbeat (pixel clock), 1 video PLL locked, 2 frame counter bit 5.
`default_nettype none

module hdmi_probe_top (
    input  wire       clk_27m,
    output wire [5:0] led_n,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

  wire fclk, lock, pclk;

  Gowin_rPLL_video pll (.clkin(clk_27m), .clkout(fclk), .lock(lock));

  CLKDIV #(.DIV_MODE("5"), .GSREN("false")) div (
      .HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0), .CLKOUT(pclk));

  reg [3:0] rst_sync;
  always @(posedge pclk or negedge lock)
    if (!lock) rst_sync <= 4'd0;
    else rst_sync <= {rst_sync[2:0], 1'b1};
  wire rst = !rst_sync[3];

  wire [9:0] t0, t1, t2;
  wire       frame_tog;
  video_out vo (
      .i_clk(pclk), .i_rst(rst), .i_en(1'b0), .i_test(1'b1),
      .o_req_tog(), .o_req_line(), .i_rdy_tog(1'b0), .i_rdy_line(10'd0),
      .o_lb_adr(), .i_lb_dat(32'd0),
      .o_underflow_tog(), .o_frame_tog(frame_tog), .o_vblank(),
      .o_tmds0(t0), .o_tmds1(t1), .o_tmds2(t2));

  hdmi_phy_gowin phy (
      .i_pclk(pclk), .i_fclk(fclk), .i_rst(rst),
      .i_tmds0(t0), .i_tmds1(t1), .i_tmds2(t2),
      .o_clk_p(tmds_clk_p), .o_clk_n(tmds_clk_n), .o_d_p(tmds_d_p), .o_d_n(tmds_d_n));

  reg [24:0] beat;
  reg [ 5:0] frames;
  reg        ft_d;
  always @(posedge pclk) begin
    beat <= beat + 25'd1;
    ft_d <= frame_tog;
    if (ft_d != frame_tog) frames <= frames + 6'd1;
  end

  assign led_n = ~{3'b000, frames[5], lock, beat[24]};

endmodule

`default_nettype wire
