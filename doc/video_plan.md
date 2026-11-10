# Video plan: 640×480 RGB565 over HDMI

Status (2026-11-10): **V0-V2 work on the board.** HDMI colour bars, then a framebuffer
uploaded from the host and shown pixel-exact from PSRAM, then Linux (MMU kernel) with
`/dev/fb0` through simple-framebuffer. Stage 2 (SV32 Linux) is the base: QERV at 42 MHz,
16 KB cache, 8 MB PSRAM through the Gowin IP (see `doc/stage2_plan.md`). Progress and
results are below the plan.

## Goal and definition of done

A simple display controller that scans an RGB565 framebuffer in PSRAM out to the board's
HDMI connector at 640×480, 60 Hz (DVI signalling, which HDMI sinks accept).

Done means:
- A monitor shows a stable 640×480@60 picture from the framebuffer, pixel-exact against
  memory, with no underflows over minutes of CPU load.
- Linux (MMU kernel) exposes it as `/dev/fb0` (simple-framebuffer). Writes to it appear on
  screen.
- The boot time and free memory are measured against the current 12.0 s / 3,352 KB, and the
  42 MHz build still meets timing.

Out of scope: audio, HDMI data islands/InfoFrames, other modes, 2D acceleration, a
framebuffer console (option in V3).

## Fixed numbers

| Item | Value |
| --- | --- |
| Timing (CEA/VESA 640×480@60) | H 640 + 16 FP + 96 sync + 48 BP = 800; V 480 + 10 + 2 + 33 = 525; both syncs negative |
| Pixel clock | 25.2 MHz = 126 MHz / 5 (frame rate exactly 60.0 Hz; the nominal 25.175 is within monitor tolerance) |
| TMDS bit rate | 252 Mbit/s per lane: `OSER10` with FCLK 126 MHz (DDR), PCLK 25.2 MHz |
| Framebuffer | 640 × 480 × 2 B = 614,400 B (0x96000), stride 1280 B |
| Bandwidth | 1280 B per 31.75 µs line = 40 PSRAM bursts of 32 B; 36.9 MB/s average |
| PSRAM channel capacity | one 32 B burst per TCMD = 19 cycles at 42 MHz = 70.7 MB/s |
| Line fetch cost | 40 × 19 = 760 cycles of the 1,333-cycle line period: **57%** of one channel during active lines, 52% averaged over the frame |
| Fetch window (two line buffers) | from the end of line L−2's active part to the start of line L's: 960 pixel clocks = 1,600 CPU cycles, for 760 cycles of work |

HDMI pins (from litex-boards `sipeed_tang_nano_9k.py`, same as Sipeed's examples): clock
p/n 69/68, data0 71/70, data1 73/72, data2 75/74, as `ELVDS_OBUF` pairs with
`PULL_MODE=NONE`. **These pins are also the 40-pin RGB LCD connector's R/G lines** (the
ov7670 project drives its LCD on 68–75), so no LCD panel may be plugged in.

## Architecture

```
            42 MHz (SoC clock, PSRAM clk_out)                  |   25.2 MHz pixel / 126 MHz serial
                                                               |
 CPU ── MMU ── bus ─┬─ 0x8xxx_xxxx ── l1_cache ──┐             |
                    ├─ 0x9xxx_xxxx (uncached) ──┤ psram_arb ── PSRAM IP (2 channels)
                    └─ 0x1120_0000 video regs   │     ▲        |
                                                │     │ reads  |
                         video_dma (line fetch) ┘─────┘        |
                              │ 32-bit writes                  |
                              ▼                                |
                      2 line buffers (BSRAM, dual clock) ──────┼──► pixel pipe ─► 3× TMDS encode
                              ▲ line-done / line-ready toggles │      (RGB565→888)   ─► OSER10 ×3
                              └────────── CDC ─────────────────┼── video_timing      ─► ELVDS_OBUF ×4
```

### Clocks
- **Second rPLL** (`fpga/src/gowin_rpll/gowin_rpll_video.v`, hand-written like the first):
  27 MHz × 14 / 3 = 126 MHz (IDIV_SEL 2, FBDIV_SEL 13, ODIV_SEL 4 → VCO 504 MHz; check the
  VCO range in the datasheet). A `CLKDIV` (DIV_MODE "5") makes the 25.2 MHz pixel clock. The
  GW1NR-9 has two rPLLs; the PSRAM uses the first.
- **SDC:** the 126 MHz clock, the ÷5 generated clock, and `set_clock_groups -asynchronous`
  between them and `cpu_clk`.
- The pixel domain resets from the video PLL lock plus the synchronized system reset.

### Pixel side (25.2 MHz)
- `rtl/video/video_timing.v`: H/V counters, hsync/vsync, DE, line and frame start.
- **Pixel pipe:** reads the line buffer 16 bits per pixel and expands RGB565 to 888 by bit
  replication (`{r5, r5[4:2]}`, `{g6, g6[5:4]}`, `{b5, b5[4:2]}`). It outputs black when
  disabled and colour bars in test mode.
- `rtl/video/tmds_encoder.v`: DVI 1.0 8b/10b with DC balance; control symbols in blanking
  (hsync/vsync on lane 0). Lane 0 = blue, 1 = green, 2 = red.
- `rtl/video/hdmi_phy_gowin.v`: `OSER10` per lane plus `ELVDS_OBUF`. The TMDS clock goes out
  as the 1111100000 pattern through a fourth `OSER10`, or as the pixel clock itself as LiteX
  does.

### Memory side (42 MHz)
- `rtl/video/video_dma.v`:
  - On each synchronized "line done" toggle it fetches the next display line: 40 read
    bursts from `BASE + line × 1280` into the free line buffer. A "line ready" toggle goes
    back to the pixel side.
  - `BASE` is latched at frame start, so changing it pans or flips buffers without tearing.
  - Line buffers: two `SDPB` (port A 32-bit write at 42 MHz, port B 16-bit read at
    25.2 MHz), one per line (640 × 16 bit each).
- `rtl/soc/psram_arb.v` (new; between `l1_cache` and the IP):
  - It owns the per-channel TCMD counters and muxes the registered IP inputs. The 8-beat
    write stream needs no extra handling: TCMD (19) is longer than a burst.
  - It routes `rd_data_valid` beats to the master whose read is outstanding (a 2-deep owner
    queue per channel).
  - **Policy, CPU first with a deadline:** the DMA uses every slot the cache leaves free,
    and takes priority only when `bursts_left × 19 + margin ≥ cycles left in its window`.
    So a CPU miss waits at most one video burst (≤ 19 cycles) in the normal case, and the
    line still completes in the worst case. Round-robin alone guarantees only 42 slots per
    window for the 40 needed: too thin.
  - `l1_cache` keeps its FSM. Its `tcmd_ok` becomes a per-channel grant from the arbiter.
- **Uncached alias** in `l1_cache`:
  - `0x9000_0000`–`0x907F_FFFF` maps the same PSRAM with no lookup. A word write becomes one
    burst with only beat 0 enabled (`data_mask` from `sel`), acked when issued (posted). A
    read becomes one burst, taking beat 0.
  - The CPU (W=4 store ≈ 22 cycles) can't outrun TCMD (19), so single-word posted writes
    keep pace without write-combining.
  - The video DMA reads PSRAM directly, so the CPU must reach the framebuffer only through
    this alias. Linux's linear map must not cover it: reserved-memory `no-map`.
- **Registers** as SYSCON words 8-10 at `0x1110_0020` (built: syscon already registers its read
  data, so the SoC's read path, its critical one, gains nothing; the plan had `0x1120_0000`):

  | Offset | Name | Contents |
  | --- | --- | --- |
  | 0x20 | CTRL | bit 0 EN (scan the framebuffer; 0 = black), bit 1 TEST (colour bars). Reset value: TEST |
  | 0x24 | BASE | physical byte address of the framebuffer, 32 B aligned, in 0x8000_0000–0x807F_FFFF; taken at frame start |
  | 0x28 | STATUS | bit 0 vblank, bit 1 underflow (sticky, write 1 to clear), [31:16] frame counter |

  Sync runs from reset, so the monitor locks while the boot ROM is still at its prompt.
- **Build option:** `VIDEO=1 fpga/build.sh` (a `define` in `tang9k_cfg.v`, a `soc_top`
  parameter). That keeps a no-video build for A/B timing and boot-time comparisons.
  `sim/soc/run.sh` gets the same switch.

### Memory map and layout
- **Framebuffer:** `0x8070_0000`–`0x8079_5FFF`, in channel 1 (byte address bit 22). The
  CPU reaches it through the alias at `0x9070_0000`. It is clear of the kernel at
  `0x8000_0000`, the SBI page `0x807F_E000` (also the RNG noise page) and the DTB at
  `0x807F_F000`.
- **RAM cost:** Linux loses 600 KB of its 8 MB.

## Software

- **Boot ROM** (`sw/bootrom/bootrom.S`, 2,152 of 4,096 bytes used):
  - New command `v` <base>: enable scanout at base. Used for host-loaded test images.
  - Before entering a kernel (`b`, `B`, `f`, autoboot): clear the framebuffer through the
    alias (150K posted stores ≈ 0.2 s), then set BASE and CTRL = EN. simple-framebuffer
    expects the firmware to have set up the display.
- **Host:** `qerv_boot.py --fb IMAGE` converts to RGB565, loads it at `0x9070_0000` with
  `l`, and sends `v`. 600 KB at 1 Mbaud is ~6 s.
- **Linux (MMU kernel first):**
  - DT: a reserved-memory `framebuffer@80700000 { reg = <0x0 0x80700000 0x0 0x96000>;
    no-map; }`, plus a `simple-framebuffer` node with `reg = <0x0 0x90700000 0x0 0x96000>`,
    `width = <640>`, `height = <480>`, `stride = <1280>` and `format = "r5g6b5"`.
  - Kernel: `CONFIG_FB`, `CONFIG_FB_SIMPLE`, `CONFIG_FB_DEVICE` (fbdev simplefb, not DRM
    simpledrm, which is larger). `CONFIG_VT` stays off, so there is no framebuffer console
    and nothing on screen slows the boot.
  - busybox: `fbset` and `fbsplash`. Tests: `dd if=/dev/urandom of=/dev/fb0`, and
    `fbsplash -s` of a PPM in the rootfs overlay.
  - The no-MMU kernel can take the same nodes later. Its memory is the tighter one.

## Verification

- **Unit tests** (`verif/video/`, Icarus, Gowin `prim_sim.v` for `OSER10`/`ELVDS_OBUF`/`CLKDIV`):
  - TMDS encoder: random and corner bytes. A decoder in the TB must give the data back, the
    running disparity must stay bounded, and blanking must send the four control symbols.
  - Timing: counts, sync positions and polarity, DE.
  - PHY: deserialize the `OSER10` output in the TB and decode it. This catches D0…D9 order
    and p/n mistakes before the board.
  - DMA + arbiter + cache, with `rtl/sim/psram_ui_model.v` and two clocks at a 5:3 ratio
    with drift:
    - the cache's random-traffic test (`verif/cache/tb_cache.v`) still passes under
      continuous scanout;
    - the scanned pixels equal memory;
    - zero underflows under worst-case CPU traffic (back-to-back write-back misses on
      channel 1);
    - uncached reads and writes, including byte masks.
- **SoC sim** (Verilator):
  - A second clock in `sim_main.cpp` (1,260 MHz time base: 30 ticks per CPU cycle, 50 per
    pixel).
  - `+frame_dump=<file.ppm>` writes a frame from the pixel stream, before TMDS. That makes
    the boot ROM's bars and clear, and Linux's writes, visible in simulation.
  - Cycles to `~ #` with and without scanout give the CPU slowdown.
- **Regression:** riscv-tests, the directed tests and `verif/cache` must all stay green. The
  CPU itself is unchanged.
- **Board:**
  - The monitor OSD reports 640×480 60 Hz.
  - An image loaded with `--fb` matches its source.
  - STATUS underflow stays 0 through `m` (memtest) and a Linux boot.
  - Boot time against 12.0 s.

## Milestones

- **V0 HDMI colour bars, no memory:**
  - The rPLL, timing, TMDS, PHY, pins and SDC.
  - First a CPU-less probe (`fpga/probe_hdmi/`, like `fpga/probe`, builds in seconds) to
    prove the pins, PLL and monitor lock. Then into `tang9k_top` with `VIDEO=1`.
  - Done when: bars on the monitor; the SoC build places (second rPLL and `CLKDIV` beside
    the PSRAM IP's) and still meets 42 MHz; Linux boots as before.
- **V1 framebuffer scanout:**
  - `video_dma`, the line buffers, CDC, `psram_arb`, the uncached alias, the registers,
    ROM `v` and the clear-on-boot, and `qerv_boot.py --fb`.
  - Done when: an uploaded image shows pixel-exact; underflow stays 0; all sims and
    regressions pass; boot time measured. Expected cost: under ~2% (a CPU miss to channel 1
    waits ≤ 19 cycles while a video burst is in flight).
- **V2 Linux `/dev/fb0`:**
  - DT nodes, kernel config, busybox applets.
  - Done when: `dd`/`fbsplash` draw on screen from Linux; free memory and boot time are
    recorded.
- **V3 options**, each only if wanted, measured after V2:
  - Write-combining buffer on the alias (8 stores → 1 burst). It cuts channel occupancy for
    big framebuffer writes.
  - A framebuffer console: `CONFIG_VT`, fbcon, 8×16 font. Scrolling through uncached
    memory is ~0.1–0.2 s per scroll, so keep the boot console on ttyS0.
  - Hardware pan / double buffering through BASE, which needs a small fbdev driver
    instead of simplefb.
  - A 320×240 pixel-doubled mode: 150 KB, a quarter of the bandwidth.
  - Interleaving the PSRAM channels on address bit 5 instead of 22. This halves the video
    load per channel, if contention shows in the measurements.

## Budget (estimates)

| Block | LUT | FF | BSRAM |
| --- | --- | --- | --- |
| Timing generator | ~60 | ~25 | |
| TMDS encoders ×3 | ~250 | ~40 | |
| PHY | primitives: `OSER10` ×3–4, `ELVDS_OBUF` ×4, rPLL, `CLKDIV` | | |
| Pixel pipe + CDC | ~80 | ~60 | |
| Line buffers | ~30 | | 2 |
| Video DMA | ~100 | ~60 | |
| PSRAM arbiter (2 channels) | ~150 | ~110 | |
| Uncached alias in the cache | ~80 | ~10 | |
| Registers + decode | ~50 | ~60 | |
| **Total** | **~800** | **~370** | **2** |

Logic would go from 4,913 to ~5,700 of 8,640 (~66%), BSRAM from 14 to 16 of 26, rPLL to 2
of 2.

## Risks

- **42 MHz timing** has no slack today (Fmax 42.004 MHz). The arbiter's mux in front of the
  IP and the alias path add logic next to the cache.
  - Mitigation: register the arbiter's outputs (one more cycle per PSRAM command), and keep
    every video compare out of the CPU bus path (the MMU rule).
  - Fallback: memory_clk 76 MHz / CPU 38 MHz. It calibrates, but costs ~10% CPU.
- **Clock resources:** whether a second HCLK/`CLKDIV` for the `OSER10`s places beside the
  PSRAM IP's is unverified. V0's SoC build answers it before any memory-side work.
  LiteX's 9K target uses the same video structure, but with its own HyperRAM core, not the
  Gowin IP.
- **Pins shared with the LCD connector:** keep any panel unplugged.
- **DVI on an HDMI sink:** monitors accept it. Some TVs expect InfoFrames and may show
  limited-range colour or nothing. RGB565 shows banding (64 green levels, 32 red/blue).
- **Contention:** heavy CPU traffic to channel 1 (e.g. a framebuffer memmove) is throttled
  while the DMA is urgent. A missed line shows as wrong pixels and sets the underflow bit.
- **Coherence:** a cached access to the framebuffer would show stale pixels (no crash).
  Only the alias may be used. The DT `no-map` covers Linux; the boot ROM uses the alias.
- **RAM:** 600 KB less for Linux. Stage 1 (no-MMU) is fragmentation-bound, so video starts
  on the MMU kernel only.

## Open decisions

1. **Framebuffer console (fbcon):** recommended off. `/dev/fb0` only, so the boot is
   unaffected and `CONFIG_VT` stays off.
2. **Reset picture:** recommended colour bars until software enables the framebuffer. The
   alternative is black.
3. **Pixel clock:** recommended 25.2 MHz (exact 60 Hz from 126 MHz), not the nominal
   25.175 MHz, which no simple PLL setting gives.

## Progress (2026-11-10)

### Built

- **Pixel side:** `rtl/video/video_out.v` (timing, colour bars, line-buffer pixels, RGB565 to 888,
  line requests) and `tmds_encoder.v`. `hdmi_phy_gowin.v` (`OSER10` per lane, clock lane
  1111100000, `ELVDS_OBUF`). `fpga/src/gowin_rpll/gowin_rpll_video.v` (126 MHz) and a `CLKDIV`
  "5" in `fpga/src/tang9k_top.v`.
- **Memory side:** `rtl/video/video_dma.v`, `video_ctrl.v` (registers, line buffer: 2 BSRAM),
  `rtl/soc/psram_arb.v`.
  - The cache asks the arbiter for each PSRAM command (o_req/i_gnt) instead of counting TCMD
    itself.
  - It has the uncached alias (`0x9xxx_xxxx`, `i_unc`): posted single-beat writes, beat-0
    reads.
- **Build:** `VIDEO=1 fpga/build.sh` (`TANG9K_VIDEO` define; build.sh writes one SDC,
  `fpga/build/tang9k_soc.sdc`, with the video clocks added: Gowin reads each SDC file on its
  own). The HDMI pins are in the board `.cst` always (driven low without video).
- **Boot ROM:** `v <base>`; `s` prints SYSCON words 0-10 (with the video registers); entering a
  kernel clears the framebuffer and turns scanout on when CTRL reads non-zero.
- **Host:** `qerv_boot.py --fb IMAGE|test|bars`.
- **Linux (MMU):**
  - DT: `framebuffer@80700000` reserved (mapped, like the SBI page: the linear map keeps its
    megapages), and `simple-framebuffer` at `0x90700000`.
  - `CONFIG_FB`, `CONFIG_FB_SIMPLE`, `CONFIG_FB_DEVICE`; busybox `fbset`. No fbcon.

### Changed from the plan

- **Line deadline:** a line must be fetched within 800 pixel clocks of its request (the
  request period), not 960 (its real deadline). With 960, under heavy CPU traffic a line could
  still be in flight when the next request came; the queued line then started its own full
  window late, and every later line underflowed. The system test found it.
- **Timing (42 MHz with no slack before video):** the first video build reached 36.6 MHz.
  - The bus address path started at SERV's `o_ibus_cyc = ibus_cyc & !i_rst`: the reset net
    went through the MMU's ibus/dbus address select, the address decode and the read mux.
    SERV now also exports `o_ibus_sel` (the register, no reset gating) and the MMU selects
    with it.
  - The CPU reset is registered.
  - The cache latches the miss tag and the uncached request before asking the arbiter.
  - The SoC read mux selects by the slaves' registered acks (AND-OR), not by the address.
  - Result: 42.000 MHz, TNS 0, logic 5,603/8,640 (65%), BSRAM 16/26.
- **Write stream bug** (found by the extended cache test): both channels' `wr_data`/
  `data_mask` carry one stream. A write waiting for its grant already drove its data with the
  bytes enabled, over the tail beats of the write before it. Bytes are now enabled only in
  the granted cycle (and the arbiter keeps writes 8 cycles apart).

### Tests

- `verif/video/run.sh`: video_out + TMDS + OSER10 models.
  - PHY=1 deserializes and decodes the lanes at a reduced timing; PHY=0 checks the real
    640x480 timing.
  - Both cover bars, framebuffer frames through a model DMA, one late line (exactly one
    underflow) and video off.
  - Five mutants (bit order, DC balance, hsync width, halfword order, lane swap) each fail it.
- `verif/cache/run.sh`: cache + arbiter + PSRAM model.
  - Cached and uncached random traffic with an 8-line cache.
  - A video-like DMA reader on the arbiter, urgent 20% of the time: 70k bursts checked,
    26.5 cycles per burst; the model's protocol checker stays silent.
- `verif/video/run_sys.sh`: cache + arbiter + video_ctrl + PSRAM model at 42 / 25.2 MHz, real
  timing, the CPU missing constantly in channel 1. Two frames are checked pixel by pixel
  (614,400 pixels), no underflow; the tightest line finished 24 cycles inside its 800-pixel
  budget.
- `VIDEO=1 [FRAME_DUMP=1] CONFIG=mmu sim/soc/run.sh`: the SoC at 42 MHz with the pixel
  clock; frame dumps as PPM.

### Board

- **V0:** the CPU-less probe (`fpga/probe_hdmi/run.sh`) showed the bars on a monitor at
  640x480@60.
- **V1:** `qerv_boot.py --fb test` loads 614,400 B through the alias in 6.1 s, and its hash
  through the alias matches. After about 10 s of scanout, STATUS showed 649 frames and no
  underflow.
- **V2 (MMU kernel, UART-loaded):** `simple-framebuffer ... fb0: simplefb registered!`, fbset
  reports `640x480 16 rgba 5/11,6/5,5/0`, and `dd` to `/dev/fb0` draws.
  - `B` to `~ #` takes 12.5 s (12.0 s without video): about 0.17 s is the simplefb probe,
    0.1 s the ROM's clear, and a 34 KB larger kernel.
  - `free`: 3,540 KB free, 3,132 KB available.
- **Scanout cost to the CPU:** with the old kernel, `Run /init` was at 8.86 s of kernel time
  with scanout on and 8.87 s without.
- **Standalone:** the video bitstream is in the internal flash and the fb kernel in the SPI
  flash. At power-up the monitor shows the bars at the ROM prompt, then the ROM autoboots
  Linux with `/dev/fb0`: `~ #` 17.6 s after the prompt (17.1 s before video).
- **Simulation** (`VIDEO=1 FRAME_DUMP=1 CONFIG=mmu sim/soc/run.sh`, 6 min): `~ #` at 12.46 s
  of 42 MHz time (board 12.5 s), 747 frames, no underflow. The dumped frames show the bars,
  then black once the ROM clears the framebuffer.

### Boot screen (the user's choice after V2: a splash during boot, then a console)

- **Splash:**
  - `sw/tools/mksplash.py` draws a default splash (or fits a given picture) and run-length
    encodes it: 29 KB for the default.
  - `sw/mkflash.py --splash` puts it after the kernel and records it in the flash header
    (`flash_linux.sh` does both).
  - At reset the boot ROM draws it through the uncached alias (~0.2 s, before the prompt)
    and turns scanout on. Entering the kernel keeps a framebuffer that is already on.
- **Console:**
  - The MMU kernel has `CONFIG_VT`, `CONFIG_FRAMEBUFFER_CONSOLE` and
    `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER`. fbcon leaves the splash alone until
    something is written to tty1, and the kernel log stays on ttyS0.
  - `/usr/bin/console-shell` (inittab) runs the shell under busybox `script`, which copies
    the session to tty1. The screen mirrors the UART session; the first write there makes
    fbcon take over.
  - It also sets the console loglevel to 5, since fbcon's info-level takeover messages
    otherwise landed on the serial console after the first prompt.
- **VT count:** `CONFIG_VT` registered a tty device for each of 63 virtual consoles: 2.6 s
  of `chr_dev_init`. `patches/linux/0002-vt-four-virtual-consoles.patch` makes it 4.
- **Cost:**
  - The kernel is 144 KB larger (VT, fbcon, font, input core).
  - `B` to `~ #` takes 14.1 s, against 12.5 s with plain `/dev/fb0`. The extra time is
    mostly fbcon's takeover and `script`; `Run /init` is back at 9.3 s of kernel time.
  - Standalone power-up: `~ #` 19.4 s after the ROM prompt (17.6 s).

### Console speed (after the boot screen)

fbcon on the 42 MHz core was slow: about 0.36 s per scrolled line, and `dmesg > /dev/tty1`
took 55 s. Three changes, in order:

- **UART interrupt** (`rtl/soc/plic.v`, a minimal `sifive,plic-1.0.0`; 256-byte UART FIFOs;
  SEIP in the CPU). This is for the serial side: `dmesg` to ttyS0 went from 6.9 s to 1.3 s.
- **Y-wrap panning** (`YOFF`, word 11, and `patches/linux/0003`, the `qervfb` driver with
  `FBINFO_HWACCEL_YWRAP`). The RTL works (`tb_video_sys` with YOFF=123), but on the board
  fbcon never panned (`/sys/class/graphics/fb0/pan` stayed 0,0, still SCROLL_REDRAW) and the
  cause was not found. qervfb stays as the `/dev/fb0` driver.
- **Hardware text mode** (the user's choice, after the ov7670 project's character display):
  - **Registers:** CTRL bit 2 TEXT (overrides EN; the DMA stays idle). TSTART (word 12,
    `0x1110_0030`): the text-buffer row shown at the top, 0..29. CURSOR (word 13, `0x34`):
    bit 12 enable, bits 11:7 row, 6:0 column, in screen coordinates.
  - **Text buffer** at `0x1180_0000`, write-only: 80 × 30 cells of {attribute, character},
    16 bits each (the Linux VT's layout), row-major, byte lanes. 4,800 bytes in 3 BSRAM,
    written on the CPU clock and read on the pixel clock.
  - **Pixels** (`video_out.v`): stage 0 forms the cell address
    (`((y/16 + TSTART) mod 30) * 40 + x/16`), stage 1 picks the cell and addresses the font
    ROM (`rtl/video/font8x16.hex`, the kernel's CP437 `font_8x16`, 4 KB in 2 BSRAM), stage 2
    picks the glyph bit and the colour (16-colour VGA palette, background from attr[7:4]).
    A blinking underline (glyph rows 14–15) is the cursor.
  - **I/O register stage** (`soc_top.v`): every I/O slave now decodes a registered copy of
    the request (+1 cycle per I/O access). It took the video and text decodes out of the
    CPU's address path.
  - **Linux:** `patches/linux/0004`, `drivers/video/console/qervcon.c`
    (`CONFIG_QERV_CONSOLE`, DT `qerv,tang9k-text`), replaces fbcon
    (`CONFIG_FRAMEBUFFER_CONSOLE` off). One 16-bit store per character. A full-screen
    scroll moves TSTART and clears the new rows. A partial scroll rewrites the region from
    the VT's buffer. The screen keeps the boot ROM's splash until the first character
    other than a blank, and shows the framebuffer while a program has the VT in
    KD_GRAPHICS.
  - **Fit:** 69% logic, BSRAM 24/26, Fmax 44.9 MHz (CPU, at 42) and 27.8 MHz (pixel,
    at 25.2), TNS 0.
  - **Tests:** `verif/video/run.sh` checks text frames against a reference model
    (`textpix()` in `tb_video_out.v`): TSTART=3 and a cursor. The TB sets `BLINK=0`, so
    the cursor blinks every frame and the two checked frames cover both phases. A mutant
    with the cursor one glyph row too high fails it.
  - **Board (UART-loaded kernel, 2026-11-11):**

    | Command | fbcon | Text mode |
    | --- | --- | --- |
    | `dmesg > /dev/tty1` (4 KB) | 55.0 s | 2.78 s |
    | `dmesg` (mirrored to ttyS0 and tty1) | 62.5 s | 3.62 s |
    | `dmesg > /dev/ttyS0` | 1.3 s | 1.21 s |

    What is left on tty1 is the VT layer itself: about 0.4 ms per character.
  - **Boot time:** `Run /init` comes at 10.33 s of kernel time, against 9.47 s with the
    fbcon kernel. The qervcon probe accounts for 0.2 s of that: with its DT node disabled,
    the same kernel reaches `Run /init` at 10.13 s. The rest is in the initramfs wait
    (`clk: Disabling unused clocks` → `Run /init`: 3.78 s vs 3.12 s). It also appears with
    the old bitstream, so it comes from the kernel, not the hardware. The cause is not
    known yet; a different code layout in the direct-mapped cache is one guess.

### Not done yet

- The no-MMU kernel's DT.
- Write-combining, 320x240 (V3 options).
- The boot ROM could print on the text screen too.
