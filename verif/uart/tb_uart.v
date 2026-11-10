// Unit test for rtl/soc/uart_16550.v (256-byte block-RAM FIFOs, interrupt output). Run:
// verif/uart/run.sh. Checks:
//   1. TX: 300 bytes written to THR as fast as the bus allows (pausing only while the 256-byte
//      FIFO is full) come out of the TX pin as 8N1 frames, in order; the THR-empty interrupt
//      (IER[1]) is off while bytes are queued and on again when the FIFO drains; IIR 0x2.
//   2. RX: 40 frames sent on the RX pin read back from RBR in order; the RX interrupt (IER[0])
//      is up while data is there, IIR 0x4; it drops when the FIFO is read empty.
//   3. RX overrun: 260 frames with nobody reading: the first 256 are kept, LSR[1] reports the
//      overrun (cleared by the LSR read), and with IER[2] it is IIR 0x6.
`timescale 1ns / 1ps
`default_nettype none

module tb_uart;
  localparam CPB = 8;                     // clocks per bit (fast)

  reg clk = 0, rst = 1;
  always #5 clk = !clk;

  reg  [2:2] adr;
  reg  [31:0] dat;
  reg  [3:0] sel;
  reg        we, cyc = 0;
  wire [31:0] rdt;
  wire       ack, tx, irq;
  reg        rx = 1;

  uart_16550 #(.CLKS_PER_BIT(CPB), .FIFO_L2(8)) dut (
      .i_clk(clk), .i_rst(rst), .i_adr(adr), .i_dat(dat), .i_sel(sel), .i_we(we), .i_cyc(cyc),
      .o_rdt(rdt), .o_ack(ack), .o_tx(tx), .i_rx(rx), .o_irq(irq), .o_tx_push(), .o_tx_byte());

  integer errors = 0;
  task fail(input [8*40-1:0] what);
    begin
      errors = errors + 1;
      if (errors < 10) $display("FAIL: %0s (%0t)", what, $time);
    end
  endtask

  // byte register access (reg 0..7 as the 8250 driver does with reg-shift 0)
  reg [7:0] rb;
  task reg_rw(input [2:0] r, input w, input [7:0] v);
    begin
      @(posedge clk);
      adr <= r[2]; sel <= 4'b0001 << r[1:0]; dat <= {4{v}}; we <= w; cyc <= 1;
      @(posedge clk);
      while (!ack) @(posedge clk);
      rb = rdt >> (8 * r[1:0]);
      cyc <= 0;
      repeat (3) @(posedge clk);
    end
  endtask

  // TX monitor: decode 8N1 frames on tx
  reg [7:0] tx_log [0:1023];
  integer   tx_n = 0, b;
  reg [7:0] f;
  always begin
    @(negedge tx);
    #(CPB * 10 * 1.5);                    // middle of bit 0
    for (b = 0; b < 8; b = b + 1) begin
      f[b] = tx;
      #(CPB * 10);
    end
    if (tx !== 1'b1) fail("TX stop bit");
    tx_log[tx_n] = f;
    tx_n = tx_n + 1;
  end

  // RX driver
  task send_rx(input [7:0] v);
    integer k;
    begin
      rx = 0; #(CPB * 10);
      for (k = 0; k < 8; k = k + 1) begin rx = v[k]; #(CPB * 10); end
      rx = 1; #(CPB * 10);
    end
  endtask

  integer i, n;
  initial begin
    repeat (4) @(posedge clk);
    rst = 0;
    reg_rw(3'd2, 1, 8'h07);               // FCR: enable + clear FIFOs

    // ---------------------------------------------------------------- 1: TX
    reg_rw(3'd1, 1, 8'h02);               // IER: THRE
    @(posedge clk); #1;
    if (!irq) fail("THRE irq with an empty FIFO");
    reg_rw(3'd2, 0, 0);
    if (rb[3:0] != 4'h2) fail("IIR THRE");
    for (i = 0; i < 300; i = i + 1) begin
      while (dut.tx_full) @(posedge clk);  // wait for room
      reg_rw(3'd0, 1, i[7:0] ^ 8'h5A);
      if (i == 10) begin
        @(posedge clk); #1;
        if (irq) fail("THRE irq while bytes are queued");
      end
    end
    wait (tx_n == 300);
    repeat (CPB * 20) @(posedge clk); #1;
    for (i = 0; i < 300; i = i + 1)
      if (tx_log[i] !== (i[7:0] ^ 8'h5A)) begin
        fail("TX byte order/value");
        i = 300;
      end
    if (!irq) fail("THRE irq after draining");
    reg_rw(3'd1, 1, 8'h00);
    @(posedge clk); #1;
    if (irq) fail("irq with IER = 0");

    // ---------------------------------------------------------------- 2: RX
    reg_rw(3'd1, 1, 8'h01);               // IER: RX data
    for (i = 0; i < 40; i = i + 1) send_rx(8'hC3 ^ i[7:0]);
    repeat (10) @(posedge clk); #1;
    if (!irq) fail("RX irq");
    reg_rw(3'd2, 0, 0);
    if (rb[3:0] != 4'h4) fail("IIR RX data");
    for (i = 0; i < 40; i = i + 1) begin
      reg_rw(3'd5, 0, 0);
      if (!rb[0]) fail("LSR.DR");
      reg_rw(3'd0, 0, 0);
      if (rb !== (8'hC3 ^ i[7:0])) fail("RX byte");
    end
    reg_rw(3'd5, 0, 0);
    if (rb[0]) fail("LSR.DR after draining");
    @(posedge clk); #1;
    if (irq) fail("RX irq after draining");

    // ---------------------------------------------------------------- 3: RX overrun
    reg_rw(3'd1, 1, 8'h04);               // IER: line status only
    for (i = 0; i < 260; i = i + 1) send_rx(i[7:0]);
    repeat (10) @(posedge clk); #1;
    if (!irq) fail("line status irq");
    reg_rw(3'd2, 0, 0);
    if (rb[3:0] != 4'h6) fail("IIR line status");
    reg_rw(3'd5, 0, 0);
    if (!rb[1]) fail("LSR overrun");
    reg_rw(3'd5, 0, 0);
    if (rb[1]) fail("LSR overrun not cleared by reading LSR");
    n = 0;
    for (i = 0; i < 300; i = i + 1) begin
      reg_rw(3'd5, 0, 0);
      if (rb[0]) begin
        reg_rw(3'd0, 0, 0);
        if (rb !== n[7:0]) fail("RX byte after overrun");
        n = n + 1;
      end
    end
    if (n != 256) begin
      fail("RX FIFO depth");
      $display("  kept %0d bytes", n);
    end

    $display("%s: %0d TX bytes, %0d errors", errors ? "FAIL" : "PASS", tx_n, errors);
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL: timeout");
    $finish;
  end
endmodule

`default_nettype wire
