// spi_master (rtl/soc/spi_master.v) against a mode-0 SPI slave model with a configurable
// output delay (an SD card in SPI mode: it samples MOSI on the rising edge and changes MISO
// after the falling edge, the first bit when CS falls).
// Checks: register reset values, 8- and 32-bit transfers both ways (byte order, MSB first),
// back-to-back writes, accesses waiting while busy (STATUS does not), CS changing only between
// bytes, SCK period per DIV, MOSI setup before each rising edge, MOSI idle high, and a slave
// output delay of 30 ns at DIV 0 (the end-of-bit MISO sample allows ~one SCK period), and the
// CRC register: CRC-ITU-T of the bits sent and received (the XMODEM check value 0x31C3 for
// "123456789", 0x7FA1 for an SD block of 512 x 0xFF, the slave's bytes against a reference),
// a CRC read waiting for the transfer in progress, and the reset.
`timescale 1ns / 1ps
`default_nettype none

module tb_spi_master;
  reg clk = 1'b0, rst = 1'b1;
  always #12 clk = !clk;                 // 41.7 MHz

  reg  [ 4:2] adr = 3'd0;
  reg  [31:0] dat = 32'd0;
  reg         we = 1'b0, cyc = 1'b0;
  wire [31:0] rdt;
  wire        ack, sck, mosi, cs_n;
  reg         miso = 1'b1;

  spi_master dut (
      .i_clk(clk), .i_rst(rst), .i_adr(adr), .i_dat(dat), .i_we(we), .i_cyc(cyc),
      .o_rdt(rdt), .o_ack(ack), .o_sck(sck), .o_mosi(mosi), .o_cs_n(cs_n), .i_miso(miso));

  integer errors = 0;
  task fail(input [8*64-1:0] what);
    begin
      errors = errors + 1;
      if (errors < 20) $display("FAIL: %0s (%0t)", what, $time);
    end
  endtask

  // ---------------------------------------------------------------- bus
  integer waited;                        // cycles from request to ack, last access
  task bus(input w, input [2:0] a, input [31:0] d, output [31:0] q);
    begin
      @(posedge clk); #2;
      adr = a; dat = d; we = w; cyc = 1'b1;
      waited = 0;
      @(posedge clk); #2;
      while (!ack) begin
        waited = waited + 1;
        if (waited > 100000) begin fail("no ack"); disable bus; end
        @(posedge clk); #2;
      end
      q = rdt;
      cyc = 1'b0; we = 1'b0;
    end
  endtask
  reg [31:0] q;
  task wr(input [2:0] a, input [31:0] d); bus(1'b1, a, d, q); endtask
  task rd(input [2:0] a); bus(1'b0, a, 32'd0, q); endtask

  // reference CRC-ITU-T (CRC16-CCITT, MSB first)
  function [15:0] crc_byte(input [15:0] c, input [7:0] b);
    integer j;
    reg [15:0] x;
    begin
      x = c;
      for (j = 7; j >= 0; j = j - 1) x = {x[14:0], 1'b0} ^ ((x[15] ^ b[j]) ? 16'h1021 : 16'h0);
      crc_byte = x;
    end
  endfunction

  // ---------------------------------------------------------------- slave model
  real        odly = 10.0;               // MISO output delay after the falling edge / CS
  integer     bitn = 0, nrx = 0, ntx = 0;
  reg  [ 7:0] in_b, out_b;
  reg  [ 7:0] got[0:4095];               // bytes the slave received
  function [7:0] resp(input integer k); resp = (k * 37 + 5) & 8'hFF; endfunction
  real        t_mosi = 0.0, t_rise = 0.0, period = 0.0;

  always @(mosi) t_mosi = $realtime;
  always @(negedge cs_n) begin
    if (sck) fail("SCK high when CS falls");
    if (bitn != 0) fail("CS fell inside a byte");
    out_b = resp(ntx);
    miso <= #(odly) out_b[7];
  end
  always @(posedge cs_n) begin
    if (sck) fail("SCK high when CS rises");
    if (bitn != 0) fail("CS rose inside a byte");
    #1 miso = 1'b1;
  end
  always @(posedge sck) if (!cs_n) begin
    if ($realtime - t_mosi < 15.0) fail("MOSI changed too close to the rising edge");
    if (t_rise > 0.0) period = $realtime - t_rise;
    t_rise = $realtime;
    in_b = {in_b[6:0], mosi};
    bitn = bitn + 1;
    if (bitn == 8) begin
      got[nrx] = in_b;
      nrx = nrx + 1;
      ntx = ntx + 1;
      bitn = 0;
      out_b = resp(ntx);
    end else out_b = {out_b[6:0], 1'b0};
  end
  always @(negedge sck) if (!cs_n) miso <= #(odly) out_b[7];
  // the slave's view of a byte boundary: the first bit of the next byte goes out after the
  // last falling edge, as an SD card does

  // ---------------------------------------------------------------- test
  integer i, k0;
  reg [15:0] crc_ref;
  reg [31:0] w;
  initial begin
    repeat (4) @(posedge clk);
    #2 rst = 1'b0;

    rd(3'd0);
    if (q !== 32'h1FF) fail("CTRL reset value");
    if (cs_n !== 1'b1 || sck !== 1'b0 || mosi !== 1'b1) fail("pins at reset");

    // DIV 0, CS low
    wr(3'd0, 32'h000);
    if (cs_n !== 1'b0) fail("CS low");
    k0 = ntx;
    wr(3'd2, 32'hA5);
    rd(3'd2);
    if (q !== {24'd0, resp(k0)}) fail("DATA8 read");
    if (nrx != 1 || got[0] !== 8'hA5) fail("DATA8 write");
    if (period != 48.0) fail("SCK period at DIV 0");
    if (mosi !== 1'b1) fail("MOSI idles high");

    // DATA32: bytes go out bits 7:0 first; read: the first byte in bits 7:0
    k0 = ntx;
    wr(3'd3, 32'h44332211);
    rd(3'd3);
    if (q !== {resp(k0 + 3), resp(k0 + 2), resp(k0 + 1), resp(k0)}) fail("DATA32 read");
    if (got[1] !== 8'h11 || got[2] !== 8'h22 || got[3] !== 8'h33 || got[4] !== 8'h44)
      fail("DATA32 write order");

    // a write waits for the transfer in progress; STATUS does not
    wr(3'd3, 32'hFFFFFFFF);
    rd(3'd1);
    if (q !== 32'd1 || waited != 0) fail("STATUS while busy");
    wr(3'd3, 32'h0);
    if (waited < 50) fail("a write did not wait for the transfer in progress");
    rd(3'd3);
    if (waited < 50) fail("a read did not wait");

    // back-to-back stream of 64 bytes, then CS high: it must land after the last bit
    k0 = nrx;
    for (i = 0; i < 16; i = i + 1) wr(3'd3, {i[7:0] + 8'd3, i[7:0] + 8'd2, i[7:0] + 8'd1, i[7:0]});
    wr(3'd0, 32'h100);
    if (cs_n !== 1'b1) fail("CS high");
    if (nrx != k0 + 64) fail("stream byte count");
    for (i = 0; i < 64; i = i + 1)
      if (got[k0 + i] !== (i / 4 + i % 4) & 8'hFF) fail("stream byte");

    // SCK runs with CS high too (the SD card's 74 initial clocks)
    wr(3'd2, 32'hFF);
    rd(3'd2);
    rd(3'd1);
    if (q !== 32'd0) fail("idle after a transfer");

    // DIV 3: SCK period 8 clocks; a slow slave (30 ns output delay) at DIV 0
    wr(3'd0, 32'h003);
    wr(3'd2, 32'h5A);
    rd(3'd2);
    if (period != 192.0) fail("SCK period at DIV 3");
    odly = 30.0;
    wr(3'd0, 32'h000);
    for (i = 0; i < 8; i = i + 1) begin
      k0 = ntx;
      wr(3'd3, 32'hFFFFFFFF);
      rd(3'd3);
      if (q !== {resp(k0 + 3), resp(k0 + 2), resp(k0 + 1), resp(k0)}) fail("DATA32 with a 30 ns slave");
    end
    wr(3'd0, 32'h100);

    // CRC: "123456789" out (DATA32 x2 + DATA8): 0x31C3; the slave's 9 bytes against the reference
    wr(3'd0, 32'h000);
    wr(3'd4, 32'd0);
    rd(3'd4);
    if (q !== 32'd0) fail("CRC after reset");
    k0 = ntx;
    wr(3'd3, 32'h34333231);
    wr(3'd3, 32'h38373635);
    wr(3'd2, 32'h39);
    rd(3'd4);
    if (waited < 8) fail("a CRC read did not wait for the transfer in progress");
    if (q[31:16] !== 16'h31C3) fail("TX CRC of 123456789");
    crc_ref = 16'd0;
    for (i = 0; i < 9; i = i + 1) crc_ref = crc_byte(crc_ref, resp(k0 + i));
    if (q[15:0] !== crc_ref) fail("RX CRC of the slave's bytes");
    // a 512-byte block of 0xFF (what mmc_spi clocks out while reading): 0x7FA1 both ways when
    // the slave also sends 0xFF; here the slave sends its pattern, checked against the reference
    wr(3'd4, 32'd0);
    k0 = ntx;
    for (i = 0; i < 128; i = i + 1) begin
      wr(3'd3, 32'hFFFFFFFF);
      rd(3'd3);
    end
    rd(3'd4);
    if (q[31:16] !== 16'h7FA1) fail("TX CRC of 512 x 0xFF");
    crc_ref = 16'd0;
    for (i = 0; i < 512; i = i + 1) crc_ref = crc_byte(crc_ref, resp(k0 + i));
    if (q[15:0] !== crc_ref) fail("RX CRC of a 512-byte block");
    wr(3'd0, 32'h100);

    $display("%0s: %0d bytes to the slave, %0d errors", errors ? "FAIL" : "PASS", nrx, errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule

`default_nettype wire
