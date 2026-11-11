// Unified L1 cache for the QERV SoC: direct-mapped, write-back, write-allocate, 32-byte lines,
// between the CPU bus and the Gowin PSRAM HS 2ch IP, whose commands go through psram_arb
// (shared with the video DMA). Everything runs on one clock (the IP's clk_out).
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
// Cache-block operations (Zicbom; i_cmo with the request, i_cmo_op 00 inval, 01 clean,
// 10 flush; both latched with the request, so the CPU's decode is not in the state logic)
// act on the line holding the address: clean and flush write it back if it is
// dirty (the same 8-beat burst as an eviction), then clean keeps it (now clean) and flush
// drops it; inval drops it without writing it back. A miss, or the uncached alias (acked
// from S_UNC_CMD without a command), has nothing to do and is acked straight away. Once the ack is out, the write burst has been
// granted, so a later PSRAM read by another master (the video DMA) sees the data.
//
// Uncached alias (i_unc, CPU address 0x9xxx_xxxx): one PSRAM burst per access, no lookup.
// A write is a burst with only beat 0 enabled (data_mask from i_sel), acked as soon as it is
// granted (posted); a read takes beat 0 of a burst at the word's address (bursts wrap inside
// their 32-byte group, so beat 0 is that word) and then waits out the other seven beats.
// Used for the video framebuffer, which the display DMA reads straight from PSRAM: software
// must not reach the same memory through the cached window as well.
//
// PSRAM side (psram_arb, rtl/sim/psram_ui_model.v): o_req asks for a command, granted by
// i_gnt in the same cycle; write beat k is o_wdata/o_wmask k cycles after the grant (mask
// bit = 1: byte not written); a read's 8 beats come back on i_rvalid/i_rdata. Byte address
// bit 22 selects the channel; the arbiter keeps the command spacing (TCMD).
`default_nettype none

module l1_cache #(
    parameter       LINES     = 512       // 512 x 32 B = 16 KB
) (
    input  wire        i_clk,
    input  wire        i_rst,
    // CPU side
    input  wire [22:0] i_adr,
    input  wire [31:0] i_dat,
    input  wire [ 3:0] i_sel,
    input  wire        i_we,
    input  wire        i_cyc,
    input  wire        i_unc,             // uncached alias
    input  wire        i_cmo,             // cache-block operation (Zicbom), not an access
    input  wire [ 1:0] i_cmo_op,          // 00 inval, 01 clean, 10 flush
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    // PSRAM commands (psram_arb)
    output reg         o_req,
    output reg         o_req_we,
    output reg  [22:2] o_req_adr,
    input  wire        i_gnt,
    output wire [31:0] o_wdata,
    output reg  [ 3:0] o_wmask,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata,
    // statistics (free-running, for software/bring-up)
    output reg  [31:0] o_hits,
    output reg  [31:0] o_misses,
    output reg  [31:0] o_writebacks
);

  localparam IW = $clog2(LINES);          // index bits
  localparam TW = 23 - 5 - IW;            // tag bits

  localparam [3:0] S_IDLE = 4'd0, S_LOOKUP = 4'd1, S_WB_PRE = 4'd2, S_WB_GO = 4'd3,
                   S_WB_BURST = 4'd4, S_FILL_CMD = 4'd5, S_FILL_DATA = 4'd6, S_RELOOKUP = 4'd7,
                   S_UNC_CMD = 4'd8, S_UNC_DATA = 4'd9, S_UNC_DRAIN = 4'd10,
                   S_CMO_END = 4'd11;
  localparam [1:0] CMO_INVAL = 2'b00, CMO_CLEAN = 2'b01, CMO_FLUSH = 2'b10;

  reg  [3:0] state;
  reg  [2:0] beat;
  reg  [IW-1:0] idx;                      // line being written back / filled
  reg  [TW-1:0] victim_tag;
  reg  [TW-1:0] fill_tag;                 // tag of the missing line (latched: the PSRAM
                                          // command path starts from registers)
  reg  [22:2]   unc_adr;                  // uncached request, latched the same way
  reg  [31:0]   unc_dat;
  reg  [ 3:0]   unc_sel;
  reg           unc_we;
  reg           cmo_wb;                   // the write-back belongs to a CMO, not a miss
  reg           cmo_q;                    // the request is a CMO (latched in IDLE)
  reg  [ 1:0]   cmo_op_q;

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
  wire        rd_valid = i_rvalid;
  wire [31:0] rd_data  = i_rdata;
  wire        issue    = o_req & i_gnt;   // a PSRAM command starts now
  // write stream: dq holds burst beat k in the k-th cycle after the grant; an uncached
  // write sends the CPU's word as beat 0
  assign o_wdata = (state == S_UNC_CMD) ? unc_dat : dq;

  // ---------------------------------------------------------------- control
  always @(*) begin
    // RAM ports default to the CPU request so a lookup reads tag and data at once
    daddr    = {cpu_idx, cpu_word};
    dwe      = 4'b0000;
    dwd      = i_dat;
    taddr    = cpu_idx;
    twe      = 1'b0;
    twd      = {1'b1, 1'b1, cpu_tag};
    o_req     = 1'b0;
    o_req_we  = 1'b0;
    o_req_adr = {victim_tag, idx, 3'd0};
    // no byte written outside a write's own beats: both channels see this one stream, and
    // a write waiting for its grant must not touch the tail of the one before it
    o_wmask   = 4'b1111;

    case (state)
      S_LOOKUP:
        if (cmo_q) begin
          // drop a hit line that needs no write-back (inval, or flush of a clean line)
          twd = {(TW + 2) {1'b0}};
          twe = hit & ((cmo_op_q == CMO_INVAL) | ((cmo_op_q == CMO_FLUSH) & !t_dirty));
        end else if (hit & i_we) begin
          dwe = i_sel;                    // write hit: bytes + mark dirty
          twe = 1'b1;
        end
      S_WB_PRE:  daddr = {idx, 3'd0};
      S_WB_GO: begin
        daddr     = {idx, 3'd0};          // hold word 0 on dq while waiting
        o_req     = 1'b1;
        o_req_we  = 1'b1;
        o_req_adr = {victim_tag, idx, 3'd0};
        if (i_gnt) begin
          o_wmask = 4'b0000;
          daddr   = {idx, 3'd1};          // beat 0 is on dq now, prefetch beat 1
        end
      end
      S_WB_BURST: begin
        daddr   = {idx, beat + 3'd1};
        o_wmask = 4'b0000;
      end
      S_FILL_CMD: begin
        o_req     = 1'b1;
        o_req_adr = {fill_tag, idx, 3'd0};
      end
      S_UNC_CMD: begin
        o_req     = !cmo_q;                // a CMO on the uncached alias: no command
        o_req_we  = unc_we;
        o_req_adr = unc_adr;
        if (i_gnt & unc_we) o_wmask = ~unc_sel;
      end
      S_CMO_END: begin                    // after the write-back: clean keeps the line
        taddr = idx;
        twd   = {cmo_op_q == CMO_CLEAN, 1'b0, victim_tag};
        twe   = 1'b1;
      end
      S_FILL_DATA: begin
        daddr = {idx, beat};
        dwd   = rd_data;
        if (rd_valid) dwe = 4'b1111;
        taddr = idx;
        twd   = {1'b1, 1'b0, fill_tag};
        twe   = rd_valid & (beat == 3'd7);
      end
      default: ;
    endcase
  end

  always @(posedge i_clk) begin
    o_ack <= 1'b0;

    case (state)
      // a request still held in the cycle after its ack is not a new one
      S_IDLE, S_RELOOKUP:
        if (i_cyc & !o_ack) begin
          state    <= i_unc ? S_UNC_CMD : S_LOOKUP;
          cmo_q    <= i_cmo;
          cmo_op_q <= i_cmo_op;
          unc_adr <= i_adr[22:2];
          unc_dat <= i_dat;
          unc_sel <= i_sel;
          unc_we  <= i_we;
        end
      S_LOOKUP:
        if (cmo_q) begin
          idx        <= cpu_idx;
          victim_tag <= t_tag;
          if (hit & t_dirty & (cmo_op_q != CMO_INVAL)) begin
            o_writebacks <= o_writebacks + 32'd1;
            cmo_wb       <= 1'b1;
            state        <= S_WB_PRE;
          end else begin
            o_ack <= 1'b1;
            state <= S_IDLE;
          end
        end else if (hit) begin
          o_rdt  <= dq;
          o_ack  <= 1'b1;
          o_hits <= o_hits + 32'd1;
          state  <= S_IDLE;
        end else begin
          idx        <= cpu_idx;
          victim_tag <= t_tag;
          fill_tag   <= cpu_tag;
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
        if (beat == 3'd7) state <= cmo_wb ? S_CMO_END : S_FILL_CMD;
      end
      S_CMO_END: begin
        cmo_wb <= 1'b0;
        o_ack  <= 1'b1;
        state  <= S_IDLE;
      end
      S_FILL_CMD:
        if (issue) begin
          beat  <= 3'd0;
          state <= S_FILL_DATA;
        end
      S_FILL_DATA:
        if (rd_valid) begin
          beat <= beat + 3'd1;
          if (beat == 3'd7) state <= S_RELOOKUP;
        end
      S_UNC_CMD:
        if (cmo_q) begin                  // nothing cached behind the uncached alias
          o_ack <= 1'b1;
          state <= S_IDLE;
        end else if (issue) begin
          if (unc_we) begin
            o_ack <= 1'b1;                // posted write
            state <= S_IDLE;
          end else state <= S_UNC_DATA;
        end
      S_UNC_DATA:
        if (rd_valid) begin
          o_rdt <= rd_data;
          o_ack <= 1'b1;
          beat  <= 3'd1;
          state <= S_UNC_DRAIN;
        end
      S_UNC_DRAIN:                        // the other seven beats of the burst
        if (rd_valid) begin
          beat <= beat + 3'd1;
          if (beat == 3'd7) state <= S_IDLE;
        end
      default: state <= S_IDLE;
    endcase

    if (i_rst) begin
      state        <= S_IDLE;
      o_ack        <= 1'b0;
      cmo_wb       <= 1'b0;
      o_hits       <= 32'd0;
      o_misses     <= 32'd0;
      o_writebacks <= 32'd0;
    end
  end

endmodule

`default_nettype wire
