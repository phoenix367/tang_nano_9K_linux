// PSRAM calibration probe for the Tang Nano 9K: rPLL + the PSRAM IP, no CPU. A beacon UART
// on the 27 MHz crystal (1 Mbaud = 27 clocks/bit) sends "<tag> lock=L c0=X c1=Y t=TTTT\r\n"
// about 10 times a second, where t counts 1/27 MHz * 2^16 (~2.4 ms) ticks since the IP's
// rst_n rose, frozen when both channels have calibrated. Built by fpga/probe/run.sh with the
// rPLL dividers as defines (PROBE_IDIV/FBDIV/ODIV, PROBE_TAG).
`default_nettype none

module psram_probe_top (
    input  wire        clk_27m,
    input  wire        btn_rst_n,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire [ 5:0] led_n,
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n
);

  wire memory_clk, pll_lock;
  wire gnd = 1'b0;
  wire clkoutp_o, clkoutd_o, clkoutd3_o;

  rPLL rpll_inst (
      .CLKOUT(memory_clk), .LOCK(pll_lock), .CLKOUTP(clkoutp_o), .CLKOUTD(clkoutd_o),
      .CLKOUTD3(clkoutd3_o), .RESET(gnd), .RESET_P(gnd), .CLKIN(clk_27m), .CLKFB(gnd),
      .FBDSEL({6{gnd}}), .IDSEL({6{gnd}}), .ODSEL({6{gnd}}), .PSDA({4{gnd}}),
      .DUTYDA({4{gnd}}), .FDLY({4{gnd}})
  );
  defparam rpll_inst.FCLKIN = "27";
  defparam rpll_inst.DYN_IDIV_SEL = "false";
  defparam rpll_inst.IDIV_SEL = `PROBE_IDIV;
  defparam rpll_inst.DYN_FBDIV_SEL = "false";
  defparam rpll_inst.FBDIV_SEL = `PROBE_FBDIV;
  defparam rpll_inst.DYN_ODIV_SEL = "false";
  defparam rpll_inst.ODIV_SEL = `PROBE_ODIV;
  defparam rpll_inst.PSDA_SEL = "0000";
  defparam rpll_inst.DYN_DA_EN = "true";
  defparam rpll_inst.DUTYDA_SEL = "1000";
  defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
  defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
  defparam rpll_inst.CLKOUT_DLY_STEP = 0;
  defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
  defparam rpll_inst.CLKFB_SEL = "internal";
  defparam rpll_inst.CLKOUT_BYPASS = "false";
  defparam rpll_inst.CLKOUTP_BYPASS = "false";
  defparam rpll_inst.CLKOUTD_BYPASS = "false";
  defparam rpll_inst.DYN_SDIV_SEL = 2;
  defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
  defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
  defparam rpll_inst.DEVICE = "GW1NR-9C";

  // IP reset: held for ~10 ms after configuration, then follows the button
  reg [18:0] por = 19'd0;
  always @(posedge clk_27m) if (!por[18]) por <= por + 19'd1;
  wire ip_rst_n = por[18] & btn_rst_n;

  wire calib0, calib1, clk_out;
  Video_frame_buffer psram (
      .clk(clk_27m), .rst_n(ip_rst_n), .memory_clk(memory_clk), .pll_lock(pll_lock),
      .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .IO_psram_rwds(IO_psram_rwds),
      .O_psram_reset_n(O_psram_reset_n), .IO_psram_dq(IO_psram_dq), .O_psram_cs_n(O_psram_cs_n),
      .init_calib0(calib0), .init_calib1(calib1), .clk_out(clk_out),
      .cmd0(1'b0), .cmd1(1'b0), .cmd_en0(1'b0), .cmd_en1(1'b0), .addr0(21'd0), .addr1(21'd0),
      .wr_data0(32'd0), .wr_data1(32'd0), .rd_data0(), .rd_data1(), .rd_data_valid0(),
      .rd_data_valid1(), .data_mask0(4'd0), .data_mask1(4'd0)
  );

  // ---------------------------------------------------------------- beacon (27 MHz domain)
  reg [2:0] c0_s, c1_s, lk_s;
  always @(posedge clk_27m) begin
    c0_s <= {c0_s[1:0], calib0};
    c1_s <= {c1_s[1:0], calib1};
    lk_s <= {lk_s[1:0], pll_lock};
  end
  wire c0 = c0_s[2], c1 = c1_s[2], lk = lk_s[2];

  reg [31:0] t_cnt = 32'd0;              // since ip_rst_n, frozen at calibration
  always @(posedge clk_27m)
    if (!ip_rst_n) t_cnt <= 32'd0;
    else if (!(c0 & c1)) t_cnt <= t_cnt + 32'd1;
  wire [15:0] t = t_cnt[31:16];

  function [7:0] hex(input [3:0] v);
    hex = v < 10 ? 8'h30 + v : 8'h57 + v;
  endfunction

  localparam N = 30;                     // PROBE_TAG is 4 characters
  // "`PROBE_TAG lock=L c0=X c1=Y t=TTTT\r\n", built from 8-bit characters
  wire [8*N-1:0] msg = {`PROBE_TAG, " lock=", 8'h30 + lk, " c0=", 8'h30 + c0, " c1=", 8'h30 + c1,
                        " t=", hex(t[15:12]), hex(t[11:8]), hex(t[7:4]), hex(t[3:0]), 8'h0d, 8'h0a};

  reg [21:0] period = 22'd0;
  reg [ 4:0] idx = N;                    // character index, N = idle
  reg [ 9:0] sh = 10'h3FF;
  reg [ 3:0] bits = 4'd0;
  reg [ 4:0] div = 5'd0;
  reg [8*N-1:0] snap;
  always @(posedge clk_27m) begin
    period <= period + 22'd1;
    if (bits == 4'd0) begin
      if (idx < N) begin
        sh   <= {1'b1, snap[8*(N-1-idx) +: 8], 1'b0};
        bits <= 4'd10;
        div  <= 5'd0;
        idx  <= idx + 5'd1;
      end else if (period == 22'd0) begin
        snap <= msg;
        idx  <= 5'd0;
      end
    end else if (div == 5'd26) begin
      div  <= 5'd0;
      sh   <= {1'b1, sh[9:1]};
      bits <= bits - 4'd1;
    end else
      div <= div + 5'd1;
  end
  assign uart_tx = sh[0];

  reg [24:0] beat = 25'd0;
  always @(posedge clk_out) beat <= beat + 25'd1;
  assign led_n = ~{2'b00, c1, c0, lk, beat[24]};
  wire unused = uart_rx;

endmodule

`default_nettype wire
