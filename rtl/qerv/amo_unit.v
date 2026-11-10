// A-extension execution unit for the QERV (SERV LINUX=1) data bus.
//
// The core issues AMO/LR/SC as one data-bus transaction: o_dbus_amo=1, o_dbus_amo_op=funct5,
// adr=rs1 (word aligned, misalignment already trapped by the core), dat=rs2, sel=1111. This
// unit sits between the core's dbus and the memory bus and turns that into plain Wishbone
// transactions; everything else passes through combinationally (no added latency).
//
//   AMO*  : read old value, compute op(old, rs2) into a register, write it; return old.
//   LR.W  : read; set the reservation (word address); return the value.
//   SC.W  : if the reservation is valid for this word, write rs2 and return 0, else return 1
//           without a memory access. Every SC clears the reservation. The address compare
//           is registered (S_SCCHK, one cycle): combinational, its 30-bit carry chain sat
//           between the MMU's translated address and the core's ack, the SoC's worst path
//           once the I2C and SD controllers were in (doc/peripherals.md).
//
// Single hart and no other bus masters in stage 1, so holding the bus between the read and
// the write is enough for atomicity. Linux clears stale reservations itself with a dummy SC
// on every trap return. Ack handling mirrors servant_ram: after acking, one cycle in DONE
// so a request still held high by the core is not started twice.
`default_nettype none

module amo_unit (
    input  wire        i_clk,
    input  wire        i_rst,
    // core data bus
    input  wire [31:0] i_cpu_adr,
    input  wire [31:0] i_cpu_dat,
    input  wire [ 3:0] i_cpu_sel,
    input  wire        i_cpu_we,
    input  wire        i_cpu_cyc,
    input  wire        i_cpu_amo,
    input  wire [ 4:0] i_cpu_amo_op,
    output wire [31:0] o_cpu_rdt,
    output wire        o_cpu_ack,
    // memory bus
    output wire [31:0] o_mem_adr,
    output wire [31:0] o_mem_dat,
    output wire [ 3:0] o_mem_sel,
    output wire        o_mem_we,
    output wire        o_mem_cyc,
    input  wire [31:0] i_mem_rdt,
    input  wire        i_mem_ack
);

  localparam [4:0] OP_ADD = 5'b00000, OP_SWAP = 5'b00001, OP_LR = 5'b00010, OP_SC = 5'b00011,
                   OP_XOR = 5'b00100, OP_OR = 5'b01000, OP_AND = 5'b01100, OP_MIN = 5'b10000,
                   OP_MAX = 5'b10100, OP_MINU = 5'b11000, OP_MAXU = 5'b11100;

  localparam [2:0] S_IDLE = 3'd0, S_READ = 3'd1, S_GAP = 3'd2, S_WRITE = 3'd3,
                   S_SCFAIL = 3'd4, S_DONE = 3'd5, S_SCCHK = 3'd6;

  reg [ 2:0] state;
  reg [31:0] old;
  reg [31:0] wdat;   // op(old, rs2), registered in S_GAP so the ALU is not on the bus path
  reg        res_valid;
  reg [29:0] res_adr;
  reg        sc_hit;   // the reservation matches the request's word, one cycle late

  wire       is_lr = i_cpu_amo_op == OP_LR;
  wire       is_sc = i_cpu_amo_op == OP_SC;

  // op(old, rs2)
  wire signed [31:0] s_old = old;
  wire signed [31:0] s_rs2 = i_cpu_dat;
  reg  [31:0] new_val;
  always @(*) begin
    case (i_cpu_amo_op)
      OP_ADD:  new_val = old + i_cpu_dat;
      OP_XOR:  new_val = old ^ i_cpu_dat;
      OP_OR:   new_val = old | i_cpu_dat;
      OP_AND:  new_val = old & i_cpu_dat;
      OP_MIN:  new_val = (s_old < s_rs2) ? old : i_cpu_dat;
      OP_MAX:  new_val = (s_old > s_rs2) ? old : i_cpu_dat;
      OP_MINU: new_val = (old < i_cpu_dat) ? old : i_cpu_dat;
      OP_MAXU: new_val = (old > i_cpu_dat) ? old : i_cpu_dat;
      default: new_val = i_cpu_dat;  // AMOSWAP, SC
    endcase
  end

  wire is_amo = i_cpu_amo;
  assign o_mem_adr = i_cpu_adr;
  assign o_mem_sel = is_amo ? 4'b1111 : i_cpu_sel;
  assign o_mem_cyc = is_amo ? (state == S_READ) | (state == S_WRITE) : i_cpu_cyc;
  assign o_mem_we  = is_amo ? (state == S_WRITE) : i_cpu_we;
  assign o_mem_dat = (is_amo & !is_sc) ? wdat : i_cpu_dat;

  assign o_cpu_ack = is_amo ? ((state == S_READ) & i_mem_ack & is_lr) |
                           ((state == S_WRITE) & i_mem_ack) |
                           (state == S_SCFAIL)
                         : i_mem_ack;
  assign o_cpu_rdt = !is_amo                 ? i_mem_rdt :
                     (state == S_READ)       ? i_mem_rdt :   // LR
                     (state == S_SCFAIL)     ? 32'd1 :
                     is_sc                   ? 32'd0 :
                                               old;

  always @(posedge i_clk) begin
    sc_hit <= res_valid & (res_adr == i_cpu_adr[31:2]);
    case (state)
      S_IDLE:
        if (i_cpu_cyc & is_amo) state <= is_sc ? S_SCCHK : S_READ;
      S_SCCHK:
        state <= sc_hit ? S_WRITE : S_SCFAIL;
      S_READ:
        if (i_mem_ack) begin
          old <= i_mem_rdt;
          if (is_lr) begin
            res_valid <= 1'b1;
            res_adr   <= i_cpu_adr[31:2];
          end
          state <= is_lr ? S_DONE : S_GAP;
        end
      S_GAP: begin
        wdat  <= new_val;
        state <= S_WRITE;
      end
      S_WRITE:
        if (i_mem_ack) begin
          if (is_sc) res_valid <= 1'b0;
          state <= S_DONE;
        end
      S_SCFAIL: begin
        res_valid <= 1'b0;
        state     <= S_DONE;
      end
      default: state <= S_IDLE;  // S_DONE
    endcase
    if (i_rst) begin
      state     <= S_IDLE;
      res_valid <= 1'b0;
    end
  end

endmodule

`default_nettype wire
