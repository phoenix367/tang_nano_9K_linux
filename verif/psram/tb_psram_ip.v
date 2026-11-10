// tb_psram_ip: measures the user-side behaviour of the REAL Gowin
// "PSRAM Memory Interface HS 2ch" netlist (Video_frame_buffer, .vo from the
// ov7670 project) driving two hyperram_model pin models, and runs the same
// stimulus against rtl/sim/psram_ui_model.v clocked by the IP's clk_out.
// Every clk_out edge rd_data_valid0/1 must match and, when valid, rd_data0/1
// must match (compare is switched off only in the deliberate protocol-
// violation phases, where the model is expected to report errors instead).
//
// Icarus only (-g2012). See run.sh and NOTES.md. A full run is ~16 ms of
// simulated time (the IP's read calibration sweep dominates) and takes a
// long time; `define FAST_MODEL_ONLY runs the stimulus against the model alone.
`timescale 1ns/1ps

`ifndef TCKD
 `define TCKD 2.0
`endif
`ifndef M_RD_LATENCY
 `define M_RD_LATENCY 16
`endif
`ifndef M_WR_BEAT0
 `define M_WR_BEAT0 0
`endif
`ifndef M_CALIB
 `define M_CALIB 100
`endif
`ifndef M_CHECK_RD_BUSY
 `define M_CHECK_RD_BUSY 0
`endif
`ifndef MCLK_HALF
 `define MCLK_HALF 3.7037            // memory_clk half period (ns): 135 MHz
`endif
`ifndef N_RANDOM
 `define N_RANDOM 300
`endif

module tb_psram_ip;
    // ------------------------------------------------------------ clocks --
    reg memory_clk = 0, refclk = 0, rst_n = 0, pll_lock = 0;
    always #(`MCLK_HALF) memory_clk = ~memory_clk; // 135 MHz unless MCLK_HALF is set
    always #18.519 refclk = ~refclk;              // 27 MHz (IP "clk" = reference clock)

    wire        clk_out;
    // ------------------------------------------------------ user signals --
    reg         u_cmd0 = 0, u_en0 = 0, u_cmd1 = 0, u_en1 = 0;
    reg  [20:0] u_addr0 = 0, u_addr1 = 0;
    reg  [31:0] u_wd0 = 0, u_wd1 = 0;
    reg  [3:0]  u_m0 = 0, u_m1 = 0;

    wire        ip_cal0, ip_cal1, ip_v0, ip_v1;
    wire [31:0] ip_rd0, ip_rd1;
    wire        m_cal0, m_cal1, m_v0, m_v1;
    wire [31:0] m_rd0, m_rd1;

`ifdef FAST_MODEL_ONLY
    reg fclk = 0;
    always #7.4074 fclk = ~fclk;
    assign clk_out = fclk;
    assign ip_cal0 = m_cal0; assign ip_cal1 = m_cal1;
    assign ip_v0 = m_v0; assign ip_v1 = m_v1; assign ip_rd0 = m_rd0; assign ip_rd1 = m_rd1;
`else
    wire [1:0]  ck, ckn, rwds, rstn_o, csn;
    wire [15:0] dq;
    Video_frame_buffer dut (
        .clk(refclk), .rst_n(rst_n), .memory_clk(memory_clk), .pll_lock(pll_lock),
        .O_psram_ck(ck), .O_psram_ck_n(ckn), .IO_psram_rwds(rwds), .O_psram_reset_n(rstn_o),
        .IO_psram_dq(dq), .O_psram_cs_n(csn),
        .init_calib0(ip_cal0), .init_calib1(ip_cal1), .clk_out(clk_out),
        .cmd0(u_cmd0), .cmd1(u_cmd1), .cmd_en0(u_en0), .cmd_en1(u_en1),
        .addr0(u_addr0), .addr1(u_addr1), .wr_data0(u_wd0), .wr_data1(u_wd1),
        .rd_data0(ip_rd0), .rd_data1(ip_rd1), .rd_data_valid0(ip_v0), .rd_data_valid1(ip_v1),
        .data_mask0(u_m0), .data_mask1(u_m1));
    // channel 1's CK leaves the IP inverted (OSER4 "genclkneg" + ELVDS):
    // the die's true CK is the IP's O_psram_ck_n[1]
    hyperram_model #(.NAME("ch0"), .TCKD(`TCKD), .VERBOSE(1)) pm0 (
        .resetb(rstn_o[0]), .ck(ck[0]), .ck_n(ckn[0]), .csb(csn[0]), .dq(dq[7:0]), .rwds(rwds[0]));
    hyperram_model #(.NAME("ch1"), .TCKD(`TCKD), .VERBOSE(1)) pm1 (
        .resetb(rstn_o[1]), .ck(ckn[1]), .ck_n(ck[1]), .csb(csn[1]), .dq(dq[15:8]), .rwds(rwds[1]));
    initial begin pm0.log_en = 0; pm1.log_en = 0; end
`endif

    psram_ui_model #(
        .RD_LATENCY(`M_RD_LATENCY), .TCMD(19), .BURST_WORDS(8), .CALIB_CYCLES(`M_CALIB),
        .WR_BEAT0(`M_WR_BEAT0), .CHECK_RD_BUSY(`M_CHECK_RD_BUSY), .VERBOSE(1)
    ) mdl (
        .clk(clk_out), .rst_n(rst_n),
        .cmd0(u_cmd0), .cmd_en0(u_en0), .addr0(u_addr0), .wr_data0(u_wd0), .data_mask0(u_m0),
        .rd_data0(m_rd0), .rd_data_valid0(m_v0), .init_calib0(m_cal0),
        .cmd1(u_cmd1), .cmd_en1(u_en1), .addr1(u_addr1), .wr_data1(u_wd1), .data_mask1(u_m1),
        .rd_data1(m_rd1), .rd_data_valid1(m_v1), .init_calib1(m_cal1));

    // ------------------------------------------------------- cycle count --
    integer cyc = 0;                  // index of the NEXT clk_out rising edge
    integer rst_edge = -1;            // first edge after rst_n release
    integer cal_edge0 = -1, cal_edge1 = -1, mcal_edge0 = -1, mcal_edge1 = -1;
    real    t_rst, t_cal0, t_cal1;
    always @(posedge rst_n) t_rst = $realtime;

    // ------------------------------------------------- command schedule --
    localparam NS = 4096;
    integer    ns = 0;                // number of scheduled commands
    integer    s_edge [0:NS-1];       // edge at which cmd_en is sampled
    reg        s_ch   [0:NS-1];
    reg        s_wr   [0:NS-1];
    reg [20:0] s_addr [0:NS-1];
    reg [7:0]  s_id   [0:NS-1];
    integer    s_mp   [0:NS-1];       // mask pattern selector
    // read results (per scheduled command)
    integer    r_first [0:NS-1];      // edge of first valid beat (IP)
    integer    r_n     [0:NS-1];      // beats received (IP)
    reg        r_gap   [0:NS-1];      // beats not consecutive
    reg [31:0] r_data  [0:NS-1][0:7];
    integer    r_last  [0:NS-1];
    integer    rd_ptr  [0:1];         // oldest read command still collecting beats
    integer    i, j;

    // data tag: lane3 = id, lane L<3 = {L, id[1:0], k+4}; k = edge offset vs cmd_en
    function [31:0] tag;
        input [7:0] id;
        input integer k;
        reg [3:0] kk;
        begin
            kk = k + 4;
            tag = {id, 2'd2, id[1:0], kk, 2'd1, id[1:0], kk, 2'd0, id[1:0], kk};
        end
    endfunction

    function [3:0] mtag;
        input integer mp;
        input integer k;
        input [7:0] id;
        begin
            case (mp)
                0: mtag = 4'b0000;
                1: mtag = (k + 3);                  // k=-2..10 -> 1..13, all distinct
                2: mtag = (k * 5 + 7);              // second, independent pattern
                3: mtag = 4'b1111;
                default: mtag = (mp * 13 + k * 7 + id) ^ ((mp >> 2) + k); // pseudo random
            endcase
        end
    endfunction

    task add_cmd;
        input integer edge_abs;
        input         ch;
        input         wr;
        input [20:0]  a;
        input [7:0]   id;
        input integer mp;
        begin
            s_edge[ns] = edge_abs; s_ch[ns] = ch; s_wr[ns] = wr; s_addr[ns] = a;
            s_id[ns] = id; s_mp[ns] = mp;
            r_first[ns] = -1; r_n[ns] = 0; r_gap[ns] = 0; r_last[ns] = -1;
            ns = ns + 1;
        end
    endtask

    // drive: values assigned at edge e are sampled at edge e+1
    integer tgt, best, bk, c, dc, di, mc, mj;
    reg     en_n [0:1];
    reg     cmd_n [0:1];
    reg [20:0] a_n [0:1];
    reg [31:0] wd_n [0:1];
    reg [3:0]  m_n [0:1];
    task drive_next;
        begin
        tgt = cyc + 1;
        for (dc = 0; dc < 2; dc = dc + 1) begin
            en_n[dc] = 0; cmd_n[dc] = 0; a_n[dc] = 0; wd_n[dc] = 32'hEEEEEEEE; m_n[dc] = 4'b0000; best = -1;
            for (di = 0; di < ns; di = di + 1) begin
                if (s_ch[di] == dc) begin
                    if (s_edge[di] == tgt) begin en_n[dc] = 1; cmd_n[dc] = s_wr[di]; a_n[dc] = s_addr[di]; end
                    if (s_wr[di] && tgt >= s_edge[di] - 2 && tgt <= s_edge[di] + 10) best = di;
                end
            end
            if (best >= 0) begin
                bk = tgt - s_edge[best];
                wd_n[dc] = tag(s_id[best], bk);
                m_n[dc]  = mtag(s_mp[best], bk, s_id[best]);
            end
        end
        u_en0 <= en_n[0]; u_cmd0 <= cmd_n[0]; u_addr0 <= a_n[0]; u_wd0 <= wd_n[0]; u_m0 <= m_n[0];
        u_en1 <= en_n[1]; u_cmd1 <= cmd_n[1]; u_addr1 <= a_n[1]; u_wd1 <= wd_n[1]; u_m1 <= m_n[1];
    end
    endtask

    // --------------------------------------------- monitor and compare --
    reg     cmp_en = 0;
    integer mism = 0, ip_beats = 0;
    reg     v_ip, v_m;
    reg [31:0] d_ip, d_m;
    integer stray = 0;
    integer f_ip = 0, f_m = 0;        // traces: "<phase> <edge-T0> <ch> <data>"
    always @(posedge clk_out) begin
        if (rst_n && rst_edge < 0) rst_edge = cyc;
        if (ip_cal0 === 1'b1 && cal_edge0 < 0) begin cal_edge0 = cyc; t_cal0 = $realtime; end
        if (ip_cal1 === 1'b1 && cal_edge1 < 0) begin cal_edge1 = cyc; t_cal1 = $realtime; end
        if (m_cal0 === 1'b1 && mcal_edge0 < 0) mcal_edge0 = cyc;
        if (m_cal1 === 1'b1 && mcal_edge1 < 0) mcal_edge1 = cyc;
        for (mc = 0; mc < 2; mc = mc + 1) begin
            v_ip = mc ? ip_v1 : ip_v0;  d_ip = mc ? ip_rd1 : ip_rd0;
            v_m  = mc ? m_v1  : m_v0;   d_m  = mc ? m_rd1  : m_rd0;
            if (t0_edge >= 0 && f_ip != 0 && v_ip === 1'b1) $fdisplay(f_ip, "%0d %0d %0d %h", phase_no, cyc - t0_edge, mc, d_ip);
            if (t0_edge >= 0 && f_m  != 0 && v_m  === 1'b1) $fdisplay(f_m,  "%0d %0d %0d %h", phase_no, cyc - t0_edge, mc, d_m);
            if (cmp_en) begin
                if (v_ip !== v_m || (v_ip === 1'b1 && d_ip !== d_m)) begin
                    mism = mism + 1;
                    if (mism <= 40)
                        $display("%t MISMATCH ch%0d edge %0d: ip v=%b d=%h  model v=%b d=%h", $time, mc, cyc, v_ip, d_ip, v_m, d_m);
                end
            end
            if (v_ip === 1'b1) begin
                ip_beats = ip_beats + 1;
                if (mc == 0 && bl_n < 65536) begin bl_e[bl_n] = cyc; bl_d[bl_n] = d_ip; bl_n = bl_n + 1; end
                // attach to the oldest read on this channel still collecting
                while (rd_ptr[mc] < ns && !(s_ch[rd_ptr[mc]] == mc && !s_wr[rd_ptr[mc]] && r_n[rd_ptr[mc]] < 8))
                    rd_ptr[mc] = rd_ptr[mc] + 1;
                if (rd_ptr[mc] < ns && s_edge[rd_ptr[mc]] < cyc) begin
                    mj = rd_ptr[mc];
                    if (r_n[mj] == 0) r_first[mj] = cyc;
                    else if (r_last[mj] != cyc - 1) r_gap[mj] = 1;
                    r_data[mj][r_n[mj]] = d_ip;
                    r_last[mj] = cyc;
                    r_n[mj] = r_n[mj] + 1;
                end else begin
                    stray = stray + 1;
                    if (stray <= 20) $display("%t STRAY valid beat ch%0d edge %0d d=%h", $time, mc, cyc, d_ip);
                end
            end
        end
        drive_next;
        cyc = cyc + 1;
    end

    // ----------------------------------------------------------- helpers --
    // Phase bases are derived from T0 (first stimulus edge) only, so the
    // same stimulus lands on the same T0-relative edges in every run.
    integer base, ph_first, next_base, t0_edge = -1, phase_no = 0;
    task phase_begin;
        input [8*40-1:0] name;
        begin
            base = next_base;
            ph_first = ns;
            phase_no = phase_no + 1;
            $display("");
            $display("==== phase %0s (T0+%0d, t=%0t)", name, base - t0_edge, $time);
        end
    endtask
    // wait until all commands of the phase are done (+ drain)
    integer last_e;
    task phase_end;
        begin
            last_e = base;
            for (i = ph_first; i < ns; i = i + 1) if (s_edge[i] > last_e) last_e = s_edge[i];
            next_base = last_e + 70;
            while (cyc < last_e + 60) @(posedge clk_out);
        end
    endtask

    // decode a 32-bit read word built from tags
    task show_word;
        input [31:0] w;
        reg [3:0] l0, l1, l2;
        begin
            $write("%h [id%02h", w, w[31:24]);
            $write(" L2:id%0d/k%0d", w[21:20], $signed({1'b0, w[19:16]}) - 4);
            $write(" L1:id%0d/k%0d", w[13:12], $signed({1'b0, w[11:8]}) - 4);
            $write(" L0:id%0d/k%0d]", w[5:4], $signed({1'b0, w[3:0]}) - 4);
        end
    endtask

    task show_read;
        input integer n;
        integer b;
        begin
            $display("  read ch%0d addr=%06h issued@%0d: %0d beats, first@%0d -> latency %0d%s",
                     s_ch[n], s_addr[n], s_edge[n], r_n[n], r_first[n], r_first[n] - s_edge[n],
                     r_gap[n] ? " (GAPS!)" : " (consecutive)");
            for (b = 0; b < r_n[n]; b = b + 1) begin
                $write("    beat %0d: ", b); show_word(r_data[n][b]); $display("");
            end
        end
    endtask

    // ---------------------------------------- violation-phase analysis --
    integer v_kind [0:31], v_sp [0:31], v_cmd [0:31], nv;
    integer win_n, win_first, n1, f1;
    reg [8*24-1:0] st1, st2;
    // all valid beats per channel 0 (edge, data) for window analysis
    integer    bl_n = 0;
    integer    bl_e [0:65535];
    reg [31:0] bl_d [0:65535];
    // beats of channel 0 seen in [e0+w0, e0+40]; checks them against tag(id, b)
    // (id ignored when mode == -1: only counts; mode == -2: id is exact)
    function [8*24-1:0] beats_state;
        input integer e0;
        input integer w0;          // window starts at e0 + w0
        input [7:0]   id;
        input integer mode;
        integer q, good, xs, zero;
        begin
            win_n = 0; win_first = -1; good = 0; xs = 0; zero = 0;
            for (q = 0; q < bl_n; q = q + 1)
                if (bl_e[q] >= e0 + w0 && bl_e[q] <= e0 + 40 && win_n < 8) begin
                    if (win_first < 0) win_first = bl_e[q] - e0;
                    if (bl_d[q] === tag(id, win_n)) good = good + 1;
                    if (^bl_d[q] === 1'bx) xs = xs + 1;
                    if (bl_d[q] === 32'd0) zero = zero + 1;
                    win_n = win_n + 1;
                end
            if (win_n == 0) beats_state = "NO BEATS";
            else if (xs > 0) beats_state = "GARBLED (X)";
            else if (mode != -1 && good == 8 && win_first == `M_RD_LATENCY) beats_state = "OK";
            else if (mode == -1) beats_state = "data";
            else if (zero == 8) beats_state = "ALL ZERO (lost)";
            else beats_state = "WRONG DATA";
        end
    endfunction

    // ------------------------------------------------------ the stimulus --
    integer n, k, id, sp, lat_min, lat_max, nrd, err0, e1, cmds;
    integer rnd_seed;
    reg [20:0] a;
    integer gap0, gap1, e_ch0, e_ch1;
    initial begin
        rd_ptr[0] = 0; rd_ptr[1] = 0;
        $display("tb_psram_ip: memory_clk %0.2f MHz, TCKD=%0.2f ns, model RD_LATENCY=%0d WR_BEAT0=%0d CALIB=%0d",
                 1000.0 / (2.0 * `MCLK_HALF), `TCKD, `M_RD_LATENCY, `M_WR_BEAT0, `M_CALIB);
        #100 pll_lock = 1;
        #100 rst_n = 1;
        // ------------------------------------------------ init/calibration
        wait (ip_cal0 === 1'b1 && ip_cal1 === 1'b1 && m_cal0 === 1'b1 && m_cal1 === 1'b1);
        @(posedge clk_out); @(posedge clk_out);
        $display("");
        $display("==== init: rst_n released at %0.3f us (clk_out edge %0d)", t_rst / 1000.0, rst_edge);
        $display("  IP    init_calib0 at edge %0d (%0.3f us), +%0d clk_out edges after rst_n",
                 cal_edge0, t_cal0 / 1000.0, cal_edge0 - rst_edge);
        $display("  IP    init_calib1 at edge %0d (%0.3f us), +%0d clk_out edges after rst_n",
                 cal_edge1, t_cal1 / 1000.0, cal_edge1 - rst_edge);
        $display("  model init_calib0/1 at edges %0d/%0d (+%0d/+%0d)", mcal_edge0, mcal_edge1,
                 mcal_edge0 - rst_edge, mcal_edge1 - rst_edge);
`ifndef FAST_MODEL_ONLY
        pm0.log_en = 1; pm1.log_en = 1;
        // calibration result: ss = IDES4 slip count (ss[3] moves the read-valid
        // window by one edge), dly = DQ IODELAY taps
        $display("  calibration result ch0: ss=%0d dly=%0d   ch1: ss=%0d dly=%0d",
            {dut.\u_psram_top0/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [4],
             dut.\u_psram_top0/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [3],
             dut.\u_psram_top0/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [2],
             dut.\u_psram_top0/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [1],
             dut.\u_psram_top0/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [0]},
            dut.\u_psram_top0/u_psram_wd/dq_iodelay_gen0[0].[0].iodelay .delay_data,
            {dut.\u_psram_top1/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [4],
             dut.\u_psram_top1/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [3],
             dut.\u_psram_top1/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [2],
             dut.\u_psram_top1/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [1],
             dut.\u_psram_top1/u_psram_wd/data_lane_gen[0].u_psram_lane/ss [0]},
            dut.\u_psram_top1/u_psram_wd/dq_iodelay_gen0[0].[0].iodelay .delay_data);
`endif
        err0 = mdl.error_count;
        // T0: a fixed distance after the later of the two calibration edges
        @(posedge clk_out); #1;
        t0_edge = cyc + 8;
        next_base = t0_edge;
`ifndef FAST_MODEL_ONLY
        f_ip = $fopen("trace_ip.txt", "w");
`endif
        f_m = $fopen("trace_model.txt", "w");
        cmp_en = 1;

        // ------------------------------------------- P1: write beat alignment
        phase_begin("P1 write alignment / first read");
        add_cmd(base + 0,  0, 1, 21'h000100, 8'h11, 0);
        add_cmd(base + 40, 0, 0, 21'h000100, 0, 0);
        add_cmd(base + 0,  1, 1, 21'h000100, 8'h12, 0);
        add_cmd(base + 40, 1, 0, 21'h000100, 0, 0);
        phase_end;
        show_read(ph_first + 1);
        show_read(ph_first + 3);
`ifndef FAST_MODEL_ONLY
        $display("  pin model ch0 halfwords 0x100..0x10f:");
        $write("   ");
        for (k = 0; k < 16; k = k + 1) $write(" %h", pm0.mem[21'h100 + k]);
        $display("");
`endif

        // ------------------------------------------------ P2: mask polarity
        phase_begin("P2 data_mask");
        add_cmd(base + 0,   0, 1, 21'h000200, 8'h21, 0);   // prefill
        add_cmd(base + 40,  0, 1, 21'h000200, 8'h22, 1);   // masked, pattern 1
        add_cmd(base + 80,  0, 0, 21'h000200, 0, 0);
        add_cmd(base + 120, 0, 1, 21'h000300, 8'h31, 0);
        add_cmd(base + 160, 0, 1, 21'h000300, 8'h32, 2);   // masked, pattern 2
        add_cmd(base + 200, 0, 0, 21'h000300, 0, 0);
        add_cmd(base + 240, 0, 1, 21'h000400, 8'h41, 0);
        add_cmd(base + 280, 0, 1, 21'h000400, 8'h42, 3);   // all ones
        add_cmd(base + 320, 0, 0, 21'h000400, 0, 0);
        phase_end;
        $display("  mask pattern 1: m(k) = k+3; pattern 2: m(k) = 5k+7 (4 bits), k = edge offset vs cmd_en");
        show_read(ph_first + 2);
        show_read(ph_first + 5);
        show_read(ph_first + 8);

        // ------------------------------------------ P3: read latency sweep
        phase_begin("P3 read latency");
        // isolated reads, reads at exactly TCMD, both channels same edge and skewed
        n = 0;
        for (k = 0; k < 6; k = k + 1) begin
            add_cmd(base + n, 0, 0, 21'h000100 + 16 * k, 0, 0);
            add_cmd(base + n + (k < 2 ? k : 2), 1, 0, 21'h000100 + 16 * k, 0, 0);
            n = n + (k < 3 ? 19 : 57 + 13 * k);
        end
        phase_end;
        lat_min = 999; lat_max = -1;
        for (i = ph_first; i < ns; i = i + 1) begin
            $display("  read ch%0d issued@%0d first@%0d latency %0d beats %0d%s", s_ch[i], s_edge[i], r_first[i],
                     r_first[i] - s_edge[i], r_n[i], r_gap[i] ? " GAPS" : "");
            if (r_first[i] - s_edge[i] < lat_min) lat_min = r_first[i] - s_edge[i];
            if (r_first[i] - s_edge[i] > lat_max) lat_max = r_first[i] - s_edge[i];
        end
        $display("  read latency (cmd_en edge -> first rd_data_valid edge): min %0d max %0d", lat_min, lat_max);

        // ----------------------------------------- P4: address/data mapping
        phase_begin("P4 mapping");
        add_cmd(base + 0,   0, 1, 21'h001000, 8'h51, 0);
        add_cmd(base + 19,  0, 1, 21'h001010, 8'h52, 0);
        add_cmd(base + 38,  0, 1, 21'h001020, 8'h53, 0);
        add_cmd(base + 0,   1, 1, 21'h001000, 8'h61, 0);   // channel 1, same address, other data
        add_cmd(base + 19,  1, 1, 21'h1FFFF0, 8'h62, 0);   // top of channel
        add_cmd(base + 38,  1, 1, 21'h100000, 8'h63, 0);
        n = base + 80;
        add_cmd(n, 0, 0, 21'h001000, 0, 0); n = n + 19;   // ph+6
        add_cmd(n, 0, 0, 21'h001010, 0, 0); n = n + 19;   // ph+7
        add_cmd(n, 0, 0, 21'h001001, 0, 0); n = n + 19;   // ph+8
        add_cmd(n, 0, 0, 21'h001002, 0, 0); n = n + 19;   // ph+9
        add_cmd(n, 0, 0, 21'h001008, 0, 0); n = n + 19;   // ph+10
        add_cmd(n, 0, 0, 21'h00100F, 0, 0); n = n + 19;   // ph+11
        add_cmd(n, 0, 0, 21'h001013, 0, 0); n = n + 19;   // ph+12
        add_cmd(n, 1, 0, 21'h001000, 0, 0);               // ph+13
        add_cmd(n + 19, 1, 0, 21'h1FFFF0, 0, 0);          // ph+14
        add_cmd(n + 38, 1, 0, 21'h100000, 0, 0);          // ph+15
        add_cmd(n + 57, 1, 0, 21'h1FFFF8, 0, 0);          // ph+16 (unaligned, top group)
        n = n + 100;
        add_cmd(n, 0, 1, 21'h001015, 8'h54, 0); n = n + 19;  // ph+17 unaligned odd write
        add_cmd(n, 0, 1, 21'h001022, 8'h55, 0); n = n + 19;  // ph+18 unaligned even write
        add_cmd(n, 0, 0, 21'h001010, 0, 0); n = n + 19;      // ph+19
        add_cmd(n, 0, 0, 21'h001020, 0, 0); n = n + 19;      // ph+20
        add_cmd(n, 0, 0, 21'h001030, 0, 0); n = n + 19;      // ph+21 (untouched neighbour)
        phase_end;
        for (i = ph_first + 6; i <= ph_first + 16; i = i + 1) show_read(i);
        $display("  after unaligned writes id54 @001015 and id55 @001022:");
        for (i = ph_first + 19; i <= ph_first + 21; i = i + 1) show_read(i);
`ifndef FAST_MODEL_ONLY
        $display("  pin model ch0 halfwords 0x1000..0x102f (after all P4 writes):");
        for (j = 0; j < 3; j = j + 1) begin
            $write("   %06h:", 21'h1000 + 16 * j);
            for (k = 0; k < 16; k = k + 1) $write(" %h", pm0.mem[21'h1000 + 16 * j + k]);
            $display("");
        end
        $display("  pin model ch1 hw 0x1000: %h %h, 0x1ffff0: %h %h, 0x100000: %h %h",
                 pm1.mem[21'h1000], pm1.mem[21'h1001], pm1.mem[21'h1ffff0], pm1.mem[21'h1ffff1],
                 pm1.mem[21'h100000], pm1.mem[21'h100001]);
`endif

        // -------------------------- P5: legal back-to-back combinations at TCMD
        phase_begin("P5 TCMD combos");
        n = base;
        add_cmd(n, 0, 1, 21'h002000, 8'h71, 0); n = n + 19;   // W
        add_cmd(n, 0, 0, 21'h002000, 0, 0);     n = n + 19;   // R after W (same line) at TCMD
        add_cmd(n, 0, 0, 21'h001000, 0, 0);     n = n + 19;   // R after R at TCMD
        add_cmd(n, 0, 1, 21'h002000, 8'h72, 0); n = n + 19;   // W after R at TCMD (same line as next read)
        add_cmd(n, 0, 0, 21'h002000, 0, 0);     n = n + 19;
        add_cmd(n, 0, 1, 21'h002010, 8'h73, 0); n = n + 19;   // W after R
        add_cmd(n, 0, 1, 21'h002020, 8'h74, 0); n = n + 19;   // W after W at TCMD
        add_cmd(n, 0, 0, 21'h002010, 0, 0);     n = n + 19;
        add_cmd(n, 0, 0, 21'h002020, 0, 0);     n = n + 19;
        phase_end;
        for (i = ph_first; i < ns; i = i + 1) if (!s_wr[i]) show_read(i);
        $display("  model protocol errors in legal phases so far: %0d", mdl.error_count - err0);

        // ----------------------------------------- P6: random legal traffic
        phase_begin("P6 random");
        rnd_seed = 12345;
        e_ch0 = base; e_ch1 = base + 3;
        for (n = 0; n < `N_RANDOM; n = n + 1) begin
            for (c = 0; c < 2; c = c + 1) begin
                k = $random(rnd_seed);
                a = {7'd0, 10'(k[25:16] & 10'h00f), k[3:0]};     // 16 lines, any offset
                if (k[7:6] == 0) a[3:0] = 0;
                sp = 19 + ((k[30:28] == 0) ? (k[11:8]) : 0) + ((k[31]) ? 0 : 20);
                add_cmd(c ? e_ch1 : e_ch0, c, k[4], a, 8'h80 + n[6:0], k[5] ? 0 : 100 + n);
                if (c) e_ch1 = e_ch1 + sp; else e_ch0 = e_ch0 + sp;
            end
        end
        phase_end;
        nrd = 0; lat_min = 999; lat_max = -1;
        for (i = ph_first; i < ns; i = i + 1) if (!s_wr[i]) begin
            nrd = nrd + 1;
            if (r_n[i] != 8 || r_gap[i]) $display("  random read %0d: %0d beats gap=%b", i, r_n[i], r_gap[i]);
            if (r_first[i] - s_edge[i] < lat_min) lat_min = r_first[i] - s_edge[i];
            if (r_first[i] - s_edge[i] > lat_max) lat_max = r_first[i] - s_edge[i];
        end
        $display("  %0d random reads, latency min %0d max %0d", nrd, lat_min, lat_max);
        $display("  model protocol errors in legal phases: %0d", mdl.error_count - err0);
        $display("  IP-vs-model mismatches in legal phases: %0d, stray beats: %0d", mism, stray);
        e1 = mdl.error_count;

        // -------------------------------------- P7: protocol violations (IP only)
        cmp_en = 0;
        // Each case: the violating pair, then (>= 60 edges later) legal reads of
        // both lines. Expected line contents are tag(id, beat).
        phase_begin("P7 pre-fill");
        for (k = 0; k < 16; k = k + 1) add_cmd(base + 19 * k, 0, 1, 21'h004000 + 16 * k, 8'hC0 + k, 0);
        phase_end;

        phase_begin("P7 spacing violations");
        n = base;
        nv = 0;
        // W-W pairs (fresh lines 0x3000+), R-R pairs (pre-filled lines),
        // W-R and R-W on the same pre-filled line
        for (k = 0; k < 6; k = k + 1) begin
            case (k) 0: sp = 18; 1: sp = 17; 2: sp = 16; 3: sp = 12; 4: sp = 4; default: sp = 1; endcase
            v_kind[nv] = 0; v_sp[nv] = sp; v_cmd[nv] = ns;
            add_cmd(n,      0, 1, 21'h003000 + 32 * k,      8'hA0 + 2 * k, 0);
            add_cmd(n + sp, 0, 1, 21'h003000 + 32 * k + 16, 8'hA1 + 2 * k, 0);
            add_cmd(n + sp + 60, 0, 0, 21'h003000 + 32 * k, 0, 0);
            add_cmd(n + sp + 100, 0, 0, 21'h003000 + 32 * k + 16, 0, 0);
            n = n + sp + 160; nv = nv + 1;
        end
        for (k = 0; k < 5; k = k + 1) begin
            case (k) 0: sp = 18; 1: sp = 17; 2: sp = 16; 3: sp = 12; default: sp = 4; endcase
            v_kind[nv] = 1; v_sp[nv] = sp; v_cmd[nv] = ns;
            add_cmd(n,      0, 0, 21'h004000 + 32 * k,      0, 0);
            add_cmd(n + sp, 0, 0, 21'h004000 + 32 * k + 16, 0, 0);
            n = n + sp + 100; nv = nv + 1;
        end
        for (k = 0; k < 2; k = k + 1) begin
            sp = 18 - k;
            v_kind[nv] = 2; v_sp[nv] = sp; v_cmd[nv] = ns;              // W then R, same line
            add_cmd(n,      0, 1, 21'h004000 + 16 * (10 + k), 8'hD0 + k, 0);
            add_cmd(n + sp, 0, 0, 21'h004000 + 16 * (10 + k), 0, 0);
            n = n + sp + 100; nv = nv + 1;
            v_kind[nv] = 3; v_sp[nv] = sp; v_cmd[nv] = ns;              // R then W, same line
            add_cmd(n,      0, 0, 21'h004000 + 16 * (12 + k), 0, 0);
            add_cmd(n + sp, 0, 1, 21'h004000 + 16 * (12 + k), 8'hD2 + k, 0);
            add_cmd(n + sp + 60, 0, 0, 21'h004000 + 16 * (12 + k), 0, 0);
            n = n + sp + 120; nv = nv + 1;
        end
        phase_end;
        for (k = 0; k < nv; k = k + 1) begin
            i = v_cmd[k];
            case (v_kind[k])
                0: begin
                    st1 = beats_state(s_edge[i + 2], 8, s_id[i], -2);
                    st2 = beats_state(s_edge[i + 3], 8, s_id[i + 1], -2);
                    $display("  W-W spacing %0d: 1st write read back %0s, 2nd write read back %0s", v_sp[k], st1, st2);
                end
                1: begin
                    st1 = beats_state(s_edge[i], 1, 8'hC0 + 2 * (k - 6), -2);
                    n1 = win_n; f1 = win_first;
                    st2 = beats_state(s_edge[i + 1], 8, 8'hC0 + 2 * (k - 6) + 1, -2);
                    $display("  R-R spacing %0d: 1st read %0s (%0d beats from +%0d), 2nd read %0s (%0d beats from +%0d)",
                             v_sp[k], st1, n1, f1, st2, win_n, win_first);
                end
                2: begin
                    $display("  W-R same line spacing %0d: read returns %0s", v_sp[k],
                             beats_state(s_edge[i + 1], 8, s_id[i], -2));
                end
                3: begin
                    st1 = beats_state(s_edge[i], 8, 8'hCC + (k - 12) / 2, -2);
                    st2 = beats_state(s_edge[i + 2], 8, s_id[i + 1], -2);
                    $display("  R-W same line spacing %0d: read returns %0s (old data expected); line afterwards %0s",
                             v_sp[k], st1, st2);
                end
            endcase
        end
        $display("  model errors flagged in violation phases: %0d", mdl.error_count - e1);

        if (f_ip) $fclose(f_ip);
        if (f_m) $fclose(f_m);
        $display("");
        $display("==== SUMMARY: mismatches=%0d stray=%0d model_errors_legal=%0d model_errors_violations=%0d",
                 mism, stray, e1 - err0, mdl.error_count - e1);
        if (mism == 0 && stray == 0 && e1 == err0 && mdl.error_count > e1)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TIMEOUT: calib %b%b model %b%b", ip_cal0, ip_cal1, m_cal0, m_cal1);
        $display("RESULT: FAIL");
        $finish;
    end
endmodule
