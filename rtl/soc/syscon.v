// SYSCON for the QERV SoC (DT syscon-poweroff / syscon-reboot, offset 0, same values as the
// mini-rv32ima emulator): writing 0x5555 to offset 0 pulses o_poweroff, 0x7777 pulses
// o_reboot. Reads return status words selected by i_adr (word index): i_status[32*i +: 32]
// for i < WORDS, else 0. soc_top documents the layout (it also decodes writes to the video
// registers, which read back here).
`default_nettype none

module syscon #(
    parameter WORDS = 16
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [ 5:2] i_adr,
    input  wire [31:0] i_dat,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    output reg         o_poweroff,
    output reg         o_reboot,
    input  wire [32*WORDS-1:0] i_status
);

  always @(posedge i_clk) begin
    o_ack      <= i_cyc & !o_ack;
    o_rdt      <= (i_adr < WORDS) ? i_status[32*i_adr +: 32] : 32'd0;
    o_poweroff <= i_cyc & !o_ack & i_we & (i_adr == 4'd0) & (i_dat[15:0] == 16'h5555);
    o_reboot   <= i_cyc & !o_ack & i_we & (i_adr == 4'd0) & (i_dat[15:0] == 16'h7777);
    if (i_rst) begin
      o_ack      <= 1'b0;
      o_poweroff <= 1'b0;
      o_reboot   <= 1'b0;
    end
  end

endmodule

`default_nettype wire
