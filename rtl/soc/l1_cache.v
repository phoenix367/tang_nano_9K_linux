// Unified L1 cache for the QERV SoC: direct-mapped, write-back, write-allocate, 32-byte lines,
// between the CPU bus and the Gowin PSRAM HS 2ch IP user interface. Everything runs on one
// clock (the IP's clk_out) - no clock-domain crossing.
//
// One cache for instructions and data is enough because SERV never has a fetch and a data
// access outstanding at the same time; it also makes fence.i a no-op (no I/D coherence).
//
// CPU side: Wishbone classic (cyc = stb), one access at a time, byte address within the
// 8 MB PSRAM window. Hit: ack two cycles after cyc rises (tag/data block RAMs are read in
// the request cycle, compared the next, ack registered). Miss: write back the victim if
// dirty (one 8-beat PSRAM write burst streamed out of the data RAM), fill the line (one
// 8-beat read burst streamed into the data RAM), then look up again.
//
// PSRAM side, per the IP's user protocol (see rtl/sim/psram_ui_model.v / verif/psram):
//   write: cmd_en=1, cmd=1, addr, wr_data = beat 0 in one cycle, beats 1..7 on the next
//          seven cycles; read: cmd_en=1, cmd=0, addr, then 8 beats flagged by rd_data_valid;
//   at least TCMD cycles between commands; addr in 16-bit units, 4 MB per channel.
// Byte address bit 22 selects the channel. All IP inputs are registered here (a uniform
// one-cycle pipeline stage, as the ov7670 design does for timing).
`default_nettype none

module l1_cache #(
    parameter       LINES     = 512,      // 512 x 32 B = 16 KB
    parameter       TCMD      = 19,       // IP command spacing for 32-byte bursts
    parameter [3:0] MASK_NONE = 4'b0000   // data_mask value that writes all four bytes
) (
    input  wire        i_clk,
    input  wire        i_rst,
    // CPU side
    input  wire [22:0] i_adr,
    input  wire [31:0] i_dat,
    input  wire [ 3:0] i_sel,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    // PSRAM IP user interface
    input  wire        i_calib,           // init_calib0 & init_calib1
    output reg         o_cmd0,
    output reg         o_cmd_en0,
    output reg  [20:0] o_addr0,
    output reg  [31:0] o_wr_data0,
    output reg  [ 3:0] o_data_mask0,
    input  wire [31:0] i_rd_data0,
    input  wire        i_rd_data_valid0,
    output reg         o_cmd1,
    output reg         o_cmd_en1,
    output reg  [20:0] o_addr1,
    output reg  [31:0] o_wr_data1,
    output reg  [ 3:0] o_data_mask1,
    input  wire [31:0] i_rd_data1,
    input  wire        i_rd_data_valid1,
    // statistics (free-running, for software/bring-up)
    output reg  [31:0] o_hits,
    output reg  [31:0] o_misses,
    output reg  [31:0] o_writebacks
);

  localparam IW = $clog2(LINES);          // index bits
  localparam TW = 23 - 5 - IW;            // tag bits

  localparam [2:0] S_IDLE = 3'd0, S_LOOKUP = 3'd1, S_WB_PRE = 3'd2, S_WB_GO = 3'd3,
                   S_WB_BURST = 3'd4, S_FILL_CMD = 3'd5, S_FILL_DATA = 3'd6, S_RELOOKUP = 3'd7;

  reg  [2:0] state;
  reg  [2:0] beat;
  reg  [IW-1:0] idx;                      // line being written back / filled
  reg  [TW-1:0] victim_tag;
  reg  [5:0] tcmd_cnt;
  wire       tcmd_ok = (tcmd_cnt == 6'd0);

  wire [2:0]    cpu_word = i_adr[4:2];
  wire [IW-1:0] cpu_idx  = i_adr[5+IW-1:5];
  wire [TW-1:0] cpu_tag  = i_adr[22:5+IW];

  // ---------------------------------------------------------------- RAMs
  // data: LINES*8 words, byte-writable, synchronous read
  reg [31:0] data_ram[0:LINES*8-1];
  reg [31:0] dq;
  reg [IW+2:0] daddr;
  reg [ 3:0] dwe;
  reg [31:0] dwd;

  // tag: {valid, dirty, tag}, synchronous read
  reg [TW+1:0] tag_ram[0:LINES-1];
  reg [TW+1:0] tq;
  reg [IW-1:0] taddr;
  reg          twe;
  reg [TW+1:0] twd;

  integer i;
  initial begin
    for (i = 0; i < LINES; i = i + 1) tag_ram[i] = {(TW + 2) {1'b0}};
  end

  always @(posedge i_clk) begin
    if (dwe[0]) data_ram[daddr][7:0] <= dwd[7:0];
    if (dwe[1]) data_ram[daddr][15:8] <= dwd[15:8];
    if (dwe[2]) data_ram[daddr][23:16] <= dwd[23:16];
    if (dwe[3]) data_ram[daddr][31:24] <= dwd[31:24];
    dq <= data_ram[daddr];
  end

  always @(posedge i_clk) begin
    if (twe) tag_ram[taddr] <= twd;
    tq <= tag_ram[taddr];
  end

  wire          t_valid = tq[TW+1];
  wire          t_dirty = tq[TW];
  wire [TW-1:0] t_tag   = tq[TW-1:0];
  wire          hit     = t_valid & (t_tag == cpu_tag);

  // ---------------------------------------------------------------- PSRAM command
  reg        rd_ch;                       // channel of the outstanding fill
  wire       rd_valid = rd_ch ? i_rd_data_valid1 : i_rd_data_valid0;
  wire [31:0] rd_data = rd_ch ? i_rd_data1 : i_rd_data0;

  reg         issue;                      // combinational: start a PSRAM command now
  reg         issue_we;
  reg  [22:5] issue_line;                 // byte address of the line

  // ---------------------------------------------------------------- control
  always @(*) begin
    // RAM ports default to the CPU request so a lookup reads tag and data at once
    daddr    = {cpu_idx, cpu_word};
    dwe      = 4'b0000;
    dwd      = i_dat;
    taddr    = cpu_idx;
    twe      = 1'b0;
    twd      = {1'b1, 1'b1, cpu_tag};
    issue    = 1'b0;
    issue_we = 1'b0;
    issue_line = {victim_tag, idx};

    case (state)
      S_LOOKUP:
        if (hit & i_we) begin
          dwe = i_sel;                    // write hit: bytes + mark dirty
          twe = 1'b1;
        end
      S_WB_PRE:  daddr = {idx, 3'd0};
      S_WB_GO: begin
        daddr = {idx, 3'd0};              // hold word 0 on dq while waiting
        if (tcmd_ok & i_calib) begin
          issue      = 1'b1;
          issue_we   = 1'b1;
          issue_line = {victim_tag, idx};
          daddr      = {idx, 3'd1};       // beat 0 is on dq now, prefetch beat 1
        end
      end
      S_WB_BURST: daddr = {idx, beat + 3'd1};
      S_FILL_CMD:
        if (tcmd_ok & i_calib) begin
          issue      = 1'b1;
          issue_line = {cpu_tag, idx};
        end
      S_FILL_DATA: begin
        daddr = {idx, beat};
        dwd   = rd_data;
        if (rd_valid) dwe = 4'b1111;
        taddr = idx;
        twd   = {1'b1, 1'b0, cpu_tag};
        twe   = rd_valid & (beat == 3'd7);
      end
      default: ;
    endcase
  end

  always @(posedge i_clk) begin
    o_ack <= 1'b0;
    if (tcmd_cnt != 6'd0) tcmd_cnt <= tcmd_cnt - 6'd1;
    if (issue) tcmd_cnt <= TCMD[5:0] - 6'd1;

    case (state)
      // a request still held in the cycle after its ack is not a new one
      S_IDLE, S_RELOOKUP: if (i_cyc & !o_ack) state <= S_LOOKUP;
      S_LOOKUP:
        if (hit) begin
          o_rdt  <= dq;
          o_ack  <= 1'b1;
          o_hits <= o_hits + 32'd1;
          state  <= S_IDLE;
        end else begin
          idx        <= cpu_idx;
          victim_tag <= t_tag;
          o_misses   <= o_misses + 32'd1;
          if (t_valid & t_dirty) begin
            o_writebacks <= o_writebacks + 32'd1;
            state        <= S_WB_PRE;
          end else
            state <= S_FILL_CMD;
        end
      S_WB_PRE: state <= S_WB_GO;
      S_WB_GO:
        if (issue) begin
          beat  <= 3'd1;
          state <= S_WB_BURST;
        end
      S_WB_BURST: begin
        beat <= beat + 3'd1;
        if (beat == 3'd7) state <= S_FILL_CMD;
      end
      S_FILL_CMD:
        if (issue) begin
          beat  <= 3'd0;
          rd_ch <= cpu_tag[TW-1];         // byte address bit 22
          state <= S_FILL_DATA;
        end
      S_FILL_DATA:
        if (rd_valid) begin
          beat <= beat + 3'd1;
          if (beat == 3'd7) state <= S_RELOOKUP;
        end
      default: state <= S_IDLE;
    endcase

    // registered IP inputs
    o_cmd_en0 <= issue & !issue_line[22];
    o_cmd_en1 <= issue & issue_line[22];
    if (issue) begin
      o_cmd0  <= issue_we;
      o_cmd1  <= issue_we;
      o_addr0 <= {issue_line[21:5], 4'b0000};
      o_addr1 <= {issue_line[21:5], 4'b0000};
    end
    // dq holds burst beat k in the k-th cycle after the issue cycle, so the registered
    // wr_data presents beats 0..7 on the command cycle and the seven after it
    o_wr_data0   <= dq;
    o_wr_data1   <= dq;
    o_data_mask0 <= MASK_NONE;
    o_data_mask1 <= MASK_NONE;

    if (i_rst) begin
      state        <= S_IDLE;
      tcmd_cnt     <= 6'd0;
      o_ack        <= 1'b0;
      o_cmd_en0    <= 1'b0;
      o_cmd_en1    <= 1'b0;
      o_hits       <= 32'd0;
      o_misses     <= 32'd0;
      o_writebacks <= 32'd0;
    end
  end

endmodule

`default_nettype wire
