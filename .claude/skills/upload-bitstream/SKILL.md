---
name: upload-bitstream
description: Load an FPGA bitstream (.fs) onto the Tang Nano 9K, either into SRAM for a test run (gone at power-off) or into the GW1NR-9's internal flash so it loads at every power-up. Use this whenever the user wants to load, program, flash, upload, install or try a bitstream, FPGA design or SoC build on the board, or wants a fresh `fpga/build.sh` result running on the hardware, even if they don't say "bitstream". Also covers which bitstream the board holds and checking a build's timing before trusting it.
argument-hint: "[sram|flash] [file.fs]"
---

# Upload a bitstream to the Tang Nano 9K

| | SRAM (default) | Internal flash |
| --- | --- | --- |
| Lasts | until power-off or a reconfigure | loads at every power-up |
| Command | `openFPGALoader -b tangnano9k <fs>` | `openFPGALoader -b tangnano9k -f <fs>` (~12 s) |

Load into SRAM unless the user asks for the design to stay (flash it, make it permanent,
boot it at power-up). The internal flash is what the board runs when someone just plugs it
in, and the write erases it first: an interrupted write leaves the board with no design at
power-up. So write it only on an explicit request. "Flash both" means this skill plus
`upload-kernel` (SPI flash).

## 1. Pick the bitstream

- A fresh build is `fpga/impl/pnr/tang9k_soc.fs`. The current system is built with
  `SMODE=1 VIDEO=1 fpga/build.sh` (~2 min). `SMODE=0` is the stage-1 no-MMU CPU, which can't
  run the MMU kernel. Without `VIDEO=1` there is no HDMI, text console or splash, and the MMU
  kernel's DT names those devices.
- Check the build's timing before it goes on the board:
  ```
  python3 .claude/skills/upload-bitstream/scripts/timing_summary.py
  ```
  It prints the bitstream's md5 and date, Fmax against each clock's constraint, TNS, the
  worst paths and the logic use. It exits 1 if a clock misses. `cpu_clk` must reach 42 MHz
  with TNS 0. A design that misses can still pass a quick test and then corrupt data at
  random, so don't load one that misses unless the user knowingly wants to try it. (Hold
  violations inside the PSRAM IP's `u_psram_init` are a known, harmless exception; see
  CLAUDE.md.)
- Copy the build to a named file and load the copy:
  ```
  cp fpga/impl/pnr/tang9k_soc.fs /mnt/data/build/tang9k_linux/tang9k_soc_<tag>.fs
  ```
  The next build overwrites `fpga/impl/`. The named copies are how CLAUDE.md records what
  the board holds (`ls -lt /mnt/data/build/tang9k_linux/*.fs` lists the earlier ones). Pick
  a short tag for the change (`cbo`, `irq`, `text`).
- **The kernel has to match.** The kernel's device tree describes the hardware of the
  bitstream it was built with. On a bitstream without the text buffer, I2C or SPI blocks,
  that kernel's drivers talk to hardware that isn't there, and an older kernel can't use
  newer hardware. Pair a new
  bitstream with the kernel from the same point in time. When persisting, flash both.

## 2. Preflight

Put logs (`<log>` below) in the session's scratchpad directory.

```
pgrep -a 'programmer_cli|openFPGALoader'; lsusb | grep 0403:6010
```

- Only one program can hold the JTAG cable. If one of them is left over from an earlier run
  in this session, `kill -9` it (`programmer_cli` ignores SIGTERM). Otherwise openFPGALoader
  fails with "unable to claim usb device". Don't kill one you didn't start; ask instead,
  because it may be the user's Gowin programmer mid-write.
- If the board isn't in lsusb, ask the user to plug it in.
- Loading any bitstream resets the SoC and loses PSRAM, so a running Linux session is gone.
  Mention it if the user was using the board.

## 3a. SRAM

- To run something on it right away, let `sw/tools/qerv_boot.py` do the load. Its
  `--bitstream` option loads the SRAM first, then talks to the boot ROM:
  - `--bitstream <fs> --linux --mmu --timeout 120 --log <log> --input 'uname -a\n'` boots
    the kernel images over the UART (see `upload-kernel`).
  - `--bitstream <fs> --autoboot --timeout 120 --log <log>` sends nothing, so the ROM
    autoboots the SPI flash's kernel as at power-up.
  - `--bitstream <fs> --load prog.bin@0x80000000 --boot --timeout 5` runs a bare-metal test
    (`sw/tests/`).
- To load only: `openFPGALoader -b tangnano9k <fs>`. The boot ROM then prints `QERV boot ROM`
  on the UART (`/dev/ttyUSB1`, 1 Mbaud) and autoboots the flash's kernel after 2 s.
- `qerv_boot.py --reconfig ...` goes back to the internal flash's design without a power
  cycle.

## 3b. Internal flash

```
openFPGALoader -b tangnano9k -f /mnt/data/build/tang9k_linux/tang9k_soc_<tag>.fs 2>&1 \
  | tr '\r' '\n' | grep -aE 'CRC|rror'
```

- Success is `CRC check: Success`. On anything else, write again before the board is
  power-cycled.
- When writing both flashes, write the SPI flash first (`upload-kernel`, `flash_linux.sh`).
  Its tool erases the FPGA's SRAM and leaves Gowin's bridge there. Then write this one, then
  verify.
- Verify the power-up path:
  ```
  sw/tools/qerv_boot.py --reconfig --autoboot --timeout 120 --log <log> --input 'uname -a\n'
  ```
  This reloads the design from internal flash, as at power-up. Look for the ROM banner in
  the log and `[shell prompt after N s]` from the tool. With the current system that's about
  25 s. If the SPI flash holds no kernel, the banner alone confirms the design.
- Then update "What the board holds now" in CLAUDE.md: the named `.fs`, the date, and which
  kernel image it pairs with.

## Report

Say which file went where (path, md5 or tag), its Fmax and TNS, and the verification result
(ROM banner, shell prompt time). For a flash write, also say what it replaced: that comes
from CLAUDE.md's record before the update.
