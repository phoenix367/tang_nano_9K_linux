// tb_model_unit: self-checking unit test of rtl/sim/psram_ui_model.v alone.
// Runs in Icarus (iverilog -g2012) and Verilator 5.020 (--binary --timing).
//   * backdoor loader (+psram_load0/1, +psram_addr0/1) and the byte mapping:
//     a burst read at {b[21:5],4'b0} returns file byte b in beat b[4:2],
//     lane b[1:0]; backdoor_read_byte agrees
//   * write -> read round trip with data_mask (1 = byte not written)
//   * unaligned (wrapping) reads/writes against an independent halfword model
//   * protocol checks: command before init_calib, spacing < TCMD, X on addr
// Expects the run script to create the two load files (see run.sh).
`timescale 1ns/1ps
module tb_model_unit;
    localparam LAT = 15, CAL = 20, TCMD = 19;
    reg clk = 0;
    always #7.4 clk = ~clk;
    reg rst_n = 0;

    reg         cmd0 = 0, en0 = 0, cmd1 = 0, en1 = 0;
    reg  [20:0] a0 = 0, a1 = 0;
    reg  [31:0] wd0 = 0, wd1 = 0;
    reg  [3:0]  m0 = 0, m1 = 0;
    wire [31:0] rd0, rd1;
    wire        v0, v1, cal0, cal1;

    psram_ui_model #(.RD_LATENCY(LAT), .TCMD(TCMD), .CALIB_CYCLES(CAL), .VERBOSE(1)) mdl (
        .clk(clk), .rst_n(rst_n),
        .cmd0(cmd0), .cmd_en0(en0), .addr0(a0), .wr_data0(wd0), .data_mask0(m0),
        .rd_data0(rd0), .rd_data_valid0(v0), .init_calib0(cal0),
        .cmd1(cmd1), .cmd_en1(en1), .addr1(a1), .wr_data1(wd1), .data_mask1(m1),
        .rd_data1(rd1), .rd_data_valid1(v1), .init_calib1(cal1));

    integer fails = 0;

    // ---------------------------------------------------------- the file --
    reg [7:0] img0 [0:4095];
    reg [7:0] img1 [0:4095];
    integer   n0 = 0, n1 = 0;
    reg [22:0] la0, la1;
    task read_img;
        input [8*256-1:0] fname;
        input             which;
        integer fd, c, n;
        begin
            n = 0;
            fd = $fopen(fname, "rb");
            if (fd != 0) begin
                c = $fgetc(fd);
                while (c >= 0 && n < 4096) begin
                    if (which) img1[n] = c[7:0]; else img0[n] = c[7:0];
                    n = n + 1;
                    c = $fgetc(fd);
                end
                $fclose(fd);
            end
            if (which) n1 = n; else n0 = n;
        end
    endtask

    // -------------------------------------------------- bus-level helpers --
    reg [31:0] got [0:7];
    integer    got_n, got_first, issue_edge;
    // issue one command on channel ch; for writes data[k]/mask[k] are beats
    reg [31:0] wbuf [0:7];
    reg [3:0]  mbuf [0:7];
    // Timing convention (race-free in Icarus and Verilator): E0 = edge at
    // which cmd_en is sampled. Inputs change 1 ns after an edge; outputs are
    // looked at 1 ns after edge E0+m, which is what a synchronous user samples
    // at edge E0+m+1. got_first/issue_edge are in those user-edge units.
    task do_cmd;
        input        ch;
        input        wr;
        input [20:0] addr;
        integer m;
        begin
            @(posedge clk); #1;
            if (ch) begin en1 = 1; cmd1 = wr; a1 = addr; wd1 = wbuf[0]; m1 = mbuf[0]; end
            else    begin en0 = 1; cmd0 = wr; a0 = addr; wd0 = wbuf[0]; m0 = mbuf[0]; end
            @(posedge clk); #1;                          // edge E0 has passed
            issue_edge = 0;
            if (ch) en1 = 0; else en0 = 0;
            got_n = 0; got_first = -1;
            for (m = 0; m < LAT + 24; m = m + 1) begin
                if (m < 7) begin                         // beat m+1, sampled at E0+m+1
                    if (ch) begin wd1 = wbuf[m + 1]; m1 = mbuf[m + 1]; end
                    else    begin wd0 = wbuf[m + 1]; m0 = mbuf[m + 1]; end
                end else if (m == 7) begin
                    if (ch) begin wd1 = 32'hx; m1 = 4'hx; end else begin wd0 = 32'hx; m0 = 4'hx; end
                end
                if (!wr && (ch ? v1 : v0) === 1'b1 && got_n < 8) begin
                    if (got_n == 0) got_first = m + 1;
                    got[got_n] = ch ? rd1 : rd0;
                    got_n = got_n + 1;
                end
                @(posedge clk); #1;
            end
        end
    endtask

    // reference halfword memory for the touched region (HyperRAM view)
    reg [15:0] ref_hw [0:255];               // channel 0, halfwords 0x8000..0x80ff
    function [15:0] wrap_hw;                  // halfword index inside ref for beat k half hi
        input [20:0] addr;
        input integer k;
        input integer hi;
        reg [3:0] off;
        begin
            off = addr[3:0] + 2 * k + hi;
            wrap_hw = {addr[7:4], off};
        end
    endfunction

    integer i, k, b, L, errs_before, t;
    reg [22:0] ba;
    reg [7:0]  exp_b, got_b;
    reg [20:0] ad;
    reg [31:0] expw;
    initial begin
        if (!$value$plusargs("psram_addr0=%h", la0)) la0 = 0;
        if (!$value$plusargs("psram_addr1=%h", la1)) la1 = 0;
        read_img("unit_img0.bin", 0);
        read_img("unit_img1.bin", 1);
        $display("tb_model_unit: image0 %0d bytes at 0x%06h, image1 %0d bytes at 0x%06h", n0, la0, n1, la1);
        for (i = 0; i < 8; i = i + 1) begin wbuf[i] = 0; mbuf[i] = 0; end

        // ---------------------------------------- 1. command before calib
        #20 rst_n = 1;
        errs_before = mdl.error_count;
        do_cmd(0, 0, 21'h000000);
        if (mdl.error_count != errs_before + 1) begin
            $display("FAIL: command before init_calib not flagged"); fails = fails + 1;
        end
        wait (cal0 === 1'b1 && cal1 === 1'b1);
        repeat (40) @(posedge clk);

        // ------------------------------------- 2. loader + byte mapping
        if (n0 == 0 || n1 == 0) begin
            $display("FAIL: load images missing (run via run.sh)"); fails = fails + 1;
        end
        for (t = 0; t < 2; t = t + 1) begin
            for (i = 0; i < (t ? n1 : n0); i = i + 32) begin
                ba = (t ? la1 : la0) + i;              // byte address of this line (32-B aligned files)
                do_cmd(ba[22], 0, {ba[21:5], 4'b0});
                if (got_n != 8 || got_first - issue_edge != LAT) begin
                    $display("FAIL: read @%06h: %0d beats, latency %0d", ba, got_n, got_first - issue_edge);
                    fails = fails + 1;
                end
                for (k = 0; k < 8; k = k + 1)
                    for (L = 0; L < 4; L = L + 1) begin
                        b = i + 4 * k + L;
                        if (b < (t ? n1 : n0)) begin
                            exp_b = t ? img1[b] : img0[b];
                            got_b = got[k][8 * L +: 8];
                            if (got_b !== exp_b || mdl.backdoor_read_byte(ba + 4 * k + L) !== exp_b) begin
                                if (fails < 10)
                                    $display("FAIL: byte %06h: file %h, burst beat %0d lane %0d = %h, backdoor %h",
                                             ba + 4 * k + L, exp_b, k, L, got_b, mdl.backdoor_read_byte(ba + 4 * k + L));
                                fails = fails + 1;
                            end
                        end
                    end
            end
        end
        $display("  loader/mapping check done, fails=%0d", fails);

        // --------------------- 3. write/read round trip, masks, wrapping
        // reference: halfwords 0x8000..0x80ff of channel 0, start from backdoor
        for (i = 0; i < 256; i = i + 1)
            ref_hw[i] = i[0] ? mdl.mem0[(21'h8000 + i) >> 1][15:0] : mdl.mem0[(21'h8000 + i) >> 1][31:16];
        for (t = 0; t < 40; t = t + 1) begin
            ad = 21'h8000 + (($random & 32'hff));
            for (k = 0; k < 8; k = k + 1) begin
                wbuf[k] = $random;
                mbuf[k] = (t % 3 == 0) ? 4'b0000 : $random;
            end
            do_cmd(0, 1, ad);
            for (k = 0; k < 8; k = k + 1) begin
                // data[31:16] -> halfword h0 (mask[3:2]), data[15:0] -> h1 (mask[1:0])
                i = wrap_hw(ad, k, 0);
                if (!mbuf[k][3]) ref_hw[i][15:8] = wbuf[k][31:24];
                if (!mbuf[k][2]) ref_hw[i][7:0]  = wbuf[k][23:16];
                i = wrap_hw(ad, k, 1);
                if (!mbuf[k][1]) ref_hw[i][15:8] = wbuf[k][15:8];
                if (!mbuf[k][0]) ref_hw[i][7:0]  = wbuf[k][7:0];
            end
            ad = 21'h8000 + (($random & 32'hff));
            do_cmd(0, 0, ad);
            for (k = 0; k < 8; k = k + 1) begin
                expw = {ref_hw[wrap_hw(ad, k, 0)], ref_hw[wrap_hw(ad, k, 1)]};
                if (got[k] !== expw) begin
                    if (fails < 20) $display("FAIL: rd @%06h beat %0d got %h exp %h", ad, k, got[k], expw);
                    fails = fails + 1;
                end
            end
        end
        $display("  round-trip/mask/wrap check done, fails=%0d", fails);

        // --------------------------------------------- 4. protocol checks
        errs_before = mdl.error_count;
        @(posedge clk); #1 en0 = 1; cmd0 = 0; a0 = 21'h10;
        @(posedge clk); #1 en0 = 0;
        repeat (9) @(posedge clk);
        #1 en0 = 1; cmd0 = 0; a0 = 21'h20;                     // 10 edges after: too close
        @(posedge clk); #1 en0 = 0;
        repeat (40) @(posedge clk);
        if (mdl.error_count < errs_before + 1) begin
            $display("FAIL: spacing < TCMD not flagged"); fails = fails + 1;
        end
`ifndef VERILATOR                                            // 2-state: no X
        errs_before = mdl.error_count;
        @(posedge clk); #1 en1 = 1; cmd1 = 0; a1 = 21'bx;     // X address
        @(posedge clk); #1 en1 = 0; a1 = 0;
        repeat (40) @(posedge clk);
        if (mdl.error_count != errs_before + 1) begin
            $display("FAIL: X on addr not flagged"); fails = fails + 1;
        end
`endif

        $display("tb_model_unit: %0d failures, model error_count=%0d", fails, mdl.error_count);
        if (fails == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
