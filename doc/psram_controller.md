# The 16-bit PSRAM controller

The SoC reaches its 8 MB of PSRAM through `rtl/psram/hyperram_x16.v`, a controller written for
this project. Until 2026-11 it went through Gowin's "PSRAM Memory Interface HS 2CH" IP, which
had four problems:
- it was a generated netlist that this machine cannot regenerate (IP generation fails on the
  license);
- it cost about 1,180 LUTs;
- it had a band of memory clocks (77.6–81 MHz) where it never calibrated, likely because the
  netlist was generated for 135 MHz;
- its calibration took 15.6 ms after every reset, and it carried three IP-internal hold
  violations.

The IP's netlist stays in `fpga/src/psram_memory_interface_hs_2ch/` for the calibration probe
`fpga/probe/`; its user-side model `rtl/sim/psram_ui_model.v` and the tests in `verif/psram/`
are kept as a record.

## Design

- **Both dies in lockstep as one 16-bit DDR bus.** Die 0 is on DQ[7:0], die 1 on DQ[15:8].
  At CK = 42 MHz that moves 32 bits per clock, the cache's beat, so a 32-byte line is one
  8-beat burst. Both dies get the same command-address: the host word index `addr[22:2]`.
- **1:1 clocking, no calibration.**
  - The rPLL makes the SoC clock (`CLKOUT`, 42 MHz) and the same clock 90° later
    (`CLKOUTP`).
  - CS#, DQ, RWDS and their output enables leave through `ODDR` cells on the SoC clock.
  - CK leaves through an `ODDR` on the delayed clock, so its edges fall inside the data
    eyes. Its inputs come from falling-edge registers: an `ODDR` on the delayed clock samples
    them T/2 + phase after the SoC clock's edge, not a cycle early.
  - Reads come back through `IDDR` cells on the SoC clock.
- **Fixed latency**, CR0 = `0x8FEE`:
  - initial latency 3 (2 × 3 clocks, since it is fixed);
  - legacy wrapped bursts of 16 bytes per die, so 32 bytes in all: a burst wraps inside the
    line from the addressed word, and an uncached word read gets its word as beat 0;
  - drive strength 34 Ω.
- **Bus timing** (bus cycles from the command's first):

  | cycles | what |
  |---|---|
  | 0–2 | CS# Low, the 48-bit command-address, 2 bytes per die and cycle |
  | 3–7 | latency; a write drives RWDS Low from cycle 7 (the preamble) |
  | 8–15 | data, one 16-bit word per die and cycle |
  | 16–17 | CS# High, CK stopped (tRWR 36 ns) |

  A full line takes 18 cycles. A write ends after the beat flagged `i_wlast`, so an uncached
  word write takes 11. The CR0 write at init has zero latency: its data is cycle 3.
- **Read words are found from RWDS, not counted.** The die drives RWDS High with the first
  byte of each word and Low with the second. A word sits in one `IDDR` cycle or straddles
  two, depending on the phase, and both are handled.
  - Each die is captured into its own 8-word FIFO, and a beat leaves when both hold a word.
  - Capture is armed from bus cycle 8 for a 16-cycle window. A die that has not delivered 8
    words by then gets filler words with `o_rerr` set, so a reader never waits forever.
  - The SoC counts fillers in SYSCON word 2; it should stay 0.

## Interface

| signal | meaning |
|---|---|
| `o_init_done` | RESET# pulsed and CR0 written, ~0.2 ms after reset (`INIT_US` = 160) |
| `o_ready` | a command is taken this cycle: `i_cmd_en`, `i_cmd_we`, `i_addr[22:2]` (a word) |
| `o_wnext`, `o_wbeat` | write beat k is asked for one cycle ahead; `i_wdata`, `i_wmask` (1 = byte not written) and `i_wlast` are read in that cycle |
| `o_rvalid`, `o_rdata`, `o_rerr` | a read's 8 beats in order, {die 1 word, die 0 word}; beat k comes 16 + k cycles after the command, and may still be arriving when the next command starts |
| `o_rlat0/1`, `o_ralign`, `o_dbg_*` | diagnostics: the bus cycle of each die's first word in the last read, its alignment, the raw `IDDR` samples |

## In the SoC

- **`rtl/soc/psram_arb.v`** shares the controller between the L1 cache and the video DMA.
  - It grants a master in the cycle it asks, when the controller is ready and no command is
    waiting. The cache goes first; the DMA goes first while it flags its line deadline as
    near.
  - The granted command is registered and taken by the controller in the next cycle.
  - Write beats go into an 8-entry buffer: the cache sends beat k k cycles after the grant,
    and the controller asks for it from cycle 9 on. `o_wlast` marks the last beat with an
    enabled byte.
  - A queue of owners routes each read's beats to the master that asked.
- **`rtl/video/video_dma.v`** paces itself with `TBURST` = 18 cycles per burst and asks for
  priority once the time left no longer covers its remaining bursts plus `MARGIN` = 66
  cycles (a CPU command already running, the last read's data, the synchronizers).
- **`fpga/src/tang9k_top.v`** instantiates the controller with CR0 `0x8FEE` and the clock
  wiring below. LED 2 shows `o_init_done`.
- **SYSCON status words** (`soc_top.v`): 0 = {init, init} (3 when ready), 1 = commands taken,
  2 = read beats with a filler word, 3 = read beats, 5 = cache misses, 6 = write-backs.
- **Constraints** (`fpga/src/tang9k_soc.sdc`): `cpu_clk` on net `clk` and `ck_clk` on
  `clk_p`, 90° later, with a 1.5 ns setup guard band on cpu_clk's paths (see CLAUDE.md,
  "Timing").

## Verification

- **`verif/psram16/run.sh`** (~20 s, in `scripts/ci.sh units`), in Icarus, without a Gowin
  install (`rtl/sim/gowin_io_sim.v` stands in for `ODDR`/`IDDR`/`ELVDS_OBUF`; `PRIM=gowin`
  uses Gowin's own models):
  - `tb_hyperram.v`: random line and word writes with masks and reads from any word of a
    line, against two W955D8MBYA die models with protocol checkers, per CK phase (45° and
    90°) and seed. Every beat is checked, and no beat may be a filler.
  - The same traffic on the cycle model, which must take exactly as many cycles as the
    controller.
  - `tb_psram16.v`: the board probe's memory test on 64 lines.
- **`rtl/sim/hyperram_x16_model.v`** is the controller's command interface as a cycle model,
  with 8 MB of memory. The cache, video and SoC simulations run against it. It also has a
  backdoor and the `+psram_load0/1 +psram_addr0/1` loader.
- The die model is takayuki-nagata/psram_controller's (MIT, `verif/psram16/model/LICENSE`),
  with the CR0 address fixed (below). Its datasheet limits bound the phase window more
  tightly than the board: tCSS (2 ns, CS# to the first CK edge, which comes one phase after
  CS# falls) needs at least 30°, and its worst-case tCKD (5.5 ns) fails beyond ~95°.

## What the board showed

The probe `fpga/probe_psram16/` (no CPU) settled the pin-level questions on 2026-11-11, with
the controller's first version (separate per-die read ports):

| finding | detail |
|---|---|
| CR0 address | `CA[24]` (as zf3's controller and the W957 datasheet). A write with `CA[16]` (takayuki-nagata's model) has no effect: the dies keep their default 2 × 6 latency. Our copy of that model is patched. |
| die 0's clock | true clock on `O_psram_ck[0]`. Its two pins (IOL8A, IOL7A) are **not** a differential pair: each gets its own `ODDR`. An `ELVDS_OBUF` there made the placer move the pair to package pins 85/86, and die 0 got no clock. |
| die 1's clock | true clock on `O_psram_ck_n[1]` (IOL23B), as `verif/psram/NOTES.md` read from the Gowin netlist; the pair is driven through `ELVDS_OBUF`. Driving `O_psram_ck[1]` as the true clock (as some open designs do) fails every read. |
| drive strength | 34 Ω and 115 Ω behaved the same. |
| CK phase window | 22.5° to 157.5° pass, 0° fails: CK edges on the data transitions, so even the CR0 write is lost. 90° is the middle and the default. |
| result | at every phase in the window, both dies: the whole 8 MB written from a 32-bit LFSR and read back, then again inverted. 524,288 reads per die: no wrong word, no short read. First read word on bus cycle 13 (matches simulation). |

## Running the probe

```sh
fpga/probe_psram16/run.sh [PSDA] [SECONDS]  # build, load into SRAM, print the result line
BUILD_ONLY=1 fpga/probe_psram16/run.sh      # build only
```

- The probe now uses the SoC's interface and configuration. It writes the whole 8 MB in line
  commands, reads it back with the reads issued back to back, then repeats inverted. It
  prints wrong words and fillers per die, the first error and the cycle count (18 per
  command), once every 2 s.
- Twice the board's USB-UART bridge stopped delivering anything after probe runs that
  streamed continuously. Once it has locked up, only a USB replug brings it back.
- After a probe run, `openFPGALoader -b tangnano9k -r` (or a power cycle) brings back the flash
  design.

## Cost and throughput

- **Logic:** the SoC (stage 2, video, text mode, I2C, SD) went from 6,352 to 5,584 logic
  (74% → 65%); the controller and the arbiter's write buffer took back about 400 of the IP's
  ~1,180.
- **Bandwidth:** one 32-byte line per 18 cycles, 74.7 MB/s at 42 MHz, shared by the CPU and
  video. The IP had two channels of 70.7 MB/s. Scan-out needs 36.9 MB/s on average, 720 of
  every 1,333 cycles during a line.
- **Latency:** a line fill's first beat comes 17 cycles after the cache's grant (one cycle in
  the arbiter's register).
- **Simulation:** `verif/video/run_sys.sh` (worst-case CPU traffic under scan-out) has no
  underflow, with a minimum deadline slack of 17 cycles; `verif/cache/run.sh` measures the
  DMA at 33.6 cycles per burst under random CPU traffic.
