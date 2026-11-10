// DVI 1.0 TMDS encoder (8b/10b with DC balance) for one lane, registered output.
//
// i_de = 1: encode i_d (transition minimisation, then running-disparity balance).
// i_de = 0: send the control symbol for i_c = {C1, C0} and reset the disparity.
// o_q[0] is the first bit on the wire. Lane 0 carries C0 = hsync, C1 = vsync; lanes 1 and 2
// send C = 00 in blanking (DVI, no HDMI data islands).
`default_nettype none

module tmds_encoder (
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire       i_de,
    input  wire [7:0] i_d,
    input  wire [1:0] i_c,
    output reg  [9:0] o_q
);

  function [3:0] ones8(input [7:0] v);
    ones8 = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
  endfunction

  // stage 1: transition-minimised q_m
  wire [3:0] n1d = ones8(i_d);
  wire       use_xnor = (n1d > 4'd4) | ((n1d == 4'd4) & !i_d[0]);
  wire [8:0] q_m;
  assign q_m[0] = i_d[0];
  genvar i;
  generate
    for (i = 1; i < 8; i = i + 1) begin : g_qm
      assign q_m[i] = use_xnor ? !(q_m[i-1] ^ i_d[i]) : (q_m[i-1] ^ i_d[i]);
    end
  endgenerate
  assign q_m[8] = !use_xnor;

  // stage 2: DC balance against the running disparity cnt (ones minus zeros sent so far)
  wire        [3:0] n1q = ones8(q_m[7:0]);
  // n1q - n0q = 2*n1q - 8, in -8..8 (computed on 6 bits: 2*n1q reaches 16)
  wire signed [5:0] diff6 = $signed({1'b0, n1q, 1'b0}) - 6'sd8;
  wire signed [4:0] diff  = diff6[4:0];
  reg  signed [4:0] cnt;

  always @(posedge i_clk) begin
    if (i_rst) begin
      cnt <= 5'sd0;
      o_q <= 10'b1101010100;
    end else if (!i_de) begin
      cnt <= 5'sd0;
      case (i_c)
        2'b00: o_q <= 10'b1101010100;
        2'b01: o_q <= 10'b0010101011;
        2'b10: o_q <= 10'b0101010100;
        default: o_q <= 10'b1010101011;
      endcase
    end else if ((cnt == 5'sd0) | (diff == 5'sd0)) begin
      o_q <= {!q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
      cnt <= q_m[8] ? cnt + diff : cnt - diff;
    end else if ((!cnt[4] & !diff[4]) | (cnt[4] & diff[4])) begin   // same sign: invert
      o_q <= {1'b1, q_m[8], ~q_m[7:0]};
      cnt <= cnt + {3'b000, q_m[8], 1'b0} - diff;
    end else begin
      o_q <= {1'b0, q_m[8], q_m[7:0]};
      cnt <= cnt - {3'b000, !q_m[8], 1'b0} + diff;
    end
  end

endmodule

`default_nettype wire
