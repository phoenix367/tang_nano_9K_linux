// M1 testbench for the QERV-Linux CPU (rtl/qerv/qerv_cpu.v).
//
// qerv_cpu -> servile_arbiter -> servant_ram (registered ack, like perf/serv_cpi), plus:
//   * a store to MTIP_ADR sets the timer interrupt line to bit 0 of the data,
//   * a store to HALT_ADR ends the run (directed tests: 0 = pass, else failing test id),
//   * a store to +tohost=<hex> ends the run (riscv-tests: 1 = pass, else (n << 1) | 1).
// RAM is MEMSIZE bytes and decodes only the low address bits, so programs can be linked at
// 0x80000000 (riscv-tests) with RESET_PC = 0x80000000.
//
// Trace (+trace=<file>), sampled at the negative edge:
//   I <pc> <cycle>                 instruction fetch acknowledged
//   S <adr> <dat> <sel> <cycle>    write acknowledged (incl. the write half of an AMO)
//   R <adr> <sel> <cycle>          read acknowledged
`default_nettype none
`timescale 1ns/1ps

module qerv_tb;

  parameter        W        = 4;
  parameter [31:0] RESET_PC = 32'h8000_0000;
  parameter        memfile  = "";
  parameter        MEMSIZE  = 65536;
  parameter [31:0] MTIP_ADR = 32'h8000_FFF8;
  parameter [31:0] HALT_ADR = 32'h8000_FFFC;
  parameter        EXTRA_WAIT = 0;
  parameter        TIMEOUT  = 20000000;

  localparam aw = $clog2(MEMSIZE);

  reg clk = 1'b0;
  always #5 clk = !clk;

  reg        rst = 1'b1;
  reg [63:0] cycle = 64'd0;
  always @(posedge clk) begin
    cycle <= cycle + 64'd1;
    if (cycle == 64'd8) rst <= 1'b0;
  end

  reg mtip = 1'b0;

  wire [31:0] ibus_adr, ibus_rdt, dbus_adr, dbus_dat, dbus_rdt;
  wire [ 3:0] dbus_sel;
  wire        ibus_cyc, ibus_ack, dbus_we, dbus_cyc, dbus_ack;

  qerv_cpu #(.W(W), .RESET_PC(RESET_PC)) cpu (
      .i_clk      (clk),
      .i_rst      (rst),
      .i_timer_irq(mtip),
      .o_ibus_adr (ibus_adr),
      .o_ibus_cyc (ibus_cyc),
      .i_ibus_rdt (ibus_rdt),
      .i_ibus_ack (ibus_ack),
      .o_dbus_adr (dbus_adr),
      .o_dbus_dat (dbus_dat),
      .o_dbus_sel (dbus_sel),
      .o_dbus_we  (dbus_we),
      .o_dbus_cyc (dbus_cyc),
      .i_dbus_rdt (dbus_rdt),
      .i_dbus_ack (dbus_ack)
  );

  // mdu_top does not reset these; the FPGA powers them up at 0 (see perf/serv_cpi)
  initial begin
    cpu.mdu.div_ready = 1'b0;
    cpu.mdu.mul_en    = 1'b0;
    cpu.mdu.mul_done  = 1'b0;
  end

  wire [31:0] mem_adr, mem_dat, mem_rdt;
  wire [ 3:0] mem_sel;
  wire        mem_we, mem_stb, mem_ack;

  servile_arbiter arbiter (
      .i_wb_cpu_dbus_adr(dbus_adr),
      .i_wb_cpu_dbus_dat(dbus_dat),
      .i_wb_cpu_dbus_sel(dbus_sel),
      .i_wb_cpu_dbus_we (dbus_we),
      .i_wb_cpu_dbus_stb(dbus_cyc),
      .o_wb_cpu_dbus_rdt(dbus_rdt),
      .o_wb_cpu_dbus_ack(dbus_ack),
      .i_wb_cpu_ibus_adr(ibus_adr),
      .i_wb_cpu_ibus_stb(ibus_cyc),
      .o_wb_cpu_ibus_rdt(ibus_rdt),
      .o_wb_cpu_ibus_ack(ibus_ack),
      .o_wb_mem_adr     (mem_adr),
      .o_wb_mem_dat     (mem_dat),
      .o_wb_mem_sel     (mem_sel),
      .o_wb_mem_we      (mem_we),
      .o_wb_mem_stb     (mem_stb),
      .i_wb_mem_rdt     (mem_rdt),
      .i_wb_mem_ack     (mem_ack)
  );

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

  servant_ram #(
      .memfile       (memfile),
      .depth         (MEMSIZE),
      .RESET_STRATEGY("MINI")
  ) ram (
      .i_wb_clk(clk),
      .i_wb_rst(rst),
      .i_wb_adr(mem_adr[aw-1:2]),
      .i_wb_cyc(ram_cyc),
      .i_wb_we (mem_we),
      .i_wb_sel(mem_sel),
      .i_wb_dat(mem_dat),
      .o_wb_rdt(mem_rdt),
      .o_wb_ack(mem_ack)
  );

  // ---------------------------------------------------------------- monitor
  integer      f = 0;
  reg [1023:0] tracefile;
  reg [31:0]   tohost = 32'hFFFF_FFFF;
  reg [63:0]   n_fetch = 64'd0;

  initial begin
    if (!$value$plusargs("tohost=%h", tohost)) tohost = 32'hFFFF_FFFF;
    if ($value$plusargs("trace=%s", tracefile)) f = $fopen(tracefile, "w");
  end

  task finish(input [8*8-1:0] what, input [31:0] value);
    begin
      $display("%0s value=%08h cycle=%0d fetches=%0d", what, value, cycle, n_fetch);
      if (f) $fclose(f);
      $finish;
    end
  endtask

  always @(negedge clk) begin
    if (!rst) begin
      if (ibus_ack) begin
        n_fetch = n_fetch + 1;
        if (f) $fwrite(f, "I %08h %0d\n", ibus_adr, cycle);
      end
      if (mem_ack & mem_we) begin  // only the data side writes
        if (f) $fwrite(f, "S %08h %08h %1h %0d\n", mem_adr, mem_dat, mem_sel, cycle);
        if (mem_adr == MTIP_ADR) mtip = mem_dat[0];
        if (mem_adr == HALT_ADR) finish("HALT", mem_dat);
        if (mem_adr == tohost) finish("TOHOST", mem_dat);
      end
      if (mem_ack & !mem_we & dbus_cyc & f) $fwrite(f, "R %08h %1h %0d\n", mem_adr, mem_sel, cycle);
    end
    if (cycle > TIMEOUT) finish("TIMEOUT", ibus_adr);
  end

endmodule

`default_nettype wire
