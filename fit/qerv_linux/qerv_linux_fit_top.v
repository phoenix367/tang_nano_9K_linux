// Fit/utilization probe for the QERV-Linux CPU (rtl/qerv/qerv_cpu.v: SERV LINUX=1 + MDU +
// AMO unit) on the Tang Nano 9K. Same scheme as fit/qerv: LFSR-driven inputs, XOR-folded
// outputs on one LED pin. Probe overhead: 64-bit LFSR + ~105-input XOR tree.
`default_nettype none

module qerv_linux_fit_top (
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

  wire [31:0] ibus_adr, dbus_adr, dbus_dat;
  wire [ 3:0] dbus_sel;
  wire        ibus_cyc, dbus_we, dbus_cyc;

  qerv_cpu #(.W(`SERV_W), .RESET_PC(32'h0), .SMODE(`SERV_SMODE)) cpu (
      .i_clk      (clk),
      .i_rst      (rst),
      .i_timer_irq(lfsr[40] & lfsr[47] & lfsr[54]),
      .i_mtime    (lfsr),
      .o_ibus_adr (ibus_adr),
      .o_ibus_cyc (ibus_cyc),
      .i_ibus_rdt (lfsr[31:0]),
      .i_ibus_ack (lfsr[32]),
      .o_dbus_adr (dbus_adr),
      .o_dbus_dat (dbus_dat),
      .o_dbus_sel (dbus_sel),
      .o_dbus_we  (dbus_we),
      .o_dbus_cyc (dbus_cyc),
      .i_dbus_rdt ({lfsr[15:0], lfsr[63:48]}),
      .i_dbus_ack (lfsr[33])
  );

  reg fold;
  always @(posedge clk)
    fold <= ^{ibus_adr, ibus_cyc, dbus_adr, dbus_dat, dbus_sel, dbus_we, dbus_cyc};

  assign led = fold;

endmodule

`default_nettype wire
