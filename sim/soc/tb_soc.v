// Simulation top for the QERV SoC (Verilator): soc_top + the PSRAM controller's cycle model
// (rtl/sim/hyperram_x16_model.v) + an SPI flash model. The kernel can be preloaded into PSRAM (+psram_load0/1 +psram_addr0/1) or put in
// the flash image (+flash_load) for the boot ROM to copy. sim_main.cpp drives the clock,
// reset and UART RX, and watches the console tap. VIDEO=1 adds the video controller: its
// pixel clock/reset come from sim_main (+video) and its pixel stream goes back for frame dumps.
`default_nettype none

module tb_soc #(
    parameter BOOTROM_FILE = "",
    parameter CLK_HZ       = 27000000,
    parameter UART_BAUD    = 1000000,
    parameter CPU_W        = 4,
    parameter CPU_SMODE    = 0,
    parameter VIDEO        = 0,
    parameter FONT_FILE    = "font8x16.hex",
    parameter PSRAM_INIT   = 200       // cycles to the PSRAM's init_done (board: ~0.2 ms)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pclk,
    input  wire        prst,
    output wire        vde,
    output wire        vhs,
    output wire        vvs,
    output wire [15:0] vpx,
    output wire [31:0] vstat,             // video STATUS register
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        poweroff,
    output wire        tx_push,
    output wire [ 7:0] tx_byte,
    output wire        fetch,
    output wire [31:0] pc,
    // CPU state for debugging (hierarchical references into SERV)
    output wire        dbg_mie,
    output wire        dbg_mpie,
    output wire        dbg_mode_m,
    output wire        dbg_new_irq,
    output wire        dbg_mtip
);

  assign dbg_mie     = soc.cpu.core.cpu.gen_csr.csr.mstatus_mie;
  assign dbg_mpie    = soc.cpu.core.cpu.gen_csr.csr.mstatus_mpie;
  assign dbg_mode_m  = soc.cpu.core.cpu.gen_csr.csr.mode_m;
  assign dbg_new_irq = soc.cpu.core.cpu.gen_csr.csr.o_new_irq;
  assign dbg_mtip    = soc.mtip;
  assign vstat       = soc.video_regs[95:64];   // STATUS

  wire        psram_init, psram_ready, psram_cmd_en, psram_cmd_we, psram_wnext, psram_wlast;
  wire        psram_rvalid;
  wire [22:2] psram_adr;
  wire [ 2:0] psram_wbeat;
  wire [31:0] psram_wdata, psram_rdata;
  wire [ 3:0] psram_wmask;
  wire [ 1:0] psram_rerr;
  wire        flash_sck, flash_cs_n, flash_mosi, flash_miso;

  // I2C: open drain with pull-ups, a 24C02-like EEPROM at 0x50 (doc/peripherals.md)
  wire i2c_scl_oe, i2c_sda_oe, eep_sda_oe;
  wire i2c_scl = !i2c_scl_oe;
  wire i2c_sda = !(i2c_sda_oe | eep_sda_oe);
  i2c_eeprom_model #(.ADDR(7'h50)) eeprom (
      .i_clk(clk), .i_scl(i2c_scl), .i_sda(i2c_sda), .o_sda_oe(eep_sda_oe));

  soc_top #(
      .CPU_W       (CPU_W),
      .CPU_SMODE   (CPU_SMODE[0]),
      .VIDEO       (VIDEO[0]),
      .FONT_FILE   (FONT_FILE),
      .CLK_HZ      (CLK_HZ),
      .UART_BAUD   (UART_BAUD),
      .BOOTROM_FILE(BOOTROM_FILE)
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
      .o_sd_sck        (),
      .o_sd_mosi       (),
      .o_sd_cs_n       (),
      .i_sd_miso       (1'b1),              // empty slot
      .o_flash_sck     (flash_sck),
      .o_flash_cs_n    (flash_cs_n),
      .o_flash_mosi    (flash_mosi),
      .i_flash_miso    (flash_miso),
      .i_psram_init    (psram_init),
      .i_psram_ready   (psram_ready),
      .o_psram_cmd_en  (psram_cmd_en),
      .o_psram_cmd_we  (psram_cmd_we),
      .o_psram_adr     (psram_adr),
      .i_psram_wnext   (psram_wnext),
      .i_psram_wbeat   (psram_wbeat),
      .o_psram_wdata   (psram_wdata),
      .o_psram_wmask   (psram_wmask),
      .o_psram_wlast   (psram_wlast),
      .i_psram_rvalid  (psram_rvalid),
      .i_psram_rdata   (psram_rdata),
      .i_psram_rerr    (psram_rerr),
      .i_pclk          (pclk),
      .i_prst          (prst),
      .o_tmds0         (),
      .o_tmds1         (),
      .o_tmds2         (),
      .o_dbg_vde       (vde),
      .o_dbg_vhs       (vhs),
      .o_dbg_vvs       (vvs),
      .o_dbg_vpx       (vpx),
      .i_clint_tick    (1'b0),
      .o_dbg_tx_push   (tx_push),
      .o_dbg_tx_byte   (tx_byte),
      .o_dbg_fetch     (fetch),
      .o_dbg_pc        (pc)
  );

  // contents: +flash_load=<file> +flash_addr=<hex>
  spi_flash_model flash (.sck(flash_sck), .cs_n(flash_cs_n), .mosi(flash_mosi), .miso(flash_miso));

  hyperram_x16_model #(.INIT_CYCLES(PSRAM_INIT)) psram (
      .clk        (clk),
      .rst        (rst),
      .o_init_done(psram_init),
      .o_ready    (psram_ready),
      .i_cmd_en   (psram_cmd_en),
      .i_cmd_we   (psram_cmd_we),
      .i_addr     (psram_adr),
      .o_wnext    (psram_wnext),
      .o_wbeat    (psram_wbeat),
      .i_wdata    (psram_wdata),
      .i_wmask    (psram_wmask),
      .i_wlast    (psram_wlast),
      .o_rvalid   (psram_rvalid),
      .o_rdata    (psram_rdata),
      .o_rerr     (psram_rerr)
  );

endmodule

`default_nettype wire
