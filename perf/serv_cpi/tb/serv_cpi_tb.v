// Cycle-accounting testbench for SERV (W=1) / QERV (W=4) with the MDU (M extension).
//
// CPU wiring is identical to fit/qerv/qerv_fit_top.v (serv_rf_top + mdu_top).
// Memory system mirrors upstream servile/servant: servile_arbiter merges ibus and dbus onto
// one Wishbone port, which drives an unmodified servant_ram (registered ack: the ack and read
// data arrive the cycle after cyc is raised). EXTRA_WAIT > 0 holds cyc away from servant_ram
// for that many extra cycles, i.e. it adds EXTRA_WAIT wait states to every bus transaction.
//
// Trace written to +trace=<file> (one line per event, all sampled at the negative edge so
// every signal is settled; "cycle" = number of rising edges since time 0):
//   I <pc> <cycle>                      instruction fetch acknowledged
//   S <adr> <dat> <sel> <cycle>         data-bus write acknowledged
//   R <adr> <sel> <cycle>               data-bus read acknowledged
//   M <value> <cycle> <ibus_acks> <dbus_acks>   write to MARK_ADR (timing marker)
// The run ends on a write to HALT_ADR or after TIMEOUT cycles.
`default_nettype none
`timescale 1ns/1ps

module serv_cpi_tb;

   parameter W          = 1;
   parameter memfile    = "";
   parameter memsize    = 262144;            // bytes
   parameter [31:0] MARK_ADR = 32'h0003FFF0;
   parameter [31:0] HALT_ADR = 32'h0003FFF4;
   parameter EXTRA_WAIT = 0;
   parameter TIMEOUT    = 100000000;

   localparam aw = $clog2(memsize);

   reg clk = 1'b0;
   always #5 clk = !clk;

   reg rst = 1'b1;
   reg [63:0] cycle = 64'd0;
   always @(posedge clk) begin
      cycle <= cycle + 64'd1;
      if (cycle == 64'd8) rst <= 1'b0;
   end

   // ---------------------------------------------------------------- CPU + MDU
   wire [31:0] ibus_adr;
   wire        ibus_cyc;
   wire [31:0] ibus_rdt;
   wire        ibus_ack;
   wire [31:0] dbus_adr;
   wire [31:0] dbus_dat;
   wire [ 3:0] dbus_sel;
   wire        dbus_we;
   wire        dbus_cyc;
   wire [31:0] dbus_rdt;
   wire        dbus_ack;

   wire [31:0] ext_rs1;
   wire [31:0] ext_rs2;
   wire [ 2:0] ext_funct3;
   wire        mdu_valid;
   wire [31:0] mdu_rd;
   wire        mdu_ready;

   serv_rf_top
     #(.RESET_PC      (32'h0),
       .COMPRESSED    (1'b0),
       .MDU           (1'b1),
       .PRE_REGISTER  (1),
       .RESET_STRATEGY("MINI"),
       .WITH_CSR      (1),
       .W             (W))
   cpu
     (.clk         (clk),
      .i_rst       (rst),
      .i_timer_irq (1'b0),
      .o_ibus_adr  (ibus_adr),
      .o_ibus_cyc  (ibus_cyc),
      .i_ibus_rdt  (ibus_rdt),
      .i_ibus_ack  (ibus_ack),
      .o_dbus_adr  (dbus_adr),
      .o_dbus_dat  (dbus_dat),
      .o_dbus_sel  (dbus_sel),
      .o_dbus_we   (dbus_we),
      .o_dbus_cyc  (dbus_cyc),
      .i_dbus_rdt  (dbus_rdt),
      .i_dbus_ack  (dbus_ack),
      .o_ext_rs1   (ext_rs1),
      .o_ext_rs2   (ext_rs2),
      .o_ext_funct3(ext_funct3),
      .i_ext_rd    (mdu_rd),
      .i_ext_ready (mdu_ready),
      .o_mdu_valid (mdu_valid));

   // mdu_top does not reset div_ready / mul_en / mul_done; on the FPGA they power up at 0,
   // but in a 4-state simulator the X on o_mdu_ready leaks into SERV's rf_wreq and the
   // core never starts. Emulate the FPGA power-up value.
   initial begin
      mdu.div_ready = 1'b0;
      mdu.mul_en    = 1'b0;
      mdu.mul_done  = 1'b0;
   end

   mdu_top mdu
     (.i_clk      (clk),
      .i_rst      (rst),
      .i_mdu_rs1  (ext_rs1),
      .i_mdu_rs2  (ext_rs2),
      .i_mdu_op   (ext_funct3),
      .i_mdu_valid(mdu_valid),
      .o_mdu_ready(mdu_ready),
      .o_mdu_rd   (mdu_rd));

   // ---------------------------------------------------------------- memory system
   wire [31:0] mem_adr;
   wire [31:0] mem_dat;
   wire [ 3:0] mem_sel;
   wire        mem_we;
   wire        mem_stb;
   wire [31:0] mem_rdt;
   wire        mem_ack;

   servile_arbiter arbiter
     (.i_wb_cpu_dbus_adr (dbus_adr),
      .i_wb_cpu_dbus_dat (dbus_dat),
      .i_wb_cpu_dbus_sel (dbus_sel),
      .i_wb_cpu_dbus_we  (dbus_we),
      .i_wb_cpu_dbus_stb (dbus_cyc),
      .o_wb_cpu_dbus_rdt (dbus_rdt),
      .o_wb_cpu_dbus_ack (dbus_ack),
      .i_wb_cpu_ibus_adr (ibus_adr),
      .i_wb_cpu_ibus_stb (ibus_cyc),
      .o_wb_cpu_ibus_rdt (ibus_rdt),
      .o_wb_cpu_ibus_ack (ibus_ack),
      .o_wb_mem_adr      (mem_adr),
      .o_wb_mem_dat      (mem_dat),
      .o_wb_mem_sel      (mem_sel),
      .o_wb_mem_we       (mem_we),
      .o_wb_mem_stb      (mem_stb),
      .i_wb_mem_rdt      (mem_rdt),
      .i_wb_mem_ack      (mem_ack));

   // Optional extra wait states: keep cyc away from the RAM for EXTRA_WAIT cycles.
   wire ram_cyc;
   generate
      if (EXTRA_WAIT == 0) begin : gen_no_wait
         assign ram_cyc = mem_stb;
      end else begin : gen_wait
         reg [7:0] wcnt = 8'd0;
         always @(posedge clk)
           if (rst | mem_ack | !mem_stb) wcnt <= 8'd0;
           else if (wcnt != EXTRA_WAIT) wcnt <= wcnt + 8'd1;
         assign ram_cyc = mem_stb & (wcnt == EXTRA_WAIT);
      end
   endgenerate

   servant_ram
     #(.memfile        (memfile),
       .depth          (memsize),
       .RESET_STRATEGY ("MINI"))
   ram
     (.i_wb_clk (clk),
      .i_wb_rst (rst),
      .i_wb_adr (mem_adr[aw-1:2]),
      .i_wb_cyc (ram_cyc),
      .i_wb_we  (mem_we),
      .i_wb_sel (mem_sel),
      .i_wb_dat (mem_dat),
      .o_wb_rdt (mem_rdt),
      .o_wb_ack (mem_ack));

   // ---------------------------------------------------------------- tracing
   integer     f = 0;
   reg [1023:0] tracefile;
   reg [63:0]  n_ibus = 64'd0;
   reg [63:0]  n_dbus = 64'd0;

   initial begin
      if (!$value$plusargs("trace=%s", tracefile)) tracefile = "trace.log";
      f = $fopen(tracefile, "w");
      if (f == 0) begin
         $display("ERROR: cannot open trace file");
         $finish;
      end
   end

   always @(negedge clk) begin
      if (!rst) begin
         if (ibus_ack) begin
            $fwrite(f, "I %08h %0d\n", ibus_adr, cycle);
            n_ibus = n_ibus + 1;
         end
         if (dbus_ack) begin
            if (dbus_we) begin
               $fwrite(f, "S %08h %08h %1h %0d\n", dbus_adr, dbus_dat, dbus_sel, cycle);
               if (dbus_adr == MARK_ADR)
                 $fwrite(f, "M %08h %0d %0d %0d\n", dbus_dat, cycle, n_ibus, n_dbus);
               if (dbus_adr == HALT_ADR) begin
                  $fwrite(f, "H %08h %0d\n", dbus_dat, cycle);
                  $fclose(f);
                  $display("HALT value=%08h cycle=%0d fetches=%0d", dbus_dat, cycle, n_ibus);
                  $finish;
               end
            end else begin
               $fwrite(f, "R %08h %1h %0d\n", dbus_adr, dbus_sel, cycle);
            end
            n_dbus = n_dbus + 1;
         end
      end
      if (cycle > TIMEOUT) begin
         $fwrite(f, "T %0d\n", cycle);
         $fclose(f);
         $display("TIMEOUT at cycle %0d (pc=%08h)", cycle, ibus_adr);
         $finish;
      end
   end

endmodule
`default_nettype wire
