// Memory-mapped, read-only window onto an SPI NOR flash (Tang Nano 9K: 32 Mbit P25Q32) for
// the QERV SoC at 0x2000_0000. Used by the boot ROM to copy the kernel Image and DTB into
// PSRAM; not meant for executing code.
//
// Standard READ (0x03) + 24-bit address, single-bit SPI mode 0, SCK = clk / 2. Each 32-bit
// bus read returns the four bytes at the word address, first byte in bits 7:0 (little-
// endian, like the CPU). CS stays low after a word: if the next read is for the following
// word, the flash simply keeps streaming (32 SCK per word instead of 64). Any other address,
// a write, or IDLE_DESELECT idle cycles end the stream (CS high).
`default_nettype none

module spi_flash_xip #(
    parameter IDLE_DESELECT = 256
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [23:2] i_adr,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    output reg         o_sck,
    output reg         o_cs_n,
    output reg         o_mosi,
    input  wire        i_miso
);

  localparam [1:0] S_IDLE = 2'd0, S_CMD = 2'd1, S_DATA = 2'd2, S_GAP = 2'd3;

  reg  [ 1:0] state;
  reg  [31:0] sh_out;            // command + address, MSB first
  reg  [31:0] sh_in;
  reg  [ 5:0] nbits;             // bits left in this phase
  reg  [23:2] next_adr;          // word that a continuing stream would return next
  reg  [ 8:0] idle;
  reg         streaming;         // CS low and positioned at next_adr
  reg  [ 1:0] gap;               // CS-high cycles before a new command (tSHSL)

  // writes and any read get acked; writes are ignored
  wire start = i_cyc & !o_ack & (state == S_IDLE);

  always @(posedge i_clk) begin
    o_ack <= 1'b0;
    case (state)
      S_IDLE: begin
        o_sck <= 1'b0;
        if (start) begin
          if (i_we) o_ack <= 1'b1;
          else if (streaming && i_adr == next_adr) begin
            nbits <= 6'd32;
            state <= S_DATA;
          end else begin                        // end any stream, then a new READ
            o_cs_n    <= 1'b1;
            streaming <= 1'b0;
            gap       <= 2'd3;
            state     <= S_GAP;
          end
        end else if (streaming) begin
          idle <= idle + 9'd1;
          if (idle == IDLE_DESELECT[8:0] - 9'd1) begin
            o_cs_n    <= 1'b1;
            streaming <= 1'b0;
          end
        end
        if (start) idle <= 9'd0;
      end
      S_GAP: begin
        gap <= gap - 2'd1;
        if (gap == 2'd0) begin
          o_cs_n <= 1'b0;
          sh_out <= {8'h03, i_adr, 2'b00};
          o_mosi <= 1'b0;                       // bit 7 of 0x03
          nbits  <= 6'd32;
          state  <= S_CMD;
        end
      end
      S_CMD: begin                               // shift out 32 bits on falling edges
        o_sck <= !o_sck;
        if (o_sck) begin                         // falling edge: next bit
          sh_out <= {sh_out[30:0], 1'b0};
          o_mosi <= sh_out[30];
          nbits  <= nbits - 6'd1;
          if (nbits == 6'd1) begin
            nbits <= 6'd32;
            state <= S_DATA;
          end
        end
      end
      default: begin                             // S_DATA: sample on rising edges
        o_sck <= !o_sck;
        if (!o_sck) begin
          sh_in <= {sh_in[30:0], i_miso};
          nbits <= nbits - 6'd1;
          if (nbits == 6'd1) begin
            // bytes arrive in address order: first byte -> bits 7:0
            o_rdt     <= {sh_in[6:0], i_miso, sh_in[14:7], sh_in[22:15], sh_in[30:23]};
            o_ack     <= 1'b1;
            next_adr  <= i_adr + 22'd1;
            streaming <= 1'b1;
            state     <= S_IDLE;
          end
        end
      end
    endcase
    if (i_rst) begin
      state     <= S_IDLE;
      o_cs_n    <= 1'b1;
      o_sck     <= 1'b0;
      o_mosi    <= 1'b0;
      o_ack     <= 1'b0;
      streaming <= 1'b0;
      idle      <= 9'd0;
    end
  end

endmodule

`default_nettype wire
