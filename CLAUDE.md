# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status and goal

Experimental, greenfield: bring up a Linux kernel on a **Tang Nano 9K** by putting a RISC-V
soft core into the FPGA with the on-package PSRAM as main memory. The core is QERV (SERV
W=4) extended for no-MMU M-mode Linux. M0–M3 are done, and in M4 Linux boots to a shell on
the board. Stage 2 (SV32 MMU, S-mode kernel under a ROM SBI shim) also boots to a shell on
the board, with real fork and pipelines; `doc/stage2_plan.md` has the plan and status. The
board autoboots the MMU kernel from its flashes: `~ #` about 27 s after the boot ROM prompt
at 42 MHz (21 s after a UART-loaded `B`, 2 s of it the greeting). The PSRAM is driven by the project's own 16-bit
controller (`doc/psram_controller.md`), which replaced Gowin's PSRAM IP. The stage-1 milestones (M0 software image in the emulator →
M1 core → M2 SoC sim → M3 fit → M4 board), memory map and open decisions are in
`doc/stage1_plan.md`. `doc/01-architecture.md` describes the hardware as a whole
(clocks, reset, memory, address map, timing, resources); keep it in step with changes. HDMI video works on the board too: a 640×480 RGB565 framebuffer in
PSRAM, scanned out over HDMI, with a boot splash from the ROM and, in the MMU kernel,
`/dev/fb0` plus an 80×30 hardware text console mirroring the UART shell
(`doc/video_plan.md`: plan, status, results). The MMU kernel also has an I2C bus (the
ov7670 project's OpenCores master) and the microSD card over SPI (`doc/peripherals.md`).
Update this file as decisions land. Don't describe planned structure as
if it exists.

## Build commands

- `scripts/gw_run.sh` (+ `gw_run.tcl`, from the ov7670 project) runs `gw_sh` headlessly.
  Env: `GOWIN_PATH`, `GPRJ`, `STAGE=syn|pnr|all`, `TOP`, optional
  `PLACE_OPTION`/`ROUTE_OPTION`, and `GW_OPTIONS` ("-name value" pairs for `set_option`,
  added here). A full synth + PnR of a fit probe takes 1–2 min.
- **Board build (M3):** `fpga/build.sh` (~2 min) writes `fpga/build/` (boot ROM hex and
  `tang9k_cfg.v` with `TANG9K_CPU_HZ` and the hex path; `fpga/build.sh prep` does only this)
  and builds `fpga/tang9k_soc.gprj`, top `fpga/src/tang9k_top.v`. The bitstream is
  `fpga/impl/pnr/tang9k_soc.fs`.
  - **Clocks:** the rPLL makes the SoC clock, 42 MHz (`CLKOUT`, net `clk`, SDC `cpu_clk`),
    and the PSRAM's CK clock, the same 90° later (`CLKOUTP`, `clk_p`, `ck_clk`). The rPLL
    wrapper `fpga/src/gowin_rpll/gowin_rpll.v` is written by hand (the user's call: no
    regeneration needed). If its frequency changes, change the SDC's multiply/divide and
    `CPU_HZ` too.
  - **Timing:** `fpga/src/tang9k_soc.sdc` keeps a 1.5 ns setup guard band on cpu_clk's paths
    (`set_clock_uncertainty`, the user's idea; `SDC_UNCERT=<ns> fpga/build.sh` tries another
    value). Gowin's slack and Fmax include it (`tUnc` on each path), so TNS 0 means 42 MHz
    with 1.5 ns to spare; real Fmax = 1 / (1 / Fmax − 1.5 ns).
    - Gowin's PnR is deterministic, and the constraints alone move the result (2026-11-11,
      real Fmax): no band 39.3 MHz; 1.5 / 2.0 / 2.5 / 3.0 ns → 45.18 / 42.02 / 44.58 / 42.23.
      Over-constraining the clock instead (×15/16/17 → 45/48/51 MHz) gave 42.58 / 45.0 /
      41.96, but it also inflated the power estimate. Retry other values when a change costs
      timing.
    - `timing_summary.py` (upload-bitstream skill) adds each listed path's uncertainty back,
      so a build that eats into its band but meets 42 MHz passes with a note. The SDC's
      `report_timing` lists 200 setup paths.
    - The current build (`tang9k_soc_unc.fs`): TNS 0 with the band, +1.675 ns without it
      (45.18 MHz), no hold violations. The worst paths are the RF read port / SERV's buffer
      registers → RF write data and AMO write data.
  - **Video (`VIDEO=1 fpga/build.sh`, doc/video_plan.md):**
    - A second hand-written rPLL (`gowin_rpll_video.v`) makes 126 MHz, and a `CLKDIV` "5"
      the 25.2 MHz pixel clock.
    - `hdmi_phy_gowin.v` serializes onto pins 68–75. These are shared with the RGB LCD
      connector: no panel plugged in.
    - build.sh writes `TANG9K_VIDEO` into `tang9k_cfg.v`, and one SDC,
      `fpga/build/tang9k_soc.sdc`: `fpga/src/tang9k_soc.sdc` plus the video clocks. Gowin
      reads each SDC file on its own, so a second SDC can't refer to the first one's clocks.
    - Stage 2 + video + text mode + I2C + SD: 65% logic (5,584; 86% of CLS), BSRAM 24/26
      (`tang9k_soc_unc.fs`). With the Gowin PSRAM IP it was 74% (6,352).
      - With the IP, Fmax swung with placement: 45.7 MHz in one build, 42.25 MHz after the
        +7-LUT SD CRC, 42.126 MHz with Zicbom (`tang9k_soc_cbo.fs`).
      - Zicbom's first build made 42.085 MHz: the CMO decode reached the cache's state
        logic. Latching the CMO in the cache (`cmo_q`) and decoding only imm[2:0] took that
        path out.
      - Without the AMO unit's registered SC compare it was 38.4–39.9 MHz
        (`doc/peripherals.md`).
    - The font ROM is `rtl/video/font8x16.hex` (the kernel's CP437 `font_8x16`); build.sh
      writes its path as `TANG9K_FONT_FILE`.
    - `fpga/probe_hdmi/run.sh` is a CPU-less colour-bar probe (~10 s build).
  - **PSRAM controller:** `rtl/psram/hyperram_x16.v` (doc/psram_controller.md), in the SoC
    since 2026-11-11. It runs both dies in lockstep as one 16-bit DDR bus, with CK at the
    SoC clock (1:1, from the rPLL's `CLKOUTP` 90° later) and no calibration.
    - A 32-byte line is one 8-beat burst of 18 cycles; read beat k comes 16 + k cycles after
      the command. A word write ends after its beat (11 cycles). CR0 = `0x8FEE` (latency 3
      fixed, 16-byte wrap per die, so a burst wraps inside the line).
    - Read words are found from RWDS into per-die FIFOs. A word missing at the end of the
      capture window comes out as a filler with `o_rerr` (SYSCON word 2 counts them).
    - Facts the board settled (CPU-less probe `fpga/probe_psram16/run.sh`, full 8 MB):
      - CR0 is written at `CA[24]`; a write at `CA[16]` is ignored.
      - Die 0's true clock is `O_psram_ck[0]`, on two single-ended pins (IOL8A/IOL7A, not a
        differential pair: an `ELVDS_OBUF` there moved them to pins 85/86). Die 1's is
        `O_psram_ck_n[1]`, on the IOL23A/B pair.
      - Every CK phase from 22.5 to 157.5 degrees passes; 0 fails.
    - Tests: `verif/psram16/run.sh` (~20 s, in CI). `rtl/sim/gowin_io_sim.v` models the
      ODDR/IDDR/ELVDS_OBUF cells, so no Gowin install is needed (`PRIM=gowin` uses Gowin's).
  - **Gowin PSRAM IP (retired 2026-11-11):** `fpga/src/psram_memory_interface_hs_2ch/` is the
    ov7670 project's generated netlist (135 MHz settings, module `Video_frame_buffer`), kept
    for the calibration probe `fpga/probe/`. IP generation in this machine's IDE fails on the
    license. With it the SoC ran on the IP's clk_out = memory_clk / 2 (84 → 42 MHz).
    - It never calibrated at memory_clk ~77.6–81 MHz (channel 1; at 81 MHz both). 54–77.1
      and 84–135 MHz calibrate. `fpga/probe/run.sh TAG IDIV FBDIV ODIV` builds a CPU-less
      probe (rPLL + IP + a 27 MHz beacon UART printing lock/calib) in ~15 s and loads it.
    - Likely cause: the netlist was generated for another clock. Its `.ipc` says
      `MEMORY_CLK=135`, `SHIFT_DELAY=152`; the generator picks `SHIFT_DELAY` per clock. An
      element14 article (shabaz, 2026-10) generated the IP for 81 MHz and passed a
      full-memory test of both channels there.
  - **Board top:** UART 1 Mbaud (`BAUD` env of `fpga/build.sh`; the divider is fixed in
    hardware). The button labelled S2 is the system reset. That is pin 3 on our board: the
    Sipeed schematic names pin 4 S2, but this board's S1/S2 silkscreen is swapped (checked by
    pressing). It is synchronized and debounced (2.4 ms) in the
    27 MHz domain, with a ~10 ms power-on reset. It resets the PSRAM controller (RESET# and
    the CR0 write again, ~0.2 ms; RAM contents are not guaranteed), the cache's FSM, the
    TLB, the CPU and peripherals, so the boot ROM starts over. The cache's tag RAM is not
    reset (only the bitstream initializes it), so lines cached before a reset stay valid.
    LEDs: heartbeat, PLL lock, PSRAM ready, UART TX, reset, poweroff.
  - **SYSCON status words** (read at 0x1110_0000 + 4·i, layout in `soc_top.v`): 0 PSRAM
    ready (3), 1 PSRAM commands, 2 read beats with a filler word (should stay 0), 3 read
    beats, 4 zero, 5 cache misses, 6 write-backs. Words 8–13 are the video registers
    CTRL/BASE/STATUS/YOFF/TSTART/CURSOR (writable; `video_ctrl.v`).
    - Poweroff (0x5555) and reboot (0x7777) act only on writes to offset 0. Before the
      fix, any SYSCON write of those values counted.
  - **Flash pins (59–62) are MSPI dual-purpose pins:** the build passes
    `GW_OPTIONS="-use_mspi_as_gpio 1 -use_sspi_as_gpio 1"`. A build from the IDE needs the
    same in Project → Configuration → Dual-Purpose Pin.
  - **Results:** see `doc/stage1_plan.md` M3/M4 and `doc/stage2_plan.md` (stage 2: 57% logic,
    Fmax 42.004 MHz vs 42, and IP-internal hold violations of the known ov7670 class).
- **Boot ROM monitor + host tool (M4):** `sw/bootrom/bootrom.S` prints a banner and a `> `
  prompt and takes single-byte commands with binary LE arguments: `l` load (replies a djb2
  hash), `c` hash memory, `m` memtest, `s` status (SYSCON words 0–10), `b` boot RAM, `f` boot
  from flash (autoboot after 2 s if the flash holds an image), `q`/`r` poweroff/reboot, `v`
  video base (0 = colour bars).
  - **Video at reset:** with video present, the ROM draws the flash's boot splash (a
    run-length list, header word 4 "SPLH") right after the banner and turns scanout on.
  - **Entering a kernel:** a framebuffer that isn't on yet (still bars) is cleared (~0.1 s)
    and turned on; one that is on (splash, `v`) is kept.
  - `sw/tools/qerv_boot.py --bitstream fpga/impl/pnr/tang9k_soc.fs --linux [--memtest]
    [--input 'cmd\n...']` loads the bitstream into SRAM, uploads Image + DTB, boots, logs
    the console and types the input (one character per echo). `--fb IMAGE|test|bars` shows
    an image on HDMI: the image is loaded through the uncached alias, then the ROM's `v`
    turns scanout on.
  - **The BL702 USB-UART bridge applies the baud rate of the previous port open**, so open
    the port twice (`qerv_boot.py` and `fpga/probe/beacon.py` do).
  - In simulation, `sim/soc/run.sh` sends `b` (or `f` with `FLASH=1`) at the prompt;
    `ROM_INPUT=<records>` overrides that (`sim_main.cpp` `+rom_input`: records of
    {u32 length, bytes}, one per `> ` prompt). `sim/soc/test_bootrom.py` (~1 min) checks
    every command.
- **Docker:** `docker/bootstrap.sh` builds the image `tang9k-linux-build` (Ubuntu 24.04,
  ~1.8 GB, ~3 min) and writes `docker/.env` (git-ignored). `docker/run.sh <cmd>` runs a
  command in it. Mounts: the repo at `/work`; the Gowin install read-only at `/opt/gowin`
  (`GOWIN_PATH`); `WORK_DIR` at `/build` (`WORK`); Buildroot's download cache at `/dl`
  (`BR2_DL_DIR`, shared with the host's `$WORK/buildroot/dl`). USB and ttyUSB are passed
  through.
  - The container's `WORK` is a separate host directory
    (`/mnt/data/build/tang9k_linux/docker`): Buildroot's host tools are linked against the
    libc they were built with, so host and container trees must not mix. The container's
    kernel images land in `docker/images-tang9k-mmu/`, not the host's.
  - Checked in the container: `scripts/ci.sh all` passes, `fpga/build.sh` builds the
    same 42.126 MHz bitstream (then with the Gowin PSRAM IP; gw_sh reaches the licence server through the default
    network), `CONFIG=mmu sw/build.sh` builds from scratch.
  - `scripts/gw_run.sh` preloads `libfreetype.so.6`, not `libfreetype.so`. The unversioned
    name exists only with `libfreetype-dev`, and without the preload `gw_sh` dies on
    Gowin's old bundled FreeType.
- **CI:** `scripts/ci.sh cpu|units|soc|all` runs the checks that need no Gowin tools, board
  or kernel: the CPU tests and riscv-tests, the CPI check, the unit benches (not
  `verif/video/run.sh`, which needs Gowin's primitive models), and the SoC model (boot ROM
  commands, `cbo_test`). `.github/workflows/ci.yml` runs the three groups on ubuntu-24.04
  with the packaged `gcc-riscv64-unknown-elf`, Icarus and Verilator. Locally:
  `RISCV_PREFIX=riscv64-unknown-elf- scripts/ci.sh all`. A new test script belongs in it.
- **Board access:** the Tang Nano 9K shows up as FT2232 `0403:6010`.
  - `openFPGALoader -b tangnano9k --detect` sees the GW1N(R)-9C.
  - `--external-flash --dump-flash --file-size N out.bin` reads the external flash. Note
    that the output file is positional; `-o` is the offset. It reads at ~0.65 KB/s and
    erases the SRAM configuration first.
  - **Writing the external flash:** `sw/tools/flash_linux.sh [mmu|nommu]` (~1 min) runs
    mkflash and Gowin `programmer_cli --run 38` (exFlash C Bin through the GAO bridge,
    `--cable-index 4` = "USB Debugger A"). Don't use openFPGALoader `--external-flash -f`
    for it: it bit-bangs SPI over the 6 MHz JTAG, ~1 h. Three gotchas, all handled by the
    script:
    - `programmer_cli` cannot open the JTAG channel while the kernel's `ftdi_sio` holds
      it (`/dev/ttyUSB0`). openFPGALoader re-attaches it on exit, so the script detaches
      it via libusb.
    - The script passes `--location` from `--scan-cables`.
    - It erases the FPGA's SRAM first (`--run 24`). With a design running, the bridge write
      crawls (>12 min).
    - The bridge sometimes hangs at the first sector erase (5 of 12 runs). The hung runs
      reported bridge status 0x0003F020, the good ones 0x0001F020. Retries in the same state
      hang too; reconfiguring the FPGA cleared it.
    - It also stopped once partway through programming (43%, for 45 min). Unplugging and
      replugging the board's USB cleared it.
    - So a watchdog SIGKILLs an attempt whose progress hasn't changed for 60 s. The next
      attempt first reconfigures (`openFPGALoader -r`), detaches ftdi_sio again and rescans
      the cable.
    - Don't wrap the script in a short `timeout`: killing it leaves `programmer_cli` holding
      the cable (openFPGALoader then fails with "unable to claim usb device") and the flash
      half-written.
    - A stuck `programmer_cli` ignores SIGTERM, and a failing `kill` under `set -e` used to
      end the script. The SRAM erase is bounded too (30 s).
    - It also writes the boot splash: `sw/tools/mksplash.py` (default picture, or
      `SPLASH=<image>`), then `sw/mkflash.py --splash`.
  - **Internal flash (persistent bitstream):** `openFPGALoader -b tangnano9k -f <fs>`, ~12 s
    with a CRC check. `qerv_boot.py --reconfig` reloads it (openFPGALoader -r), as at
    power-on.
  - **What the board holds now:**
    - Internal flash (written 2026-11-11, after the SPI flash):
      `/mnt/data/build/tang9k_linux/tang9k_soc_unc.fs` (md5 ea952537…; SMODE=1 VIDEO=1, the
      16-bit PSRAM controller, the SDC's 1.5 ns guard band, splash boot ROM, reset on pin 3).
      Earlier the same day: `tang9k_soc_hr16.fs` (the same RTL, placed against an
      over-constrained 48 MHz) and before it `tang9k_soc_cbo.fs` (the same system with the
      Gowin PSRAM IP), which stays as the fallback.
    - SPI flash (written 2026-11-11, 19:54): `/mnt/data/build/tang9k_linux/flash_mmu_greet.bin`
      (3,441,268 B: Image 3,403,420, DTB 2,871, S-mode flag, splash 29,300). The Zicbom
      system plus the shell greeting and qervcon's Unicode-map fix (kernel #5, 19:31). It
      runs on `tang9k_soc_unc.fs` and `tang9k_soc_cbo.fs` alike (the PSRAM change added no
      device). Earlier images: `flash_mmu_cbo.bin` (the same system without the greeting),
      `flash_mmu_irq.bin` (with `tang9k_soc_irq.fs`) and `flash_mmu_pre_video.bin`.
      - That write needed 3 attempts (the bridge stalled loading, then at the first sector
        erase with status 0x0003F020), after an earlier run of 3 failed attempts that a USB
        replug cleared.
    - Flash a kernel and a bitstream together when the devices change: a kernel's DT expects
      the devices of its own bitstream (text buffer, I2C, SPI).
    - At power-up the splash is on screen from the boot ROM on. Linux autoboots, and when its
      shell starts the screen switches to the text console and the greeting: `Run /init`
      20.1 s and `~ #` 27.3 s after the ROM's prompt. Without the greeting it was 19.9 /
      24.8 s (with the IP: 19.8 / 24.6 s; the irq system: 16.0 / 19.3 s, before I2C + SD
      init and the larger Image).
  - **Checking the flash:** `qerv_boot.py --hash-flash flash.bin` has the boot ROM hash the
    flash window (2.7 MB in ~18 s). `--flash-boot` boots it, and `--autoboot` loads the
    bitstream and sends nothing (the power-up path).
  - The console UART is `/dev/ttyUSB1` (interface 1); JTAG is interface 0. It runs at 1 Mbaud
    8N1, fixed in the FPGA.
  - `sw/tools/console.sh [gtkterm|miniterm|--prime]` primes the port at 1 Mbaud (the bridge
    quirk above) and starts gtkterm. A terminal that opens the port once after something
    used 9600 otherwise shows garbage. The script refuses if the port is in use.
  - Opening the port at another rate while a terminal has it open changes that terminal's
    line rate too.
- **Fit probes** (`fit/<probe>/`) measure one CPU core alone on the GW1NR-9:
  - **Wrapper:** an LFSR drives the CPU's inputs and every output is XOR-folded onto one LED,
    so nothing is pruned and the design still goes through PnR. This adds ~100 LUTs and ~70 FFs.
  - **Running:** `fit/run_probe.sh <probe> [label]` builds `fit/<probe>/<probe>_fit.gprj`
    (top `<probe>_fit_top`), copies the reports to `fit/<probe>/results/<label>/`, and prints
    a summary row. `python3 fit/summarize.py fit/*/results/*` reprints all rows.
  - **Build options:** each probe's options live in a generated `<x>_cfg.v` listed first in its
    `.gprj`, and GowinSyn carries those macros into the later files. Probes with variants have
    a `run_fit.sh` that rewrites the cfg and sets the label, e.g. `fit/qerv/run_fit.sh [1|4]`
    (SERV width).
  - **Constraints:** pins and the 50 MHz analysis clock are shared in `fit/common/`.
- **Linux image (M0):** `sw/build.sh [buildroot-target]` builds the stage-1 software.
  - **Inputs:** Buildroot is pinned to 2026.08.1 and checked out in
    `/mnt/data/build/tang9k_linux/buildroot`. The external tree `sw/br2-external`
    (`configs/tang9k_nommu_defconfig`, `board/tang9k/`) holds `linux.config`, `tang9k.dts`,
    `busybox.config` and the rootfs overlay.
  - **What gets built:** an rv32ima/ilp32 uClibc-ng toolchain with elf2flt, kernel 6.18.7
    with the initramfs linked in, and the DTB.
  - **Outputs:** the build tree is `/mnt/data/build/tang9k_linux/br-tang9k`. `Image` and
    `tang9k.dtb` are copied to `/mnt/data/build/tang9k_linux/images-tang9k/`.
  - **Timing:** the first build is ~40 min. Kernel/busybox-only rebuilds take minutes, e.g.
    `sw/build.sh linux-rebuild all`.
  - **Defconfig:** re-applied on every run, so edit the files in the repo, not
    `.config`/menuconfig.
  - **Gotcha:** Buildroot's RISC-V arch never selects `BR2_SOFT_FLOAT`, so uClibc-ng gets
    `UCLIBC_HAS_FENV` and fails on `frrm`. `sw/br2-external/Config.in` selects it for F-less
    RISC-V.
  - **Booting the result:** `perf/boot_trace/run.sh` traces this image by default.
- GowinSyn `NL0002 ... is swept in optimizing` on small combinational modules means the module
  was absorbed into its parent, not deleted. The hardware-proven ov7670 build shows it for
  `servile_mux`.
- The installed yosys (0.33) does not map `*` to Gowin DSPs, so its `synth_gowin` numbers
  for a core with a multiplier (KianV was one) are wildly inflated. Use GowinSyn for any
  utilization figure.
- **QERV SoC (M2):** `rtl/soc/soc_top.v` contains:
  - qerv_cpu → servile_arbiter → an address decoder (memory map in `doc/stage1_plan.md`, the
    same as the emulator; `0x9000_0000` is the uncached alias of the PSRAM)
  - **Read data:** each slave's registered ack selects its registered read data (AND-OR). The
    address decode stays out of the read path, which is the SoC's critical one.
  - `l1_cache.v`: 16 KB unified, direct-mapped, write-back. It asks `psram_arb.v` for each
    PSRAM command. The arbiter registers the command for the controller (`hyperram_x16`, one
    command at a time) and shares it with the video DMA: CPU first, the DMA first only when
    its line deadline is near. The cache also serves the uncached alias: posted single-beat
    writes and beat-0 reads.
    - **Cache-block operations (Zicbom):** the CPU's `cbo.clean`/`cbo.flush`/`cbo.inval`
      reach the cache as a request with `i_cmo`/`i_cmo_op`. clean and flush write a dirty
      line back (the eviction burst); clean keeps the line, flush drops it. inval drops it
      without a write-back. A miss or the uncached alias is acked at once. The ack comes
      after the write burst is granted, so a later DMA read sees the data.
    - In soc_top the flag skips the arbiter (`m_cmo = dbus_cmo & !ibus_cyc`). A CMO to an
      I/O address is acked there and never reaches a slave.
  - **Write beats:** the cache sends beat k k cycles after the grant into the arbiter's
    8-entry buffer, and the controller takes them from cycle 9 on. The cache masks every
    byte outside a write's own beats: the arbiter's `o_wlast` ends the burst after the last
    enabled beat, so an uncached word write takes 11 cycles instead of 18.
  - **Bandwidth:** one line per 18 cycles, 74.7 MB/s, shared by the CPU and scan-out (36.9
    MB/s; 720 of every 1,333 cycles during a line). `video_dma.v` paces itself with
    `TBURST` = 18 and asks for priority with a `MARGIN` of 66 cycles.
  - `video_ctrl.v` (`VIDEO=1`): registers, `video_dma.v`, a 2-line buffer and `video_out.v`
    on the pixel clock.
    - **Text mode** (CTRL bit 2): an 80×30 text buffer at `0x1180_0000` (write-only,
      {attribute, character} cells, the Linux VT's layout), a CP437 font ROM, TSTART
      (hardware scroll) and CURSOR registers. The DMA stays idle in text mode.
  - **I/O register stage:** every I/O slave decodes a registered copy of the request (+1
    cycle per I/O access); only PSRAM (`0x8`/`0x9`) keeps the direct path.
  - `uart_16550.v` (256-byte block-RAM FIFOs, interrupt output), `clint.v`, `syscon.v`
  - `plic.v` at `0x1200_0000`: a minimal `sifive,plic-1.0.0` with one source (the UART) and
    one context, the hart's S-mode external interrupt (SEIP). The MMU kernel's DT uses it
    (`interrupts-extended = <&plic 1>`, `fifo-size = <256>`). The no-MMU kernel and the boot
    ROM still poll the UART.
    - With the interrupt, `dmesg` to ttyS0 takes 1.3 s instead of 6.9 s (polling refilled
      16 bytes per 10 ms tick).
    - The HDMI console is the hardware text mode (qervcon, below): `dmesg > /dev/tty1` takes
      2.8 s, against 55 s with fbcon on the framebuffer (and Y-wrap panning didn't help:
      fbcon never panned).
  - `spi_flash_xip.v`: read-only flash window at `0x2000_0000`
  - **I2C and microSD** (`doc/peripherals.md`):
    - `rtl/i2c/`: the ov7670 project's OpenCores I2C master at `0x1130_0000`, pins 25/26,
      PLIC source 2. Linux uses mainline `i2c-ocores`.
    - `spi_master.v`: the SD slot in SPI mode at `0x1140_0000` (pins 36–39). Data accesses
      wait on the bus while a byte or word shifts. Linux: `spi-qerv` (patch `0005`) +
      `mmc_spi`.
  - `bootrom.v`, holding `sw/bootrom/bootrom.S`

  It is one clock domain, the rPLL's 42 MHz (the PSRAM controller's too), plus the pixel
  clock with video.
  - **Boot ROM:** copies Image + DTB from flash (layout from `sw/mkflash.py`: header `QRVL`,
    DTB @0x1000, Image @0x2000) to `0x80000000` / `0x807FF000`, or uses preloaded RAM. It then
    enters the kernel with a0=0, a1=DTB.
  - **Full-boot simulation:** `sim/soc/run.sh` (Verilator; env `INPUT`, `FLASH=1`, `W`,
    `MAX_CYCLES`, `QUIET=1`). It runs ~2.4 MHz, so a full boot takes ~8 min. The console goes
    to `sim/soc/results/`.
    - `IMAGE=<bin>` boots another image instead of the kernel, and `ROM_CMD=b` replaces the
      ROM command (`CONFIG=mmu` sends `B`).
    - Bare-metal SoC tests live in `sw/tests/*.S`; `sw/tests/build.sh` builds them.
      `cbo_test.S` checks the cache-block operations through the uncached alias: it prints
      PASS/FAIL and powers off, in ~1M cycles.
      - It passes in simulation on both CPUs, and on the board
        (`qerv_boot.py --bitstream <fs> --load cbo_test.bin@0x80000000 --boot`).
    - `VIDEO=1` builds the video controller and runs at the board's 42 MHz (`+clk_hz`) with
      the 25.2 MHz pixel clock between the CPU clock's edges.
    - `FRAME_DUMP=1` writes every 60th frame to `$WORK/frames-<tag>/` as PPM.
  - **PSRAM model:** `rtl/sim/hyperram_x16_model.v`, the controller's command interface as
    a cycle model with 8 MB behind it. `verif/psram16/run.sh` checks that it takes exactly
    as many cycles as the controller with two die models.
    - **Timing:** read beat k comes 16 + k cycles after the command is taken (always use
      rvalid); `o_ready` again at +18. Write beat k is asked for at +7 + k (`o_wnext`), and a
      write ending after beat k frees the controller at +11 + k.
    - **Mask:** wmask=1 means the byte is not written.
    - **Bursts** wrap inside their 32-byte line from the addressed word.
    - **Loader:** `+psram_load0/1 +psram_addr0/1` take byte addresses. Its checker counts
      commands issued while not ready (`error_count`).
    - The Gowin IP's model `rtl/sim/psram_ui_model.v` (matched edge for edge to the IP
      netlist, `verif/psram/`, `verif/psram/NOTES.md`) is kept as a record; nothing uses it.
  - **RTL boot results (2026-11-10, 27 MHz, with the IP's model):**
    - `~ #` after 1.88G cycles = 69.5 s (80.3M instructions, CPI 23.4); flash copy +4.7 s.
    - About 4.5× more timer ticks than the emulator model, so tick/sched/timekeeping work is
      ~14% of instructions.
  - **Unit tests:**
    - `verif/cache/run.sh` (~4 min): cache + arbiter. Random cached and uncached traffic with
      an 8-line cache, plus a video-like DMA reader; the PSRAM model's protocol checker must
      stay silent.
      - It also mixes in cache-block operations, checked through the PSRAM model's backdoor.
        After clean/flush the block is in PSRAM, and the write-back was granted before the
        ack. Before an inval the TB writes "device" data into PSRAM; it must survive and
        become what the CPU reads. The line's tag must end in the right state.
      - Six cache mutants each fail it.
    - `verif/video/run.sh`: TMDS/timing/PHY, then text frames (TSTART, cursor) against a
      reference model. PHY=1 decodes the `OSER10` model's output; PHY=0 is the full 640×480
      timing (~7 min). `PHYS=1` runs one.
    - `verif/video/run_sys.sh` (~3 min): cache + arbiter + video controller at 42/25.2 MHz
      under worst-case CPU traffic, every pixel checked. With the 16-bit controller the
      tightest line had 17 cycles of deadline slack.
    - `verif/psram16/run.sh` (~20 s): the PSRAM controller against die models, its cycle
      model, and the probe's memory test (see "PSRAM controller" above).
    - `verif/spi_flash/tb_spi_flash.v` covers the flash reader.
  - **I2C and SPI tests:** `verif/i2c/run.sh` (the core against
    `rtl/sim/i2c_eeprom_model.v`, which `tb_soc.v` also puts on the SoC sim's I2C bus at
    0x50) and `verif/spi/run.sh` (the SD SPI master against a mode-0 slave model).
  - **UART tests:** `verif/uart/run.sh` (TX burst through the 256-byte FIFO, RX, overrun,
    interrupt and IIR).
  - **UART in polled mode:** IIR must report pending RX/THRE sources (gated by IER) even
    without an IRQ line. The 8250 driver's poll timer calls the IRQ handler, which returns
    at once on "no interrupt". With IIR stuck at 0x01, TX still works through the driver's
    THRE-bug backup timer, but RX is never read.
  - **Debugging a boot:** `BREAK_PC=<hex> sim/soc/run.sh` stops at a PC and dumps the last
    20k fetches with MIE/MPIE/mode/irq/mtip to `sim/soc/results/soc_w<W>.break.txt`.
    Resolve the PCs with the kernel's `System.map`.
  - **Verilator gotchas:**
    - A comment that starts with "Verilator" is parsed as a directive.
    - `commandArgsPlusMatch` returns "" (not NULL) when a plusarg is absent.
- **Stage 2 (doc/stage2_plan.md):**
  - **CPU:** `qerv_cpu` `SMODE=1` = SERV `LINUX=1 SMODE=1` (U/S/M, delegation, sret, S CSRs,
    satp, time/timeh from the CLINT's mtime, the S external interrupt SEIP: mie/sie.SEIE,
    mideleg bit 9, priority MTI > SEI > STI) + `rtl/qerv/sv32_mmu.v` (TLB in BSRAM, a
    one-page micro-TLB per bus that skips the TLB's 2 cycles, read-only walker, Svade).
    `SMODE=0` is the stage-1 core, unchanged (CPI and tests identical).
  - **One physical bus with SMODE=1:** the MMU merges fetches, data and PTE reads onto the
    dbus port (through the AMO unit), and the ibus port stays idle. Physical fetches for
    traces and profiles come from `qerv_cpu`'s `o_dbg_fetch`/`o_dbg_pc` in both modes.
  - **Software:** `CONFIG=mmu sw/build.sh` → `images-tang9k-mmu/`. Keep `CONFIG_EFI` off: it
    forces the C extension on.
    - The MMU image adds `board/tang9k-mmu/rootfs-overlay` and `busybox.fragment` to the
      shared stage-1 ones.
    - The overlay's inittab mounts devpts and runs `/usr/bin/console-shell`. Its busybox
      `script` mirrors the UART shell onto the HDMI text console on tty1 (the board has
      no keyboard).
    - `console-shell` also turns info-level kernel messages off the serial console, so none
      land after the first prompt (they used to stall `qerv_boot.py`).
    - **Greeting:** every login shell prints Tux and an info box (kernel, available memory,
      uptime) in coloured pseudographics, on both screens. `/etc/profile.d/greeting.sh` is
      generated by `sw/tools/mkgreeting.py` (edit the bitmap and box there; `--preview
      out.png` renders it with the HDMI font and palette).
      - It costs ~2 s of the shell prompt (21.2 s after `B` instead of 19.1).
      - It forks nothing: each fork + exec of busybox costs most of a second on the board
        (a `$(cat)` and a `$(sed)` made it 3.3 s).
      - It reads only 90 bytes of `/proc/meminfo`: busybox's `read` takes ~1.5 ms per byte
        there (a `ppoll` with signal masking per byte).
      - The VT shows bright colours as foreground only, so a cell (two pixels) holds at most
        one bright pixel; the picture has its own blue panel.
      - `/dev/vcsa1` dumped with `od -v -b` shows what the HDMI screen holds (glyph and
        attribute per cell).
    - **busybox 1.38.0 `read` from a file (open):** at the interactive prompt, a second
      `read` from a regular file on the same redirection (`while read ...; done < file`,
      `{ read a; read b; } < file`) blocks; with `-t` it times out, in a background job the
      loop ends after one line. From a pipe it works, and the same loop worked in the login
      profile. Not investigated further.
    - **Kernel video drivers** (patches in `sw/br2-external/patches/linux/`):
      - `0003` qervfb: `/dev/fb0` with Y-wrap panning (YOFF).
      - `0004` qervcon (`CONFIG_QERV_CONSOLE`, DT `qerv,tang9k-text`): the text console,
        replacing fbcon (`CONFIG_FRAMEBUFFER_CONSOLE` off). It keeps the ROM's splash on
        screen until the first character other than a blank. It shows the framebuffer while
        a program has the VT in KD_GRAPHICS.
      - Its init sets the default CP437 Unicode map (`con_set_default_unimap`, as vgacon
        and fbcon do): taking over a VT frees the map, and without one every non-ASCII
        character fell back to ASCII (6.18's `ucs_get_fallback`: box drawing became
        `+ - |`, blocks `#`). Fixed 2026-11-11.
      - Its probe costs ~0.2 s of boot. `do_take_over_console` needs `console_lock()`.
      - `0005` spi-qerv: the microSD slot's SPI master, plus hooks in `spi.h` for its
        hardware CRC16. `0006` makes mmc_spi use them (`doc/peripherals.md`).
    - The MMU kernel has `CONFIG_BLOCK` for the SD card (MMC, mmc_spi, VFAT) and I2C
      (`i2c-ocores`, `/dev/i2c-0`). busybox has the i2c tools, `mkfs.vfat` and `devmem`.
    - **Cost of I2C + SD:** +500 KB of kernel; 1,916 KB available after boot (2,820 before).
      `Run /init` moves from 10.3 to 12.5 s.
    - **SD writes are broken (open):** in the first write test, most of a 512 KB file read
      back as zeros, with no errors logged (`doc/peripherals.md`). The user suspects the
      card itself; it hasn't been tried with another card. Don't write to it.
      - Later boots (2026-11-11) found no card at all, on the new bitstream and on
        `tang9k_soc_crc.fs`: the slot is empty or the card no longer answers.
    - **Zicbom:** the MMU kernel has `CONFIG_RISCV_ISA_ZICBOM` (DT `zicbom`,
      `riscv,cbom-block-size = <32>`), for drivers of non-coherent DMA devices.
      - No current driver uses it. The kernel does run `cbo.flush` over its atomic DMA pool
        at boot.
      - `/proc/cpuinfo` shows `rv32ima_zicbom_...`. The kernel is +8 KB.
      - The option selects `DMA_DIRECT_REMAP`, which preallocates a 128 KB atomic DMA pool.
        The bootargs' `coherent_pool=4K` shrinks it to one page; available memory is then
        2,100 KB after boot.
      - Kernel time to `Run /init`: 12.39 s, unchanged.
    - **SD reads:** 72 KB/s buffered (95 KB/s raw) with the SPI-mode CRC on (the default).
      The SPI master computes the CRC16 (patches `0005`/`0006`); in software it was
      44 KB/s.
    - **Mounting the card:** `mount /mnt` (the overlay's `/etc/fstab` adds `usefree`).
      Without `usefree`, the first `df` reads the whole FAT (~3.5 min for 4 GB) in
      uninterruptible I/O, so the shell looks hung.
    - **On-board kernel profiling:** `CONFIG_PROFILING` plus `profile=5` in bootargs; dump
      `/proc/profile` with busybox `od -D` and resolve with System.map. This is how the SD
      costs were found.
    - `CONFIG_VT` needs `patches/linux/0002-vt-four-virtual-consoles.patch`: registering
      63 VT devices took 2.6 s of `chr_dev_init`.
  - **Boot-time findings (both kernels):**
    - `CONFIG_LEGACY_PTYS` must stay off: `pty_init` registering 256 BSD pty pairs took 44
      of 55 s.
    - `sw/br2-external/patches/linux/` holds a kernel patch (in `BR2_GLOBAL_PATCH_DIR`)
      making `__div64_32` use 32-bit `divu`. Patches apply on extract, so use
      `sw/build.sh linux-dirclean` after adding one.
    - **Kernel hash:** `BR2_GLOBAL_PATCH_DIR` is only our `patches/`. Its
      `linux/linux.hash` and `linux-headers/linux-headers.hash` give the sha256 of the
      kernel tarball (the toolchain headers use the same tarball).
      - `BR2_DOWNLOAD_FORCE_CHECK_HASHES` makes a missing hash an error, so a new kernel
        version needs its line in both files, from kernel.org's `sha256sums.asc`.
      - The hash used to come from Buildroot's `board/qemu/patches` (hash files only).
    - **Buildroot output is not byte-reproducible.** Rebuilding with nothing changed gives an
      `Image` of the same size but different bytes: the initramfs carries timestamps.
      Compare images by behaviour, not by checksum.
    - The DT `/chosen/rng-seed`, marked "QRNGSEED", is filled by the boot ROM (`seed_dtb`:
      uninitialized PSRAM page + mtime). An unseeded crng runs a full entropy extraction
      for every random number drawn at boot (~1 s per 150 calls).
    - What is left (`sim/soc/profile.py`): the 100 Hz tick (~25% of cycles: PELT,
      timekeeping, 64-bit math, SBI round trip) and the initramfs unpack.
  - **Profiling:** `PC_PROF=1 [PROF_FROM='console text' PROF_TO='text'] CONFIG=mmu
    sim/soc/run.sh` writes a per-PC cycle profile to `$WORK/soc_<tag>.pcprof`, and
    `python3 sim/soc/profile.py <pcprof> <System.map> --mmu` sums it by kernel function. On
    the board, `initcall_debug loglevel=8` in a DTB loaded with `qerv_boot.py --load` times
    every initcall.
  - **Boot ROM:** `B` boots the kernel in S-mode under the SBI v0.1 shim in the ROM (stack in
    the DT-reserved page 0x807FE000). It delegates the S timer and S external interrupts
    (mideleg 0x220). `sw/mkflash.py --smode` makes `f` / autoboot do the same.
  - **Simulation:** `CONFIG=mmu sim/soc/run.sh` (CPU_SMODE=1, MMU images, boot ROM `B`;
    results in `sim/soc/results/soc_w4-mmu.*`).
  - **Board:** `SMODE=1 fpga/build.sh` (default 0 = stage-1 CPU), then
    `sw/tools/qerv_boot.py --bitstream fpga/impl/pnr/tang9k_soc.fs --linux --mmu`.
  - **MMU timing rule:** keep the TLB compare and the PTE check out of combinational paths
    to and from the bus. The SoC's address decode and read-data mux already make that path
    long. The first version missed 36 MHz at 29 MHz. A compare may gate a strobe, but never
    anything that selects the address: `servile_arbiter` selects the address with ibus_stb.
    A micro-TLB hit gating ibus_cyc fell to 38.7 MHz, which is why the bus is merged.
    - SERV's `o_ibus_cyc` is `ibus_cyc & !i_rst`, which puts the reset net in front of every
      address select. The MMU selects with `o_ibus_sel` (the register, no reset gating; added
      to the fork). With video, that path was 36.6 MHz before the change.
    - Likewise the MMU's translation enable is `o_xlate`, a register in the CSR block updated
      with priv and satp.MODE, not logic on them. With the PLIC and UART interrupt, the priv
      → xlate → address path made 40.1 MHz; with `o_xlate`, 42.06 MHz.
  - **Tests:**
    - `verif/qerv/run_directed.sh` runs `s2_*` tests with SMODE=1 against `iss.py --smode`.
      `s2_eirq` covers SEI; the TB drives SEIP with a store to `0x8000FFF4`. `s2_cbo` (and
      `m1_cbo` on the stage-1 core) covers Zicbom. The TB records each CMO's physical
      address and `(count << 2) | op` at `0x8000FFE8`/`FFEC`, and iss.py models the same.
      (`TESTS="s2_mmu"` selects).
    - `SMODE=1 [ENV=v] verif/qerv/run_riscv_tests.sh` runs the riscv-tests on the stage-2
      core. `ENV=v` (user tests on demand-paged SV32, 512 KB TB RAM) takes ~10 min at W=4.
    - `rv32si-p-dirty` is skipped because MPRV is not implemented.
  - **Debug:** the testbench takes `+vcd=<f> +vcd_start=<cycle> +vcd_end=<cycle>`. Trap-entry
    RF writes trail the serial counter, so anything that selects their RF address must stay
    stable until the next fetch (see `tpriv` in serv_csr).
- **QERV-Linux CPU (M1):** `rtl/qerv/qerv_cpu.v` = SERV `LINUX=1` + MDU + `rtl/qerv/amo_unit.v`.
  - **Zicbom** (both modes): `cbo.inval`/`clean`/`flush` (imm 0/1/2) leave as a byte read of
    rs1 with `o_dbus_cmo` and `o_dbus_cmo_op` (00 inval, 01 clean, 10 flush).
    - There is no immediate, no misalignment trap, and no register write. `cbo.zero` stays a
      no-op.
    - The MMU checks a CMO like a load (R needed, D not) and reports its fault as a store
      page fault (15).
    - No `menvcfg`/`senvcfg`: there are no illegal-instruction traps anyway, so U-mode may
      use them too.
    - At W=1, the decoder must not shift the immediate register holding rs1's address
      (`co_immdec_en[1] & !co_cmo`). Without that, rs1 read as X.
  - `verif/qerv/run_riscv_tests.sh` runs riscv-tests rv32ui/um/ua, p env, in U-mode via `mret`.
    It runs at W=4 and W=1 in ~50 s (env `WIDTHS`, `SUITES`). `ma_data` is skipped because
    SERV traps misaligned accesses, which Linux emulates.
  - `verif/qerv/run_directed.sh` runs `verif/qerv/tests/*.S` self-checking and in lockstep
    with `verif/qerv/iss.py`. `iss.py` is the reference model of the LINUX core: CSRs,
    U-mode, traps, timer IRQ via a TB-written mtip, LR/SC/AMO.
  - Both use `verif/qerv/tb/qerv_tb.v`: qerv_cpu → servile_arbiter → servant_ram. A store to
    `0x8000FFF8` drives mtip; a store to `0x8000FFFC` halts (0 = pass); `+tohost=<hex>` serves
    the riscv-tests.
  - Link test programs with `-Wl,--build-id=none`. Otherwise the build-id note lands at
    `0x80000000`, SERV executes it, and it hangs (no illegal-instruction trap).
  - `fit/qerv_linux/run_fit.sh [4|1]` is the fit probe for qerv_cpu. When qerv_cpu gets a new
    output, fold it into `fit/qerv_linux/qerv_linux_fit_top.v` too: an unused output lets
    synthesis prune its logic, and the probe then reports too little, with no error.
- **Boot-time model** (`perf/`), three pieces:
  - `perf/serv_cpi/run.sh` (~90 s) measures cycles per instruction class on SERV/QERV + MDU
    in Icarus. It checks the RTL against a Python ISS (`iss.py`) and writes
    `perf/serv_cpi/results.json`.
  - `perf/boot_trace/run.sh` boots our `images-tang9k/Image` + DTB at 8 MB by default
    (`STOCK=1` for cnlohr's prebuilt images; env `RAM_MB`, `US`, `TRACE=1` for a PC trace).
    It runs `boot_trace.c`, which is mini-rv32ima's core with hooks:
    - instruction classes and shift-amount histograms
    - split I/D and unified cache simulation
    - UART milestones
    - `-b` DTB and `-T` PC trace

    The CPU state lives outside guest RAM. Results go to `perf/boot_trace/results/`.
  - `python3 perf/estimate_boot.py <trace.json>... [--mhz] [--t0-ns] [--icache/--dcache
    size:line:ways | --ucache size:line:ways] [--wait]` combines the two.
  - **Running the trace:** auto-mode blocks Claude from building or running the downloaded
    emulator/images, so the user runs `perf/boot_trace/run.sh` themselves (via `!`).

## Fit results (GowinSyn 1.9.12.02 SP2, 2026-11-10, core only, no caches/peripherals)

Multipliers use one DSP `MULT36X36` in every row. "Logic" counts each RAM16 as 6 LUTs.
The KianV rows came from probes of splinedrive/kianRiscV at da994e6. Those probes and the
submodule were removed on 2026-11-11, since nothing else used them; git history has them.

| Core | Logic (of 8,640) | CLS | FF | BSRAM | Fmax |
| --- | --- | --- | --- | --- | --- |
| KianV SV32, TLB 64/64 (upstream) | 7,712 (90%) | 93% | 2,424 | 2 | 11.8 MHz |
| KianV SV32, TLB 16/16 | 6,775 (79%) | 86% | 2,112 | 2 | 17.2 MHz |
| KianV no-MMU (uLinux core) | 3,812 (45%) | 56% | 1,165 | 1 | 23.4 MHz |
| QERV (SERV W=4) + MDU + CSR | 953 (12%) | 16% | 541 | 1 (RF) | 50.4 MHz |
| SERV W=1 + MDU + CSR | 821 (10%) | 15% | 505 | 1 (RF) | 61.7 MHz |
| **QERV-Linux (qerv_cpu, W=4)** | 1,313 (16%) | 22% | 644 | 1 (RF) | 50.9 MHz |
| QERV-Linux (qerv_cpu, W=1) | 1,223 (15%) | 21% | 610 | 1 (RF) | 51.7 MHz |

- **KianV SV32:** the critical path is MMU address → DTLB lookup/LRU update (35–38 logic
  levels). As-is it leaves too little room for caches, the PSRAM controller and peripherals.
- **KianV no-MMU:** fits, but at 24 logic levels it misses the 27 MHz crystal.
- **SERV/QERV:** the MDU is the `external/mdu` core (DSP multiply + serial divide).
- **QERV-Linux:** `LINUX=1` costs about +360 logic over plain QERV, about 130 of it ALUs (the
  AMO unit's adder and comparators). The AMO write data is registered in the unit's GAP
  cycle; with it combinational, Fmax was 44 MHz. The next-worst path is SERV's rd mux, where
  the readable mie/mip add a level.
- **Atomic cycle costs (W=4 / W=1):** AMO 26/74, LR 23/71, SC 23–24/71–72 (one more than
  before, since the reservation compare is registered). Plain lw/sw are 22/70.

## Boot-time estimate (2026-11-10)

**SERV/QERV cycles per instruction** (`perf/serv_cpi`): fixed per instruction, measured with
servant_ram's 1-cycle ack. Format is W=1 / W=4.

| Class | Cycles |
| --- | --- |
| ALU, lui/auipc, CSR, ecall/mret | 36 / 12 |
| slt*, branches (taken or not), jal/jalr, left shifts | 68 / 20 |
| Right shifts | 68+s / 20+⌊s/4⌋ |
| Loads/stores | 70 / 22 |
| mul* | 71 / 23 |
| div/rem (fixed time) | 103 / 55 |

Each extra wait state adds 1 cycle per bus transaction.

**Boot traces** (`perf/boot_trace`, cnlohr images, 8 MB vs 16 MB):
- **In 8 MB, neither stock image reaches a usable shell.**
  - The kernel and initramfs reserve ~3.6 MB, and the initramfs files stay pinned in RAM.
  - binfmt_flat needs one contiguous power-of-two block for each program. busybox needs
    552–712 KB, so an order-8 (1 MB) block.
  - 6.1: init fails. 6.8: init starts, but every later exec fails.
  - On RISC-V a FLAT binary's text can't be shared or run in place (pc-relative GOT access ties
    text to data), so every process holds a full copy. The real system needs small binaries and
    few processes.
- **In 16 MB:**
  - 6.8-rc1 reaches the root shell in 35.2M instructions (24.4M to "Run /init").
  - 6.1.14 reaches the login prompt in 46.8M (29.0M to "Run /init").
  - Userspace is under 1M of it. The rest is the kernel: initramfs unpacking, page zeroing,
    and copying/relocating flat binaries on exec.
- **Mix:** ~40% loads/stores, then addi. Atomics are 0.17% (~59k LR/SC/AMO), and there are
  ~12k fences.
- **Caches:** 8 KB direct-mapped with 32 B lines miss ~5% of fetches and ~8% of data
  accesses.

**Estimate** (8 KB/32 B direct-mapped I$ and D$, 1 hit wait state, PSRAM fill
200–450 ns + line/270 MB/s, 6.8 image to shell):

| Core | 27 MHz | 50 MHz |
| --- | --- | --- |
| QERV (W=4) | ~27–28 s | ~15–16 s |
| SERV (W=1) | ~79–80 s | ~43–44 s |

QERV runs at about 0.44 µs/instruction at 50 MHz. Cache misses add only 1–2 s, so CPI
dominates. The trace's time base was 0.3 µs/instr; rerun with `US=0.45` to match QERV
exactly.

**Our image (M0, `sw/build.sh`, 2026-11-10) boots to `~ #` in 8 MB in the emulator:**
- **Instructions:**
  - 51.4M in total: 45.6M kernel to "Run /init", then 5.8M for init and the shell.
  - Each later command costs about 1M instructions, mostly the kernel copying busybox for
    exec.
- **Kernel:** `Memory: 5192K/8192K available` (1577K code, 83K rwdata, 159K rodata, 36K bss;
  the 818K init section is freed). Kernel 6.18.7; RELOCATABLE off via `PHYS_RAM_BASE_FIXED`;
  `LOG_BUF_SHIFT=12`.
- **After boot:** `free` shows 6208K total, 2408K free and 1960K available.
- **Fragmentation:** `/proc/buddyinfo` has one free order-7 (512 KB) block and none larger. So
  one more busybox process (458 KB in RAM, needs an order-7 block) fits next to init and the
  shell, which `ps` confirmed. A two-command pipeline of non-NOFORK applets would not fit.
- **Boot-time estimate:** QERV ~23 s at 50 MHz, ~41 s at 27 MHz. A unified 16 KB/32 B cache is
  equal to split 8+8 KB.
- **Profile (`PROFILE=1`, `perf/boot_trace/profile.py`):** spread out, no single hotspot:
  - memcpy/memset ~15%
  - 64-bit division ~5%
  - scheduler load tracking ~6%
  - printk formatting ~5%
  - slab/kernfs/idr bookkeeping
  The kernel takes ~2× the instructions of cnlohr's 6.8 image to reach init. That is the next
  boot-time lead.

**SERV quirks that matter for Linux.** The first three were found by `perf/serv_cpi`; all are
fixed under `LINUX=1`.
- `wfi` is decoded as `ebreak` and traps (mcause 3).
- `fence`/`fence.tso`/`fence.i` are decoded as loads that don't write rd. They do a real
  byte/halfword read at an address made from the immediate bits; some of those addresses
  have bit 31 set (I/O region).
- `mie` is not readable, so `csrs`/`csrc mie` write MTIE back as 0.
- A timer interrupt that lands on an `ecall` reports mcause `0x8000000F` instead of 7. Bit 3
  is taken from the decoded ecall. Found by the M1 directed test 13; it is an upstream bug.
- An interrupt that lands on a CSR instruction touching mstatus or mie still performs that
  write during the trap cycle. For example, an interrupt on `csrr a5, mstatus` clears MIE
  before the trap saves it into MPIE, so `mret` returns with interrupts off. Linux hit this
  in `do_idle`: `WARN_ON_ONCE(irqs_disabled())`, found with `BREAK_PC` in the SoC sim. It is
  an upstream bug, fixed by `csr_wr_ok` in `serv_csr.v` and covered by directed test 17.
- `mdu_top` doesn't reset `div_ready`/`mul_en`/`mul_done`. That's harmless on the FPGA, but
  4-state simulation needs them initialized.

## Target hardware: the constraints that drive every design decision

- FPGA: Gowin **GW1NR-LV9QN88PC6/I5** (GW1NR-9, device version C). **8,640 LUT4, 6,480 FF,
  26 BSRAM (468 Kbit ≈ 58 KB)**, 20 DSP multipliers, 2 rPLLs. LUTs are the binding resource.
- Main memory: **64 Mbit = 8 MB on-package PSRAM** (HyperRAM-style, 2 × 32 Mbit dies). It is
  **not 32 MB**. Measured: a stock no-MMU kernel + busybox initramfs does not fit (see
  Boot-time estimate). Plan on small binaries and few processes.
- Boot storage: 32 Mbit (4 MB) external SPI flash, which also holds the bitstream. A microSD slot
  is on the board.
- Clock: 27 MHz crystal on pin 52. Button/reset on pin 4. LEDs on pins 10, 11, 13, 14, 15, 16
  (active-low, 1.8 V bank). Console UART: TX 17 / RX 18 (3.3 V), reachable through the
  on-board USB-JTAG/UART bridge.
- The PSRAM dies sit on internal pads, placed by port name (`O_psram_ck`, `IO_psram_dq`,
  ...), not by `IO_LOC` in the user `.cst`. Each die has an 8-bit bus; our controller
  (`rtl/psram/hyperram_x16.v`) runs both in lockstep as one 16-bit bus, so Linux sees one
  contiguous 8 MB. Gowin's IP instead exposed them as two 4 MB channels. PSRAM latency is
  high, so the CPU needs a cache in BSRAM.

## Prior art for Linux at this memory size (checked 2026-11)

- **KianV** (splinedrive/kianRiscV; the paths below are in that repo, as of da994e6). Its
  RV32IMA SoCs boot Linux, and the Tiny Tapeout edition does it with **8 MiB of PSRAM** at
  ~30 MHz, the closest match to this board's memory budget. Several directories under
  `linux_socs/` are symlinks to the same two trees:
  - `kianv_harris_mcycle_edition/` (= `uLinuxSoC`, `linux_nommu_...`): **no-MMU** multicycle
    core with no cache. RTL targets ULX3S / iCESugar-Pro. Its Tang Nano 20K port (8 MB SDRAM)
    is **binary-only** (`demo/tangNano20K/`), so there is no Gowin RTL to start from.
  - `kianv_mc_rv32ima_sv32/` (= `LinuxSoC`, `rv32ima_sv32_zicntr_sstc`): **SV32 MMU** core
    with I/D caches, CLINT, PLIC and SPI NOR boot. Board files live in `engineering/boards/`;
    all are ECP5, Cyclone or Artix, none are Gowin.
  - `LinuxSoC_v2/`: a slimmer rework of the SV32 SoC. Its CPU was split out upstream as
    splinedrive/kianv-rv32-linuxcore.

  All variants talk to SDRAM or QSPI PSRAM, so porting means replacing the memory controller
  with the Gowin PSRAM IP and adding a `.cst` and top level for the 9K. The project chose
  SERV instead (see Fit results).
- **linux-on-litex-vexriscv**: VexRiscv with MMU on LiteX. It needs 32 MB, or 8 MB when the
  rootfs is on SD. It supports the Tang Nano 20K, not the 9K. litex-boards has a
  `sipeed_tang_nano_9k` target, but its HyperRAM support is not mainline-clean.
- **SERV** (olofk/serv; our fork is the submodule `external/sparrow-serv`, below; its
  M-extension unit is `external/mdu`, zeeshanrafique23/mdu). Bit-serial, already proven on this chip in the ov7670 reference.
  Upstream also has a `tangnano9k` servant target (`servant.core`). Today it has:
  - RV32I; M via the external MDU (`MDU=1`); optional C; `W=1` or `W=4` (QERV, NEWS 1.4.0).
  - M-mode only, with mstatus MIE/MPIE, mie.MTIE, mcause, and mtvec/mscratch/mepc/mtval kept
    in the register-file RAM.
  - The timer IRQ only.

  It lacks A, an external IRQ, illegal-instruction traps and S/U modes. CSR addresses are only
  partly decoded (`serv_decode.v`), so e.g. `mhartid` aliases another CSR. It can't run
  Linux as-is.

  **Our fork:** `external/sparrow-serv` is Sparrow-SERV, branch `qerv-linux` of
  `github.com/phoenix367/sparrow-serv` (its README describes the changes). In the submodule,
  `origin` is the fork (fetch over HTTPS, push over SSH) and `upstream` is olofk/serv. A
  change there is committed and pushed in the fork first, then the new submodule pointer is
  committed here.
  - **The fork's CI** (GitHub Actions) keeps upstream's jobs: RISCOF compliance on servant,
    the Verilator lint, riscv-formal and OpenLANE. Two things break it:
    - A new `serv_top` port must also be connected in `servile/servile.v` and
      `rtl/serv_synth_wrapper.v` (inputs tied off). Verilator's PINMISSING is fatal there.
    - `data/verilator_waiver.vlt` waives by line number. An edit above a waived line in
      `serv_top.v`, `serv_decode.v`, `serv_csr.v` or `serv_rf_if.v` must update the waiver.
    - Check locally with FuseSoC: `fusesoc run --target=lint serv --W=1` (and `--W=4`),
      `--target=lint servant --width=1|4`, `--target=lint serving`. It adds `parameter LINUX`, and `LINUX=0` is
  cycle-identical to upstream (`perf/serv_cpi` results unchanged). `LINUX=1` adds:
  - A: one dbus transaction with `o_dbus_amo`/`o_dbus_amo_op`, executed by `amo_unit`.
  - U-mode, with mstatus MPP (00/11) and MPIE readable and writable.
  - Readable mie and mip.
  - Exact 12-bit CSR decode: unknown CSRs read 0 and ignore writes.
  - fence/fence.i/wfi as no-ops, and the mcause fix.
  - Zicbom: `o_dbus_cmo`/`o_dbus_cmo_op` (decode only; the cache does the work).

  The changed files are `serv_decode.v`, `serv_csr.v`, `serv_top.v` and `serv_rf_top.v`;
  `serv_state.v` also exports `o_ibus_sel` (ibus_cyc without the reset gating), and
  `serv_csr.v` (SMODE) has SEIP and `o_xlate`.
  `SMODE=1` adds S-mode and the MMU hooks (stage 2, above). Still absent:
  illegal-instruction traps, the M external interrupt, MPRV.

Linux requires at least RV32IMA. For a normal kernel it also needs an SV32 MMU and
S-mode/M-mode, with OpenSBI or an equivalent M-mode shim. A no-MMU kernel saves logic but
limits userspace.

## Reference projects (read these instead of re-deriving)

- `~/projects/tang_nano_9K_ov7670`: the **same board**. Reuse from it:
  - The headless Gowin flow, `scripts/gw_run.sh` + `scripts/gw_run.tcl` (env: `GOWIN_PATH`,
    `GPRJ`, `STAGE=syn|pnr|all`, optional `TOP`, `PLACE_OPTION`, `ROUTE_OPTION`).
  - The working PSRAM IP setup at 135 MHz `memory_clk` / 67.5 MHz `fb_clk`, including its SDC
    handling. Three hold violations inside the IP's `u_psram_init` are known and can't be
    cleared from user constraints.
  - The `.cst` pin conventions, and `serv_soc/` as a minimal standalone CPU project with
    BSRAM preloaded from `$readmemh`.
  - The CMake + Icarus/ctest simulation infra in `sim/`, including the behavioural
    `sim/common/psram_model.sv`.
  - The `hw-check` skill's `parse_timing.py` for detailed PnR timing (worst paths, TNS).
- `~/projects/mega_138K_test`: a **working Linux bring-up** on a Gowin FPGA (AE350 RV32 on the
  Tang Mega 138K). Reuse its boot-stack approach: OpenSBI, U-Boot and kernel forks as
  submodules, `scripts/build_kernel.sh` with release numbering in `linux/RELEASE`, a
  per-package `scripts/rootfs/build_<pkg>.sh` recipe for every userspace binary, and a
  `boardtest` harness. Its hardware (hard SoC, 1 GB DDR3, FPU) is far larger, so don't copy its
  kernel config or DT sizes.

## Tools on this machine

- Gowin EDA: `/mnt/data/Gowin_V1.9.12.02_SP2_linux` (contains `IDE/` and `Programmer/`). If
  `gw_sh` fails with `License verification failed Server not responding`, retry once.
- Programming: `programmer_cli --run 2` loads SRAM (volatile); `--run 6` writes embedded flash
  (persistent). `openFPGALoader` is also installed.
- Simulation and lint: `iverilog`, `verilator`, `yosys` (in `/usr/bin`).
- RISC-V toolchains:
  - Bare-metal `riscv64-unknown-elf-gcc` under `/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin`.
  - Andes `nds32le-linux-glibc-v5d` (`riscv32-linux-`) under `/mnt/data/toolchains`.
  - Bootlin `~/projects/riscv32-ilp32d--musl--stable-2025.08-1`.
  - The Bootlin and Andes Linux toolchains target the **ilp32d (hard-float) ABI**. An FPU-less
    soft core needs an **ilp32 soft-float** userspace toolchain, which doesn't exist here yet.
    Build it (e.g. with buildroot) rather than reusing those two.
- Scratch builds that need disk space go under `/mnt/data/build/`, because the root disk is
  nearly full.

## Conventions carried over from the reference projects

- Generated Gowin IP (rPLL, PSRAM, BSRAM wrappers) is regenerated through the IDE IP wizard,
  never hand-edited. Keep the `.ipc` next to the output.
- Every new source must be registered in the `.gprj` `<FileList>`. If CMake owns the build,
  register it in the CMake source lists too.
- Every top-level port needs an `IO_LOC` in the `.cst` before PnR.
- `impl/` is build output, not source.
- Testbenches: when sampling a signal the DUT drives with a nonblocking assignment on
  `@(posedge clk)`, insert `#2;` after the edge before sampling. Without it the testbench races
  the NBA.
