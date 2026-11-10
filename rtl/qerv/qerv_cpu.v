// QERV-Linux CPU: SERV (external/serv, qerv-linux branch) with LINUX=1, the MDU for the M
// extension and the AMO unit for the A extension. ISA: RV32IMA_Zicsr_Zifencei, M and U modes,
// timer interrupt, no MMU. See doc/stage1_plan.md (M1).
// SMODE=1 (stage 2, doc/stage2_plan.md): adds S-mode and the SV32 MMU (rtl/qerv/sv32_mmu.v)
// between the core and the buses; the AMO unit then works on physical addresses.
//
// Two Wishbone-classic style buses (cyc doubles as stb, one outstanding access each, the core
// never drives both at once): instruction fetch and data. Merge them with servile_arbiter.
`default_nettype none

module qerv_cpu #(
    parameter        W        = 4,             // 1 = SERV, 4 = QERV
    parameter [31:0] RESET_PC = 32'h0000_0000,
    // 1: stage 2 (doc/stage2_plan.md): S-mode, time CSR, SV32 MMU
    parameter [0:0]  SMODE    = 1'b0,
    parameter        TLB_L2   = 8              // SMODE: TLB entries = 2^TLB_L2
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_timer_irq,            // CLINT mtip
    input  wire [63:0] i_mtime,                // CLINT mtime (SMODE: time/timeh CSRs)
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

  // core side (virtual with SMODE)
  wire [31:0] ibus_adr, ibus_rdt;
  wire        ibus_cyc, ibus_ack, ibus_fault;
  wire [31:0] dbus_adr, dbus_dat, dbus_rdt;
  wire [ 3:0] dbus_sel;
  wire        dbus_we, dbus_cyc, dbus_ack, dbus_amo, dbus_fault, dbus_fault_we;
  wire [ 4:0] dbus_amo_op;
  wire [ 1:0] priv;
  wire        sum, mxr, satp_mode, sfence;
  wire [19:0] satp_ppn;
  // AMO unit input (physical)
  wire [31:0] pd_adr, pd_dat, pd_rdt;
  wire [ 3:0] pd_sel;
  wire        pd_we, pd_cyc, pd_ack, pd_amo;
  wire [ 4:0] pd_amo_op;

  wire [31:0] ext_rs1, ext_rs2, mdu_rd;
  wire [ 2:0] ext_funct3;
  wire        mdu_valid, mdu_ready;

  serv_rf_top #(
      .RESET_PC      (RESET_PC),
      .COMPRESSED    (1'b0),
      .MDU           (1'b1),
      .LINUX         (1'b1),
      .SMODE         (SMODE),
      .PRE_REGISTER  (1),
      .RESET_STRATEGY("MINI"),
      .WITH_CSR      (1),
      .W             (W)
  ) core (
      .clk          (i_clk),
      .i_rst        (i_rst),
      .i_timer_irq  (i_timer_irq),
      .o_ibus_adr   (ibus_adr),
      .o_ibus_cyc   (ibus_cyc),
      .i_ibus_rdt   (ibus_rdt),
      .i_ibus_ack   (ibus_ack),
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
      .o_mdu_valid  (mdu_valid),
      .i_mtime        (i_mtime),
      .i_ibus_fault   (ibus_fault),
      .i_dbus_fault   (dbus_fault),
      .i_dbus_fault_we(dbus_fault_we),
      .o_priv         (priv),
      .o_sum          (sum),
      .o_mxr          (mxr),
      .o_satp_mode    (satp_mode),
      .o_satp_ppn     (satp_ppn),
      .o_sfence       (sfence)
  );

  generate
    if (SMODE) begin : gen_mmu
      sv32_mmu #(.TLB_L2(TLB_L2)) mmu (
          .i_clk          (i_clk),
          .i_rst          (i_rst),
          .i_priv         (priv),
          .i_sum          (sum),
          .i_mxr          (mxr),
          .i_satp_mode    (satp_mode),
          .i_satp_ppn     (satp_ppn),
          .i_sfence       (sfence),
          .i_ibus_adr     (ibus_adr),
          .i_ibus_cyc     (ibus_cyc),
          .o_ibus_rdt     (ibus_rdt),
          .o_ibus_ack     (ibus_ack),
          .o_ibus_fault   (ibus_fault),
          .i_dbus_adr     (dbus_adr),
          .i_dbus_dat     (dbus_dat),
          .i_dbus_sel     (dbus_sel),
          .i_dbus_we      (dbus_we),
          .i_dbus_cyc     (dbus_cyc),
          .i_dbus_amo     (dbus_amo),
          .i_dbus_amo_op  (dbus_amo_op),
          .o_dbus_rdt     (dbus_rdt),
          .o_dbus_ack     (dbus_ack),
          .o_dbus_fault   (dbus_fault),
          .o_dbus_fault_we(dbus_fault_we),
          .o_mibus_adr    (o_ibus_adr),
          .o_mibus_cyc    (o_ibus_cyc),
          .i_mibus_rdt    (i_ibus_rdt),
          .i_mibus_ack    (i_ibus_ack),
          .o_mdbus_adr    (pd_adr),
          .o_mdbus_dat    (pd_dat),
          .o_mdbus_sel    (pd_sel),
          .o_mdbus_we     (pd_we),
          .o_mdbus_cyc    (pd_cyc),
          .o_mdbus_amo    (pd_amo),
          .o_mdbus_amo_op (pd_amo_op),
          .i_mdbus_rdt    (pd_rdt),
          .i_mdbus_ack    (pd_ack)
      );
    end else begin : gen_no_mmu
      assign o_ibus_adr = ibus_adr;
      assign o_ibus_cyc = ibus_cyc;
      assign ibus_rdt   = i_ibus_rdt;
      assign ibus_ack   = i_ibus_ack;
      assign ibus_fault = 1'b0;
      assign {pd_adr, pd_dat, pd_sel, pd_we, pd_cyc, pd_amo, pd_amo_op} =
             {dbus_adr, dbus_dat, dbus_sel, dbus_we, dbus_cyc, dbus_amo, dbus_amo_op};
      assign dbus_rdt   = pd_rdt;
      assign dbus_ack   = pd_ack;
      assign {dbus_fault, dbus_fault_we} = 2'b00;
    end
  endgenerate

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
      .i_cpu_adr   (pd_adr),
      .i_cpu_dat   (pd_dat),
      .i_cpu_sel   (pd_sel),
      .i_cpu_we    (pd_we),
      .i_cpu_cyc   (pd_cyc),
      .i_cpu_amo   (pd_amo),
      .i_cpu_amo_op(pd_amo_op),
      .o_cpu_rdt   (pd_rdt),
      .o_cpu_ack   (pd_ack),
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
