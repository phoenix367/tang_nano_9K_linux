// Boot ROM for the QERV SoC at 0x00000000 (reset vector): WORDS x 32-bit block RAM, contents
// from a $readmemh file built by sw/bootrom. Registered read and ack (like servant_ram).
`default_nettype none

module bootrom #(
    parameter WORDS     = 1024,
    parameter INIT_FILE = ""
) (
    input  wire                     i_clk,
    input  wire                     i_rst,
    input  wire [$clog2(WORDS)+1:2] i_adr,
    input  wire                     i_cyc,
    output reg  [31:0]              o_rdt,
    output reg                      o_ack
);

  reg [31:0] mem[0:WORDS-1];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

  always @(posedge i_clk) begin
    o_rdt <= mem[i_adr];
    o_ack <= i_cyc & !o_ack;
    if (i_rst) o_ack <= 1'b0;
  end

endmodule

`default_nettype wire
