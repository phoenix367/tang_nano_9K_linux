// SV32 MMU for the stage-2 QERV CPU (doc/stage2_plan.md). Sits between the core's virtual
// ibus/dbus and the physical buses (dbus then goes through amo_unit).
//
// Translation: when satp.MODE = 1 and the hart is in S or U (M is never translated; no MPRV).
//
// TLB: direct-mapped, 2^TLB_L2 entries in one RAM (block RAM), the upper half for data
// accesses and the lower half for fetches so code and data do not evict each other.
//   entry = {valid, tag = VPN[19:IW], PPN[19:0], D, U, X, W, R}
// A megapage leaf is stored as the 4 KB page that was touched. An entry is only filled from a
// valid leaf with A = 1; permissions are checked on every lookup, so SUM, MXR and the
// privilege can change without a flush.
//
// Page-table walk: up to two word reads on the physical dbus (through the L1 cache). Svade:
// the walker never writes a PTE. A = 0, or a store/AMO to a page with D = 0, is a page fault
// and Linux sets the bits itself.
//
// Faults are reported with the core's bus ack: o_ibus_fault (instruction page fault) or
// o_dbus_fault + o_dbus_fault_we (load page fault / store-AMO page fault). LR is a load, SC
// and the other AMOs are stores.
//
// sfence.vma (any operands) clears the whole TLB by sweeping it (2^TLB_L2 cycles); requests
// wait meanwhile.
//
// Timing: untranslated accesses pass straight through. A translated access spends one
// cycle in IDLE (TLB read) and one in LOOK (tag and permission check), then issues the
// physical request from ACC with the registered PPN; a fetched PTE is registered and
// checked in PCHK. Neither the TLB compare nor the PTE check is in a combinational path to
// or from the bus (the SoC's address decode and read-data mux make that path long). After an ack
// the MMU waits (DONE) for the core to drop the request: after a faulting dbus ack SERV
// keeps dbus_cyc up for two more cycles (its trap stage first reads the RF), and that must
// not start a new lookup.
`default_nettype none

module sv32_mmu #(
    parameter TLB_L2 = 8
) (
    input  wire        i_clk,
    input  wire        i_rst,
    // from the core's CSRs
    input  wire [ 1:0] i_priv,
    input  wire        i_sum,
    input  wire        i_mxr,
    input  wire        i_satp_mode,
    input  wire [19:0] i_satp_ppn,
    input  wire        i_sfence,
    // core instruction bus (virtual)
    input  wire [31:0] i_ibus_adr,
    input  wire        i_ibus_cyc,
    output wire [31:0] o_ibus_rdt,
    output wire        o_ibus_ack,
    output wire        o_ibus_fault,
    // core data bus (virtual)
    input  wire [31:0] i_dbus_adr,
    input  wire [31:0] i_dbus_dat,
    input  wire [ 3:0] i_dbus_sel,
    input  wire        i_dbus_we,
    input  wire        i_dbus_cyc,
    input  wire        i_dbus_amo,
    input  wire [ 4:0] i_dbus_amo_op,
    output wire [31:0] o_dbus_rdt,
    output wire        o_dbus_ack,
    output wire        o_dbus_fault,
    output wire        o_dbus_fault_we,
    // physical instruction bus
    output wire [31:0] o_mibus_adr,
    output wire        o_mibus_cyc,
    input  wire [31:0] i_mibus_rdt,
    input  wire        i_mibus_ack,
    // physical data bus (also carries the page-table reads)
    output wire [31:0] o_mdbus_adr,
    output wire [31:0] o_mdbus_dat,
    output wire [ 3:0] o_mdbus_sel,
    output wire        o_mdbus_we,
    output wire        o_mdbus_cyc,
    output wire        o_mdbus_amo,
    output wire [ 4:0] o_mdbus_amo_op,
    input  wire [31:0] i_mdbus_rdt,
    input  wire        i_mdbus_ack
);

  localparam N  = 1 << TLB_L2;
  localparam IW = TLB_L2 - 1;              // VPN bits in the index
  localparam TW = 20 - IW;                 // tag bits
  localparam EW = 1 + TW + 20 + 5;

  localparam [3:0] S_IDLE = 4'd0, S_LOOK = 4'd1, S_ACC = 4'd2, S_FAULT = 4'd3,
                   S_WALK = 4'd4, S_FILL = 4'd5, S_SWEEP = 4'd6, S_DONE = 4'd7,
                   S_PCHK = 4'd8;

  reg  [3:0] st;
  reg  [31:0] p;                           // PTE being checked (PCHK)
  reg        lvl;                          // walk level: 1 (root) or 0
  reg  [19:0] next_ppn;                    // level-0 table (from the level-1 PTE)
  reg  [19:0] ppn_r;                       // physical page of the access in progress
  reg        sfence_pend;
  reg        req_d;                        // the translated request is on the dbus
  reg  [TLB_L2-1:0] scnt;
  reg  [EW-1:0] fill;

  // ---------------------------------------------------------------- request
  wire        is_d  = i_dbus_cyc;          // the core never drives both buses
  wire        req   = i_ibus_cyc | i_dbus_cyc;
  wire        xlate = i_satp_mode & !i_priv[1];
  // TLB read address in IDLE (from the live request); once accepted, everything else uses
  // the latched bus (req_d), which keeps the core's dbus_cyc decode out of those paths
  wire [31:0] va_i  = is_d ? i_dbus_adr : i_ibus_adr;
  wire [31:0] va    = req_d ? i_dbus_adr : i_ibus_adr;
  wire        is_lr = i_dbus_amo & (i_dbus_amo_op == 5'b00010);
  wire        is_st = req_d & i_dbus_we & !is_lr;
  wire [TLB_L2-1:0] idx = (st == S_IDLE) ? {is_d, va_i[12 +: IW]} : {req_d, va[12 +: IW]};
  wire [TW-1:0]     tag = va[31 -: TW];

  // ---------------------------------------------------------------- TLB RAM
  reg  [EW-1:0] tlb[0:N-1];
  reg  [EW-1:0] ent;
  wire          tlb_we = (st == S_FILL) | (st == S_SWEEP);
  wire [TLB_L2-1:0] tlb_wa = (st == S_SWEEP) ? scnt : idx;
  wire [EW-1:0]     tlb_wd = (st == S_SWEEP) ? {EW{1'b0}} : fill;
  always @(posedge i_clk) begin
    if (tlb_we) tlb[tlb_wa] <= tlb_wd;
    ent <= tlb[idx];
  end

  wire          e_v = ent[EW-1];
  wire [TW-1:0] e_tag = ent[EW-2 -: TW];
  wire [19:0]   e_ppn = ent[24:5];
  wire          e_d = ent[4], e_u = ent[3], e_x = ent[2], e_w = ent[1], e_r = ent[0];

  wire hit = e_v & (e_tag == tag);
  // U pages: U-mode only; S may load/store them with SUM, never execute them
  wire u_ok = !i_priv[0] ? e_u : (!e_u | (req_d & i_sum));
  wire rwx_ok = !req_d ? e_x : is_st ? (e_w & e_d) : (e_r | (i_mxr & e_x));
  wire perm_ok = u_ok & rwx_ok;

  // ---------------------------------------------------------------- walk
  wire        p_bad  = !p[0] | (!p[1] & p[2]);           // !V, or W without R
  wire        p_leaf = p[1] | p[3];                       // R or X
  wire        p_fault = p_bad | (p_leaf ? (!p[6] | (lvl & (p[19:10] != 10'd0))) : !lvl);
  wire [31:0] pte_adr = lvl ? {i_satp_ppn, va[31:22], 2'b00} : {next_ppn, va[21:12], 2'b00};
  wire        walk = st == S_WALK;

  always @(posedge i_clk) begin
    if (i_sfence) sfence_pend <= 1'b1;
    case (st)
      S_IDLE:
        if (sfence_pend) begin
          st <= S_SWEEP;
          scnt <= {TLB_L2{1'b0}};
        end else if (req & xlate) begin
          st <= S_LOOK;
          req_d <= is_d;
        end
      S_LOOK:
        if (!req) st <= S_IDLE;
        else if (hit) begin
          ppn_r <= e_ppn;
          st <= perm_ok ? S_ACC : S_FAULT;
        end else begin
          lvl <= 1'b1;
          st <= S_WALK;
        end
      S_ACC:
        if (req_d ? i_mdbus_ack : i_mibus_ack) st <= S_DONE;
      S_FAULT:
        st <= S_DONE;
      S_DONE:
        if (!req) st <= S_IDLE;
      S_WALK:
        if (i_mdbus_ack) begin
          p <= i_mdbus_rdt;
          st <= S_PCHK;
        end
      S_PCHK:
        if (p_fault) st <= S_FAULT;
        else if (!p_leaf) begin
          lvl <= 1'b0;
          next_ppn <= p[29:10];
          st <= S_WALK;
        end else begin
          fill <= {1'b1, tag, lvl ? {p[29:20], va[21:12]} : p[29:10], p[7], p[4], p[3], p[2], p[1]};
          st <= S_FILL;
        end
      S_FILL:
        st <= S_IDLE;                      // IDLE reads the new entry, then LOOK
      S_SWEEP: begin
        scnt <= scnt + 1'b1;
        if (&scnt) begin
          st <= S_IDLE;
          sfence_pend <= 1'b0;
        end
      end
      default: st <= S_IDLE;
    endcase
    if (i_rst) begin
      st <= S_SWEEP;                       // start with an empty TLB
      scnt <= {TLB_L2{1'b0}};
      sfence_pend <= 1'b0;
      lvl <= 1'b0;
      req_d <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- physical buses
  wire        pass = (st == S_IDLE) & !xlate & !sfence_pend;   // untranslated
  wire        acc  = st == S_ACC;

  assign o_mibus_cyc = (i_ibus_cyc & pass) | (acc & !req_d);
  assign o_mibus_adr = acc ? {ppn_r, i_ibus_adr[11:0]} : i_ibus_adr;

  assign o_mdbus_cyc    = walk | (i_dbus_cyc & pass) | (acc & req_d);
  assign o_mdbus_adr    = walk ? pte_adr : acc ? {ppn_r, i_dbus_adr[11:0]} : i_dbus_adr;
  assign o_mdbus_dat    = i_dbus_dat;
  assign o_mdbus_sel    = walk ? 4'hF : i_dbus_sel;
  assign o_mdbus_we     = !walk & i_dbus_we;
  assign o_mdbus_amo    = !walk & i_dbus_amo;
  assign o_mdbus_amo_op = i_dbus_amo_op;

  // ---------------------------------------------------------------- core buses
  wire fault = st == S_FAULT;
  assign o_ibus_rdt      = i_mibus_rdt;
  assign o_ibus_ack      = (i_mibus_ack & i_ibus_cyc) | (fault & !req_d);
  assign o_ibus_fault    = fault & !req_d;
  assign o_dbus_rdt      = i_mdbus_rdt;
  assign o_dbus_ack      = (i_mdbus_ack & !walk & i_dbus_cyc) | (fault & req_d);
  assign o_dbus_fault    = fault & req_d;
  assign o_dbus_fault_we = is_st;

endmodule

`default_nettype wire
