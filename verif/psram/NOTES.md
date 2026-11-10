# PSRAM user-interface model: how it was calibrated

`rtl/sim/psram_ui_model.v` models the user side of Gowin's "PSRAM Memory Interface HS 2ch"
IP (module `Video_frame_buffer` in `~/projects/tang_nano_9K_ov7670`). The IP config is
BURST_MODE=32, INITIAL_LATENCY=6, DQ_WIDTH=8, ADDR_WIDTH=21, MEMORY_CLK=135 and
MEMORY_TYPE=W955D8MBYA. The numbers below were measured by simulating the IP's
gate-level netlist (`psram_memory_interface_hs_2ch.vo`) in Icarus 12. That netlist is not
encrypted and uses only Gowin primitives. The bench uses `prim_sim.v` from Gowin
1.9.12.02 SP2 and two pin-level HyperRAM models.

## Results

Bench: `tb_psram_ip.v`, with the real netlist driving two `hyperram_model` pin models at
135 MHz `memory_clk` (pin-model read delay TCKD = 2.0 ns) and `psram_ui_model` on the same
`clk_out`. "Edge" means a `clk_out` rising edge. "Sampled at edge E" is what a
synchronous user sees at E.

| Item | Result | Source |
| --- | --- | --- |
| Init: `rst_n` release -> `init_calib0/1` | 1,055,888 edges = 15.64 ms; both channels on the same edge | measured |
| Init with TCKD 5.5 ns | 1,057,855 edges (15.67 ms): the final calibration steps depend on board delay | measured |
| `pll_lock` | Must be high: it gates the DLL and the start-up lock counter. `clk` must be a free-running reference (27 MHz in ov7670), not `clk_out` | netlist |
| Write beat alignment | Beat 0 is sampled with `cmd_en` (`cmd`=1); beats 1..7 on the next 7 edges | measured |
| `data_mask` | Bit L = 1: byte lane L (`wr_data[8L+7:8L]`) is NOT written. Sampled per beat, like the data | measured |
| Read latency | 16 edges from `cmd_en` (`cmd`=0) to the first `rd_data_valid`; 8 consecutive beats | measured |
| Read latency spread | Constant 16 on both channels: >300 reads, spacing 19..>100, both channels on the same or skewed edges | measured |
| Read latency vs board delay | 16 at TCKD 2.0 and 5.5 ns, with identical valid timing. The netlist starts `rd_data_valid` from command shift-register bit 13 or 14, chosen by the calibrated slip count (`ss[3]`). A board with a much larger round-trip delay could therefore settle on 15 or 17. TCKD 9.2/12.9 ns runs were started but had not finished when this was written. Drive the cache from `rd_data_valid`, not from a fixed count | measured / netlist |
| TCMD | 18 edges is the measured minimum for every combination (W-W, R-R, W-R, R-W). At 17 or less, transfers are lost or garbled (table below). Keep 19 (ov7670's value) as the rule | measured |
| Read after write, 19 edges, same line | Returns the new data | measured |
| Write after read, 19 edges, same line | The read returns the old data; the write lands | measured |
| Command while read data is still returning | Legal at >= TCMD. With latency 16 + 8 beats, a command 19 edges after a read overlaps its beats 3..7 | measured |
| Address | `addr` goes unchanged to the HyperRAM as the halfword address of a WRAPPED burst. CA[45]=0; CR0 burst length 32 B, legacy wrap | measured (CA on the pins) |
| Channels | Independent: same address on ch0/ch1 holds different data, and simultaneous commands work | measured |
| `cmd_en` before `init_calib` | Ignored by the IP (mux on `init_calib`) | netlist |

### Data mapping

- **Aligned burst at A** (A % 16 == 0): HyperRAM halfwords A..A+15.
  - Beat k = {hw[A+2k], hw[A+2k+1]}: `data[31:16]` = halfword A+2k and `data[15:0]` =
    A+2k+1.
  - The IP sends `data[31:24]` first on DQ, i.e. the upper byte of halfword A+2k.
  - Write then read at A returns the beats in order. A burst at A+16 is the next group and
    does not overlap.
- **Unaligned A:** the burst stays in group G = A & ~15 and wraps. Beat k =
  {hw[G + ((A+2k) & 15)], hw[G + ((A+2k+1) & 15)]}.
  - Odd A therefore mixes halves of two aligned beats. A read at 0x1001 returned
    {hw 0x1001, hw 0x1002}, ... and its last beat was {hw 0x100F, hw 0x1000}.
  - Unaligned writes rewrite the whole group, rotated the same way.
  - Verified on the pin model's memory and by read-back through the IP.
- **Model arrays:** `memN[i]` = beat (i & 7) of an aligned burst at addr = (i >> 3) << 4.
  So `memN[i][31:16]` = hw 2i and `memN[i][15:0]` = hw 2i+1.
- **Loader byte b of a channel:** `memN[b >> 2][8*(b & 3) +: 8]`. That is beat b[4:2],
  lane b[1:0] of a burst at {b[21:5], 4'b0}.

### Protocol violations

The real IP at TCKD 2.0 ns. Each pair was followed by legal read-back.

| Pair | Spacing 18 | 17 | 16 | 12 | 4 | 1 |
| --- | --- | --- | --- | --- | --- | --- |
| write, write | both OK | 2nd lost | 2nd lost | 1st corrupted, 2nd lost | 1st corrupted, 2nd lost | 1st lost, 2nd corrupted |
| read, read | both OK | 2nd garbled (X) | 2nd garbled | both bad | both garbled | - |
| write, read (same line) | OK | read garbled | | | | |
| read, write (same line) | OK | read OK; line afterwards WRONG | | | | |

"Garbled (X)" means the pin model saw a broken transaction and drove nothing, so the IP
captured undriven DQ. On hardware that would be arbitrary data. `rd_data_valid` still
pulses 8 times at +16, so nothing in the user interface signals the error. The model
reports every one of these as "closer than TCMD" (17 errors in P7). It does not
reproduce the corruption.

### Clock range (MEMORY_CLK)

- **Generator range:** the IP generator GUI labels the Memory Clock field "(50 - 250)"
  MHz. This is a string in `ipcore/PSRAM_HS_2CH/libPSRAM_HS_2CH.so`; `_V2` and
  `PSRAM_HS_V2` say the same, and the older `PSRAM_HS` says "(50 - 166)". "CLK Ratio" is
  fixed at 1:2.
  - So `memory_clk` 54-100 MHz (`clk_out` = CPU clock 27-50 MHz) is inside the accepted
    range. The IP has to be regenerated with that MEMORY_CLK.
  - The headless `gw_sh` IPFlow (`create_ipc`/`set_property`) does not support this
    deprecated IP, so the generator's own range check could not be exercised.
- **What was not verified:**
  - The GW1NR-9 DLL input-frequency range. The IP shifts CK by 90 degrees with
    DLL + IODELAY: 128 taps x 25 ps in the sim library, about 3.2 ns. A quarter period is
    2.5 ns at 100 MHz but 4.6 ns at 54 MHz, so at the low end the shift probably
    saturates.
  - The W955D8MBYA minimum clock (no datasheet offline).
  - Hardware behaviour.
- **Simulation of the 135 MHz netlist at other clocks:** runs at `memory_clk` 100 and 54 MHz were started (`verif/psram/tb_psram_ip.v` with `-DMCLK_HALF=5.0` / `9.259`) but had not finished when this was written.
- **ov7670 precedent:** that design already runs user logic (VideoController, the
  FrameUploader/Downloader) directly on `clk_out`.


## Files

| File | What it is |
| --- | --- |
| `rtl/sim/psram_ui_model.v` | the model (Icarus and Verilator 5.020) |
| `verif/psram/hyperram_model.v` | pin-level HyperRAM die model used with the real IP |
| `verif/psram/tb_psram_ip.v` | real IP + 2 pin models + the model, same stimulus, per-edge compare |
| `verif/psram/tb_model_unit.v` | model-only unit test (loader/mapping, masks, wrap, protocol checks) |
| `verif/psram/run.sh` | fast checks (default) or the full real-IP run (`--ip`) |
| `verif/psram/golden/trace_ip.txt` | read beats recorded from the real IP, used for fast replay |
| `verif/psram/golden/ip_run.log` | log of the real-IP run the golden trace came from |

## Pin model (`hyperram_model.v`)

The ov7670 project's `sim/common/psram_model.sv` does not elaborate in Icarus 12 (it has a
function with an unpacked-array argument). It also ignores wrapped bursts, CR0 and RWDS
ownership, so a new model was written from the HyperBus protocol.

- **Command/address:** CA is 6 bytes on consecutive CK edges, starting on a rising edge.
  - CA[47] = read, CA[46] = register space, CA[45] = linear (1) / wrapped (0).
  - The halfword address is {CA[33:16], CA[2:0]}.
- **Register writes** have zero latency.
- **Memory data** starts `LAT_EDGES`=23 CK edges after the last CA edge (CK clock 14 after
  CS# falls). The read path drives DQ/RWDS `TCKD` after the CK edge.
- **Byte order:** the rising-edge byte is halfword[15:8]. On writes, RWDS=1 masks the
  byte.
- **Bursts:** wrapped bursts wrap inside the CR0 burst length. Legacy wrap wraps forever;
  hybrid wraps once.

Facts about the IP that the pin model had to match, all observed on the netlist's pins:

- **CR0 and latency:** the IP writes CR0 = 0x8F1F (latency 6, fixed 2x latency, legacy
  wrapped bursts, 32-byte burst length) and CR1 = 0x0040. It starts driving write data
  on CK clock 14 after CS# falls (edge 28). That is 2 x 6 clocks counted from the third CA
  clock, so `LAT_EDGES` = 23 is taken from the IP itself, not from a datasheet.
- **RWDS:** the IP never reads RWDS (the input buffer output is unconnected). It relies on
  fixed latency and a read-capture calibration.
- **Channel 1 clock:** channel 1's CK is generated inverted (OSER4 `genclkneg` +
  ELVDS_OBUF). The die's true CK is the IP pin `O_psram_ck_n[1]`, and the bench wires it
  that way.
- **Calibration sequence:**
  - Writes the pattern [0, 0x55AA33CC, 0, 0xACD6E3D9, 0, 0, 0, 0] to halfword 0. The CA is
    0x1FFC0000FFF8: unused and reserved CA bits are driven to 1.
  - Then sweeps 32 IODELAY settings x 16 IDES4 bit-slip steps, doing 31 reads per step and
    comparing on `rd_data_valid`.
  - Programs the chosen setting and does a final 31-read check. Only then does
    `init_calib` rise.

## What the netlist shows about the command path

These were read off the netlist with a small LUT-expression extractor; they explain the
simulation results.

- **No interlock on commands.** The user `cmd_en0`/`cmd0` go straight into a mux with the
  calibration engine's command. The mux selects on `init_calib0`. Its output starts
  fixed-length shift-register sequencers (`shift_burst128_w/_r`) and loads the CA
  register.
  - There is no busy flag and no ready output.
  - A second command inside the window of the first restarts or overlaps the sequencers
    and overwrites the CA. That is why TCMD exists (see the P7 results).
  - A `cmd_en` before `init_calib` is ignored by the IP. The model reports it as an
    error.
  - `cmd_en`/`cmd`/`addr` are used without an input register, so drive them from flops.
- **Write data buffer.** Write data goes into an 8-entry RAM16SDP4 buffer (32 data + 4
  mask bits, 9 RAM16SDP4 per channel) on `clk_out`. The OSER4s serialize it later.
- **Clocks and reset:**
  - The IP's `clk` input clocks only the start-up synchronizer (`u_psram_sync`: a 16-bit
    lock counter on `pll_lock & dll_lock`, then the DLL/DHCEN/CLKDIV reset sequence). It
    must be a free-running clock that does not come from `clk_out`. The ov7670 design
    uses the 27 MHz system clock.
  - `pll_lock` gates the DLL (`STOP = !pll_lock`) and the lock counter, so nothing
    proceeds until `pll_lock` is high.
  - `clk_out` = CLKDIV/2 of a DHCEN-gated `memory_clk`. It runs from time 0, before
    `rst_n` and before `pll_lock`.
  - During the sync sequence `clk_out` stops once, for ~0.46 us (one 459 ns period instead
    of 14.8 ns). That happens 624 us after `rst_n` with a 27 MHz `clk`. No runt pulses
    were seen. Hold a CPU clocked by `clk_out` in reset until `init_calib`.

## Init timeline (27 MHz `clk`, 135 MHz `memory_clk`, `pll_lock` before `rst_n`)

| t after rst_n | event |
| --- | --- |
| 16 us | DLL lock (sim model, DIV_SEL=1 fast lock) |
| 622 us | lock counter (on `clk`) done; clock/IO sync, `clk_out` pauses ~0.46 us |
| 624 us | O_psram_reset_n released |
| 1.11 ms | CR0/CR1 written (after a 2^15 `clk_out` tVCS wait) |
| 1.11 - 15.6 ms | read calibration sweep (32 delays x 16 slips x 31 reads) |
| ~15.64 ms | init_calib0 and init_calib1 rise together |


