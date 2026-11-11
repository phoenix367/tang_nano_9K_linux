// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Behavioral model of one Winbond W955D8MBYA 32Mb x8 HyperRAM die, with protocol checkers.
//
// Local change (tang_nano_9k_linux, 2026-11-11): CR0/CR1 are selected with CA[24], as in the
// W957D8 datasheet's register map and zf3's controller, instead of CA[16]. On the board a CR0
// write with CA[16] left the dies at their default latency; one with CA[24] takes effect.
//
// Written from the W955D8MBYA datasheet (Rev. A01-001, Jun. 05 2019) independently of the
// controller RTL; section/table/figure numbers below refer to it. Every protocol or timing
// violation is reported with $error and counted in error_count; tests fail if it is non-zero.
//
// Modelled:
//   - Command-Address decode (sec. 7.1, Tables 3-5), reserved CA bits must be zero
//   - Memory space: 2M x 16-bit words (sec. 8.1.1), wrapped (CR0[1:0]) and linear bursts (sec. 9.4.1)
//   - Register space: ID0/ID1 (read only), CR0/CR1 (Table 5); register writes have zero
//     latency and no RWDS mask (sec. 7.4, 9.2)
//   - Initial latency from CR0[7:4] (Table 8), fixed (CR0[3]=1, default) or variable
//     latency with a random refresh collision (sec. 9.4.2, 9.4.3)
//   - Latency is counted from the third CA clock: the first data word is transferred on
//     clock (3 + latency count) (Figures 9 and 11)
//   - Read data and RWDS change tCKD after the CK edge and are X in between (Table 14);
//     DQ/RWDS go X then Z within tOZ/tDSZ after CS# rises
//   - Write mask on RWDS; the host must drive RWDS Low before the end of the initial
//     latency (Figure 11 note 3) and must not drive it during a register write (sec. 9.2)
//
// Checked (Table 14, sec. 11): tRP, tRH/tVCS, tCSS, tCSHI, tRWR, tCSM, tCK/tCH/tCL,
// CK Low when CS# changes (sec. 7.1), no X/Z on DQ where the die samples it, bus contention.
`timescale 1ns / 1ps

module w955d8mbya_die #(
    parameter integer DIE = 0  // Only used in messages
) (
    input  wire       ck,
    input  wire       ck_n,
    input  wire       cs_n,
    input  wire       reset_n,
    inout  wire [7:0] dq,
    inout  wire       rwds
);
    // ---------------------------------------------------------------- timing (ns)
    localparam real T_RP    = 200.0;     // RESET# pulse width (min)
    localparam real T_VCS   = 150000.0;  // RESET# High to first access (min), also covers tRH
    localparam real T_CSS   = 2.0;       // CS# setup to next CK rising edge (min)
    localparam real T_CSHI  = 6.0;       // CS# High between transactions (min)
    localparam real T_RWR   = 36.0;      // Read-write recovery (min)
    localparam real T_CSM   = 4000.0;    // CS# maximum Low time (max, TCASE < 85C)
    localparam real T_CK_MIN = 6.0;
    localparam real T_CK_MAX = 1000.0;
    localparam real T_CKD   = 5.5;       // CK transition to DQ/RWDS valid (max)
    localparam real T_OZ    = 6.0;       // CS# inactive to DQ/RWDS High-Z (max)
    localparam real T_DSV   = 8.0;       // CS# active to RWDS valid (max)

    // ---------------------------------------------------------------- registers (sec. 9.3-9.5)
    localparam [15:0] ID0_VALUE   = 16'h005F;  // [6:4] 101b = 32Mb, [3:0] 1111b = Winbond
    localparam [15:0] ID1_VALUE   = 16'h000F;  // [3:0] 1111b = HyperRAM
    localparam [15:0] CR0_DEFAULT = 16'h8F1F;  // normal, 50 ohm, 6 clocks, fixed, legacy wrap, 32 B
    localparam [15:0] CR1_DEFAULT = 16'h0000;  // full array refresh, normal operation

    reg [15:0] mem [0:(1 << 21) - 1];  // Uninitialized (X): reading unwritten memory is visible
    reg [15:0] cr0;
    reg [15:0] cr1;

    integer error_count;
    integer transaction_count;

    // ---------------------------------------------------------------- output drivers
    reg [7:0] dq_drv;
    reg       dq_oe;
    reg       rwds_drv;
    reg       rwds_oe;
    assign dq   = dq_oe ? dq_drv : 8'bz;
    assign rwds = rwds_oe ? rwds_drv : 1'bz;

    // ---------------------------------------------------------------- transaction state
    reg        active;          // CS# Low and a valid transaction in progress
    integer    edge_idx;        // CK edges seen since CS# fell (0 = first rising edge)
    reg [47:0] ca;
    reg        is_read;
    reg        is_reg;
    reg        linear;
    reg [20:0] waddr;           // current word address
    reg [20:0] wrap_base;
    integer    wrap_words;      // 0 = linear
    integer    data_edge0;      // edge index of the first data byte
    reg        reg_sel_cr1;
    reg        reg_sel_id1;
    reg        reg_sel_cr;      // 1: configuration register, 0: identification register
    reg [15:0] reg_wdata;
    reg [15:0] rd_word;

    realtime t_reset_fall;
    realtime t_ready;           // earliest time CS# may fall
    realtime t_cs_fall;
    realtime t_cs_rise;
    realtime t_last_rise;
    realtime t_last_fall;
    realtime t_prev_rise;
    reg      refresh_now;       // RWDS level during CA: 1 = 2x latency
    integer  drive_seq;         // invalidates scheduled output changes when a new one is made

    task automatic fail(input string msg);
        begin
            error_count = error_count + 1;
            $error("[PSRAM die %0d @%0t] %0s", DIE, $realtime, msg);
        end
    endtask

    function automatic [15:0] register_value(input sel_cr, input sel_hi);
        begin
            if (sel_cr) register_value = sel_hi ? cr1 : cr0;
            else register_value = sel_hi ? ID1_VALUE : ID0_VALUE;
        end
    endfunction

    function automatic integer initial_latency(input [3:0] field);
        begin
            case (field)
                4'b0000: initial_latency = 5;
                4'b0001: initial_latency = 6;
                4'b1110: initial_latency = 3;
                4'b1111: initial_latency = 4;
                default: initial_latency = -1;
            endcase
        end
    endfunction

    function automatic integer wrap_length_words(input [1:0] bl);
        begin
            case (bl)
                2'b00: wrap_length_words = 64;  // 128 bytes
                2'b01: wrap_length_words = 32;  // 64 bytes
                2'b10: wrap_length_words = 8;   // 16 bytes
                default: wrap_length_words = 16;  // 32 bytes
            endcase
        end
    endfunction

    task automatic reset_registers;
        begin
            cr0 = CR0_DEFAULT;
            cr1 = CR1_DEFAULT;
        end
    endtask

    // Drive DQ/RWDS as a memory output: X right after the launching edge (tCKDI min = 0),
    // the new value after tCKD.
    task automatic launch(input [7:0] d, input r);
        begin
            dq_oe    = 1'b1;
            rwds_oe  = 1'b1;
            dq_drv   = 8'bx;
            rwds_drv = 1'bx;
            dq_drv   <= #(T_CKD) d;
            rwds_drv <= #(T_CKD) r;
        end
    endtask

    task automatic release_outputs(input realtime delay);
        integer seq;
        begin
            drive_seq = drive_seq + 1;
            seq = drive_seq;
            if (dq_oe) dq_drv = 8'bx;
            if (rwds_oe) rwds_drv = 1'bx;
            #(delay);
            if (seq == drive_seq) begin
                dq_oe   = 1'b0;
                rwds_oe = 1'b0;
            end
        end
    endtask

    task automatic advance_address;
        begin
            if (wrap_words == 0) waddr = waddr + 21'd1;
            else waddr = wrap_base | ((waddr + 21'd1) & (wrap_words - 1));
        end
    endtask

    initial begin
        error_count       = 0;
        transaction_count = 0;
        dq_drv   = 8'h00;
        dq_oe    = 1'b0;
        rwds_drv = 1'b0;
        rwds_oe  = 1'b0;
        active   = 1'b0;
        edge_idx = 0;
        drive_seq = 0;
        t_reset_fall = 0.0;
        t_ready  = T_VCS;  // power-up: tVCS from VCC valid (sec. 11)
        t_cs_rise = -1.0e9;
        t_cs_fall = 0.0;
        t_last_rise = 0.0;
        t_last_fall = 0.0;
        t_prev_rise = 0.0;
        refresh_now = 1'b1;
        reset_registers();
    end

    // ---------------------------------------------------------------- reset (sec. 11.2)
    always @(negedge reset_n) begin
        t_reset_fall = $realtime;
        active = 1'b0;  // a hardware reset aborts any transaction in progress
        reset_registers();
        release_outputs(0.0);
    end

    always @(posedge reset_n) begin
        if ($realtime > 0.0 && $realtime - t_reset_fall < T_RP) fail("tRP violated (RESET# Low too short)");
        t_ready = $realtime + T_VCS;
    end

    // ---------------------------------------------------------------- CS# (sec. 7.1, Table 14)
    always @(negedge cs_n) begin
        t_cs_fall = $realtime;
        transaction_count = transaction_count + 1;
        if (reset_n !== 1'b1) fail("CS# Low while RESET# is not High");
        else if ($realtime < t_ready) fail("CS# Low before tVCS/tRH elapsed after power-up or reset");
        if (ck !== 1'b0) fail("transaction not started with CK Low");
        if ($realtime - t_cs_rise < T_CSHI) fail("tCSHI violated");
        if ($realtime - t_cs_rise < T_RWR) fail("tRWR violated");
        active   = (reset_n === 1'b1);
        edge_idx = 0;
        ca       = 48'h0;
        // RWDS High during CA = 2x latency: always with fixed latency (sec. 9.4.3), otherwise
        // only when a refresh collides with this transaction (randomized here, sec. 9.4.2)
        refresh_now = cr0[3] ? 1'b1 : (($urandom % 4) == 0);
        drive_seq = drive_seq + 1;
        rwds_oe  = 1'b1;
        rwds_drv = 1'bx;
        #(T_DSV);
        if (active && edge_idx < 6) rwds_drv = refresh_now;
    end

    always @(posedge cs_n) begin
        t_cs_rise = $realtime;
        // A hardware reset aborts the transaction; RESET# may fall in the same time step
        #0.001;
        if (reset_n !== 1'b1) active = 1'b0;
        if (active) begin
            if (ck !== 1'b0) fail("CS# raised while CK is High");
            if ($realtime - t_cs_fall > T_CSM) fail("tCSM violated (CS# Low longer than 4 us)");
            if (edge_idx < 6) fail("CS# raised during the Command-Address phase");
            else if (edge_idx < data_edge0) fail("CS# raised before any data was transferred");
            else if (!is_read && is_reg && edge_idx != data_edge0 + 2)
                fail("register write must transfer exactly one word");
        end
        active = 1'b0;
        release_outputs(T_OZ);
    end

    // ---------------------------------------------------------------- CK (Table 14)
    // One block for both edges, so that the checks, the protocol engine and the edge
    // time stamps are always evaluated in this order.
    always @(ck) begin
        if (ck === 1'b1) begin
            if (active) begin
                if (edge_idx == 0 && $realtime - t_cs_fall < T_CSS) fail("tCSS violated");
                if (edge_idx >= 2) begin
                    if ($realtime - t_last_rise < T_CK_MIN) fail("tCK below minimum");
                    if ($realtime - t_last_rise > T_CK_MAX) fail("tCK above maximum");
                    if ($realtime - t_last_fall < 0.45 * ($realtime - t_last_rise) ||
                        $realtime - t_last_fall > 0.55 * ($realtime - t_last_rise))
                        fail("tCL out of 0.45..0.55 tCK");
                end
                if (edge_idx % 2 != 0) fail("CK rising edge where a falling edge was expected");
                process_edge(1'b1);
            end
            t_prev_rise = t_last_rise;
            t_last_rise = $realtime;
        end else if (ck === 1'b0) begin
            if (active) begin
                if (edge_idx >= 3 && ($realtime - t_last_rise < 0.45 * (t_last_rise - t_prev_rise) ||
                                      $realtime - t_last_rise > 0.55 * (t_last_rise - t_prev_rise)))
                    fail("tCH out of 0.45..0.55 tCK");
                if (edge_idx % 2 != 1) fail("CK falling edge where a rising edge was expected");
                process_edge(1'b0);
            end
            t_last_fall = $realtime;
        end else if (active) begin
            fail("CK is X/Z while CS# is Low");
        end
    end

    // CK# is generated from the same register as CK; allow 1 ps for the inverter
    always @(ck or ck_n) begin
        #0.001;
        if (active && ck_n !== ~ck) fail("CK# is not the complement of CK");
    end

    // ---------------------------------------------------------------- protocol engine
    task automatic process_edge(input rising);
        integer lat;
        integer d;
        reg [15:0] cur;
        begin
            // Bus contention: while the model drives a settled value, the net must carry it
            if (dq_oe && dq_drv !== 8'bx && dq !== dq_drv) fail("DQ contention (host drives while the memory does)");
            if (rwds_oe && rwds_drv !== 1'bx && rwds !== rwds_drv) fail("RWDS contention");

            if (edge_idx < 6) begin
                // ---- Command-Address (sec. 7.1): CA[47:40] on the first rising edge
                if (^dq === 1'bx) fail("DQ is X/Z during the Command-Address phase");
                ca = {ca[39:0], dq};
                if (edge_idx == 5) begin
                    is_read = ca[47];
                    is_reg  = ca[46];
                    linear  = ca[45];
                    if (ca[44:34] != 11'h0 || ca[15:3] != 13'h0) fail("reserved Command-Address bits are not zero");
                    waddr = {ca[33:22], ca[21:16], ca[2:0]};
                    wrap_words = (linear || is_reg) ? 0 : wrap_length_words(cr0[1:0]);
                    wrap_base  = (wrap_words == 0) ? 21'd0 : (waddr & ~(wrap_words - 1));
                    // Register address: CA[24] selects CR (local change, see the header),
                    // CA[0] selects ID1/CR1
                    reg_sel_cr  = ca[24];
                    reg_sel_cr1 = ca[0];
                    reg_sel_id1 = ca[0];
                    if (is_reg && (ca[33:25] != 9'h0 || ca[23:16] != 8'h0 || ca[2:1] != 2'b00))
                        fail("register space access to an undefined register address");
                    lat = initial_latency(cr0[7:4]);
                    if (lat < 0) begin
                        fail("CR0 initial latency field is reserved");
                        lat = 6;
                    end
                    if (refresh_now) lat = 2 * lat;
                    if (!is_read && is_reg) data_edge0 = 6;                // zero latency (sec. 7.4)
                    else data_edge0 = 2 * (lat + 2);                       // Figures 9 and 11
                    // End of CA: the memory stops driving RWDS (Figure 11 note 3); for reads it
                    // keeps RWDS Low until data (Figure 9)
                    drive_seq = drive_seq + 1;
                    if (is_read) begin
                        rwds_oe  = 1'b1;
                        rwds_drv = 1'b0;
                    end else begin
                        rwds_oe = 1'b0;
                    end
                end
            end else if (edge_idx < data_edge0) begin
                // ---- Initial latency
                if (!is_read && edge_idx == data_edge0 - 1 && rwds !== 1'b0)
                    fail("host did not drive the RWDS preamble Low before the end of the initial latency");
            end else begin
                // ---- Data (A byte = [15:8] on the rising edge, B byte = [7:0] on the falling edge)
                d = edge_idx - data_edge0;
                if (rising !== ((d % 2) == 0)) fail("data phase edge polarity mismatch");
                if (is_read) begin
                    if ((d % 2) == 0) rd_word = is_reg ? register_value(reg_sel_cr, reg_sel_cr1) : mem[waddr];
                    launch((d % 2) == 0 ? rd_word[15:8] : rd_word[7:0], (d % 2) == 0);
                    if ((d % 2) == 1 && !is_reg) advance_address();
                end else if (is_reg) begin
                    if (rwds !== 1'bz) fail("host drives RWDS during a register write");
                    if (^dq === 1'bx) fail("DQ is X/Z during register write data");
                    if (d == 0) reg_wdata[15:8] = dq;
                    else if (d == 1) begin
                        reg_wdata[7:0] = dq;
                        if (!reg_sel_cr) fail("write to a read-only identification register");
                        else if (reg_sel_cr1) begin
                            if (reg_wdata[15:7] != 9'h0 || reg_wdata[4:3] != 2'b00)
                                fail("CR1 reserved bits written with non-default values");
                            cr1 = reg_wdata;
                        end else begin
                            if (reg_wdata[11:8] != 4'hF) fail("CR0 reserved bits [11:8] must be written as 1111b");
                            if (reg_wdata[2] != 1'b1) fail("CR0[2] burst type 0 is reserved");
                            cr0 = reg_wdata;
                        end
                    end else fail("register write longer than one word");
                end else begin
                    if (rwds !== 1'b0 && rwds !== 1'b1) fail("RWDS (write mask) is X/Z during write data");
                    else if (rwds === 1'b0) begin
                        if (^dq === 1'bx) fail("unmasked write data byte is X/Z");
                        cur = mem[waddr];
                        if ((d % 2) == 0) cur[15:8] = dq;
                        else cur[7:0] = dq;
                        mem[waddr] = cur;
                    end
                    if ((d % 2) == 1) advance_address();
                end
            end
            edge_idx = edge_idx + 1;
        end
    endtask

endmodule
