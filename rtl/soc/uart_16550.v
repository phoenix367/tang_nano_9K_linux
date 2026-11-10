// Minimal 16550-compatible UART for the QERV SoC (Linux 8250 driver, DT "ns16550a",
// reg-shift 0, reg-io-width 1). o_irq goes to the PLIC (source 1); without it (stage 1, the
// boot ROM) the driver polls.
//
// Registers at byte offsets 0..7 (DLAB = LCR[7] maps 0/1 to DLL/DLM):
//   0 RBR (read) / THR (write)   1 IER   2 IIR (read) / FCR (write)   3 LCR
//   4 MCR   5 LSR   6 MSR   7 SCR
// 2^FIFO_L2-byte TX and RX FIFOs in block RAM (DT fifo-size: the driver writes up to that
// many bytes per THRE; a deep RX FIFO rides out the interrupt latency). The baud
// rate is fixed by CLKS_PER_BIT; DLL/DLM are storage only. 8N1 framing. IER, LCR, MCR, SCR
// are read/write storage; MSR reports CTS/DSR/DCD asserted. Bus: Wishbone classic, byte
// accesses, registered ack.
//
// Interrupt sources, by priority, gated by IER like a real 16550 and level-sensitive (each
// holds while its condition does): receiver line status (0x06) when IER[2] and an overrun is
// pending, received data (0x04) when IER[0] and the RX FIFO is not empty, THR empty (0x02)
// when IER[1] and the TX FIFO is empty; else 0x01. o_irq (registered) is any of them. IIR
// reports them whether or not the line is used: the polled 8250 driver calls its handler
// from a timer, and that handler returns at once if IIR says "no interrupt". Bits 7:6
// follow FCR[0] (FIFOs enabled).
`default_nettype none

module uart_16550 #(
    parameter CLKS_PER_BIT = 27,  // e.g. 27 MHz / 1 Mbaud
    parameter FIFO_L2      = 8    // 256-byte FIFOs
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [ 2:2] i_adr,
    input  wire [31:0] i_dat,
    input  wire [ 3:0] i_sel,
    input  wire        i_we,
    input  wire        i_cyc,
    output reg  [31:0] o_rdt,
    output reg         o_ack,
    output reg         o_tx,
    input  wire        i_rx,
    output reg         o_irq,
    // simulation console tap: a byte written to THR
    output wire        o_tx_push,
    output wire [ 7:0] o_tx_byte
);

  // ---------------------------------------------------------------- bus decode
  wire [1:0] lane = i_sel[0] ? 2'd0 : i_sel[1] ? 2'd1 : i_sel[2] ? 2'd2 : 2'd3;
  wire [2:0] rsel = {i_adr[2], lane};
  wire [7:0] wbyte = i_dat[8*lane +: 8];
  wire       access = i_cyc & !o_ack;          // once per transaction (ack follows)
  wire       wr = access & i_we;
  wire       rd = access & !i_we;

  reg  [7:0] ier, lcr, mcr, scr, dll, dlm;
  reg        fifo_en;
  wire       dlab = lcr[7];

  localparam DEPTH = 1 << FIFO_L2;

  // ---------------------------------------------------------------- TX FIFO + serializer
  // Block RAM read one cycle late: tx_head = txf[tx_rp] as of the last cycle, valid once the
  // FIFO has not been empty for a cycle (tx_ready)
  reg  [7:0] txf[0:DEPTH-1];
  reg  [FIFO_L2:0] tx_wp, tx_rp;
  wire [FIFO_L2:0] tx_count = tx_wp - tx_rp;
  wire       tx_empty = tx_count == 0;
  wire       tx_full = tx_count == DEPTH;
  reg  [7:0] tx_head;
  reg        tx_ready;

  assign o_tx_push = wr & (rsel == 3'd0) & !dlab & !tx_full;
  assign o_tx_byte = wbyte;

  reg  [9:0] tx_shift;
  reg  [3:0] tx_bits;                           // bits left to send, 0 = idle
  reg [15:0] tx_div;
  wire       tx_idle = tx_bits == 4'd0;

  always @(posedge i_clk) begin
    if (o_tx_push) begin
      txf[tx_wp[FIFO_L2-1:0]] <= wbyte;
      tx_wp <= tx_wp + 1'b1;
    end
    tx_head  <= txf[tx_rp[FIFO_L2-1:0]];
    tx_ready <= !tx_empty;
    if (tx_idle) begin
      o_tx <= 1'b1;
      if (!tx_empty & tx_ready) begin
        tx_shift <= {1'b1, tx_head, 1'b0};
        tx_rp    <= tx_rp + 1'b1;
        tx_bits  <= 4'd10;
        tx_div   <= 16'd0;
      end
    end else begin
      o_tx <= tx_shift[0];
      if (tx_div == CLKS_PER_BIT - 1) begin
        tx_div   <= 16'd0;
        tx_shift <= {1'b1, tx_shift[9:1]};
        tx_bits  <= tx_bits - 4'd1;
      end else
        tx_div <= tx_div + 16'd1;
    end
    if (wr & (rsel == 3'd2) & i_dat[8*lane+2]) tx_rp <= tx_wp;   // FCR: clear TX FIFO
    if (i_rst) begin
      tx_wp    <= 0;
      tx_rp    <= 0;
      tx_bits  <= 4'd0;
      tx_ready <= 1'b0;
      o_tx     <= 1'b1;
    end
  end

  // ---------------------------------------------------------------- RX deserializer + FIFO
  reg  [2:0] rx_sync;
  wire       rx = rx_sync[2];
  // rx_head = rxf[rx_rp] one cycle late; the bus reads RBR many cycles after any change
  reg  [7:0] rxf[0:DEPTH-1];
  reg  [FIFO_L2:0] rx_wp, rx_rp;
  wire       rx_empty = rx_wp == rx_rp;
  wire       rx_full = (rx_wp - rx_rp) == DEPTH;
  reg  [7:0] rx_head;
  reg  [3:0] rx_bits;                           // 0 = waiting for a start bit
  reg [15:0] rx_div;
  reg  [7:0] rx_shift;
  reg        rx_overrun;

  wire       rx_pop = rd & (rsel == 3'd0) & !dlab & !rx_empty;

  always @(posedge i_clk) begin
    rx_sync <= {rx_sync[1:0], i_rx};
    if (rx_bits == 4'd0) begin
      if (!rx) begin                            // start bit: sample mid-bit from here
        rx_bits <= 4'd1;
        rx_div  <= 16'd0;
      end
    end else if (rx_div == ((rx_bits == 4'd1) ? (CLKS_PER_BIT / 2) : CLKS_PER_BIT) - 1) begin
      rx_div <= 16'd0;
      if (rx_bits == 4'd1) begin
        rx_bits <= rx ? 4'd0 : 4'd2;            // false start bit -> back to idle
      end else if (rx_bits == 4'd10) begin
        rx_bits <= 4'd0;
        if (rx) begin                           // valid stop bit
          if (rx_full) rx_overrun <= 1'b1;
          else begin
            rxf[rx_wp[FIFO_L2-1:0]] <= rx_shift;
            rx_wp <= rx_wp + 1'b1;
          end
        end
      end else begin
        rx_shift <= {rx, rx_shift[7:1]};
        rx_bits  <= rx_bits + 4'd1;
      end
    end else
      rx_div <= rx_div + 16'd1;

    rx_head <= rxf[rx_rp[FIFO_L2-1:0]];
    if (rx_pop) rx_rp <= rx_rp + 1'b1;
    if (wr & (rsel == 3'd2) & i_dat[8*lane+1]) rx_rp <= rx_wp;   // FCR: clear RX FIFO
    if (rd & (rsel == 3'd5)) rx_overrun <= 1'b0;
    if (i_rst) begin
      rx_sync    <= 3'b111;
      rx_bits    <= 4'd0;
      rx_wp      <= 0;
      rx_rp      <= 0;
      rx_overrun <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- registers
  wire [7:0] lsr = {1'b0, tx_empty & tx_idle, tx_empty, 3'b000, rx_overrun, !rx_empty};
  wire       irq_ls  = ier[2] & rx_overrun;
  wire       irq_rx  = ier[0] & !rx_empty;
  wire       irq_thr = ier[1] & tx_empty;
  wire [3:0] iid = irq_ls ? 4'h6 : irq_rx ? 4'h4 : irq_thr ? 4'h2 : 4'h1;
  reg  [7:0] rbyte;
  always @(*) begin
    case (rsel)
      3'd0: rbyte = dlab ? dll : rx_head;
      3'd1: rbyte = dlab ? dlm : ier;
      3'd2: rbyte = {fifo_en, fifo_en, 2'b00, iid};
      3'd3: rbyte = lcr;
      3'd4: rbyte = mcr;
      3'd5: rbyte = lsr;
      3'd6: rbyte = 8'hB0;
      default: rbyte = scr;
    endcase
  end

  always @(posedge i_clk) begin
    o_ack <= i_cyc & !o_ack;
    o_rdt <= {4{rbyte}};
    o_irq <= irq_ls | irq_rx | irq_thr;
    if (wr)
      case (rsel)
        3'd0: if (dlab) dll <= wbyte;
        3'd1: if (dlab) dlm <= wbyte; else ier <= wbyte;
        3'd2: fifo_en <= wbyte[0];
        3'd3: lcr <= wbyte;
        3'd4: mcr <= wbyte;
        3'd7: scr <= wbyte;
        default: ;
      endcase
    if (i_rst) begin
      o_ack   <= 1'b0;
      o_irq   <= 1'b0;
      ier     <= 8'd0;
      lcr     <= 8'd0;
      mcr     <= 8'd0;
      scr     <= 8'd0;
      fifo_en <= 1'b0;
    end
  end

endmodule

`default_nettype wire
