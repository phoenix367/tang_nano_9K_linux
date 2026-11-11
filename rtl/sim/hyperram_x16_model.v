// Cycle model of rtl/psram/hyperram_x16.v as its user sees it (the command interface, not the
// pins), with 8 MB of memory: what the cache, video and SoC simulations run against instead of
// the controller and two die models (verif/psram16 tests the real controller). It runs in
// both Icarus and Verilator.
//
// Timing, in cycles after the command is taken (the cycle with o_ready & i_cmd_en):
//   write beat k is asked for (o_wnext, o_wbeat = k) at +8+k, until the beat flagged
//     i_wlast or beat 7; o_ready again at +11+k (a full line: +18)
//   read beat k on o_rvalid/o_rdata at +16+k (RD_FIRST); o_ready again at +18, while this
//     read's last beats are still due (the next read's come from +34 on)
// as the controller does with its data on bus cycles 8..15 and the first read word captured
// on bus cycle 13 (simulation with the die models and the board). Bursts wrap inside the
// 32-byte line from the addressed word.
//
// Backdoor (byte addresses 0..0x7FFFFF in the 8 MB): backdoor_read_byte(a),
// backdoor_write_byte(a, v). Loader plusargs: +psram_load0=<file> +psram_addr0=<hex byte
// address> (and ...load1/...addr1). Protocol errors (a command while not ready) are printed
// and counted in error_count.
`default_nettype none

module hyperram_x16_model #(
    parameter integer INIT_CYCLES = 100,       // reset to o_init_done (the board: ~160 us)
    parameter integer RD_FIRST    = 16
) (
    input  wire        clk,
    input  wire        rst,
    output reg         o_init_done,
    output wire        o_ready,
    input  wire        i_cmd_en,
    input  wire        i_cmd_we,
    input  wire [22:2] i_addr,
    output wire        o_wnext,
    output wire [ 2:0] o_wbeat,
    input  wire [31:0] i_wdata,
    input  wire [ 3:0] i_wmask,
    input  wire        i_wlast,
    output reg         o_rvalid,
    output reg  [31:0] o_rdata,
    output wire [ 1:0] o_rerr
);
  reg [31:0] mem [0:(1 << 21) - 1] /* verilator public */;
  reg [31:0] error_count /* verilator public */;
  reg [31:0] cmd_count /* verilator public */;

  assign o_rerr = 2'b00;

  // one access at a time; a read's beats may still be due when the next access starts
  reg         busy, we_q, wdone;
  reg  [22:2] adr_q;
  reg  [ 5:0] t;                 // cycles since the command
  reg  [ 5:0] t_end;             // o_ready returns when t reaches it
  // reads in flight: a read's beats are due until +23, the next command can start at +18,
  // so two slots
  reg  [22:2] rd_adr [0:1];
  reg  [ 5:0] rt [0:1];          // cycles since the read's command (63 = slot free)
  reg         rs;                // slot of the next read
  reg  [31:0] init_cnt;

  assign o_ready = o_init_done & !busy;
  assign o_wnext = busy & we_q & !wdone & (t >= 6'd7) & (t <= 6'd14);
  assign o_wbeat = t[2:0] - 3'd7;            // t = 7 + k asks for beat k (taken at +8+k)

  function [22:2] beat_adr(input [22:2] a, input [2:0] k);
    beat_adr = {a[22:5], a[4:2] + k};
  endfunction

  integer i;
  always @(posedge clk) begin
    o_rvalid <= 1'b0;
    if (rst) begin
      busy <= 1'b0; o_init_done <= 1'b0; init_cnt <= 32'd0; rt[0] <= 6'd63; rt[1] <= 6'd63;
      rs <= 1'b0;
    end else begin
      if (!o_init_done) begin
        init_cnt <= init_cnt + 32'd1;
        if (init_cnt == INIT_CYCLES) o_init_done <= 1'b1;
      end
      if (i_cmd_en && !o_ready) begin
        $display("%t hyperram_x16_model ERROR: command while not ready", $time);
        error_count <= error_count + 32'd1;
      end
      if (o_ready && i_cmd_en) begin
        busy <= 1'b1; we_q <= i_cmd_we; wdone <= 1'b0; adr_q <= i_addr; t <= 6'd0;
        t_end <= 6'd17;
        cmd_count <= cmd_count + 32'd1;
      end else if (busy) begin
        t <= t + 6'd1;
        if (t + 6'd1 == t_end) busy <= 1'b0;
      end
      // writes: the beat asked for in this cycle
      if (o_wnext) begin
        for (i = 0; i < 4; i = i + 1)
          if (!i_wmask[i]) mem[beat_adr(adr_q, o_wbeat)][8*i +: 8] <= i_wdata[8*i +: 8];
        if (i_wlast) begin wdone <= 1'b1; t_end <= t + 6'd3; end   // ready at +11+k
      end
      // reads: beat k visible RD_FIRST + k cycles after the command (rt counts from 0 in the
      // cycle after it, so the beat is registered when rt + 2 = RD_FIRST + k)
      for (i = 0; i < 2; i = i + 1)
        if (rt[i] != 6'd63) begin
          rt[i] <= rt[i] + 6'd1;
          if (rt[i] + 6'd2 >= RD_FIRST[5:0] && rt[i] + 6'd2 < RD_FIRST[5:0] + 6'd8) begin
            o_rvalid <= 1'b1;
            o_rdata  <= mem[beat_adr(rd_adr[i], rt[i] + 6'd2 - RD_FIRST[5:0])];
          end
          if (rt[i] + 6'd2 == RD_FIRST[5:0] + 6'd7) rt[i] <= 6'd63;
        end
      if (o_ready && i_cmd_en && !i_cmd_we) begin
        rd_adr[rs] <= i_addr; rt[rs] <= 6'd0; rs <= !rs;
      end
    end
  end

  // ---------------------------------------------------------------- backdoor and loader
  function [7:0] backdoor_read_byte(input [22:0] a);
    reg [31:0] w;
    begin
      w = mem[a[22:2]];
      backdoor_read_byte = w[8*a[1:0] +: 8];
    end
  endfunction
  task backdoor_write_byte(input [22:0] a, input [7:0] v);
    begin
      mem[a[22:2]][8*a[1:0] +: 8] = v;
    end
  endtask

  task load_file(input [8*256-1:0] fname, input [22:0] base);
    integer fd, ch, n;
    reg [22:0] a;
    begin
      fd = $fopen(fname, "rb");
      if (fd == 0) $display("hyperram_x16_model ERROR: cannot open %0s", fname);
      else begin
        a = base; n = 0;
        ch = $fgetc(fd);
        while (ch >= 0) begin
          backdoor_write_byte(a, ch[7:0]);
          a = a + 23'd1; n = n + 1;
          ch = $fgetc(fd);
        end
        $fclose(fd);
        $display("hyperram_x16_model: loaded %0d bytes from %0s at 0x%06h", n, fname, base);
      end
    end
  endtask

  reg [8*256-1:0] ld_name;
  reg [22:0]      ld_addr;
  initial begin
    error_count = 32'd0;
    cmd_count   = 32'd0;
    for (i = 0; i < (1 << 21); i = i + 1) mem[i] = 32'd0;
    ld_addr = 23'd0;
    if ($value$plusargs("psram_load0=%s", ld_name)) begin
      if (!$value$plusargs("psram_addr0=%h", ld_addr)) ld_addr = 23'd0;
      load_file(ld_name, ld_addr);
    end
    if ($value$plusargs("psram_load1=%s", ld_name)) begin
      if (!$value$plusargs("psram_addr1=%h", ld_addr)) ld_addr = 23'd0;
      load_file(ld_name, ld_addr);
    end
  end
endmodule

`default_nettype wire
