# A self-written PSRAM controller (probe)

The SoC reaches its 8 MB of PSRAM through Gowin's "PSRAM Memory Interface HS 2CH" IP, a
generated netlist that this machine cannot regenerate. It costs about 1,180 LUTs, and it has
a band of memory clocks (77.6–81 MHz) where it never calibrates (CLAUDE.md, "PSRAM IP").
This document is about its replacement candidate: `rtl/psram/hyperram_x16.v`, tested so far
on its own in a CPU-less probe (`fpga/probe_psram16/`), not in the SoC.

## Design

- **Both dies in lockstep as one 16-bit DDR bus.** Die 0 is on DQ[7:0], die 1 on DQ[15:8].
  At a 42 MHz CK that moves 32 bits per clock, the cache's beat today, so a 32-byte line is
  one 8-beat burst.
- **1:1 clocking, no calibration.**
  - Everything leaves through `ODDR` cells on the fabric clock.
  - CK leaves through an `ODDR` on the same clock delayed by the rPLL's `CLKOUTP` phase.
  - Reads come back through `IDDR` cells on the fabric clock.
  - At 42 MHz the data eye is wide enough for a fixed phase (measured below).
- **Read words are found from RWDS, not counted.** The die drives RWDS High with the first
  byte of each word and Low with the second. A word can sit in one `IDDR` cycle or straddle
  two, depending on the phase, and both are handled.
- **Fixed latency**, CR0 = `0x8FEF`:
  - initial latency 3 (2 × 3 clocks, since it is fixed);
  - legacy wrapped bursts, 32 bytes;
  - drive strength 34 Ω.

  A read or write is 3 clocks of command, 5 of latency, then 8 of data. Data starts on clock 9.
- **Interface (probe version):**
  - one 32-byte line per request;
  - write beats are requested one cycle ahead;
  - read words come out per die, then `o_rdone`.

## What the board showed (2026-11-11)

| finding | detail |
|---|---|
| CR0 address | `CA[24]` (as zf3's controller and the W957 datasheet). A write with `CA[16]` (takayuki-nagata's model) has no effect: the dies keep their default 2 × 6 latency. Our copy of that model (`verif/psram16/model/`) is patched. |
| die 0's clock | true clock on `O_psram_ck[0]`. Its two pins (IOL8A, IOL7A) are **not** a differential pair: each gets its own `ODDR`. An `ELVDS_OBUF` there made the placer move the pair to package pins 85/86, and die 0 got no clock. |
| die 1's clock | true clock on `O_psram_ck_n[1]` (IOL23B), as `verif/psram/NOTES.md` read from the Gowin netlist; the pair is driven through `ELVDS_OBUF`. Driving `O_psram_ck[1]` as the true clock (as some open designs do) fails every read. |
| drive strength | 34 Ω and 115 Ω behaved the same. |
| CK phase window | 22.5° to 157.5° pass, 0° fails: CK edges on the data transitions, so even the CR0 write is lost. 90° is the middle and the probe's default. The die model's worst-case tCKD (5.5 ns) puts the edge near 95°; the real dies are faster. |
| result | at every phase in the window, both dies: the whole 8 MB written from a 32-bit LFSR and read back, then again inverted. 524,288 reads per die: no wrong word, no short read. First read word on bus cycle 13 (matches simulation). |

Resources of the controller alone are not measured yet. The probe (controller, test
sequencer, report formatter, trace) is about half the chip, mostly the formatter.

## Running it

```sh
verif/psram16/run.sh                        # simulation: probe + two W955D8MBYA die models
PHASES="1.488 5.952" verif/psram16/run.sh   # other CK phases (ns at 42 MHz)
fpga/probe_psram16/run.sh [PSDA] [SECONDS]  # build, load into SRAM, print the result lines
```

- The simulation needs Gowin's primitive models (`$GOWIN_PATH/IDE/simlib/gw1n/prim_sim.v`), so
  it is not in `scripts/ci.sh`.
- The die model is takayuki-nagata/psram_controller's (MIT, `verif/psram16/model/LICENSE`),
  with the CR0 address change.
- In simulation the model returns correct data with either CK polarity and only logs protocol
  errors, so the polarity question needed the board.
- The probe prints its lines once every 2 s. Twice the board's USB-UART bridge stopped
  delivering anything after probe runs that streamed continuously. Once it has locked up,
  only a USB replug brings it back.
- After a probe run, `openFPGALoader -b tangnano9k -r` (or a power cycle) brings back the flash
  design.

## Toward the SoC

Not done yet. What the integration needs:
- **One channel instead of two.** `psram_arb` keeps the video DMA's deadline logic, but with a
  single channel and a ready signal instead of the 19-cycle command spacing.
- **Overlapping transactions.** The probe's controller is unpipelined: a read occupies about 27
  cycles, a write 20, including idle cycles it could overlap. The line fill the CPU waits for
  ends on bus cycle ~21 (data on cycles 8–15, plus the capture pipeline).
- **Byte masks** for the uncached alias's partial writes. The controller already takes
  `i_wmask` (RWDS as the write mask).
- **Clocking.** The SoC clock would come from the rPLL's `CLKOUT` (42 MHz) and CK from
  `CLKOUTP` at 90°. The PSRAM IP's CLKDIV, DLL and its 27 MHz calibration logic go away.
- **A new `rtl/sim/psram_ui_model.v`**, or the die models behind the real controller in the SoC
  simulation.
- **Re-verification:** `verif/cache`, `verif/video/run_sys.sh`, the SoC simulation, then the
  board.

Estimated gains: about 1,180 LUTs freed (74% → roughly 62% logic), no 15.6 ms calibration
and no IP-internal hold violations. A line fill takes about 18 cycles against 24 today. The
bandwidth is about 75–90 MB/s on one channel, against 2 × 70.7 MB/s today. Video needs
36.9 MB/s on average.
