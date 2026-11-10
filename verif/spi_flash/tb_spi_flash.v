// Unit test: spi_flash_xip reading spi_flash_model; sequential streams, random jumps, and
// idle deselects; every word checked against the model contents.
`timescale 1ns/1ps
module tb_spi_flash;
  reg clk = 0, rst = 1, cyc = 0, we = 0;
  reg [23:2] adr;
  wire [31:0] rdt;
  wire ack, sck, cs_n, mosi, miso;
  always #5 clk = !clk;

  spi_flash_xip #(.IDLE_DESELECT(64)) dut (.i_clk(clk), .i_rst(rst), .i_adr(adr), .i_we(we),
      .i_cyc(cyc), .o_rdt(rdt), .o_ack(ack), .o_sck(sck), .o_cs_n(cs_n), .o_mosi(mosi),
      .i_miso(miso));
  spi_flash_model #(.BYTES(65536)) flash (.sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso));

  integer i, errors = 0, reads = 0, k;
  reg [31:0] exp_w;
  initial for (i = 0; i < 65536; i = i + 1) flash.mem[i] = (i * 37 + (i >> 8) * 11) & 8'hFF;

  task rd(input [23:2] a);
    begin
      @(posedge clk); adr <= a; cyc <= 1;
      @(posedge clk); while (!ack) @(posedge clk);
      cyc <= 0;
      exp_w = {flash.mem[{a, 2'b11} % 65536], flash.mem[{a, 2'b10} % 65536],
                flash.mem[{a, 2'b01} % 65536], flash.mem[{a, 2'b00} % 65536]};
      reads = reads + 1;
      if (rdt !== exp_w) begin
        errors = errors + 1;
        if (errors < 5) $display("MISMATCH @%06h: got %08h expected %08h", {a, 2'b00}, rdt, exp_w);
      end
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    for (i = 0; i < 64; i = i + 1) rd(i);                       // one stream
    for (i = 0; i < 40; i = i + 1) rd(($random & 16'h3FFF));    // random words
    for (i = 100; i < 120; i = i + 1) begin rd(i); repeat (i % 3 * 40) @(posedge clk); end
    repeat (100) @(posedge clk); rd(500); rd(501);              // after an idle deselect
    $display("%s: %0d reads, %0d errors", errors ? "FAIL" : "PASS", reads, errors);
    $finish;
  end
endmodule
