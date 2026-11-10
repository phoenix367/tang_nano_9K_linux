// TMDS serializers and outputs for the Tang Nano 9K HDMI connector (GW1NR-9 primitives).
// One OSER10 per lane (D0 is sent first; FCLK = 5 x PCLK, both edges) into an ELVDS_OBUF
// pair. The clock lane sends 1111100000 through a fourth OSER10, so it has the same output
// path as the data lanes. Pins: clock 69/68, data0 71/70, data1 73/72, data2 75/74 (p/n);
// these are also the 40-pin RGB LCD connector's lines, so no panel may be plugged in.
`default_nettype none

module hdmi_phy_gowin (
    input  wire       i_pclk,       // pixel clock
    input  wire       i_fclk,       // 5 x pixel clock (same source, CLKDIV)
    input  wire       i_rst,        // pixel-domain reset
    input  wire [9:0] i_tmds0,      // blue + syncs
    input  wire [9:0] i_tmds1,      // green
    input  wire [9:0] i_tmds2,      // red
    output wire       o_clk_p,
    output wire       o_clk_n,
    output wire [2:0] o_d_p,
    output wire [2:0] o_d_n
);

  wire [9:0] word [0:3];
  assign word[0] = i_tmds0;
  assign word[1] = i_tmds1;
  assign word[2] = i_tmds2;
  assign word[3] = 10'b0000011111;            // clock lane: five ones (sent first), five zeros

  wire [3:0] ser;
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_lane
      OSER10 ser10 (
          .Q    (ser[i]),
          .D0   (word[i][0]), .D1(word[i][1]), .D2(word[i][2]), .D3(word[i][3]), .D4(word[i][4]),
          .D5   (word[i][5]), .D6(word[i][6]), .D7(word[i][7]), .D8(word[i][8]), .D9(word[i][9]),
          .PCLK (i_pclk),
          .FCLK (i_fclk),
          .RESET(i_rst)
      );
    end
  endgenerate

  ELVDS_OBUF obuf_c (.I(ser[3]), .O(o_clk_p), .OB(o_clk_n));
  ELVDS_OBUF obuf_0 (.I(ser[0]), .O(o_d_p[0]), .OB(o_d_n[0]));
  ELVDS_OBUF obuf_1 (.I(ser[1]), .O(o_d_p[1]), .OB(o_d_n[1]));
  ELVDS_OBUF obuf_2 (.I(ser[2]), .O(o_d_p[2]), .OB(o_d_n[2]));

endmodule

`default_nettype wire
