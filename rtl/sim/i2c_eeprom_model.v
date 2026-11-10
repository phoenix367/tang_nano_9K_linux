// I2C slave model for the SoC simulation (sim/soc/tb_soc.v): a 24C02-like 256-byte memory at
// address ADDR. A write's first data byte sets the pointer and later bytes are stored there
// (the pointer advances); a read returns bytes from the pointer on. The memory starts as
// mem[i] = i ^ 8'h5A. Clocked by the system clock, which oversamples SCL and SDA (tens of
// clocks per I2C bit); open drain: o_sda_oe pulls SDA low.
`default_nettype none

module i2c_eeprom_model #(
    parameter [6:0] ADDR = 7'h50
) (
    input  wire i_clk,
    input  wire i_scl,
    input  wire i_sda,
    output reg  o_sda_oe = 1'b0
);

  localparam IDLE = 3'd0, ADR = 3'd1, ACK_A = 3'd2, WR = 3'd3, ACK_W = 3'd4, RD = 3'd5,
             ACK_R = 3'd6;

  reg [7:0] mem[0:255];
  integer   i;
  initial for (i = 0; i < 256; i = i + 1) mem[i] = i[7:0] ^ 8'h5A;

  reg       scl_d = 1'b1, sda_d = 1'b1;
  reg [2:0] st = IDLE;
  reg [3:0] bitc = 4'd0;
  reg [7:0] sh = 8'd0, ptr = 8'd0;
  reg       rw = 1'b0, got_ptr = 1'b0, nack = 1'b0;

  wire start = scl_d & i_scl & sda_d & !i_sda;     // SDA falls while SCL is high
  wire stop  = scl_d & i_scl & !sda_d & i_sda;     // SDA rises while SCL is high
  wire rise  = !scl_d & i_scl;
  wire fall  = scl_d & !i_scl;

  always @(posedge i_clk) begin
    scl_d <= i_scl;
    sda_d <= i_sda;
    if (start) begin
      st       <= ADR;
      bitc     <= 4'd0;
      got_ptr  <= 1'b0;
      o_sda_oe <= 1'b0;
    end else if (stop) begin
      st       <= IDLE;
      o_sda_oe <= 1'b0;
    end else
      case (st)
        ADR, WR: begin
          if (rise) begin
            sh   <= {sh[6:0], i_sda};
            bitc <= bitc + 4'd1;
          end
          if (fall && bitc == 4'd8) begin
            bitc <= 4'd0;
            if (st == ADR) begin
              if (sh[7:1] == ADDR) begin
                o_sda_oe <= 1'b1;            // ACK
                rw       <= sh[0];
                st       <= ACK_A;
              end else st <= IDLE;           // not us: wait for the next start
            end else begin
              o_sda_oe <= 1'b1;
              st       <= ACK_W;
              if (!got_ptr) begin
                ptr     <= sh;
                got_ptr <= 1'b1;
              end else begin
                mem[ptr] <= sh;
                ptr      <= ptr + 8'd1;
              end
            end
          end
        end
        ACK_A: if (fall) begin
          if (rw) begin
            sh       <= mem[ptr];
            o_sda_oe <= !mem[ptr][7];
            st       <= RD;
          end else begin
            o_sda_oe <= 1'b0;
            st       <= WR;
          end
        end
        ACK_W: if (fall) begin
          o_sda_oe <= 1'b0;
          st       <= WR;
        end
        RD: if (fall) begin
          if (bitc == 4'd7) begin
            o_sda_oe <= 1'b0;                // release for the master's ACK
            ptr      <= ptr + 8'd1;
            bitc     <= 4'd0;
            st       <= ACK_R;
          end else begin
            o_sda_oe <= !sh[3'd6 - bitc[2:0]];
            bitc     <= bitc + 4'd1;
          end
        end
        ACK_R: begin
          if (rise) nack <= i_sda;
          if (fall) begin
            if (nack) st <= IDLE;
            else begin
              sh       <= mem[ptr];
              o_sda_oe <= !mem[ptr][7];
              st       <= RD;
            end
          end
        end
        default: ;
      endcase
  end

endmodule

`default_nettype wire
