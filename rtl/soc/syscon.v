// SYSCON for the QERV SoC (DT syscon-poweroff / syscon-reboot, offset 0, same values as the
// mini-rv32ima emulator): writing 0x5555 pulses o_poweroff, 0x7777 pulses o_reboot.
`default_nettype none

module syscon (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [31:0] i_dat,
    input  wire        i_we,
    input  wire        i_cyc,
    output wire [31:0] o_rdt,
    output reg         o_ack,
    output reg         o_poweroff,
    output reg         o_reboot
);

  assign o_rdt = 32'd0;

  always @(posedge i_clk) begin
    o_ack      <= i_cyc & !o_ack;
    o_poweroff <= i_cyc & !o_ack & i_we & (i_dat[15:0] == 16'h5555);
    o_reboot   <= i_cyc & !o_ack & i_we & (i_dat[15:0] == 16'h7777);
    if (i_rst) begin
      o_ack      <= 1'b0;
      o_poweroff <= 1'b0;
      o_reboot   <= 1'b0;
    end
  end

endmodule

`default_nettype wire
