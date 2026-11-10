// Fit/utilization probe for SERV (W=1) / QERV (W=4) with the MDU (M extension) and CSRs on
// the Tang Nano 9K. serv_rf_top includes the register-file RAM (GPRs + 4 CSRs).
// Same scheme as the KianV probes: LFSR-driven inputs, XOR-folded outputs on one LED pin.
// Probe overhead: 64-bit LFSR (~64 FF, a few LUTs) + ~105-input XOR tree (~35 LUT4, 1 FF).
`default_nettype none

module qerv_fit_top (
    input  wire clk,    // 27 MHz crystal, pin 52
    input  wire rst_n,  // S1 button, pin 4 (active low)
    output wire led     // LED0, pin 10 (active low)
);

  reg [3:0] por_cnt = 4'd0;
  reg       rst = 1'b1;
  always @(posedge clk) begin
    if (!rst_n) begin
      por_cnt <= 4'd0;
      rst     <= 1'b1;
    end else if (por_cnt != 4'hf) begin
      por_cnt <= por_cnt + 4'd1;
      rst     <= 1'b1;
    end else begin
      rst <= 1'b0;
    end
  end

  reg [63:0] lfsr = 64'h1;
  always @(posedge clk) lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};

  wire [31:0] ibus_adr;
  wire        ibus_cyc;
  wire [31:0] dbus_adr;
  wire [31:0] dbus_dat;
  wire [ 3:0] dbus_sel;
  wire        dbus_we;
  wire        dbus_cyc;

  wire [31:0] ext_rs1;
  wire [31:0] ext_rs2;
  wire [ 2:0] ext_funct3;
  wire        mdu_valid;
  wire [31:0] mdu_rd;
  wire        mdu_ready;

  serv_rf_top #(
      .RESET_PC      (32'h0),
      .COMPRESSED    (1'b0),
      .MDU           (1'b1),
      .PRE_REGISTER  (1),
      .RESET_STRATEGY("MINI"),
      .WITH_CSR      (1),
      .W             (`SERV_W)
  ) cpu (
      .clk         (clk),
      .i_rst       (rst),
      .i_timer_irq (lfsr[40] & lfsr[47] & lfsr[54]),
      .o_ibus_adr  (ibus_adr),
      .o_ibus_cyc  (ibus_cyc),
      .i_ibus_rdt  (lfsr[31:0]),
      .i_ibus_ack  (lfsr[32]),
      .o_dbus_adr  (dbus_adr),
      .o_dbus_dat  (dbus_dat),
      .o_dbus_sel  (dbus_sel),
      .o_dbus_we   (dbus_we),
      .o_dbus_cyc  (dbus_cyc),
      .i_dbus_rdt  ({lfsr[15:0], lfsr[63:48]}),
      .i_dbus_ack  (lfsr[33]),
      .o_ext_rs1   (ext_rs1),
      .o_ext_rs2   (ext_rs2),
      .o_ext_funct3(ext_funct3),
      .i_ext_rd    (mdu_rd),
      .i_ext_ready (mdu_ready),
      .o_mdu_valid (mdu_valid)
  );

  mdu_top mdu (
      .i_clk      (clk),
      .i_rst      (rst),
      .i_mdu_rs1  (ext_rs1),
      .i_mdu_rs2  (ext_rs2),
      .i_mdu_op   (ext_funct3),
      .i_mdu_valid(mdu_valid),
      .o_mdu_ready(mdu_ready),
      .o_mdu_rd   (mdu_rd)
  );

  reg fold;
  always @(posedge clk)
    fold <= ^{ibus_adr, ibus_cyc, dbus_adr, dbus_dat, dbus_sel, dbus_we, dbus_cyc};

  assign led = fold;

endmodule

`default_nettype wire
