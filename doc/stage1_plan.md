# Stage 1 plan: no-MMU Linux on QERV

Status: proposed 2026-11-10; M0, M1 and M2 met 2026-11-10. Background measurements are in `CLAUDE.md` (fit results, boot-time
estimate) and in `fit/`, `perf/`.

The PSRAM notes below (Gowin's IP, memory_clk, calibration, the two channels) describe stage
1 as it was built. Since 2026-11-11 the SoC uses the project's own 16-bit controller instead
(`doc/psram_controller.md`).

## Goal and definition of done

Boot a mainline RV32 no-MMU Linux kernel in M-mode to an interactive busybox shell on the Tang
Nano 9K. The CPU is a modified QERV (SERV at W=4) with the MDU, and main memory is the 8 MB
on-package PSRAM.

Done means all of the following:
- **Boot:** the board boots from its SPI flash to a `#` prompt on the USB UART.
- **Stability:** it survives running the busybox applets in the image without allocation
  failures.
- **Timing:** the measured boot time is compared against the `perf/estimate_boot.py` estimate
  (~27 s at 27 MHz, ~15 s at 50 MHz).
- **Self-checks:** the same kernel + DT also boots in `perf/boot_trace` (the emulator), which
  is our golden reference.

Out of scope (stage 2+): MMU/S-mode, external interrupts/PLIC, SD card, networking, running
above 50 MHz, compressed instructions.

## Facts this plan is built on

- **Fit:** QERV + MDU + CSR = 953 logic (12%), 541 FF, Fmax 50.4 MHz on the GW1NR-9. KianV
  no-MMU = 3,812 (45%) at 23.4 MHz, for comparison.
- **QERV cycle costs:** 12 (ALU/CSR), 20 (branch/jump/slt/left shift), 22 (load/store),
  23 (mul), 55 (div), plus 1 per extra wait state per bus transaction.
- **Instruction mix:** a no-MMU boot to the shell is ~35M instructions, ~40% loads/stores.
  Atomics are 0.17% and fences ~12k.
- **8 MB does not fit as-is:** stock images fail in 8 MB. The initramfs stays pinned in RAM,
  and binfmt_flat needs one contiguous power-of-two block per program (busybox 552–712 KB →
  1 MB).
- **Mainline status:** v7.4-rc2 (checked 2026-11-10) still has `MMU=n`, `RISCV_M_MODE` and
  `ARCH_RV32I`. `XIP_KERNEL` is gone, so the kernel runs from RAM.
- **No shared or in-place program code on RISC-V no-MMU** (found in M0): `-fPIC` code reaches
  its GOT pc-relatively (`auipc`), so a FLAT binary's text and data must stay at the linked
  distance. binfmt_flat therefore copies each binary whole into one contiguous power-of-two
  block per process. Clearing elf2flt's RAM-load flag makes text map from the file and crash
  on the unrelocated GOT. FDPIC, which would fix this, has no RISC-V ABI in GCC 15 / Buildroot.
- **What M-mode Linux needs from the CPU** (`head.S`, `entry.S`):
  - CSRs: mtvec, mscratch, mepc, mcause, mtval, mstatus (MIE/MPIE/**MPP**), mie, mip.
  - `mhartid` reads 0.
  - Writes to `pmpaddr0`/`pmpcfg0` are harmless (they trap or are ignored).
  - `misa` is read only with FPU/V configured.
  - A dummy `sc` runs on every trap return.
  - User mode is detected from `mstatus.MPP`.
  - Timer via CLINT MMIO.
  - The UART can be polled (no IRQ), exactly as mini-rv32ima does.

## Architecture

```
 27 MHz ──► rPLL ──► cpu_clk (27 MHz bring-up, 50 MHz later)
                └──► 135 MHz PSRAM memory clock (ov7670 config)

 ┌───────────────┐  ibus ┐
 │ QERV (W=4)    │──────►│servile_arbiter│──► AMO unit ──► address decode ─┬─► unified cache ─► PSRAM wrapper ─► Gowin PSRAM HS 2ch IP
 │ +MDU +U-mode  │  dbus │ (one master)  │   (LR/SC/AMO,                    │   (BSRAM, WB)      (2×4 MB → 8 MB,
 │ +A decode     │──────►│               │    reservation)                  │                     CDC to 67.5 MHz)
 └───────────────┘                                                          ├─► boot ROM (BSRAM)
         ▲ i_timer_irq                                                      ├─► UART (16550 subset, polled) ─► pins 17/18 (BL702 USB-UART)
         └──────────────────────────────── CLINT (mtime/mtimecmp/msip) ◄────┤
                                                                            ├─► SYSCON (poweroff/reboot)
                                                                            └─► SPI flash reader (P25Q32, read window)
```

**Memory map** = mini-rv32ima's, so one kernel + DT runs both in the emulator and on the board:

| Region | Address | Notes |
| --- | --- | --- |
| Boot ROM | `0x0000_0000` | BSRAM, reset vector, ≤ 4 KB |
| UART | `0x1000_0000` | 16550 register subset, reg-shift 0, no IRQ |
| CLINT | `0x1100_0000` | msip `+0`, mtimecmp `+0x4000`, mtime `+0xBFF8`; timebase 1 MHz (as the emulator) |
| SYSCON | `0x1110_0000` | poweroff/reboot |
| SPI flash window | `0x2000_0000` | 4 MB read-only; boot-time copy of Image + DTB |
| PSRAM | `0x8000_0000` | 8 MB, cached |

**Key choices and why:**
- **One unified cache.** SERV never has ibus and dbus active at once (`servile_arbiter`), so
  one cache serves both. That removes I/D coherence: `fence.i` is a no-op, and the kernel
  writing program text before executing it is safe. 32 B lines match the IP's 32-byte burst.
  Size is 8 or 16 KB, set by M0's unified-cache numbers.
- **Atomics outside the core.** QERV decodes AMO/LR/SC as one bus transaction that carries
  rs2 as write data plus funct5. The returned data goes to rd, like a load. A small AMO unit
  next to the cache does the read-modify-write, holds the LR reservation, and returns 0/1 for
  SC. This keeps the bit-serial datapath change to decode and a "load with write data" path.
  The ALU for amoadd/xor/and/or/min/max/swap is parallel and lives outside SERV.
- **No external interrupts in stage 1.** The 8250 driver polls when the UART has no IRQ, which
  is what the measured traces did. MEIP/PLIC is stage 2 (SD card, responsiveness).
- **No firmware layer.** An M-mode kernel needs no OpenSBI/U-Boot. The boot ROM loads
  Image + DTB and jumps to `0x8000_0000` with a0 = 0, a1 = DTB.
- **Bring-up at 27 MHz.** The CPU domain runs straight off the crystal, so only the PSRAM
  side needs a PLL. 50 MHz comes after Linux boots.

## Work breakdown

### M0: our software image, proven in the emulator (no RTL)

1. **Buildroot external tree.** Create `sw/br2-external/` (name TBD) starting from Buildroot's
   `qemu_riscv32_nommu_virt_defconfig`:
   - Toolchain: uClibc-ng + elf2flt, `rv32ima`/`ilp32` (no C, no F/D).
   - Build output goes under `/mnt/data/build/`.
2. **Kernel.** Pin a current LTS that still has `RISCV_M_MODE`. Config:
   - Must-haves: `MMU=n`, `RISCV_M_MODE=y`, `NONPORTABLE` + `ARCH_RV32I`, `RISCV_ISA_C=n`,
     `FPU=n`, `SMP=n`.
   - Drivers: `BINFMT_FLAT`, `BLK_DEV_INITRD`, `SERIAL_8250` + console + earlycon,
     `CLINT_TIMER`.
   - Size: `CC_OPTIMIZE_FOR_SIZE`, no modules.
3. **DTS.** Derive it from `external/mini-rv32ima/mini-rv32ima/sixtyfourmb.dts`:
   - 8 MB of memory, `riscv,isa = "rv32ima"`.
   - UART compatible `ns16550a`. The emulator only models THR/LSR, so this is safe.
4. **Rootfs.** A trimmed busybox whose whole in-RAM image (text + data + bss + stack) fits an
   order-7 (512 KB) block; each running process holds its own copy. Init goes straight to `sh`, with no getty/login. Compare gzip vs plain
   initramfs (decompression cost vs pinned RAM).
5. **Tracer changes** (`perf/boot_trace`):
   - Add unified-cache configs.
   - Add a `-T` PC-trace dump for M2's lockstep.
   - Make the stop string configurable to our prompt.
6. **Run and iterate.** Boot in `boot_trace` at 8 MB and iterate until it reaches a shell with
   margin. Record instructions and the estimate.

Done when the image boots to a shell at 8 MB in the emulator, with no allocation failures and
≥ 1 MB free after boot. (Running the emulator needs the user, or a permission rule; see
`CLAUDE.md`.)

**M0 status (2026-11-10): met.**
- **Boot:** our image boots to `~ #` at 8 MB in 51.4M instructions, with 2.4 MB free and one
  spare order-7 block.
- **Commands run:** `free`, `cat`, `ps`, `uname`, `ls`.
- **Software:** kernel 6.18.7 and busybox 1.38.0, built by `sw/build.sh`. Busybox is 458 KB in
  RAM per process.
- **Estimate:** QERV ~23 s at 50 MHz. Numbers are in `CLAUDE.md`.

Open follow-ups, none blocking M1:
- Kernel boot is ~2× cnlohr's instruction count to init.
- Drop busybox init (`rdinit=/bin/sh`) to free one more 512 KB block.
- Trim libgcc's 24 KB `.eh_frame` and `getaddrinfo` from busybox.
- Compare a gzip initramfs.

Fallback if 8 MB still doesn't fit: running program text from flash is not possible (see
facts above). The remaining levers are fewer concurrent processes (e.g. `rdinit=/bin/sh`, no
busybox init), splitting busybox into smaller binaries, compressed instructions (C) for ~25%
smaller code, and moving the initramfs to a flash filesystem so its files are not pinned in RAM
(binaries are still copied into RAM to run). The rootfs on SD is stage 2.

### M1: the QERV-Linux core

These changes are made in a SERV fork:

| Change | Detail |
| --- | --- |
| U-mode | 1-bit privilege. Trap entry: MPP ← priv, priv ← M. `mret`: priv ← MPP, MPP ← U. `ecall` cause 8 (U) / 11 (M). |
| CSR decode | Full 12-bit match for the implemented CSRs. Every other CSR reads 0 and ignores writes (`mhartid`, `misa`, `pmp*`, counters). This also fixes today's aliasing, where a `pmpaddr0` write could land on another CSR. |
| mstatus/mie/mip | MIE, MPIE, MPP (FS/VS read 0); mie.MTIE (MSIE/MEIE writable, unused); mip.MTIP readable. |
| fence / fence.i / wfi | No-ops. This removes the spurious dbus read (found in `perf/serv_cpi`) and the wfi→ebreak trap. |
| A extension | Decode opcode `0x2F` → dbus transaction with `amo`, `funct5`, rs2 data, address = rs1 (immediate forced to 0); rd ← returned data. |

Verification:
- **Lockstep ISS:** extend `perf/serv_cpi/iss.py` and the lockstep testbench with A, U-mode,
  CSR semantics and the no-op fences/wfi, and add directed tests for each.
- **Compliance:** run riscv-arch-test via SERV's RISCOF plugin (`external/sparrow-serv/verif`) for
  rv32i/m/a. riscv-formal (SERV has RVFI) is optional.
- **Measurements:** re-run `fit/qerv` (LUT/Fmax delta) and `perf/serv_cpi` (cycle costs for
  AMO/LR/SC).

Done when the lockstep and arch tests pass at W=4 (and W=1), and the size/Fmax delta is
recorded.

**M1 status (2026-11-10): met.**
- **Fork:** SERV branch `qerv-linux` (local, `LINUX` parameter), plus `rtl/qerv/amo_unit.v` and
  `rtl/qerv/qerv_cpu.v`.
- **Tests:**
  - riscv-tests rv32ui/um/ua: 59/59 at W=4 and W=1. `ma_data` is skipped because SERV traps
    misaligned accesses.
  - The directed lockstep suite (`verif/qerv`) passes at W=4/W=1 with 0 and 1 wait states.
  - `LINUX=0` is cycle-identical to upstream.
- **Fit:** 1,313 logic cells (16%) at 50.9 MHz.
- **Bug found:** a timer IRQ on an `ecall` gave mcause 15. It is fixed under `LINUX`, and is
  also present upstream.
- **Not done:**
  - RISCOF / riscv-arch-test; riscv-tests were used instead.
  - riscv-formal.
  - Illegal-instruction traps. Not needed by the M-mode kernel config; revisit if user code
    misbehaves.

### M2: SoC RTL in simulation

1. **Bus and memory path:**
   - Fabric: arbiter → AMO unit → decoder.
   - Unified write-back cache.
   - PSRAM wrapper: maps the two IP channels into one 8 MB space (addr[22] selects the
     channel), crosses clock domains to the IP's user clock, and does 32-byte bursts.
2. **Peripherals:**
   - UART: 16550 subset, ≥ 1 Mbaud.
   - CLINT: has a test mode where `mtime` advances per retired instruction (the same time
     model as `boot_trace -u`), so interrupts land at identical points.
   - SYSCON.
   - SPI flash reader.
3. **Boot ROM firmware:**
   - UART banner.
   - Wait for PSRAM calibration.
   - Load the image: if the host sends a magic word within ~0.5 s, receive it over UART;
     otherwise copy Image + DTB from SPI flash.
   - Jump.
4. **PSRAM model.** Write a user-interface-level model of the Gowin PSRAM IP for Verilator.
   Calibrate its latency once against the Gowin IP + the ov7670 pin-level model
   (`sim/common/psram_model.sv`) in Icarus.
5. **Full Linux sim.** A Verilator top-level that preloads the M0 image and boots Linux,
   about 700M cycles (minutes in Verilator). Compare its PC trace with `boot_trace -T` in
   lockstep.

Done when the simulated SoC boots the M0 image to a shell and matches the emulator's PC trace.

**M2 status (2026-11-10): met, except the PC-trace comparison** (`boot_trace -1` plus the
per-fetch CLINT tick are ready, but the emulator step needs the user; the boot works, so it is
kept as a debugging tool).
- **Boots:** the RTL SoC (`sim/soc`, Verilator, PSRAM model calibrated to the real IP)
  reaches `~ #` from preloaded PSRAM and also via the boot ROM's SPI flash copy. Shell
  commands work.
- **Timing at 27 MHz:**
  - Prompt after 1.88G cycles = **69.5 s** (80.3M instructions, CPI 23.4).
  - The flash copy adds 4.7 s.
- **Memory after boot** (same as the emulator): 2392 KB free and one spare order-7 block.
- **Bugs found by booting Linux, now fixed:**
  - SERV `LINUX`: an interrupt on a CSR instruction corrupted MIE/MPIE (upstream bug,
    directed test 17).
  - UART: IIR must report pending sources for the polled 8250 driver.
- **Why slower than the estimate (~41 s):** the RTL boot spans 4.5× more 10 ms ticks (69 s vs
  ~15 s of emulated time). Tick, scheduler and timekeeping work is ~14% of instructions, plus
  64-bit software division.
- **Follow-ups for boot time:**
  - Faster CPU clock (40 MHz planned).
  - Lower HZ, or a cheaper tick.
  - A write-no-allocate path for the flash copy (~185 cycles/word today).

Do early in M2: a fit probe for the PSRAM IP + wrapper alone, to replace the guessed LUT
cost in the budget below.

### M3: fit and timing on the GW1NR-9

1. **Project.** Create the Gowin project and its build target, alongside `fit/run_probe.sh`.
2. **Pins:**
   - clk 52, UART 17/18, LEDs.
   - SPI flash pins: take them from the Sipeed schematic. The external flash is separate
     from the embedded config flash, so it is free for data; `openFPGALoader
     --external-flash` writes it.
3. **SDC.** Copy the PSRAM clock and multicycle constraints from ov7670.

Done when PnR closes at 27 MHz with margin and utilization is recorded.

**Status (2026-11-10, with the Gowin PSRAM IP): met.** `fpga/build.sh` builds
`fpga/tang9k_soc.gprj` (top `fpga/src/tang9k_top.v`).
- **Clocks:** memory_clk 72 MHz (rPLL 27 × 8 / 3, written by hand in
  `fpga/src/gowin_rpll/gowin_rpll.v`); SoC on the IP's clk_out at 36 MHz, which divides the
  CLINT's 1 MHz and the 1 Mbaud UART exactly.
- **PSRAM calibration vs memory_clk (board, `fpga/probe/run.sh`, IP netlist below):** both
  channels calibrate at 54, 67.5, 72–77.1, 84–135 MHz (in ~15–27 ms). At 77.6 and 78 MHz
  channel 1 never calibrates; at 81 MHz neither does. 78 MHz was the first choice and hung
  the CPU on its first PSRAM access; 72 MHz is ~5 MHz clear of the band.
- **PSRAM IP:** the ov7670 project's generated netlist (`psram_hs_2ch` v1.0, generated for
  135 MHz, module `Video_frame_buffer`), copied unchanged. It is the netlist the simulation
  model was matched to. The IDE in 1.9.12 lists this IP under "Deprecated"; IP generation
  there failed on the license.
- **Utilization:** logic 3,869/8,640 (45%), FF 1,965, CLS 60%, BSRAM 11/26, DSP 2,
  IOLOGIC 39/97.
- **Timing:** cpu_clk Fmax 43.1 MHz against 36 MHz (with the SYSCON status counters; 46.9
  MHz before them). Setup is clean everywhere.
- **Hold:** 11 violations, all inside the IP, `u_psram_init/calib_0_s0` (cpu_clk) → IDES4
  CALIB (memory_clk), worst −0.84 ns. This is the class the ov7670 build has (3 paths, worst
  −0.25 ns there), not reachable from user SDC; the PSRAM calibrates on that board.
  Watch the calibration LED and the M4 memtest.
- **Flash:** JEDEC `85 60 16` (Puya, 4 MB). Pins 59–62 are the MSPI dual-purpose pins, so
  the build sets `use_mspi_as_gpio`. openFPGALoader reads it over JTAG at only ~0.65 KB/s,
  so load kernels over UART during bring-up. It held ~11.7 KB of RISC-V code at offset 0
  (likely the factory demo).

### M4: hardware bring-up ladder

Each step gets a small test program run from the boot ROM or loaded over UART:
1. Boot ROM banner.
2. 8 MB PSRAM memtest through the cache, plus a raw-PSRAM test.
3. CLINT timer interrupt.
4. LR/SC/AMO test.
5. UART image download.
6. Linux to shell (UART-loaded image).
7. Boot from SPI flash.
8. Measure boot time, then raise cpu_clk to ~50 MHz.

Done when the stage-1 definition of done above is met.

**Status (2026-11-10): steps 1, 2, 5 and 6 pass on the board.** The boot ROM
(`sw/bootrom/bootrom.S`) is a command monitor driven by `sw/tools/qerv_boot.py`:
- **1 Banner:** at 1 Mbaud.
- **2 Memtest:** all 8 MB through the cache (address-in-data, inverted, byte lanes) in 46 s.
- **5 UART download:** 2.7 MB Image in 27 s (98 KB/s), checked by the receive hash and a
  re-hash of PSRAM.
- **6 Linux to shell:** `Run /init` at 37.7 s and `~ #` at 43.2 s after `b` (36 MHz). `free`,
  `uname`, `/proc/cpuinfo` and `/proc/meminfo` work. About 32 s of the boot is the kernel
  between `workingset` and the 8250 probe (initramfs unpacking).
- **Still open:** step 3 (CLINT timer) and 4 (LR/SC/AMO) have no dedicated test, though
  Linux exercises both. Step 7 (boot from SPI flash) needs the image written to the
  flash, ~1 h over JTAG with openFPGALoader. Step 8 (faster clock) is limited by the IP
  calibration band and Fmax ~43 MHz.

## Resource budget (estimate except where marked)

| Block | Logic (LUT-equiv.) | BSRAM |
| --- | --- | --- |
| QERV + MDU + CSR | 953 (measured) | 1 (RF) |
| M1 core changes | 200–400 | – |
| AMO unit | 150–250 | – |
| Unified cache controller | 300–500 | 5–9 (8–16 KB data + tags) |
| PSRAM IP + wrapper | unknown, measure early in M2 | ? |
| UART | 200–300 | 0–1 |
| CLINT | 200–300 | – |
| SPI flash reader + SYSCON + decode | 200–350 | – |
| Boot ROM | ~20 | 1–2 |
| **Total excluding PSRAM IP** | **~2.2–3.1k of 8,640** | **~8–13 of 26** |

## Risks

| Risk | Mitigation |
| --- | --- |
| 8 MB too tight even when trimmed | M0 runs before any RTL; fallbacks listed under M0 |
| No-MMU removed from mainline later | Pin an LTS that has it; v7.4-rc2 still does |
| AMO path in the bit-serial core is harder than expected | Keep atomics memory-side. Fallback: an in-core micro-sequence (load phase → ALU phase → store phase) |
| PSRAM IP cost/latency/CDC | Reuse ov7670's proven config. Early fit probe; calibrated model |
| Timing with PSRAM placement pressure (ov7670 needed route_option 2) | Bring up at 27 MHz; same SDC approach |
| UART download speed via the BL702 | Measure max baud in M4 step 1. Flash boot doesn't depend on it |
| Auto mode blocks running the downloaded emulator/images | User runs those steps (`!`) or adds a permission rule |

## Decisions needed from the user

1. **SERV fork:** a GitHub fork of olofk/serv as the submodule (recommended, like the
   mega_138K boot-stack forks), or patches kept in this repo.
2. **Kernel version to pin**, once M0 shows which LTS builds cleanly for RV32 M-mode.
3. **Cache size (8 vs 16 KB)** and gzip vs plain initramfs, from M0's numbers.
