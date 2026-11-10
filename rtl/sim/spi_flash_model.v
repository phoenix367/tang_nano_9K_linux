// Behavioural SPI NOR flash for simulation: answers READ (0x03) with a 24-bit address in SPI
// mode 0 (sample MOSI on SCK rising, drive MISO on falling), streaming sequential bytes for
// as long as CS stays low. Contents: +flash_load=<file> loaded at +flash_addr=<hex>.
`default_nettype none

module spi_flash_model #(
    parameter BYTES = 4 * 1024 * 1024
) (
    input  wire sck,
    input  wire cs_n,
    input  wire mosi,
    output reg  miso
);

  reg [7:0] mem[0:BYTES-1] /* verilator public */;
  reg [7:0] cmd;
  reg [23:0] adr;
  reg [7:0] dout;
  integer   nbit;          // bits received since CS fell
  integer   i, fd, c, base;
  reg [1023:0] fname;

  initial begin
    for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'hFF;
    if ($value$plusargs("flash_load=%s", fname)) begin
      if (!$value$plusargs("flash_addr=%h", base)) base = 0;
      fd = $fopen(fname, "rb");
      i = base;
      c = $fgetc(fd);
      while (c != -1) begin
        mem[i] = c[7:0];
        i = i + 1;
        c = $fgetc(fd);
      end
      $fclose(fd);
    end
    miso = 1'b0;
  end

  always @(negedge cs_n) nbit = 0;

  always @(posedge sck) if (!cs_n) begin
    if (nbit < 8) cmd = {cmd[6:0], mosi};
    else if (nbit < 32) adr = {adr[22:0], mosi};
    nbit = nbit + 1;
  end

  always @(negedge sck) if (!cs_n) begin
    if (nbit >= 32 && cmd == 8'h03) begin
      if ((nbit - 32) % 8 == 0) begin
        dout = mem[adr % BYTES];
        adr  = adr + 24'd1;
      end
      miso = dout[7 - ((nbit - 32) % 8)];
    end
  end

endmodule

`default_nettype wire
