// SPI master for the microSD slot (SD SPI mode): mode 0 (SCK idles low, both sides sample on
// the rising edge), MSB first, one chip select. Linux driver: spi-qerv
// (sw/br2-external/patches/linux/0005), with mmc_spi on top.
//
// Registers (word offsets; Wishbone classic, registered ack and read data):
//   0x00 CTRL    bits 7:0 DIV: SCK = clk / (2 * (DIV + 1)); bit 8 CS: the chip-select line's
//                level (1 = high = deasserted). Reset: DIV 255, CS 1.
//   0x04 STATUS  bit 0 busy (read-only; the only access that does not wait)
//   0x08 DATA8   write: shift the byte in bits 7:0 out. Read: the byte received last.
//   0x0C DATA32  write: shift four bytes out, bits 7:0 first. Read: the four bytes received
//                last, the first in bits 7:0.
//   0x10 CRC     read: bits 31:16 the CRC of the bits sent, 15:0 of the bits received, since
//                the last write here (any value: both restart from 0). The SD card's CRC16,
//                CRC-ITU-T (x^16 + x^12 + x^5 + 1, MSB first, Linux crc_itu_t() with 0), so
//                mmc_spi checks and sends data-block CRCs without computing them in software
//                (patches/linux/0005, 0006).
// Every access but a STATUS read waits on the bus (no ack) while a transfer is in progress,
// so software needs no polling: write to start, read to collect, and a CTRL write (CS) lands
// only after the last bit.
//
// Timing: MOSI changes with the falling edge; MISO is sampled at the end of each bit, in the
// clock that drives SCK low again. The card's output (changed after the previous falling
// edge) then has a whole SCK period, minus the pad and board delays, to arrive: at DIV 0
// (21 MHz from 42 MHz) about 47 ns against the card's 14 ns.
`default_nettype none

module spi_master (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [ 4:2] i_adr,
    input  wire [31:0] i_dat,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    output reg         o_sck,
    output reg         o_mosi,
    output reg         o_cs_n,
    input  wire        i_miso
);

  reg  [ 7:0] div, cnt;
  reg  [ 5:0] bits;                     // bits left (0 = idle)
  reg  [30:0] sr;                       // the bits after the one on MOSI, next first
  reg  [31:0] rx;                       // received bits, the latest in bit 0
  reg  [15:0] crc_rx, crc_tx;
  wire        busy = bits != 6'd0;
  wire        status = i_adr == 3'd1;
  wire        data = i_adr[4:3] == 2'b01;   // DATA8, DATA32
  wire        go = i_cyc & !o_ack & (!busy | (status & !i_we));
  // a word's bytes go out bits 7:0 first, each MSB first
  wire [31:0] tx_order = {i_dat[7:0], i_dat[15:8], i_dat[23:16], i_dat[31:24]};

  function [15:0] crc_step(input [15:0] c, input b);
    crc_step = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
  endfunction

  always @(posedge i_clk) begin
    o_ack <= go;
    if (go & !i_we)
      case (i_adr)
        3'd0:    o_rdt <= {23'd0, o_cs_n, div};
        3'd1:    o_rdt <= {31'd0, busy};
        3'd2:    o_rdt <= {24'd0, rx[7:0]};
        3'd3:    o_rdt <= {rx[7:0], rx[15:8], rx[23:16], rx[31:24]};
        default: o_rdt <= {crc_tx, crc_rx};
      endcase
    if (go & i_we & (i_adr == 3'd4)) begin
      crc_rx <= 16'd0;
      crc_tx <= 16'd0;
    end
    if (go & i_we & (i_adr == 3'd0)) begin
      div    <= i_dat[7:0];
      o_cs_n <= i_dat[8];             // the line level (CS is active low)
    end
    if (go & i_we & data) begin         // start a transfer
      bits   <= i_adr[2] ? 6'd32 : 6'd8;
      sr     <= i_adr[2] ? tx_order[30:0] : {i_dat[6:0], 24'hFFFFFF};
      o_mosi <= i_adr[2] ? tx_order[31] : i_dat[7];
      cnt    <= div;
    end else if (busy) begin
      if (cnt != 8'd0) cnt <= cnt - 8'd1;
      else begin
        cnt <= div;
        if (!o_sck) o_sck <= 1'b1;      // rising edge: the card samples MOSI
        else begin                      // end of the bit: sample MISO, next bit
          o_sck  <= 1'b0;
          rx     <= {rx[30:0], i_miso};
          crc_rx <= crc_step(crc_rx, i_miso);
          crc_tx <= crc_step(crc_tx, o_mosi);
          sr     <= {sr[29:0], 1'b1};
          o_mosi <= bits == 6'd1 ? 1'b1 : sr[30];
          bits   <= bits - 6'd1;
        end
      end
    end
    if (i_rst) begin
      o_ack  <= 1'b0;
      div    <= 8'd255;
      o_cs_n <= 1'b1;
      o_sck  <= 1'b0;
      o_mosi <= 1'b1;
      bits   <= 6'd0;
      crc_rx <= 16'd0;
      crc_tx <= 16'd0;
    end
  end

endmodule

`default_nettype wire
