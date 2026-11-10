// The OpenCores I2C master (rtl/i2c) as soc_top wires it (word-spaced 8-bit registers, the
// I/O stage's request held until the registered ack) against the sim's EEPROM model
// (rtl/sim/i2c_eeprom_model.v), driven with the register sequences of Linux i2c-ocores:
// prescale, enable with the interrupt, an address + pointer + 3-byte write, a pointer write
// + repeated start + 4-byte read (NACK on the last), and a probe of an absent address (NACK).
`timescale 1ns / 1ps
`default_nettype none

module tb_i2c;
  reg clk = 1'b0, rst = 1'b1;
  always #12 clk = !clk;                 // ~42 MHz

  reg  [ 2:0] adr = 3'd0;
  reg  [ 7:0] dat = 8'd0;
  reg         we = 1'b0, cyc = 1'b0;
  wire [ 7:0] rdt;
  wire        ack, irq, scl_padoen, sda_padoen, eep_oe;
  wire        scl = scl_padoen;          // open drain with pull-ups: high unless pulled low
  wire        sda = sda_padoen & !eep_oe;

  i2c_master_top #(.ARST_LVL(1'b0)) dut (
      .wb_clk_i(clk), .wb_rst_i(rst), .arst_i(1'b1), .wb_adr_i(adr), .wb_dat_i(dat),
      .wb_dat_o(rdt), .wb_we_i(we), .wb_stb_i(1'b1), .wb_cyc_i(cyc), .wb_ack_o(ack),
      .wb_inta_o(irq), .scl_pad_i(scl), .scl_pad_o(), .scl_padoen_o(scl_padoen),
      .sda_pad_i(sda), .sda_pad_o(), .sda_padoen_o(sda_padoen));
  i2c_eeprom_model #(.ADDR(7'h50)) eep (.i_clk(clk), .i_scl(scl), .i_sda(sda), .o_sda_oe(eep_oe));

  integer errors = 0;
  task fail(input [8*56-1:0] what);
    begin
      errors = errors + 1;
      if (errors < 20) $display("FAIL: %0s (%0t)", what, $time);
    end
  endtask

  reg [7:0] q;
  task bus(input w, input [2:0] a, input [7:0] d);
    integer n;
    begin
      @(posedge clk); #2;
      adr = a; dat = d; we = w; cyc = 1'b1;
      n = 0;
      @(posedge clk); #2;
      while (!ack) begin
        n = n + 1;
        if (n > 10) begin fail("no ack"); disable bus; end
        @(posedge clk); #2;
      end
      q = rdt;
      // soc_top's io_* registers still hold the request in the ack cycle (the core writes
      // then): drop it one cycle later, as io_cyc does
      @(posedge clk); #2;
      cyc = 1'b0; we = 1'b0;
    end
  endtask
  localparam PRERLO = 0, PRERHI = 1, CTR = 2, TXR = 3, RXR = 3, CR = 4, SR = 4;
  localparam STA = 8'h80, STO = 8'h40, RD = 8'h20, WR = 8'h10, NACK = 8'h08, IACK = 8'h01;

  // one byte command, then wait for the interrupt as the driver does; returns SR
  task cmd(input [7:0] c, input [7:0] tx);
    integer n;
    begin
      if (c & WR) bus(1, TXR, tx);
      bus(1, CR, c);
      n = 0;
      while (!irq) begin
        @(posedge clk);
        n = n + 1;
        if (n > 200000) begin fail("no interrupt"); disable cmd; end
      end
      bus(0, SR, 8'd0);
      bus(1, CR, IACK);
      #50;
      if (irq) fail("interrupt not cleared by IACK");
    end
  endtask

  integer i;
  reg [7:0] sr;
  initial begin
    repeat (4) @(posedge clk);
    #2 rst = 1'b0;
    bus(0, PRERLO, 0); if (q !== 8'hFF) fail("PRER reset value");
    bus(1, PRERLO, 8'd20);               // 42 MHz / (5 * 400 kHz) - 1
    bus(1, PRERHI, 8'd0);
    bus(0, PRERLO, 0); if (q !== 8'd20) fail("PRER readback");
    bus(1, CTR, 8'hC0);                  // EN | IEN

    // write 0x10: A5 5A C3
    cmd(STA | WR, {7'h50, 1'b0}); sr = q; if (sr[7]) fail("no ACK for the address");
    cmd(WR, 8'h10);            if (q[7]) fail("no ACK for the pointer");
    cmd(WR, 8'hA5);
    cmd(WR, 8'h5A);
    cmd(WR | STO, 8'hC3);
    for (i = 0; i < 100; i = i + 1) @(posedge clk);
    bus(0, SR, 0); if (q[6]) fail("bus busy after STOP");
    if (eep.mem[8'h10] !== 8'hA5 || eep.mem[8'h11] !== 8'h5A || eep.mem[8'h12] !== 8'hC3)
      fail("EEPROM contents after the write");

    // read 4 bytes from 0x0F: 0x0F^0x5A, A5, 5A, C3
    cmd(STA | WR, {7'h50, 1'b0});
    cmd(WR, 8'h0F);
    cmd(STA | WR, {7'h50, 1'b1}); if (q[7]) fail("no ACK for the read address");
    cmd(RD, 8'd0);         bus(0, RXR, 0); if (q !== (8'h0F ^ 8'h5A)) fail("read byte 0");
    cmd(RD, 8'd0);         bus(0, RXR, 0); if (q !== 8'hA5) fail("read byte 1");
    cmd(RD, 8'd0);         bus(0, RXR, 0); if (q !== 8'h5A) fail("read byte 2");
    cmd(RD | NACK | STO, 8'd0); bus(0, RXR, 0); if (q !== 8'hC3) fail("read byte 3");

    // an absent device NACKs its address (what i2cdetect sees)
    for (i = 0; i < 100; i = i + 1) @(posedge clk);
    cmd(STA | WR, {7'h51, 1'b0}); if (!q[7]) fail("ACK from an absent address");
    cmd(STO, 8'd0);

    $display("%0s: %0d errors", errors ? "FAIL" : "PASS", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule

`default_nettype wire
