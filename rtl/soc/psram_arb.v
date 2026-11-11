// PSRAM command arbiter (doc/psram_controller.md): the L1 cache and the video DMA share the
// 16-bit HyperRAM controller (rtl/psram/hyperram_x16.v), one 32-byte line per command.
//   C: the L1 cache (line fills, write-backs, uncached word accesses): reads and writes
//   D: the video DMA: reads only
//
// Grant (combinational, in the cycle a master asks): when the controller is ready and no
// command is waiting for it, the cache goes first; the DMA goes first while it flags
// i_d_urgent (its line deadline is near). The granted command is registered and taken by the
// controller in the next cycle, so a grant is at most one per controller command (18 cycles
// for a full line, 11 for a single-word write).
//
// Write data: the cache sends write beat k k cycles after the grant (beat 0 in the grant
// cycle). The beats go into an 8-entry buffer; the controller asks for them from 9 cycles
// after the grant on. i_wlast tells it where the last enabled beat is, so an uncached word
// write (beat 0 only, the other beats fully masked) ends after one beat.
//
// Read data: the controller returns 8 beats per read, in order; each read's beats go to the
// master that asked (a queue of owners: a read's beats can still arrive after the next
// command has started).
`default_nettype none

module psram_arb (
    input  wire        i_clk,
    input  wire        i_rst,
    // cache: byte address bits 22:2; a line burst is 32 B aligned
    input  wire        i_c_req,
    input  wire        i_c_we,
    input  wire [22:2] i_c_adr,
    output wire        o_c_gnt,
    input  wire [31:0] i_c_wdata,
    input  wire [ 3:0] i_c_wmask,         // 1 = byte not written
    output wire        o_c_rvalid,
    output wire [31:0] o_c_rdata,
    // video DMA (reads)
    input  wire        i_d_req,
    input  wire        i_d_urgent,
    input  wire [22:2] i_d_adr,
    output wire        o_d_gnt,
    output wire        o_d_rvalid,
    output wire [31:0] o_d_rdata,
    // the controller's command interface
    input  wire        i_ready,
    output reg         o_cmd_en,
    output reg         o_cmd_we,
    output reg  [22:2] o_cmd_adr,
    input  wire        i_wnext,
    input  wire [ 2:0] i_wbeat,
    output wire [31:0] o_wdata,
    output wire [ 3:0] o_wmask,
    output wire        o_wlast,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata
);
  wire free = i_ready & !o_cmd_en;
  assign o_c_gnt = i_c_req & free & !(i_d_req & i_d_urgent);
  assign o_d_gnt = i_d_req & free & !o_c_gnt;

  // ---------------------------------------------------------------- write beats
  reg  [31:0] wb [0:7];
  reg  [ 3:0] wm [0:7];
  reg  [ 2:0] wi;                         // next beat to store
  reg         wcap;                       // beats 1..7 still to come
  wire        wstore = (o_c_gnt & i_c_we) | wcap;
  wire [ 2:0] widx   = (o_c_gnt & i_c_we) ? 3'd0 : wi;
  assign o_wdata = wb[i_wbeat];
  assign o_wmask = wm[i_wbeat];
  // the last beat: no byte enabled in any later one
  reg wl;
  integer j;
  always @(*) begin
    wl = 1'b1;
    for (j = 0; j < 8; j = j + 1)
      if (j > i_wbeat && wm[j] != 4'hF) wl = 1'b0;
  end
  assign o_wlast = wl;

  // ---------------------------------------------------------------- read owners
  reg  [3:0] own;                         // own[i]: read i (oldest first) is the DMA's
  reg  [2:0] nown;                        // reads outstanding
  reg  [2:0] rbeat;
  wire       rd_push = (o_c_gnt & !i_c_we) | o_d_gnt;
  wire       rd_pop  = i_rvalid & (rbeat == 3'd7);
  assign o_c_rvalid = i_rvalid & !own[0];
  assign o_d_rvalid = i_rvalid & own[0];
  assign o_c_rdata  = i_rdata;
  assign o_d_rdata  = i_rdata;

  always @(posedge i_clk) begin
    // command register: taken by the controller in the cycle after the grant
    if (o_cmd_en & i_ready) o_cmd_en <= 1'b0;
    if (o_c_gnt | o_d_gnt) begin
      o_cmd_en  <= 1'b1;
      o_cmd_we  <= o_c_gnt & i_c_we;
      o_cmd_adr <= o_c_gnt ? i_c_adr : i_d_adr;
    end
    if (wstore) begin
      wb[widx] <= i_c_wdata;
      wm[widx] <= i_c_wmask;
      wi       <= widx + 3'd1;
      wcap     <= (widx != 3'd7);
    end
    if (i_rvalid) rbeat <= rbeat + 3'd1;
    // owner queue: pop the head after its 8th beat, push at the grant
    begin : q
      reg [3:0] o;
      reg [2:0] n;
      o = own; n = nown;
      if (rd_pop) begin o = {1'b0, o[3:1]}; n = n - 3'd1; end
      if (rd_push) begin o[n[1:0]] = o_d_gnt; n = n + 3'd1; end
      own  <= o;
      nown <= n;
    end
    if (i_rst) begin
      o_cmd_en <= 1'b0;
      wcap     <= 1'b0;
      wi       <= 3'd0;
      own      <= 4'd0;
      nown     <= 3'd0;
      rbeat    <= 3'd0;
    end
  end

endmodule

`default_nettype wire
