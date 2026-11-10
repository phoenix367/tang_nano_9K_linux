// Fit/utilization probe for the KianV RV32IMA SV32 core on the Tang Nano 9K.
//
// NOT a working SoC. The CPU's memory bus and interrupt inputs are driven by an LFSR
// and every CPU output is XOR-folded into one registered LED pin, so synthesis can't
// prune any of the core while the design still fits the QN88 package and can go
// through place-and-route (real post-PnR utilization + Fmax).
//
// Probe overhead (counted in the reports, subtract when quoting the core):
// a 64-bit LFSR (~64 FF, a few LUTs) and a ~170-input XOR tree (~60 LUT4, 1 FF).
`default_nettype none

module kianv_sv32_fit_top (
    input  wire clk,    // 27 MHz crystal, pin 52
    input  wire rst_n,  // S1 button, pin 4 (active low)
    output wire led     // LED0, pin 10 (active low)
);

  // Power-on reset: hold for 16 cycles after config, plus the button.
  reg [3:0] por_cnt = 4'd0;
  reg       resetn = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      por_cnt <= 4'd0;
      resetn  <= 1'b0;
    end else if (por_cnt != 4'hf) begin
      por_cnt <= por_cnt + 4'd1;
      resetn  <= 1'b0;
    end else begin
      resetn <= 1'b1;
    end
  end

  // 64-bit Fibonacci LFSR (taps 64,63,61,60) as pseudo-random stimulus.
  reg [63:0] lfsr = 64'h1;
  always @(posedge clk) lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};

  wire        mem_valid;
  wire [ 3:0] mem_wstrb;
  wire [33:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [31:0] pc;
  wire [63:0] timer_counter;
  wire        is_instruction;
  wire        icache_flush;

  kianv_harris_mc_edition #(
      .RESET_ADDR(32'h0),
      .SYSTEM_CLK(27_000_000)
  ) cpu (
      .clk           (clk),
      .resetn        (resetn),
      .mem_valid     (mem_valid),
      .mem_ready     (lfsr[32]),
      .mem_wstrb     (mem_wstrb),
      .mem_addr      (mem_addr),
      .mem_wdata     (mem_wdata),
      .mem_rdata     (lfsr[31:0]),
      .PC            (pc),
      .access_fault  (lfsr[33] & lfsr[40] & lfsr[47]),  // rare
      .IRQ3          (lfsr[34] & lfsr[41] & lfsr[48]),
      .IRQ7          (lfsr[35] & lfsr[42] & lfsr[49]),
      .IRQ9          (lfsr[36] & lfsr[43] & lfsr[50]),
      .IRQ11         (lfsr[37] & lfsr[44] & lfsr[51]),
      .timer_counter (timer_counter),
      .is_instruction(is_instruction),
      .icache_flush  (icache_flush)
  );

  reg fold;
  always @(posedge clk)
    fold <= ^{mem_valid, mem_wstrb, mem_addr, mem_wdata, pc, timer_counter,
              is_instruction, icache_flush};

  assign led = fold;

endmodule

`default_nettype wire
