// Simulation of fpga/probe_psram16 (the 16-bit HyperRAM controller and its test sequencer)
// against two W955D8MBYA die models (verif/psram16/model, takayuki-nagata/psram_controller,
// MIT), with Gowin's primitive models for ODDR/IDDR/ELVDS_OBUF. The probe's UART lines are
// decoded and printed; the run ends after the sixth one (4 results, 2 traces).
//   CK1_N = 1: die 1's clock pin is O_psram_ck_n[1] (as the Gowin IP drives it), else O_psram_ck[1]
//   PHASE_NS: clk_p (CK) behind clk; 45 degrees at 42 MHz is 2.976 ns
`timescale 1ns / 1ps
`default_nettype none

module tb_psram16;
  parameter integer CK1_N    = 1;
  parameter real    PHASE_NS = 2.976;
  localparam real   HALF     = 11.905;           // 42 MHz

  GSR GSR (.GSRI(1'b1));

  reg clk = 1'b0, clk_p = 1'b0, clk27 = 1'b0;
  always #(HALF) clk = !clk;
  always @(clk) clk_p <= #(PHASE_NS) clk;
  always #(18.518) clk27 = !clk27;

  wire        uart_tx;
  wire [ 5:0] led_n;
  wire [ 1:0] ck, ck_n, rwds, reset_n, cs_n;
  wire [15:0] dq;

  psram16_probe_top dut (
      .clk_27m(clk27), .btn_rst_n(1'b1), .uart_tx(uart_tx), .uart_rx(1'b1), .led_n(led_n),
      .O_psram_ck(ck), .O_psram_ck_n(ck_n), .IO_psram_rwds(rwds), .O_psram_reset_n(reset_n),
      .IO_psram_dq(dq), .O_psram_cs_n(cs_n)
  );

  // The FPGA's configuration (GSR applying ODDR INIT values) is not simulated: hold CS# High
  // and CK Low for the first 100 ns instead of starting from the cells' 0 outputs.
  reg pwr = 1'b0;
  initial #100 pwr = 1'b1;
  // die 1's clock pin per CK1_N; the model ignores its ck_n input
  wire ck0 = pwr & ck[0];
  wire ck1 = pwr & (CK1_N ? ck_n[1] : ck[1]);
  wire [1:0] cs_n_d = pwr ? cs_n : 2'b11;
  w955d8mbya_die #(.DIE(0)) die0 (.ck(ck0), .ck_n(!ck0), .cs_n(cs_n_d[0]),
                                  .reset_n(reset_n[0]), .dq(dq[7:0]), .rwds(rwds[0]));
  w955d8mbya_die #(.DIE(1)) die1 (.ck(ck1), .ck_n(!ck1), .cs_n(cs_n_d[1]),
                                  .reset_n(reset_n[1]), .dq(dq[15:8]), .rwds(rwds[1]));

  // UART decode, 1 Mbaud
  reg [8*256-1:0] line_buf;
  integer n_lines = 0, n_chars = 0, i;
  reg [7:0] ch;
  always @(negedge uart_tx) begin
    #500;                                        // middle of the start bit
    for (i = 0; i < 8; i = i + 1) begin #1000; ch[i] = uart_tx; end
    #1000;
    if (ch == 8'h0a) begin
      $display("UART: %0s", line_buf);
      n_chars = 0; line_buf = 0; n_lines = n_lines + 1;
      if (n_lines == 6) begin
        $display("model protocol errors: die0 %0d, die1 %0d", die0.error_count, die1.error_count);
        $finish;
      end
    end else if (ch != 8'h0d) begin
      line_buf = {line_buf[8*255-1:0], ch}; n_chars = n_chars + 1;
    end
  end

`ifdef TB_DEBUG
  always @(dut.ts or dut.cfg or dut.pass)
    $display("%0t ns: test state %0d cfg %0d pass %0d line %0d", $time, dut.ts, dut.cfg, dut.pass, dut.line);
  always @(dut.ram.st) $display("%0t ns: ctrl state %0d", $time, dut.ram.st);
`endif

  initial begin
    #(200_000_000);                               // 200 ms
    $display("TIMEOUT: %0d lines", n_lines);
    $finish;
  end
endmodule

`default_nettype wire
