// Simulation of fpga/probe_psram16 (the 16-bit HyperRAM controller and its memory test) against
// two W955D8MBYA die models (verif/psram16/model, takayuki-nagata/psram_controller, MIT), wired
// as on the board: die 0's clock pin is O_psram_ck[0], die 1's O_psram_ck_n[1]. The Gowin I/O
// primitives come from rtl/sim/gowin_io_sim.v, or from Gowin's own models with GOWIN_PRIM
// defined. The probe's first UART result line is decoded and printed, and the run ends there.
//   PHASE_NS: clk_p (CK) behind clk; 90 degrees at 42 MHz is 5.952 ns
`timescale 1ns / 1ps
`default_nettype none

module tb_psram16;
  parameter real    PHASE_NS = 5.952;
  localparam real   HALF     = 11.905;           // 42 MHz

`ifdef GOWIN_PRIM
  GSR GSR (.GSRI(1'b1));
`endif

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
  wire ck0 = pwr & ck[0];
  wire ck1 = pwr & ck_n[1];
  wire [1:0] cs_n_d = pwr ? cs_n : 2'b11;
  w955d8mbya_die #(.DIE(0)) die0 (.ck(ck0), .ck_n(!ck0), .cs_n(cs_n_d[0]),
                                  .reset_n(reset_n[0]), .dq(dq[7:0]), .rwds(rwds[0]));
  w955d8mbya_die #(.DIE(1)) die1 (.ck(ck1), .ck_n(!ck1), .cs_n(cs_n_d[1]),
                                  .reset_n(reset_n[1]), .dq(dq[15:8]), .rwds(rwds[1]));

  // UART decode, 1 Mbaud
  reg [8*256-1:0] line_buf;
  integer i;
  reg [7:0] ch;
  always @(negedge uart_tx) begin
    #500;                                        // middle of the start bit
    for (i = 0; i < 8; i = i + 1) begin #1000; ch[i] = uart_tx; end
    #1000;
    if (ch == 8'h0a) begin
      $display("UART: %0s", line_buf);
      $display("model protocol errors: die0 %0d, die1 %0d", die0.error_count, die1.error_count);
      $finish;
    end else if (ch != 8'h0d) begin
      line_buf = {line_buf[8*255-1:0], ch};
    end
  end

  initial begin
    #(200_000_000);                               // 200 ms
    $display("TIMEOUT: no result line");
    $finish;
  end
endmodule

`default_nettype wire
