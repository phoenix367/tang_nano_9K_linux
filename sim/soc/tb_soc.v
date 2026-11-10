// Simulation top for the QERV SoC (Verilator): soc_top + the PSRAM IP user-interface model + an SPI flash
// model. The kernel can be preloaded into PSRAM (+psram_load0/1 +psram_addr0/1) or put in
// the flash image (+flash_load) for the boot ROM to copy. sim_main.cpp drives the clock,
// reset and UART RX, and watches the console tap.
`default_nettype none

module tb_soc #(
    parameter BOOTROM_FILE = "",
    parameter CLK_HZ       = 27000000,
    parameter UART_BAUD    = 1000000,
    parameter CPU_W        = 4,
    parameter CPU_SMODE    = 0,
    parameter CALIB_CYCLES = 200
) (
    input  wire        clk,
    input  wire        rst,
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

  wire        calib0, calib1;
  wire        cmd0, cmd_en0, cmd1, cmd_en1, rd_data_valid0, rd_data_valid1;
  wire [20:0] addr0, addr1;
  wire [31:0] wr_data0, wr_data1, rd_data0, rd_data1;
  wire [ 3:0] data_mask0, data_mask1;
  wire        flash_sck, flash_cs_n, flash_mosi, flash_miso;

  soc_top #(
      .CPU_W       (CPU_W),
      .CPU_SMODE   (CPU_SMODE[0]),
      .CLK_HZ      (CLK_HZ),
      .UART_BAUD   (UART_BAUD),
      .BOOTROM_FILE(BOOTROM_FILE)
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
      .o_dbg_tx_push   (tx_push),
      .o_dbg_tx_byte   (tx_byte),
      .o_dbg_fetch     (fetch),
      .o_dbg_pc        (pc)
  );

  // contents: +flash_load=<file> +flash_addr=<hex>
  spi_flash_model flash (.sck(flash_sck), .cs_n(flash_cs_n), .mosi(flash_mosi), .miso(flash_miso));

  psram_ui_model #(.CALIB_CYCLES(CALIB_CYCLES)) psram (
      .clk           (clk),
      .rst_n         (!rst),
      .cmd0          (cmd0),
      .cmd_en0       (cmd_en0),
      .addr0         (addr0),
      .wr_data0      (wr_data0),
      .data_mask0    (data_mask0),
      .rd_data0      (rd_data0),
      .rd_data_valid0(rd_data_valid0),
      .init_calib0   (calib0),
      .cmd1          (cmd1),
      .cmd_en1       (cmd_en1),
      .addr1         (addr1),
      .wr_data1      (wr_data1),
      .data_mask1    (data_mask1),
      .rd_data1      (rd_data1),
      .rd_data_valid1(rd_data_valid1),
      .init_calib1   (calib1)
  );

endmodule

`default_nettype wire
