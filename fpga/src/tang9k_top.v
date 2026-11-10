// Board top for the QERV SoC on the Tang Nano 9K (milestone M3, doc/stage1_plan.md).
//
// Clocks: the 27 MHz crystal feeds the rPLL, which makes memory_clk, and also the PSRAM IP's
// clk input (the IP needs the free-running reference there). The IP's clk_out
// (= memory_clk / 2) clocks the whole SoC: one clock domain, as in simulation.
// TANG9K_CPU_HZ (fpga/build/tang9k_cfg.v, written by fpga/build.sh) must equal clk_out; the
// UART divider (CPU_HZ / TANG9K_UART_BAUD) and the CLINT's 1 MHz prescaler derive from it.
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
    // on-package PSRAM: placed by the IP, no IO_LOC in the .cst
    output wire [ 1:0] O_psram_ck,
    output wire [ 1:0] O_psram_ck_n,
    inout  wire [ 1:0] IO_psram_rwds,
    output wire [ 1:0] O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    output wire [ 1:0] O_psram_cs_n
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
  // except ~77.6-81 MHz (fpga/probe), hence memory_clk 72 MHz.
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

  // ---------------------------------------------------------------- SoC
  wire poweroff;

  soc_top #(
      .CPU_W       (4),
      .CPU_SMODE   (`TANG9K_SMODE),
      .CLK_HZ      (CPU_HZ),
      .UART_BAUD   (UART_BAUD),
      .BOOTROM_FILE(`TANG9K_BOOTROM_FILE)
  ) soc (
      .i_clk           (clk),
      .i_rst           (rst),
      .o_uart_tx       (uart_tx),
      .i_uart_rx       (uart_rx),
      .o_poweroff      (poweroff),
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
      .i_clint_tick    (1'b0),
      .o_dbg_tx_push   (),
      .o_dbg_tx_byte   (),
      .o_dbg_fetch     (),
      .o_dbg_pc        ()
  );

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
