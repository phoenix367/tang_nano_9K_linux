// Board top for the QERV SoC on the Tang Nano 9K (milestone M3, doc/stage1_plan.md).
//
// Clocks: the 27 MHz crystal feeds the rPLL, which makes memory_clk, and also the PSRAM IP's
// clk input (the IP needs the free-running reference there). The IP's clk_out
// (= memory_clk / 2) clocks the whole SoC: one clock domain, as in simulation.
// TANG9K_CPU_HZ (fpga/build/tang9k_cfg.v, written by fpga/build.sh) must equal clk_out; the
// UART divider (CPU_HZ / TANG9K_UART_BAUD) and the CLINT's 1 MHz prescaler derive from it.
//
// Video (TANG9K_VIDEO, doc/video_plan.md): a second rPLL makes the 126 MHz TMDS clock, a
// CLKDIV / 5 the 25.2 MHz pixel clock; the SoC's video controller produces the TMDS words and
// hdmi_phy_gowin serializes them to the HDMI connector. Without video the HDMI pairs are
// driven low.
//
// Reset: button S2 (system reset, see below). LEDs (active low, on = signal true):
//   0 heartbeat (clk_out running)   1 PLL locked   2 PSRAM calibrated (both channels)
//   3 UART TX activity              4 SoC in reset  5 poweroff requested (SYSCON)
`default_nettype none

module tang9k_top (
    input  wire        clk_27m,
    input  wire        btn_rst_n,       // button S2 (pin 3 on this board), active low: system reset
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire [ 5:0] led_n,
    // external SPI NOR flash (Image + DTB, sw/mkflash.py layout)
    output wire        flash_sck,
    output wire        flash_cs_n,
    output wire        flash_mosi,
    input  wire        flash_miso,
    // I2C (pins 25/26, open drain, as the ov7670 project) and the microSD slot in SPI mode
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,
    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs_n,
    input  wire        sd_miso,
    // on-package PSRAM: placed by the IP, no IO_LOC in the .cst
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n,
    // HDMI (pins 68-75, shared with the RGB LCD connector: no panel plugged in)
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [ 2:0] tmds_d_p,
    output wire [ 2:0] tmds_d_n
);

  localparam integer CPU_HZ    = `TANG9K_CPU_HZ;
  localparam integer UART_BAUD = `TANG9K_UART_BAUD;

  // ---------------------------------------------------------------- system reset
  // Button S2 (pin 3: the schematic says pin 4, but this board's S1/S2 silkscreen is
  // swapped, and the button labelled S2 is pin 3; see tang9k_soc.cst) resets everything: the PSRAM
  // controller (it recalibrates), cache, TLB, CPU and peripherals, so the boot ROM starts
  // over. The button is synchronized to the 27 MHz crystal and debounced (2.4 ms stable).
  // A power-on reset of ~9.7 ms follows configuration, so the PSRAM IP always starts from
  // a clean rst_n.
  reg [ 2:0] btn_s   = 3'b111;
  reg [16:0] btn_cnt = 17'd0;
  reg        btn_down = 1'b0;                   // debounced
  reg [18:0] por     = 19'd0;
  wire       btn_raw = !btn_s[2];
  always @(posedge clk_27m) begin
    btn_s <= {btn_s[1:0], btn_rst_n};
    if (btn_raw == btn_down) btn_cnt <= 17'd0;
    else if (btn_cnt[16]) begin
      btn_down <= btn_raw;
      btn_cnt  <= 17'd0;
    end else btn_cnt <= btn_cnt + 17'd1;
    if (!por[18]) por <= por + 19'd1;
  end
  wire sys_rst_n = por[18] & !btn_down;

  // ---------------------------------------------------------------- clocks
  wire memory_clk, pll_lock;

  Gowin_rPLL pll (
      .clkin (clk_27m),
      .clkout(memory_clk),
      .lock  (pll_lock)
  );

  wire        clk;                       // IP clk_out: the SoC clock
  wire        calib0, calib1;
  wire        cmd0, cmd_en0, cmd1, cmd_en1, rd_data_valid0, rd_data_valid1;
  wire [20:0] addr0, addr1;
  wire [31:0] wr_data0, wr_data1, rd_data0, rd_data1;
  wire [ 3:0] data_mask0, data_mask1;

  // PSRAM Memory Interface HS 2CH (psram_hs_2ch v1.0), copied as generated from
  // tang_nano_9K_ov7670 (Gowin V1.9.9 Beta-4, MEMORY_CLK=135, module name Video_frame_buffer):
  // the netlist rtl/sim/psram_ui_model.v was matched to (verif/psram), which also passed at
  // memory_clk 54 and 100 MHz. On the board it calibrates both channels from 54 to 135 MHz
  // except ~77.6-81 MHz (fpga/probe); memory_clk is 84 MHz (CPU 42 MHz).
  Video_frame_buffer psram (
      .clk            (clk_27m),
      .rst_n          (sys_rst_n),
      .memory_clk     (memory_clk),
      .pll_lock       (pll_lock),
      .O_psram_ck     (O_psram_ck),
      .O_psram_ck_n   (O_psram_ck_n),
      .IO_psram_rwds  (IO_psram_rwds),
      .O_psram_reset_n(O_psram_reset_n),
      .IO_psram_dq    (IO_psram_dq),
      .O_psram_cs_n   (O_psram_cs_n),
      .init_calib0    (calib0),
      .init_calib1    (calib1),
      .clk_out        (clk),
      .cmd0           (cmd0),
      .cmd1           (cmd1),
      .cmd_en0        (cmd_en0),
      .cmd_en1        (cmd_en1),
      .addr0          (addr0),
      .addr1          (addr1),
      .wr_data0       (wr_data0),
      .wr_data1       (wr_data1),
      .rd_data0       (rd_data0),
      .rd_data1       (rd_data1),
      .rd_data_valid0 (rd_data_valid0),
      .rd_data_valid1 (rd_data_valid1),
      .data_mask0     (data_mask0),
      .data_mask1     (data_mask1)
  );

  // ---------------------------------------------------------------- reset
  // SoC reset: asserted asynchronously while sys_rst_n is low or the PLL is unlocked,
  // released synchronously to clk. The cache itself waits for init_calib, so the CPU can run
  // the boot ROM (banner) before the PSRAM is ready.
  wire      rst_in_n = sys_rst_n & pll_lock;
  reg [3:0] rst_sync;
  always @(posedge clk or negedge rst_in_n)
    if (!rst_in_n) rst_sync <= 4'd0;
    else rst_sync <= {rst_sync[2:0], 1'b1};
  wire rst = !rst_sync[3];

  // ---------------------------------------------------------------- video clocks
`ifdef TANG9K_VIDEO
  localparam [0:0] VIDEO = 1'b1;
  wire hdmi_fclk, hdmi_lock, pclk;

  Gowin_rPLL_video vpll (
      .clkin (clk_27m),
      .clkout(hdmi_fclk),
      .lock  (hdmi_lock)
  );

  CLKDIV #(.DIV_MODE("5"), .GSREN("false")) hdmi_div (
      .HCLKIN(hdmi_fclk), .RESETN(hdmi_lock), .CALIB(1'b0), .CLKOUT(pclk));

  // pixel-domain reset: video PLL unlocked or SoC reset (both sides restart together)
  wire      prst_in_n = hdmi_lock & rst_in_n;
  reg [3:0] prst_sync;
  always @(posedge pclk or negedge prst_in_n)
    if (!prst_in_n) prst_sync <= 4'd0;
    else prst_sync <= {prst_sync[2:0], 1'b1};
  wire prst = !prst_sync[3];
`else
  localparam [0:0] VIDEO = 1'b0;
  wire pclk = 1'b0, prst = 1'b1;
`endif
  wire [9:0] tmds0, tmds1, tmds2;

  // ---------------------------------------------------------------- SoC
  wire poweroff;

  wire i2c_scl_oe, i2c_sda_oe;
  assign i2c_scl = i2c_scl_oe ? 1'b0 : 1'bz;
  assign i2c_sda = i2c_sda_oe ? 1'b0 : 1'bz;

  soc_top #(
      .CPU_W       (4),
      .CPU_SMODE   (`TANG9K_SMODE),
      .VIDEO       (VIDEO),
      .FONT_FILE   (`TANG9K_FONT_FILE),
      .CLK_HZ      (CPU_HZ),
      .UART_BAUD   (UART_BAUD),
      .BOOTROM_FILE(`TANG9K_BOOTROM_FILE)
  ) soc (
      .i_clk           (clk),
      .i_rst           (rst),
      .o_uart_tx       (uart_tx),
      .i_uart_rx       (uart_rx),
      .o_poweroff      (poweroff),
      .o_i2c_scl_oe    (i2c_scl_oe),
      .i_i2c_scl       (i2c_scl),
      .o_i2c_sda_oe    (i2c_sda_oe),
      .i_i2c_sda       (i2c_sda),
      .o_sd_sck        (sd_clk),
      .o_sd_mosi       (sd_mosi),
      .o_sd_cs_n       (sd_cs_n),
      .i_sd_miso       (sd_miso),
      .o_flash_sck     (flash_sck),
      .o_flash_cs_n    (flash_cs_n),
      .o_flash_mosi    (flash_mosi),
      .i_flash_miso    (flash_miso),
      .i_calib0        (calib0),
      .i_calib1        (calib1),
      .o_cmd0          (cmd0),
      .o_cmd_en0       (cmd_en0),
      .o_addr0         (addr0),
      .o_wr_data0      (wr_data0),
      .o_data_mask0    (data_mask0),
      .i_rd_data0      (rd_data0),
      .i_rd_data_valid0(rd_data_valid0),
      .o_cmd1          (cmd1),
      .o_cmd_en1       (cmd_en1),
      .o_addr1         (addr1),
      .o_wr_data1      (wr_data1),
      .o_data_mask1    (data_mask1),
      .i_rd_data1      (rd_data1),
      .i_rd_data_valid1(rd_data_valid1),
      .i_pclk          (pclk),
      .i_prst          (prst),
      .o_tmds0         (tmds0),
      .o_tmds1         (tmds1),
      .o_tmds2         (tmds2),
      .o_dbg_vde       (),
      .o_dbg_vhs       (),
      .o_dbg_vvs       (),
      .o_dbg_vpx       (),
      .i_clint_tick    (1'b0),
      .o_dbg_tx_push   (),
      .o_dbg_tx_byte   (),
      .o_dbg_fetch     (),
      .o_dbg_pc        ()
  );

  // ---------------------------------------------------------------- HDMI
`ifdef TANG9K_VIDEO
  hdmi_phy_gowin hdmi (
      .i_pclk (pclk),
      .i_fclk (hdmi_fclk),
      .i_rst  (prst),
      .i_tmds0(tmds0),
      .i_tmds1(tmds1),
      .i_tmds2(tmds2),
      .o_clk_p(tmds_clk_p),
      .o_clk_n(tmds_clk_n),
      .o_d_p  (tmds_d_p),
      .o_d_n  (tmds_d_n)
  );
`else
  ELVDS_OBUF hdmi_c (.I(1'b0), .O(tmds_clk_p), .OB(tmds_clk_n));
  ELVDS_OBUF hdmi_0 (.I(1'b0), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
  ELVDS_OBUF hdmi_1 (.I(1'b0), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
  ELVDS_OBUF hdmi_2 (.I(1'b0), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
`endif

  // ---------------------------------------------------------------- LEDs
  reg [24:0] beat;
  reg [19:0] tx_stretch;
  always @(posedge clk) begin
    beat <= beat + 25'd1;
    if (!uart_tx) tx_stretch <= {20{1'b1}};
    else if (tx_stretch != 20'd0) tx_stretch <= tx_stretch - 20'd1;
  end

  assign led_n = ~{poweroff, rst, tx_stretch != 20'd0, calib0 & calib1, pll_lock, beat[24]};

endmodule

`default_nettype wire
