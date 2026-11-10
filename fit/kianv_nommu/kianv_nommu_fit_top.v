// Fit/utilization probe for the KianV RV32IMA no-MMU core (uLinux SoC) on the Tang Nano 9K.
// Same scheme as fit/kianv_sv32: LFSR-driven inputs, XOR-folded outputs on one LED pin,
// so nothing is pruned and the design still goes through PnR.
// Probe overhead: 64-bit LFSR (~64 FF, a few LUTs) + ~100-input XOR tree (~35 LUT4, 1 FF).
`default_nettype none

module kianv_nommu_fit_top (
    input  wire clk,    // 27 MHz crystal, pin 52
    input  wire rst_n,  // S1 button, pin 4 (active low)
    output wire led     // LED0, pin 10 (active low)
);

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

  reg [63:0] lfsr = 64'h1;
  always @(posedge clk) lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};

  wire        mem_valid;
  wire [ 3:0] mem_wstrb;
  wire [31:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [31:0] pc;

  kianv_harris_mc_edition #(
      .RESET_ADDR(32'h0)
  ) cpu (
      .clk         (clk),
      .resetn      (resetn),
      .mem_valid   (mem_valid),
      .mem_ready   (lfsr[32]),
      .mem_wstrb   (mem_wstrb),
      .mem_addr    (mem_addr),
      .mem_wdata   (mem_wdata),
      .mem_rdata   (lfsr[31:0]),
      .PC          (pc),
      .access_fault(lfsr[33] & lfsr[40] & lfsr[47]),
      .IRQ3        (lfsr[34] & lfsr[41] & lfsr[48]),
      .IRQ7        (lfsr[35] & lfsr[42] & lfsr[49])
  );

  reg fold;
  always @(posedge clk) fold <= ^{mem_valid, mem_wstrb, mem_addr, mem_wdata, pc};

  assign led = fold;

endmodule

`default_nettype wire
