// QERV SoC (stage 1, doc/stage1_plan.md): QERV-Linux CPU, unified L1 cache in front of the
// Gowin PSRAM HS 2ch IP (8 MB), boot ROM, 16550 UART, CLINT, SYSCON. One clock domain: the
// PSRAM IP's user clock (clk_out).
//
// Memory map (same as the mini-rv32ima emulator so one kernel + DTB runs in both):
//   0x0000_0000  boot ROM (reset vector)        0x1100_0000  CLINT
//   0x1000_0000  UART (16550, byte registers)   0x1110_0000  SYSCON (poweroff/reboot)
//   0x2000_0000  SPI flash, 16 MB window, read-only (boot ROM copies the kernel from it)
//   0x8000_0000  PSRAM, 8 MB, cached (bit 22 selects the IP channel)
// Anything else reads 0 and ignores writes (acked, so a stray access cannot hang the bus).
`default_nettype none

module soc_top #(
    parameter CPU_W          = 4,
    parameter CLK_HZ         = 27000000,
    parameter UART_BAUD      = 1000000,
    parameter CACHE_LINES    = 512,
    parameter BOOTROM_WORDS  = 1024,
    parameter BOOTROM_FILE   = "",
    parameter CLINT_EXT_TICK = 0
) (
    input  wire        i_clk,
    input  wire        i_rst,
    output wire        o_uart_tx,
    input  wire        i_uart_rx,
    output wire        o_poweroff,
    // SPI NOR flash
    output wire        o_flash_sck,
    output wire        o_flash_cs_n,
    output wire        o_flash_mosi,
    input  wire        i_flash_miso,
    // PSRAM IP user interface
    input  wire        i_calib0,
    input  wire        i_calib1,
    output wire        o_cmd0,
    output wire        o_cmd_en0,
    output wire [20:0] o_addr0,
    output wire [31:0] o_wr_data0,
    output wire [ 3:0] o_data_mask0,
    input  wire [31:0] i_rd_data0,
    input  wire        i_rd_data_valid0,
    output wire        o_cmd1,
    output wire        o_cmd_en1,
    output wire [20:0] o_addr1,
    output wire [31:0] o_wr_data1,
    output wire [ 3:0] o_data_mask1,
    input  wire [31:0] i_rd_data1,
    input  wire        i_rd_data_valid1,
    // simulation / debug
    input  wire        i_clint_tick,
    output wire        o_dbg_tx_push,
    output wire [ 7:0] o_dbg_tx_byte,
    output wire        o_dbg_fetch,
    output wire [31:0] o_dbg_pc
);

  // ---------------------------------------------------------------- reset / reboot
  wire       reboot;
  reg  [3:0] reboot_hold;
  always @(posedge i_clk)
    if (i_rst) reboot_hold <= 4'd0;
    else if (reboot) reboot_hold <= 4'hF;
    else if (reboot_hold != 4'd0) reboot_hold <= reboot_hold - 4'd1;
  wire cpu_rst = i_rst | (reboot_hold != 4'd0);

  // ---------------------------------------------------------------- CPU
  wire [31:0] ibus_adr, ibus_rdt, dbus_adr, dbus_dat, dbus_rdt;
  wire [ 3:0] dbus_sel;
  wire        ibus_cyc, ibus_ack, dbus_we, dbus_cyc, dbus_ack;
  wire        mtip;

  qerv_cpu #(.W(CPU_W), .RESET_PC(32'h0000_0000)) cpu (
      .i_clk      (i_clk),
      .i_rst      (cpu_rst),
      .i_timer_irq(mtip),
      .o_ibus_adr (ibus_adr),
      .o_ibus_cyc (ibus_cyc),
      .i_ibus_rdt (ibus_rdt),
      .i_ibus_ack (ibus_ack),
      .o_dbus_adr (dbus_adr),
      .o_dbus_dat (dbus_dat),
      .o_dbus_sel (dbus_sel),
      .o_dbus_we  (dbus_we),
      .o_dbus_cyc (dbus_cyc),
      .i_dbus_rdt (dbus_rdt),
      .i_dbus_ack (dbus_ack)
  );

  assign o_dbg_fetch = ibus_ack;
  assign o_dbg_pc    = ibus_adr;

  wire [31:0] m_adr, m_dat, m_rdt;
  wire [ 3:0] m_sel;
  wire        m_we, m_stb, m_ack;

  servile_arbiter arbiter (
      .i_wb_cpu_dbus_adr(dbus_adr),
      .i_wb_cpu_dbus_dat(dbus_dat),
      .i_wb_cpu_dbus_sel(dbus_sel),
      .i_wb_cpu_dbus_we (dbus_we),
      .i_wb_cpu_dbus_stb(dbus_cyc),
      .o_wb_cpu_dbus_rdt(dbus_rdt),
      .o_wb_cpu_dbus_ack(dbus_ack),
      .i_wb_cpu_ibus_adr(ibus_adr),
      .i_wb_cpu_ibus_stb(ibus_cyc),
      .o_wb_cpu_ibus_rdt(ibus_rdt),
      .o_wb_cpu_ibus_ack(ibus_ack),
      .o_wb_mem_adr     (m_adr),
      .o_wb_mem_dat     (m_dat),
      .o_wb_mem_sel     (m_sel),
      .o_wb_mem_we      (m_we),
      .o_wb_mem_stb     (m_stb),
      .i_wb_mem_rdt     (m_rdt),
      .i_wb_mem_ack     (m_ack)
  );

  // ---------------------------------------------------------------- address decode
  wire s_rom   = m_adr[31:28] == 4'h0;
  wire s_uart  = m_adr[31:20] == 12'h100;
  wire s_clint = m_adr[31:16] == 16'h1100;
  wire s_sys   = m_adr[31:20] == 12'h111;
  wire s_flash = m_adr[31:24] == 8'h20;
  wire s_mem   = m_adr[31:28] == 4'h8;
  wire s_none  = !(s_rom | s_uart | s_clint | s_sys | s_flash | s_mem);

  wire [31:0] rom_rdt, uart_rdt, clint_rdt, sys_rdt, flash_rdt, mem_rdt;
  wire        rom_ack, uart_ack, clint_ack, sys_ack, flash_ack, mem_ack;
  reg         none_ack;
  always @(posedge i_clk) none_ack <= !i_rst & m_stb & s_none & !none_ack;

  assign m_rdt = s_rom ? rom_rdt : s_uart ? uart_rdt : s_clint ? clint_rdt :
                 s_flash ? flash_rdt : s_mem ? mem_rdt : 32'd0;
  assign m_ack = rom_ack | uart_ack | clint_ack | sys_ack | flash_ack | mem_ack | none_ack;

  // ---------------------------------------------------------------- slaves
  bootrom #(.WORDS(BOOTROM_WORDS), .INIT_FILE(BOOTROM_FILE)) rom (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_adr(m_adr[$clog2(BOOTROM_WORDS)+1:2]),
      .i_cyc(m_stb & s_rom),
      .o_rdt(rom_rdt),
      .o_ack(rom_ack)
  );

  uart_16550 #(.CLKS_PER_BIT(CLK_HZ / UART_BAUD)) uart (
      .i_clk    (i_clk),
      .i_rst    (i_rst),
      .i_adr    (m_adr[2:2]),
      .i_dat    (m_dat),
      .i_sel    (m_sel),
      .i_we     (m_we),
      .i_cyc    (m_stb & s_uart),
      .o_rdt    (uart_rdt),
      .o_ack    (uart_ack),
      .o_tx     (o_uart_tx),
      .i_rx     (i_uart_rx),
      .o_tx_push(o_dbg_tx_push),
      .o_tx_byte(o_dbg_tx_byte)
  );

  clint #(.CLK_HZ(CLK_HZ), .EXT_TICK(CLINT_EXT_TICK)) clint (
      .i_clk (i_clk),
      .i_rst (i_rst),
      .i_tick(i_clint_tick),
      .i_adr (m_adr[15:2]),
      .i_dat (m_dat),
      .i_sel (m_sel),
      .i_we  (m_we),
      .i_cyc (m_stb & s_clint),
      .o_rdt (clint_rdt),
      .o_ack (clint_ack),
      .o_mtip(mtip)
  );

  syscon sys (
      .i_clk     (i_clk),
      .i_rst     (i_rst),
      .i_dat     (m_dat),
      .i_we      (m_we),
      .i_cyc     (m_stb & s_sys),
      .o_rdt     (sys_rdt),
      .o_ack     (sys_ack),
      .o_poweroff(o_poweroff),
      .o_reboot  (reboot)
  );

  spi_flash_xip flash (
      .i_clk (i_clk),
      .i_rst (i_rst),
      .i_adr (m_adr[23:2]),
      .i_we  (m_we),
      .i_cyc (m_stb & s_flash),
      .o_rdt (flash_rdt),
      .o_ack (flash_ack),
      .o_sck (o_flash_sck),
      .o_cs_n(o_flash_cs_n),
      .o_mosi(o_flash_mosi),
      .i_miso(i_flash_miso)
  );

  wire [31:0] cache_hits, cache_misses, cache_writebacks;

  l1_cache #(.LINES(CACHE_LINES)) cache (
      .i_clk           (i_clk),
      .i_rst           (i_rst),
      .i_adr           (m_adr[22:0]),
      .i_dat           (m_dat),
      .i_sel           (m_sel),
      .i_we            (m_we),
      .i_cyc           (m_stb & s_mem),
      .o_rdt           (mem_rdt),
      .o_ack           (mem_ack),
      .i_calib         (i_calib0 & i_calib1),
      .o_cmd0          (o_cmd0),
      .o_cmd_en0       (o_cmd_en0),
      .o_addr0         (o_addr0),
      .o_wr_data0      (o_wr_data0),
      .o_data_mask0    (o_data_mask0),
      .i_rd_data0      (i_rd_data0),
      .i_rd_data_valid0(i_rd_data_valid0),
      .o_cmd1          (o_cmd1),
      .o_cmd_en1       (o_cmd_en1),
      .o_addr1         (o_addr1),
      .o_wr_data1      (o_wr_data1),
      .o_data_mask1    (o_data_mask1),
      .i_rd_data1      (i_rd_data1),
      .i_rd_data_valid1(i_rd_data_valid1),
      .o_hits          (cache_hits),
      .o_misses        (cache_misses),
      .o_writebacks    (cache_writebacks)
  );

  wire unused = &{1'b0, sys_rdt, cache_hits, cache_misses, cache_writebacks};

endmodule

`default_nettype wire
