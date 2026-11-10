// QERV-Linux CPU: SERV (external/serv, qerv-linux branch) with LINUX=1, the MDU for the M
// extension and the AMO unit for the A extension. ISA: RV32IMA_Zicsr_Zifencei, M and U modes,
// timer interrupt, no MMU. See doc/stage1_plan.md (M1).
//
// Two Wishbone-classic style buses (cyc doubles as stb, one outstanding access each, the core
// never drives both at once): instruction fetch and data. Merge them with servile_arbiter.
`default_nettype none

module qerv_cpu #(
    parameter        W        = 4,             // 1 = SERV, 4 = QERV
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_timer_irq,            // CLINT mtip
    // instruction bus
    output wire [31:0] o_ibus_adr,
    output wire        o_ibus_cyc,
    input  wire [31:0] i_ibus_rdt,
    input  wire        i_ibus_ack,
    // data bus (AMOs already expanded into plain reads/writes)
    output wire [31:0] o_dbus_adr,
    output wire [31:0] o_dbus_dat,
    output wire [ 3:0] o_dbus_sel,
    output wire        o_dbus_we,
    output wire        o_dbus_cyc,
    input  wire [31:0] i_dbus_rdt,
    input  wire        i_dbus_ack
);

  wire [31:0] dbus_adr, dbus_dat, dbus_rdt;
  wire [ 3:0] dbus_sel;
  wire        dbus_we, dbus_cyc, dbus_ack, dbus_amo;
  wire [ 4:0] dbus_amo_op;

  wire [31:0] ext_rs1, ext_rs2, mdu_rd;
  wire [ 2:0] ext_funct3;
  wire        mdu_valid, mdu_ready;

  serv_rf_top #(
      .RESET_PC      (RESET_PC),
      .COMPRESSED    (1'b0),
      .MDU           (1'b1),
      .LINUX         (1'b1),
      .PRE_REGISTER  (1),
      .RESET_STRATEGY("MINI"),
      .WITH_CSR      (1),
      .W             (W)
  ) core (
      .clk          (i_clk),
      .i_rst        (i_rst),
      .i_timer_irq  (i_timer_irq),
      .o_ibus_adr   (o_ibus_adr),
      .o_ibus_cyc   (o_ibus_cyc),
      .i_ibus_rdt   (i_ibus_rdt),
      .i_ibus_ack   (i_ibus_ack),
      .o_dbus_adr   (dbus_adr),
      .o_dbus_dat   (dbus_dat),
      .o_dbus_sel   (dbus_sel),
      .o_dbus_we    (dbus_we),
      .o_dbus_cyc   (dbus_cyc),
      .o_dbus_amo   (dbus_amo),
      .o_dbus_amo_op(dbus_amo_op),
      .i_dbus_rdt   (dbus_rdt),
      .i_dbus_ack   (dbus_ack),
      .o_ext_rs1    (ext_rs1),
      .o_ext_rs2    (ext_rs2),
      .o_ext_funct3 (ext_funct3),
      .i_ext_rd     (mdu_rd),
      .i_ext_ready  (mdu_ready),
      .o_mdu_valid  (mdu_valid)
  );

  mdu_top mdu (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_mdu_rs1  (ext_rs1),
      .i_mdu_rs2  (ext_rs2),
      .i_mdu_op   (ext_funct3),
      .i_mdu_valid(mdu_valid),
      .o_mdu_ready(mdu_ready),
      .o_mdu_rd   (mdu_rd)
  );

  amo_unit amo (
      .i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_cpu_adr   (dbus_adr),
      .i_cpu_dat   (dbus_dat),
      .i_cpu_sel   (dbus_sel),
      .i_cpu_we    (dbus_we),
      .i_cpu_cyc   (dbus_cyc),
      .i_cpu_amo   (dbus_amo),
      .i_cpu_amo_op(dbus_amo_op),
      .o_cpu_rdt   (dbus_rdt),
      .o_cpu_ack   (dbus_ack),
      .o_mem_adr   (o_dbus_adr),
      .o_mem_dat   (o_dbus_dat),
      .o_mem_sel   (o_dbus_sel),
      .o_mem_we    (o_dbus_we),
      .o_mem_cyc   (o_dbus_cyc),
      .i_mem_rdt   (i_dbus_rdt),
      .i_mem_ack   (i_dbus_ack)
  );

endmodule

`default_nettype wire
