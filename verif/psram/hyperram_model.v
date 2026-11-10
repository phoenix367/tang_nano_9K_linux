// HyperRAM (Winbond W955D8MBYA-style, one 32 Mbit die, x8 DDR) pin-level model,
// written for calibrating psram_ui_model against the real Gowin
// "PSRAM Memory Interface HS 2ch" netlist (.vo) in Icarus.
//
// It replaces the ov7670 project's sim/common/psram_model.sv, which does not
// elaborate in Icarus 12 and does not model wrapped bursts, fixed latency,
// CR0 burst length, or RWDS ownership. Testbench-only (not synthesizable).
//
// Protocol modelled (HyperBus, 8-bit DQ):
//   * CS# low starts a transaction. CA[47:0] is sampled on 6 consecutive CK
//     edges (rising, falling, ...): CA[47]=R/W# (1 = read), CA[46]=register
//     space, CA[45]=burst type (0 = wrapped, 1 = linear), halfword address =
//     {CA[44:16], CA[2:0]} (21 bits used for 2M x 16).
//   * Register write: 2 data bytes follow CA with zero latency (CR value =
//     {first byte, second byte}). CR0 decodes latency, fixed-latency, hybrid
//     burst and burst length; CR1 is stored only.
//   * Memory access: data starts LAT_EDGES CK edges after the 6th CA edge
//     (parameter, see below). With fixed latency (CR0[3]=1) the latency is
//     always 2x; RWDS is driven high by the device during CA to say so.
//   * Data: 2 bytes per halfword, first edge (CK rising) = halfword[15:8],
//     second edge (CK falling) = halfword[7:0] (HyperBus byte order).
//     Writes: RWDS=1 on an edge masks that byte. Reads: device drives DQ and
//     toggles RWDS, both TCKD after the CK edge.
//   * Burst order: wrapped bursts wrap inside an aligned group of
//     BL halfwords (BL = CR0 burst length / 2). CR0[2]=1 (legacy) keeps
//     wrapping; CR0[2]=0 (hybrid) wraps once then continues linearly into the
//     following groups. Linear bursts just increment.
//
// LAT_EDGES: CK edges from the last CA edge to the first data edge, counted
// so that LAT_EDGES = 1 means data on the edge right after CA. The default
// (set by the testbench) is derived from where the Gowin IP starts driving
// write data; see verif/psram/NOTES.md.
`timescale 1ns/1ps
module hyperram_model #(
    parameter NAME       = "ch?",
    parameter LAT_EDGES  = 23,         // 2x latency 6: data on CK clock 14 (edge 28) after CS# low
    parameter real TCKD  = 2.0,        // ns, CK edge -> read DQ/RWDS valid
    parameter VERBOSE    = 0,          // 1: log transactions, 2: + every edge
    parameter TRACE_N    = 0           // print an edge trace of the first N transactions
) (
    input        resetb,
    input        ck,
    input        ck_n,
    input        csb,
    inout  [7:0] dq,
    inout        rwds
);
    localparam MEM_HW = 1 << 21;            // 2M halfwords = 4 MB

    reg [15:0] mem [0:MEM_HW-1];

    // configuration registers (reset defaults per HyperRAM: CR0 = 8F1F)
    reg [15:0] cr0, cr1;

    // transaction state
    reg        active;
    integer    edge_n;          // CK edges since CS# low (0 = first CA edge)
    reg [47:0] ca;
    reg        is_read, is_reg, is_linear;
    reg [20:0] hw_addr;         // current halfword address
    reg [20:0] hw_start;
    integer    data_edge;       // index of data edges (0 = first data byte)
    reg [15:0] wr_hw;           // halfword being assembled
    reg [1:0]  wr_mask;         // [1] = byte A masked, [0] = byte B masked
    reg        wrapped_once;
    integer    n_trans;
    integer    errors;
    reg        log_en;          // runtime switch for VERBOSE>=1 transaction logging

    // drivers
    reg  [7:0] dq_o;
    reg        dq_oe;
    reg        rwds_o;
    reg        rwds_oe;
    assign dq   = dq_oe   ? dq_o   : 8'bz;
    assign rwds = rwds_oe ? rwds_o : 1'bz;

    integer i;
    initial begin
        cr0 = 16'h8F1F; cr1 = 16'h0002;
        active = 0; dq_oe = 0; rwds_oe = 0; dq_o = 0; rwds_o = 0;
        n_trans = 0; errors = 0; edge_n = 0; log_en = 1'b1;
        for (i = 0; i < MEM_HW; i = i + 1) mem[i] = 16'h0000;
    end

    function integer burst_hw;  // wrap group size in halfwords
        input [15:0] c;
        case (c[1:0])
            2'b00: burst_hw = 64;
            2'b01: burst_hw = 32;
            2'b10: burst_hw = 8;
            default: burst_hw = 16;
        endcase
    endfunction

    function integer cr0_latency;
        input [15:0] c;
        case (c[7:4])
            4'b0000: cr0_latency = 5;
            4'b0001: cr0_latency = 6;
            4'b1110: cr0_latency = 3;
            4'b1111: cr0_latency = 4;
            4'b0010: cr0_latency = 7;
            default: cr0_latency = -1;
        endcase
    endfunction

    // advance the halfword address after one halfword of data
    task next_addr;
        integer bl;
        reg [20:0] base;
        begin
            bl = burst_hw(cr0);
            if (is_linear || wrapped_once) begin
                hw_addr = hw_addr + 1;
            end else begin
                base = hw_addr & ~(bl - 1);
                if (((hw_addr + 1) & (bl - 1)) == 0) hw_addr = base;   // wrap inside the group
                else hw_addr = hw_addr + 1;
                // hybrid (CR0[2]=0): after one full wrap continue linearly
                // from the start of the next group
                if (cr0[2] == 1'b0 && hw_addr == hw_start) begin
                    hw_addr = base + bl;
                    wrapped_once = 1;
                end
            end
        end
    endtask

    // CS# edges
    always @(negedge csb) begin
        if (resetb === 1'b1) begin
            active = 1; edge_n = 0; ca = 0; data_edge = 0; wrapped_once = 0;
            n_trans = n_trans + 1;
            // device drives RWDS during CA: high = 2x latency (always in fixed mode)
            rwds_oe <= #(TCKD) 1'b1;
            rwds_o  <= #(TCKD) 1'b1;
            if (VERBOSE >= 2) $display("%t %s CS# low", $time, NAME);
        end
    end
    always @(posedge csb) begin
        if (active) begin
            if (VERBOSE >= 1 && log_en)
                $display("%t %s CS# high after %0d CK edges (%0d data edges)", $time, NAME, edge_n, data_edge);
        end
        active = 0;
        dq_oe   <= #(TCKD) 1'b0;
        rwds_oe <= #(TCKD) 1'b0;
    end

    // one CK edge of the transaction (rising: is_rise=1)
    task do_edge;
        input is_rise;
        integer bl, lat, de;
        reg [7:0] b;
        reg       m;
        begin
            if (TRACE_N > 0 && n_trans <= TRACE_N)
                $display("%t %s T%0d edge %0d %s dq=%h rwds=%b", $time, NAME, n_trans, edge_n,
                         is_rise ? "R" : "F", dq, rwds);
            if (edge_n == 0 && !is_rise) begin
                $display("%t %s ERROR: first CA edge is a falling CK edge", $time, NAME);
                errors = errors + 1;
            end
            if (edge_n < 6) begin
                ca[47 - 8*edge_n -: 8] = dq;
                if (edge_n == 5) begin
                    is_read   = ca[47];
                    is_reg    = ca[46];
                    is_linear = ca[45];
                    hw_addr   = {ca[33:16], ca[2:0]};
                    hw_start  = hw_addr;
                    if (VERBOSE >= 1 && log_en)
                        $display("%t %s CA=%h %s %s %s hw_addr=%h", $time, NAME, ca,
                                 is_read ? "READ" : "WRITE", is_reg ? "REG" : "MEM",
                                 is_linear ? "LINEAR" : "WRAPPED", hw_addr);
                    if (is_reg && is_read) begin
                        $display("%t %s ERROR: register read not modelled", $time, NAME);
                        errors = errors + 1;
                    end
                    // writes: the device drives RWDS only during CA (latency
                    // indication); the host owns it for the write mask
                    if (!is_read) rwds_oe <= #(TCKD) 1'b0;
                end
            end else if (is_reg) begin
                // register write, zero latency: edges 6,7 carry the value
                if (edge_n == 6) wr_hw[15:8] = dq;
                if (edge_n == 7) begin
                    wr_hw[7:0] = dq;
                    if (ca[0] == 1'b0) begin
                        cr0 = wr_hw;
                        $display("%t %s CR0 <= %h: latency %0d, %s latency, %s burst, burst length %0d bytes, drive %b",
                                 $time, NAME, wr_hw, cr0_latency(wr_hw), wr_hw[3] ? "fixed" : "variable",
                                 wr_hw[2] ? "legacy-wrap" : "hybrid", 2*burst_hw(wr_hw), wr_hw[14:12]);
                    end else begin
                        cr1 = wr_hw;
                        $display("%t %s CR1 <= %h", $time, NAME, wr_hw);
                    end
                end
            end else begin
                de = edge_n - 5 - LAT_EDGES;   // data edge index
                if (de >= 0) begin
                    if (!is_read) begin
                        b = dq; m = rwds;
                        if (de[0] == 1'b0) begin wr_hw[15:8] = b; wr_mask[1] = m; end
                        else begin
                            wr_hw[7:0] = b; wr_mask[0] = m;
                            if (wr_mask[1] !== 1'b0 && wr_mask[1] !== 1'b1 || wr_mask[0] !== 1'b0 && wr_mask[0] !== 1'b1)
                                $display("%t %s WARNING: RWDS mask is %b%b at hw %h", $time, NAME, wr_mask[1], wr_mask[0], hw_addr);
                            if (wr_mask[1] === 1'b0) mem[hw_addr][15:8] = wr_hw[15:8];
                            if (wr_mask[0] === 1'b0) mem[hw_addr][7:0]  = wr_hw[7:0];
                            if (VERBOSE >= 2)
                                $display("%t %s  W hw[%h] <= %h mask %b", $time, NAME, hw_addr, wr_hw, wr_mask);
                            next_addr;
                        end
                    end
                end
            end
            // read data output: drive the byte for the NEXT edge so it is valid
            // TCKD after the edge that launches it. Data edge 0 is launched by
            // edge (5 + LAT_EDGES), i.e. valid TCKD after that edge.
            if (!is_reg && is_read && edge_n >= 5) begin
                de = edge_n - 5 - LAT_EDGES;   // data index launched at this edge
                if (de >= 0) begin
                    if (de[0] == 1'b0) b = mem[hw_addr][15:8];
                    else b = mem[hw_addr][7:0];
                    dq_o   <= #(TCKD) b;
                    dq_oe  <= #(TCKD) 1'b1;
                    rwds_o <= #(TCKD) is_rise;      // RWDS edge-aligned, high with rising-edge byte
                    if (VERBOSE >= 2)
                        $display("%t %s  R hw[%h] byte%0d = %h", $time, NAME, hw_addr, de[0], b);
                    if (de[0] == 1'b1) next_addr;
                end else begin
                    rwds_o <= #(TCKD) (edge_n < 6) ? 1'b1 : 1'b0;  // low during latency
                end
            end
            edge_n = edge_n + 1;
        end
    endtask

    always @(posedge ck) if (active && csb === 1'b0) do_edge(1'b1);
    always @(negedge ck) if (active && csb === 1'b0 && edge_n > 0) do_edge(1'b0);

    always @(negedge resetb) begin
        active = 0; dq_oe = 0; rwds_oe = 0;
        cr0 = 16'h8F1F; cr1 = 16'h0002;
    end
endmodule
