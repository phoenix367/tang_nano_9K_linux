// Minimal RISC-V PLIC for the QERV SoC (Linux "sifive,plic-1.0.0" driver): SOURCES level
// sources (1..SOURCES), one context (the hart's S-mode external interrupt, SEIP). Byte
// offsets in the 4 MB window, as the SiFive/RISC-V PLIC:
//   0x000000 + 4*i   priority of source i (3 bits; 0 = never)
//   0x001000         pending bits (read-only)
//   0x002000         context 0 enable bits
//   0x200000         context 0 priority threshold (3 bits)
//   0x200004         context 0 claim (read: highest pending enabled source above the
//                    threshold, 0 if none, and that source becomes in-service) / complete
//                    (write the source id: it may interrupt again)
// Gateways are level-triggered: a source is pending while its line is high and it is not
// in service. o_eip (registered) = some pending, enabled source above the threshold.
// Bus: Wishbone classic, word accesses, registered ack and read data.
`default_nettype none

module plic #(
    parameter SOURCES = 1                 // 1..31
) (
    input  wire               i_clk,
    input  wire               i_rst,
    input  wire [21:2]        i_adr,
    input  wire [31:0]        i_dat,
    input  wire               i_we,
    input  wire               i_cyc,
    output reg  [31:0]        o_rdt,
    output reg                o_ack,
    input  wire [SOURCES:1]   i_src,
    output reg                o_eip
);

  reg  [2:0]         prio[1:SOURCES];
  reg  [SOURCES:1]   en, busy;
  reg  [2:0]         thr;
  wire [SOURCES:1]   pending = i_src & ~busy;

  // highest-priority claimable source (lowest id wins a tie)
  reg  [4:0] best;
  reg  [2:0] best_p;
  integer    i;
  always @(*) begin
    best   = 5'd0;
    best_p = thr;
    for (i = SOURCES; i >= 1; i = i - 1)
      if (pending[i] & en[i] & (prio[i] > thr) & (prio[i] >= best_p)) begin
        best   = i[4:0];
        best_p = prio[i];
      end
  end

  wire access = i_cyc & !o_ack;
  wire a_prio = i_adr[21:12] == 10'h000;  // 0x000000-0x000FFF
  wire a_pend = i_adr[21:2] == 20'h00400; // 0x001000
  wire a_en   = i_adr[21:2] == 20'h00800; // 0x002000
  wire a_thr  = i_adr[21:2] == 20'h80000; // 0x200000
  wire a_clm  = i_adr[21:2] == 20'h80001; // 0x200004
  wire [9:0] src_i = i_adr[11:2];

  always @(posedge i_clk) begin
    o_ack <= i_cyc & !o_ack;
    o_eip <= best != 5'd0;
    o_rdt <= 32'd0;
    if (a_prio & (src_i >= 1) & (src_i <= SOURCES)) o_rdt <= {29'd0, prio[src_i]};
    if (a_pend) o_rdt <= {{(31 - SOURCES){1'b0}}, pending, 1'b0};
    if (a_en)   o_rdt <= {{(31 - SOURCES){1'b0}}, en, 1'b0};
    if (a_thr)  o_rdt <= {29'd0, thr};
    if (a_clm)  o_rdt <= {27'd0, best};
    if (access & !i_we & a_clm & (best != 5'd0)) busy[best] <= 1'b1;
    if (access & i_we) begin
      if (a_prio & (src_i >= 1) & (src_i <= SOURCES)) prio[src_i] <= i_dat[2:0];
      if (a_en)  en  <= i_dat[SOURCES:1];
      if (a_thr) thr <= i_dat[2:0];
      if (a_clm & (i_dat >= 1) & (i_dat <= SOURCES)) busy[i_dat[4:0]] <= 1'b0;
    end
    if (i_rst) begin
      o_ack <= 1'b0;
      o_eip <= 1'b0;
      en    <= {SOURCES{1'b0}};
      busy  <= {SOURCES{1'b0}};
      thr   <= 3'd0;
      for (i = 1; i <= SOURCES; i = i + 1) prio[i] <= 3'd0;
    end
  end

endmodule

`default_nettype wire
