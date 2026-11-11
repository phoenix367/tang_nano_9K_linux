// QERV SoC (stage 1, doc/stage1_plan.md): QERV-Linux CPU, unified L1 cache in front of the
// 8 MB PSRAM (through psram_arb and the 16-bit controller rtl/psram/hyperram_x16.v, which the
// board top instantiates), boot ROM, 16550 UART, CLINT, SYSCON. One clock domain, the
// controller's (42 MHz on the board).
//
// Memory map (same as the mini-rv32ima emulator so one kernel + DTB runs in both):
//   0x0000_0000  boot ROM (reset vector)        0x1100_0000  CLINT
//   0x1000_0000  UART (16550, byte registers)   0x1110_0000  SYSCON (poweroff/reboot)
//   0x2000_0000  SPI flash, 16 MB window, read-only (boot ROM copies the kernel from it)
//   0x8000_0000  PSRAM, 8 MB, cached
//   0x9000_0000  the same PSRAM, uncached (the video framebuffer; doc/video_plan.md)
//   0x1200_0000  PLIC (4 MB window): source 1 = the UART, one context = the hart's SEIP
//   0x1180_0000  video text buffer (VIDEO=1; 80 x 30 cells, write-only)
//   0x1130_0000  I2C master (OpenCores i2c, rtl/i2c; 8-bit registers at word offsets),
//                PLIC source 2
//   0x1140_0000  SPI master for the microSD slot (spi_master.v)
// SYSCON words 8..13 (0x1110_0020..34) are the video registers (VIDEO=1, video_ctrl.v).
// Anything else reads 0 and ignores writes (acked, so a stray access cannot hang the bus).
// The cache and the video DMA share the PSRAM IP through psram_arb. With VIDEO=1 the pixel
// side runs on i_pclk (25.2 MHz) and the board top serializes o_tmds*.
`default_nettype none

module soc_top #(
    parameter CPU_W          = 4,
    parameter CLK_HZ         = 27000000,
    parameter UART_BAUD      = 1000000,
    parameter CACHE_LINES    = 512,
    parameter BOOTROM_WORDS  = 1024,
    parameter BOOTROM_FILE   = "",
    parameter CLINT_EXT_TICK = 0,
    parameter [0:0] CPU_SMODE = 1'b0,   // stage 2: S-mode + SV32 MMU (doc/stage2_plan.md)
    parameter [0:0] VIDEO     = 1'b0,   // HDMI framebuffer scanout (doc/video_plan.md)
    parameter FONT_FILE       = "font8x16.hex"   // VIDEO text mode: the 8x16 font ROM
) (
    input  wire        i_clk,
    input  wire        i_rst,
    output wire        o_uart_tx,
    input  wire        i_uart_rx,
    output wire        o_poweroff,
    // SPI NOR flash
    // I2C (open drain: *_oe pulls the line low) and the microSD slot in SPI mode
    output wire        o_i2c_scl_oe,
    input  wire        i_i2c_scl,
    output wire        o_i2c_sda_oe,
    input  wire        i_i2c_sda,
    output wire        o_sd_sck,
    output wire        o_sd_mosi,
    output wire        o_sd_cs_n,
    input  wire        i_sd_miso,
    output wire        o_flash_sck,
    output wire        o_flash_cs_n,
    output wire        o_flash_mosi,
    input  wire        i_flash_miso,
    // PSRAM controller's command interface (rtl/psram/hyperram_x16.v; in simulation
    // rtl/sim/hyperram_x16_model.v)
    input  wire        i_psram_init,     // initialized (RESET#, CR0 written)
    input  wire        i_psram_ready,
    output wire        o_psram_cmd_en,
    output wire        o_psram_cmd_we,
    output wire [22:2] o_psram_adr,
    input  wire        i_psram_wnext,
    input  wire [ 2:0] i_psram_wbeat,
    output wire [31:0] o_psram_wdata,
    output wire [ 3:0] o_psram_wmask,
    output wire        o_psram_wlast,
    input  wire        i_psram_rvalid,
    input  wire [31:0] i_psram_rdata,
    input  wire [ 1:0] i_psram_rerr,     // with i_psram_rvalid: a die's word is a filler
    // video (VIDEO=1): pixel clock domain
    input  wire        i_pclk,
    input  wire        i_prst,
    output wire [ 9:0] o_tmds0,
    output wire [ 9:0] o_tmds1,
    output wire [ 9:0] o_tmds2,
    output wire        o_dbg_vde,
    output wire        o_dbg_vhs,
    output wire        o_dbg_vvs,
    output wire [15:0] o_dbg_vpx,
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
  // registered: the CPU's reset reaches its bus-request gating from a flop, not a LUT
  reg  cpu_rst;
  always @(posedge i_clk) cpu_rst <= i_rst | (reboot_hold != 4'd0);

  // ---------------------------------------------------------------- CPU
  wire [31:0] ibus_adr, ibus_rdt, dbus_adr, dbus_dat, dbus_rdt;
  wire [ 3:0] dbus_sel;
  wire        ibus_cyc, ibus_ack, dbus_we, dbus_cyc, dbus_ack, dbus_cmo;
  wire [ 1:0] dbus_cmo_op;
  wire        mtip;
  wire        seip, uart_irq;              // PLIC context 0 -> the hart's SEIP
  wire [63:0] mtime;

  qerv_cpu #(.W(CPU_W), .RESET_PC(32'h0000_0000), .SMODE(CPU_SMODE)) cpu (
      .i_clk      (i_clk),
      .i_rst      (cpu_rst),
      .i_timer_irq(mtip),
      .i_mtime    (mtime),
      .i_seip     (seip),
      .o_ibus_adr (ibus_adr),
      .o_ibus_cyc (ibus_cyc),
      .i_ibus_rdt (ibus_rdt),
      .i_ibus_ack (ibus_ack),
      .o_dbus_adr (dbus_adr),
      .o_dbus_dat (dbus_dat),
      .o_dbus_sel (dbus_sel),
      .o_dbus_we  (dbus_we),
      .o_dbus_cyc (dbus_cyc),
      .o_dbus_cmo (dbus_cmo),
      .o_dbus_cmo_op(dbus_cmo_op),
      .i_dbus_rdt (dbus_rdt),
      .i_dbus_ack (dbus_ack),
      .o_dbg_fetch(o_dbg_fetch),
      .o_dbg_pc   (o_dbg_pc)
  );

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

  // a cache-block operation (Zicbom) rides along with a data read; the arbiter puts a
  // fetch on the bus instead whenever ibus_cyc is up
  wire m_cmo = dbus_cmo & !ibus_cyc;

  // ---------------------------------------------------------------- address decode
  wire s_mem   = m_adr[31:29] == 3'b100;    // 0x8 cached, 0x9 uncached; the rest is I/O

  wire [31:0] rom_rdt, uart_rdt, clint_rdt, sys_rdt, plic_rdt, flash_rdt, mem_rdt, spi_rdt;
  wire        rom_ack, uart_ack, clint_ack, sys_ack, plic_ack, flash_ack, mem_ack, spi_ack;
  wire [ 7:0] i2c_rdt;
  wire        i2c_ack, i2c_irq;

  // ---------------------------------------------------------------- I/O request register
  // Every slave but the cache gets the request one cycle late, from registers: otherwise the
  // CPU's address (through the MMU) has to cross the decode into each slave's logic in one
  // cycle, the SoC's critical path once the PLIC and video were in. An I/O access takes a
  // cycle more; memory accesses keep their direct path. io_cyc drops in the slave's ack cycle,
  // before the CPU drops its request (the next cycle), so a held request is not seen twice.
  reg  [31:0] io_adr, io_dat;
  reg  [ 3:0] io_sel;
  reg         io_we, io_cyc;
  wire        io_ack;
  always @(posedge i_clk) begin
    {io_adr, io_dat, io_sel, io_we} <= {m_adr, m_dat, m_sel, m_we};
    io_cyc <= !i_rst & m_stb & !s_mem & !io_ack & !m_cmo;
  end
  // a CMO outside the PSRAM has nothing to act on: acked here, no I/O slave sees it
  reg  cmo_io_ack;
  always @(posedge i_clk) cmo_io_ack <= !i_rst & m_stb & m_cmo & !s_mem & !cmo_io_ack;
  wire io_rom   = io_adr[31:28] == 4'h0;
  wire io_uart  = io_adr[31:20] == 12'h100;
  wire io_clint = io_adr[31:16] == 16'h1100;
  wire io_sys   = io_adr[31:20] == 12'h111;
  wire io_plic  = io_adr[31:24] == 8'h12;
  wire io_flash = io_adr[31:24] == 8'h20;
  wire io_text  = VIDEO & (io_adr[31:20] == 12'h118);
  wire io_i2c   = io_adr[31:20] == 12'h113;
  wire io_spi   = io_adr[31:20] == 12'h114;
  wire io_none  = !(io_rom | io_uart | io_clint | io_sys | io_plic | io_flash | io_text |
                    io_i2c | io_spi);
  reg  none_ack, text_ack;                 // the text buffer reads 0
  always @(posedge i_clk) begin
    none_ack <= !i_rst & io_cyc & io_none & !none_ack;
    text_ack <= !i_rst & io_cyc & io_text & !text_ack;
  end
  assign io_ack = rom_ack | uart_ack | clint_ack | sys_ack | plic_ack | flash_ack | none_ack |
                  text_ack | i2c_ack | spi_ack;

  // Read data: every slave registers its data and its ack, so each ack selects its own data
  // (AND-OR). The address decode stays out of this path: it only has to reach the slaves'
  // request inputs, while the read data path into the CPU is the SoC's critical one.
  assign m_rdt = ({32{rom_ack}} & rom_rdt) | ({32{uart_ack}} & uart_rdt) |
                 ({32{clint_ack}} & clint_rdt) | ({32{sys_ack}} & sys_rdt) |
                 ({32{plic_ack}} & plic_rdt) | ({32{flash_ack}} & flash_rdt) |
                 ({32{i2c_ack}} & {24'd0, i2c_rdt}) | ({32{spi_ack}} & spi_rdt) |
                 ({32{mem_ack}} & mem_rdt);
  assign m_ack = io_ack | mem_ack | cmo_io_ack;

  // ---------------------------------------------------------------- slaves
  bootrom #(.WORDS(BOOTROM_WORDS), .INIT_FILE(BOOTROM_FILE)) rom (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_adr(io_adr[$clog2(BOOTROM_WORDS)+1:2]),
      .i_cyc(io_cyc & io_rom),
      .o_rdt(rom_rdt),
      .o_ack(rom_ack)
  );

  uart_16550 #(.CLKS_PER_BIT(CLK_HZ / UART_BAUD)) uart (
      .i_clk    (i_clk),
      .i_rst    (i_rst),
      .i_adr    (io_adr[2:2]),
      .i_dat    (io_dat),
      .i_sel    (io_sel),
      .i_we     (io_we),
      .i_cyc    (io_cyc & io_uart),
      .o_rdt    (uart_rdt),
      .o_ack    (uart_ack),
      .o_tx     (o_uart_tx),
      .i_rx     (i_uart_rx),
      .o_irq    (uart_irq),
      .o_tx_push(o_dbg_tx_push),
      .o_tx_byte(o_dbg_tx_byte)
  );

  plic #(.SOURCES(2)) plic (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_adr(io_adr[21:2]),
      .i_dat(io_dat),
      .i_we (io_we),
      .i_cyc(io_cyc & io_plic),
      .o_rdt(plic_rdt),
      .o_ack(plic_ack),
      .i_src({i2c_irq, uart_irq}),
      .o_eip(seip)
  );

  // OpenCores I2C master (Linux i2c-ocores: reg-shift 2). Its Wishbone ack is registered like
  // the other slaves' and it writes in the ack cycle, while io_* still hold the request.
  wire scl_padoen, sda_padoen;
  i2c_master_top #(.ARST_LVL(1'b0)) i2c (
      .wb_clk_i    (i_clk),
      .wb_rst_i    (i_rst),
      .arst_i      (1'b1),
      .wb_adr_i    (io_adr[4:2]),
      .wb_dat_i    (io_dat[7:0]),
      .wb_dat_o    (i2c_rdt),
      .wb_we_i     (io_we),
      .wb_stb_i    (1'b1),
      .wb_cyc_i    (io_cyc & io_i2c),
      .wb_ack_o    (i2c_ack),
      .wb_inta_o   (i2c_irq),
      .scl_pad_i   (i_i2c_scl),
      .scl_pad_o   (),
      .scl_padoen_o(scl_padoen),
      .sda_pad_i   (i_i2c_sda),
      .sda_pad_o   (),
      .sda_padoen_o(sda_padoen)
  );
  assign o_i2c_scl_oe = !scl_padoen;      // the pad output is always 0
  assign o_i2c_sda_oe = !sda_padoen;

  spi_master sd_spi (
      .i_clk (i_clk),
      .i_rst (i_rst),
      .i_adr (io_adr[4:2]),
      .i_dat (io_dat),
      .i_we  (io_we),
      .i_cyc (io_cyc & io_spi),
      .o_rdt (spi_rdt),
      .o_ack (spi_ack),
      .o_sck (o_sd_sck),
      .o_mosi(o_sd_mosi),
      .o_cs_n(o_sd_cs_n),
      .i_miso(i_sd_miso)
  );

  clint #(.CLK_HZ(CLK_HZ), .EXT_TICK(CLINT_EXT_TICK)) clint (
      .i_clk (i_clk),
      .i_rst (i_rst),
      .i_tick(i_clint_tick),
      .i_adr (io_adr[15:2]),
      .i_dat (io_dat),
      .i_sel (io_sel),
      .i_we  (io_we),
      .i_cyc (io_cyc & io_clint),
      .o_rdt (clint_rdt),
      .o_ack (clint_ack),
      .o_mtip(mtip),
      .o_mtime(mtime)
  );

  wire [31:0] cache_hits, cache_misses, cache_writebacks;
  wire [191:0] video_regs;

  // SYSCON status words (read at 0x1110_0000 + 4*i), for bring-up:
  //   0 {30'b0, init, init} (3: the PSRAM is ready)   1 PSRAM commands taken
  //   2 read beats with a filler word (a die missed a word; should stay 0)
  //   3 read beats   4 0   5 cache misses   6 cache write-backs   7 0
  reg [31:0] n_cmd, n_fill, n_rdv;
  always @(posedge i_clk)
    if (i_rst) {n_cmd, n_fill, n_rdv} <= 96'd0;
    else begin
      n_cmd  <= n_cmd + {31'd0, o_psram_cmd_en & i_psram_ready};
      n_fill <= n_fill + {31'd0, i_psram_rvalid & (i_psram_rerr != 2'b00)};
      n_rdv  <= n_rdv + {31'd0, i_psram_rvalid};
    end

  //   8..13 video CTRL, BASE, STATUS, YOFF, TSTART, CURSOR (video_ctrl.v; 0 without VIDEO)
  syscon #(.WORDS(16)) sys (
      .i_clk     (i_clk),
      .i_rst     (i_rst),
      .i_adr     (io_adr[5:2]),
      .i_dat     (io_dat),
      .i_we      (io_we),
      .i_cyc     (io_cyc & io_sys),
      .o_rdt     (sys_rdt),
      .o_ack     (sys_ack),
      .o_poweroff(o_poweroff),
      .o_reboot  (reboot),
      .i_status  ({64'd0, video_regs,
                   32'd0, cache_writebacks, cache_misses, 32'd0, n_rdv, n_fill, n_cmd,
                   30'd0, i_psram_init, i_psram_init})
  );

  spi_flash_xip flash (
      .i_clk (i_clk),
      .i_rst (i_rst),
      .i_adr (io_adr[23:2]),
      .i_we  (io_we),
      .i_cyc (io_cyc & io_flash),
      .o_rdt (flash_rdt),
      .o_ack (flash_ack),
      .o_sck (o_flash_sck),
      .o_cs_n(o_flash_cs_n),
      .o_mosi(o_flash_mosi),
      .i_miso(i_flash_miso)
  );

  wire        c_req, c_we, c_gnt, c_rvalid;
  wire [22:2] c_adr;
  wire [31:0] c_wdata, c_rdata;
  wire [ 3:0] c_wmask;
  wire        d_req, d_urgent, d_gnt, d_rvalid;
  wire [22:2] d_adr;
  wire [31:0] d_rdata;

  l1_cache #(.LINES(CACHE_LINES)) cache (
      .i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_adr       (m_adr[22:0]),
      .i_dat       (m_dat),
      .i_sel       (m_sel),
      .i_we        (m_we),
      .i_cyc       (m_stb & s_mem),
      .i_unc       (m_adr[28]),
      .i_cmo       (m_cmo),
      .i_cmo_op    (dbus_cmo_op),
      .o_rdt       (mem_rdt),
      .o_ack       (mem_ack),
      .o_req       (c_req),
      .o_req_we    (c_we),
      .o_req_adr   (c_adr),
      .i_gnt       (c_gnt),
      .o_wdata     (c_wdata),
      .o_wmask     (c_wmask),
      .i_rvalid    (c_rvalid),
      .i_rdata     (c_rdata),
      .o_hits      (cache_hits),
      .o_misses    (cache_misses),
      .o_writebacks(cache_writebacks)
  );

  psram_arb arb (
      .i_clk           (i_clk),
      .i_rst           (i_rst),
      .i_c_req         (c_req),
      .i_c_we          (c_we),
      .i_c_adr         (c_adr),
      .o_c_gnt         (c_gnt),
      .i_c_wdata       (c_wdata),
      .i_c_wmask       (c_wmask),
      .o_c_rvalid      (c_rvalid),
      .o_c_rdata       (c_rdata),
      .i_d_req         (d_req),
      .i_d_urgent      (d_urgent),
      .i_d_adr         (d_adr),
      .o_d_gnt         (d_gnt),
      .o_d_rvalid      (d_rvalid),
      .o_d_rdata       (d_rdata),
      .i_ready         (i_psram_ready),
      .o_cmd_en        (o_psram_cmd_en),
      .o_cmd_we        (o_psram_cmd_we),
      .o_cmd_adr       (o_psram_adr),
      .i_wnext         (i_psram_wnext),
      .i_wbeat         (i_psram_wbeat),
      .o_wdata         (o_psram_wdata),
      .o_wmask         (o_psram_wmask),
      .o_wlast         (o_psram_wlast),
      .i_rvalid        (i_psram_rvalid),
      .i_rdata         (i_psram_rdata)
  );

  // ---------------------------------------------------------------- video
  generate
    if (VIDEO) begin : gen_video
      video_ctrl #(.CLK_HZ(CLK_HZ), .FONT_FILE(FONT_FILE)) video (
          .i_clk   (i_clk),
          .i_rst   (i_rst),
          .i_adr   (io_adr[4:2]),
          .i_dat   (io_dat),
          // one cycle per bus write to SYSCON words 8..11 (syscon acks the next cycle)
          .i_wr    (io_cyc & io_sys & io_we & !sys_ack & io_adr[5]),
          .i_tb_we (io_cyc & io_text & io_we & !text_ack),
          .i_tb_adr(io_adr[12:2]),
          .i_tb_dat(io_dat),
          .i_tb_sel(io_sel),
          .o_regs  (video_regs),
          .o_req   (d_req),
          .o_urgent(d_urgent),
          .o_adr   (d_adr),
          .i_gnt   (d_gnt),
          .i_rvalid(d_rvalid),
          .i_rdata (d_rdata),
          .i_pclk  (i_pclk),
          .i_prst  (i_prst),
          .o_tmds0 (o_tmds0),
          .o_tmds1 (o_tmds1),
          .o_tmds2 (o_tmds2),
          .o_dbg_de(o_dbg_vde),
          .o_dbg_hs(o_dbg_vhs),
          .o_dbg_vs(o_dbg_vvs),
          .o_dbg_px(o_dbg_vpx)
      );
    end else begin : gen_no_video
      assign {d_req, d_urgent, d_adr} = {2'b00, 21'd0};
      assign video_regs = 192'd0;
      assign {o_tmds0, o_tmds1, o_tmds2} = 30'd0;
      assign {o_dbg_vde, o_dbg_vhs, o_dbg_vvs, o_dbg_vpx} = 19'd0;
    end
  endgenerate

  wire unused = &{1'b0, cache_hits, d_gnt, d_rvalid, d_rdata, i_pclk, i_prst};

endmodule

`default_nettype wire
