// psram_ui_model: cycle-level behavioural model of the USER-SIDE interface of
// Gowin "PSRAM Memory Interface HS 2ch" (Video_frame_buffer in the ov7670
// project: BURST_MODE=32, INITIAL_LATENCY=6 fixed, DQ_WIDTH=8, ADDR_WIDTH=21,
// MEMORY_CLK=135 MHz, clk_out = 67.5 MHz).
//
// Calibrated against the real IP netlist (.vo) driving HyperRAM pin models in
// Icarus (verif/psram/tb_psram_ip.v): with the same stimulus, rd_data_valid
// and rd_data match the IP on every clk_out edge. See verif/psram/NOTES.md
// for the measurements and their limits.
//
// Clock: `clk` is the IP's clk_out; all user signals are synchronous to it.
// The IP's own `clk` (free-running reference, 27 MHz in the ov7670 design),
// memory_clk and pll_lock are not modelled, only rst_n.
//
// ---------------------------------------------------------------------------
// User-interface protocol (per channel; the two channels are independent):
//   * E0 = the clk rising edge at which cmd_en is sampled high.
//   * Write (cmd=1): wr_data/data_mask beat j (j = 0..7) is sampled at edge
//     E0 + WR_BEAT0 + j (measured WR_BEAT0 = 0: beat 0 goes with cmd_en).
//     data_mask bit L = 1 means byte lane L (wr_data[8L+7:8L]) is NOT
//     written.
//   * Read (cmd=0): rd_data_valid is seen high at edges E0+RD_LATENCY ..
//     E0+RD_LATENCY+7 (8 consecutive beats, measured RD_LATENCY = 16),
//     rd_data = beat 0..7. rd_data outside valid is not modelled (it holds the
//     last beat; the IP shows other values).
//   * Commands on one channel must be >= TCMD (19) edges apart, whatever the
//     mix of reads and writes. The IP has no interlock: a closer command
//     corrupts or drops transfers (see NOTES.md). A command 19 edges after a
//     read is legal although that read's beats are still being returned.
//   * Before init_calib the IP ignores cmd_en (the model reports an error).
//
// Address/data mapping (addr is in 16-bit units, 2M halfwords = 4 MB/channel):
//   A burst moves 16 halfwords = 32 bytes. The IP sends addr unchanged as the
//   HyperRAM halfword address of a WRAPPED burst (CR0 burst length 32 B), so
//   a burst stays inside the aligned 16-halfword group G = addr & ~15 and
//   wraps when addr % 16 != 0. Beat k carries halfwords
//   h0 = G + ((addr + 2k) & 15) in data[31:16] and h1 = G + ((addr + 2k + 1) & 15)
//   in data[15:0]. On DQ, data[31:24] goes first. Aligned bursts at A and
//   A+16 never overlap.
//
// Memory arrays (backdoor): memN[i], i = 0 .. 2^20-1, holds the 32-bit user
// word that an ALIGNED burst returns, i.e.
//     memN[{addr[20:4], k}] = beat k of a burst at addr (addr % 16 == 0)
//     memN[i][31:16] = HyperRAM halfword 2i, memN[i][15:0] = halfword 2i+1.
//   Byte lane L of memN[i] (bits 8L+7:8L) is channel byte offset 4i + L in
//   the "user byte" view used by the loader below. With INIT_ZERO=1 the
//   arrays are zeroed in an initial block: a C++ harness writing them
//   directly must do so after the first eval() (or set INIT_ZERO=0).
//
// Backdoor loader (plusargs, both Icarus and Verilator):
//   +psram_load0=<file> +psram_addr0=<hex>   (and ...load1/...addr1)
//   The 8 MB byte space is {channel, offset[21:0]}: byte address bit 22
//   selects the channel, bits 21:0 the byte offset b inside it. File byte n
//   goes to byte address addr+n, i.e. memCH[b >> 2][8*(b & 3) +: 8].
//   A burst read at addr = {b[21:5], 4'b0} then returns that byte in beat
//   k = b[4:2], lane L = b[1:0] (rd_data[8L+7:8L]).
//   backdoor_read_byte(baddr) / backdoor_write_byte(baddr, v) use the same
//   mapping.
//
// Protocol checks: each violation prints "psram_ui_model ERROR ..." and
// increments error_count (public):
//   - cmd_en high before init_calib of that channel
//   - cmd_en less than TCMD edges after the previous cmd_en (same channel)
//   - optional (CHECK_RD_BUSY=1): cmd_en while a read burst of that channel
//     is still being returned. This is legal on the IP at >= TCMD spacing,
//     so it is off by default.
//   - X/Z (4-state simulators only) on cmd_en after reset, on cmd/addr with
//     cmd_en high, on data_mask or on unmasked wr_data bytes during write
//     beats.
// The model does not reproduce what the IP does after a violation: it still
// executes the command as if it were legal.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
// X/Z detection only exists in 4-state simulators; Verilator is 2-state.
`ifdef VERILATOR
 `define PUM_X(e) 1'b0
`else
 `define PUM_X(e) ((^(e)) === 1'bx)
`endif
/* verilator lint_off BLKSEQ */
module psram_ui_model #(
    parameter integer RD_LATENCY    = 16,      // measured on the real IP netlist (NOTES.md)
    parameter integer TCMD          = 19,
    parameter integer BURST_WORDS   = 8,       // only 8 (BURST_MODE=32) is modelled
    parameter integer CALIB_CYCLES  = 1055888, // clk edges rst_n release -> init_calib (measured; ~15.6 ms)
    parameter integer WR_BEAT0      = 0,       // edge offset of write beat 0 vs cmd_en
    parameter integer CHECK_RD_BUSY = 0,       // 1: also flag cmd_en during read data return (legal on the IP)
    parameter integer INIT_ZERO     = 1,       // 1: zero both arrays in an initial block
    parameter integer VERBOSE       = 1        // 0: silent, 1: errors, 2: + every command
) (
    input             clk,
    input             rst_n,
    input             cmd0,
    input             cmd_en0,
    input      [20:0] addr0,
    input      [31:0] wr_data0,
    input      [3:0]  data_mask0,
    output reg [31:0] rd_data0,
    output reg        rd_data_valid0,
    output reg        init_calib0,
    input             cmd1,
    input             cmd_en1,
    input      [20:0] addr1,
    input      [31:0] wr_data1,
    input      [3:0]  data_mask1,
    output reg [31:0] rd_data1,
    output reg        rd_data_valid1,
    output reg        init_calib1
);
    localparam integer NWORDS = 1 << 20;
    localparam integer RDQ    = 4;          // max outstanding read bursts per channel

    reg [31:0] mem0 [0:NWORDS-1] /* verilator public */;
    reg [31:0] mem1 [0:NWORDS-1] /* verilator public */;

    reg [31:0] error_count /* verilator public */;
    reg [31:0] cmd_count   /* verilator public */;   // accepted commands, both channels

    // ------------------------------------------------------------ helpers --
    // halfword h of channel ch (HyperRAM view)
    function [15:0] get_hw;
        input        ch;
        input [20:0] h;
        reg   [31:0] w;
        begin
            w = ch ? mem1[h[20:1]] : mem0[h[20:1]];
            get_hw = h[0] ? w[15:0] : w[31:16];
        end
    endfunction

    // write halfword h of channel ch with byte enables be (be[1] = upper byte)
    task put_hw;
        input        ch;
        input [20:0] h;
        input [15:0] d;
        input [1:0]  be;
        reg   [31:0] w;
        begin
            w = ch ? mem1[h[20:1]] : mem0[h[20:1]];
            if (h[0]) begin
                if (be[1]) w[15:8]  = d[15:8];
                if (be[0]) w[7:0]   = d[7:0];
            end else begin
                if (be[1]) w[31:24] = d[15:8];
                if (be[0]) w[23:16] = d[7:0];
            end
            if (ch) mem1[h[20:1]] = w; else mem0[h[20:1]] = w;
        end
    endtask

    // halfword address of half `hi` (0 = data[31:16], 1 = data[15:0]) of beat k
    function [20:0] beat_hw;
        input [20:0] a;
        input [2:0]  k;
        input        hi;
        reg   [3:0]  off;
        begin
            off = a[3:0] + {k, 1'b0} + {3'b000, hi};
            beat_hw = {a[20:4], off};
        end
    endfunction

    // ----------------------------------------------------------- backdoor --
    function [7:0] backdoor_read_byte;
        input [22:0] baddr;
        reg   [31:0] w;
        begin
            w = baddr[22] ? mem1[baddr[21:2]] : mem0[baddr[21:2]];
            backdoor_read_byte = w[8*baddr[1:0] +: 8];
        end
    endfunction

    task backdoor_write_byte;
        input [22:0] baddr;
        input [7:0]  v;
        begin
            if (baddr[22]) mem1[baddr[21:2]][8*baddr[1:0] +: 8] = v;
            else           mem0[baddr[21:2]][8*baddr[1:0] +: 8] = v;
        end
    endtask

    // load a binary file at byte address baddr; n = bytes loaded (-1: no file)
    task load_file;
        input  [8*256-1:0] fname;
        input  [22:0]      baddr;
        output integer     n;
        integer fd, c;
        reg [22:0] a;
        begin
            n = 0;
            fd = $fopen(fname, "rb");
            if (fd == 0) begin
                $display("psram_ui_model ERROR: cannot open %0s", fname);
                n = -1;
            end else begin
                a = baddr;
                c = $fgetc(fd);
                while (c >= 0) begin
                    backdoor_write_byte(a, c[7:0]);
                    a = a + 23'd1;
                    n = n + 1;
                    c = $fgetc(fd);
                end
                $fclose(fd);
            end
        end
    endtask

    integer i_init;
    reg [8*256-1:0] ld_name;
    reg [22:0]      ld_addr;
    integer         ld_n;
    initial begin
        error_count = 0;
        cmd_count   = 0;
        if (INIT_ZERO != 0)
            for (i_init = 0; i_init < NWORDS; i_init = i_init + 1) begin
                mem0[i_init] = 32'h0;
                mem1[i_init] = 32'h0;
            end
        if ($value$plusargs("psram_load0=%s", ld_name)) begin
            ld_addr = 0;
            if (!$value$plusargs("psram_addr0=%h", ld_addr)) ld_addr = 0;
            load_file(ld_name, ld_addr, ld_n);
            $display("psram_ui_model: loaded %0d bytes from %0s at byte address 0x%06h", ld_n, ld_name, ld_addr);
        end
        if ($value$plusargs("psram_load1=%s", ld_name)) begin
            ld_addr = 0;
            if (!$value$plusargs("psram_addr1=%h", ld_addr)) ld_addr = 0;
            load_file(ld_name, ld_addr, ld_n);
            $display("psram_ui_model: loaded %0d bytes from %0s at byte address 0x%06h", ld_n, ld_name, ld_addr);
        end
    end

    // ---------------------------------------------------- channel engines --
    // per-channel state (index = channel)
    integer    calib_cnt   [0:1];
    integer    since_cmd   [0:1];          // edges since last cmd_en (saturating)
    reg        wr_act      [0:1];
    integer    wr_cnt      [0:1];
    reg [20:0] wr_addr     [0:1];
    // outstanding reads
    reg        rq_act      [0:1][0:RDQ-1];
    integer    rq_cnt      [0:1][0:RDQ-1];
    reg [31:0] rq_buf      [0:1][0:RDQ-1][0:7];

    reg        p_cmd, p_en;
    reg [20:0] p_addr;
    reg [31:0] p_wd;
    reg [3:0]  p_m;
    reg        p_cal;
    integer    ch, q, k, b, hit;
    reg        cb;
    reg        busy;
    reg [31:0] o_data   [0:1];
    reg        o_valid  [0:1];

    task report;
        input        c;
        input [8*96-1:0] msg;
        begin
            error_count = error_count + 1;
            if (VERBOSE >= 1)
                $display("%t psram_ui_model ERROR ch%0d: %0s", $time, c, msg);
        end
    endtask

    // store write beat k of a burst at address a (mask bit = 1: byte kept)
    task write_beat;
        input        c;
        input [20:0] a;
        input [2:0]  kk;
        input [31:0] d;
        input [3:0]  m;
        begin
            if (`PUM_X(m))
                report(c, "X/Z on data_mask during a write beat");
            if ((m[3] !== 1'b1 && `PUM_X(d[31:24])) || (m[2] !== 1'b1 && `PUM_X(d[23:16])) ||
                (m[1] !== 1'b1 && `PUM_X(d[15:8]))  || (m[0] !== 1'b1 && `PUM_X(d[7:0])))
                report(c, "X/Z on an unmasked wr_data byte during a write beat");
            put_hw(c, beat_hw(a, kk, 1'b0), d[31:16], {m[3] !== 1'b1, m[2] !== 1'b1});
            put_hw(c, beat_hw(a, kk, 1'b1), d[15:0],  {m[1] !== 1'b1, m[0] !== 1'b1});
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ch = 0; ch < 2; ch = ch + 1) begin
                calib_cnt[ch] = 0;
                since_cmd[ch] = TCMD;
                wr_act[ch]    = 1'b0;
                wr_cnt[ch]    = 0;
                wr_addr[ch]   = 21'd0;
                for (q = 0; q < RDQ; q = q + 1) begin
                    rq_act[ch][q] = 1'b0;
                    rq_cnt[ch][q] = 0;
                end
            end
            init_calib0    <= 1'b0;  init_calib1    <= 1'b0;
            rd_data_valid0 <= 1'b0;  rd_data_valid1 <= 1'b0;
            rd_data0       <= 32'd0; rd_data1       <= 32'd0;
        end else begin
            for (ch = 0; ch < 2; ch = ch + 1) begin
                cb     = ch[0];
                p_cmd  = cb ? cmd1       : cmd0;
                p_en   = cb ? cmd_en1    : cmd_en0;
                p_addr = cb ? addr1      : addr0;
                p_wd   = cb ? wr_data1   : wr_data0;
                p_m    = cb ? data_mask1 : data_mask0;
                p_cal  = (calib_cnt[cb] >= CALIB_CYCLES);
                if (calib_cnt[cb] < CALIB_CYCLES) calib_cnt[cb] = calib_cnt[cb] + 1;
                if (since_cmd[cb] < TCMD) since_cmd[cb] = since_cmd[cb] + 1;

                // -------- age outstanding reads, drive read data --------
                o_valid[cb] = 1'b0;
                o_data[cb]  = cb ? rd_data1 : rd_data0;     // hold last value
                busy = 1'b0;
                for (q = 0; q < RDQ; q = q + 1) begin
                    if (rq_act[cb][q]) begin
                        rq_cnt[cb][q] = rq_cnt[cb][q] + 1;
                        b = rq_cnt[cb][q] - (RD_LATENCY - 1);
                        if (b >= 0 && b < BURST_WORDS) begin
                            o_valid[cb] = 1'b1;
                            o_data[cb]  = rq_buf[cb][q][b];
                        end
                        if (b >= BURST_WORDS - 1) rq_act[cb][q] = 1'b0;
                        // still busy if beats remain to be seen by the user
                        if (b < BURST_WORDS - 1) busy = 1'b1;
                    end
                end

                // -------- write beat capture (beats after the command edge) --------
                if (wr_act[cb]) begin
                    wr_cnt[cb] = wr_cnt[cb] + 1;
                    k = wr_cnt[cb] - WR_BEAT0;
                    if (k >= 0 && k < BURST_WORDS) begin
                        write_beat(cb, wr_addr[cb], k[2:0], p_wd, p_m);
                    end
                    if (k >= BURST_WORDS - 1) wr_act[cb] = 1'b0;
                end

                // -------- command --------
                if (`PUM_X(p_en)) begin
                    report(cb, "X/Z on cmd_en");
                end else if (p_en) begin
                    if (!p_cal)
                        report(cb, "cmd_en before init_calib");
                    if (since_cmd[cb] < TCMD)
                        report(cb, "cmd_en closer than TCMD to the previous command");
                    if (CHECK_RD_BUSY != 0 && busy)
                        report(cb, "cmd_en while a read burst is still being returned");
                    if (wr_act[cb])
                        report(cb, "cmd_en while write beats are still being sampled");
                    if (`PUM_X(p_cmd))
                        report(cb, "X/Z on cmd with cmd_en high");
                    if (`PUM_X(p_addr))
                        report(cb, "X/Z on addr with cmd_en high");
                    since_cmd[cb] = 0;
                    cmd_count = cmd_count + 1;
                    if (VERBOSE >= 2)
                        $display("%t psram_ui_model ch%0d %s addr=%06h", $time, cb, p_cmd ? "WRITE" : "READ ", p_addr);
                    if (p_cmd === 1'b1) begin
                        wr_act[cb]  = 1'b1;
                        wr_cnt[cb]  = 0;
                        wr_addr[cb] = p_addr;
                        if (WR_BEAT0 == 0) begin      // beat 0 is sampled with the command
                            write_beat(cb, p_addr, 3'd0, p_wd, p_m);
                        end
                    end else if (p_cmd === 1'b0) begin
                        // snapshot the burst now: data written by later
                        // commands must not leak into this read
                        hit = -1;
                        for (q = RDQ - 1; q >= 0; q = q - 1)
                            if (!rq_act[cb][q]) hit = q;
                        if (hit < 0) begin
                            report(cb, "too many outstanding reads (model limit)");
                        end else begin
                            rq_act[cb][hit] = 1'b1;
                            rq_cnt[cb][hit] = 0;
                            for (k = 0; k < BURST_WORDS; k = k + 1)
                                rq_buf[cb][hit][k] = {get_hw(cb, beat_hw(p_addr, k[2:0], 1'b0)),
                                                      get_hw(cb, beat_hw(p_addr, k[2:0], 1'b1))};
                        end
                    end
                end

                if (cb == 0) begin
                    init_calib0    <= p_cal || (calib_cnt[0] >= CALIB_CYCLES);
                    rd_data_valid0 <= o_valid[0];
                    rd_data0       <= o_data[0];
                end else begin
                    init_calib1    <= p_cal || (calib_cnt[1] >= CALIB_CYCLES);
                    rd_data_valid1 <= o_valid[1];
                    rd_data1       <= o_data[1];
                end
            end
        end
    end
endmodule
/* verilator lint_on BLKSEQ */
`undef PUM_X
