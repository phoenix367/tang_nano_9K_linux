---
name: upload-kernel
description: Put a Linux kernel on the Tang Nano 9K, either booted from RAM over the UART (temporary, the default) or written to the SPI flash so the board autoboots it at power-up. Use this whenever the user wants to run, boot, try, load, upload, flash or install a kernel, Image, DTB, device-tree or rootfs/initramfs change on the board, or asks what kernel the flash holds, even if they don't say "upload". Covers the stage-2 MMU kernel (default) and the no-MMU one.
argument-hint: "[ram|flash] [mmu|nommu]"
---

# Upload a kernel to the Tang Nano 9K

| | RAM (default) | SPI flash |
| --- | --- | --- |
| Lasts | until reset or power-off | boots at every power-up |
| Tool | `sw/tools/qerv_boot.py` over the UART | `sw/tools/flash_linux.sh` (Gowin programmer, JTAG) |

Boot from RAM unless the user asks for the kernel to stay (flash it, make it boot at
power-up). The SPI flash is what the board boots when someone just plugs it in. A failed or
interrupted write leaves it erased or half-written, and then the board boots no Linux until
a write succeeds. So write it only on an explicit request. "Flash both" means this skill plus
`upload-bitstream` (internal flash).

## 1. Pick and check the images

- MMU kernel (stage 2, the default):
  `/mnt/data/build/tang9k_linux/images-tang9k-mmu/Image` and `tang9k-mmu.dtb`. No-MMU:
  `images-tang9k/Image` and `tang9k.dtb`.
- Make sure they are built from the current sources. Compare their dates with the sources'
  last changes (`sw/br2-external/board/tang9k-mmu/`, `patches/linux/`, the rootfs overlay).
  If a source is newer, rebuild:
  - after a `linux.config` change: `CONFIG=mmu sw/build.sh linux-reconfigure`
  - after a DTS change: `CONFIG=mmu sw/build.sh linux-rebuild` (the DTB is built with the
    kernel)
  - after a new or changed patch: `CONFIG=mmu sw/build.sh linux-dirclean` (patches apply on
    extract)
  - then `CONFIG=mmu sw/build.sh`, which copies Image and DTB into `images-tang9k-mmu/`
  - drop `CONFIG=mmu` for the no-MMU kernel
- **The bitstream has to match.** The DT describes the devices of the bitstream the kernel
  was built for (text buffer, I2C, SPI, the CPU's extensions). The MMU kernel needs an
  `SMODE=1 VIDEO=1` bitstream. CLAUDE.md "What the board holds now" names the bitstream in
  internal flash. If it is older than the kernel's hardware, load the matching bitstream for
  a RAM boot, or flash both.

## 2. Preflight

Put logs (`<log>` below) in the session's scratchpad directory.

```
fuser /dev/ttyUSB1; pgrep -a 'programmer_cli|openFPGALoader'; lsusb | grep 0403:6010
```

- `/dev/ttyUSB1` is the console UART. If a terminal holds it, ask the user to close it.
- Only one program can hold the JTAG cable. If a `programmer_cli` or `openFPGALoader` is
  left over from an earlier run in this session, `kill -9` it (`programmer_cli` ignores
  SIGTERM). If you didn't start it, ask: it may be the user's own programmer mid-write.
- If the board isn't in lsusb, ask the user to plug it in.
- If a tool sees garbage or no echo on the UART, run `sw/tools/console.sh --prime`. The
  BL702 USB bridge applies the baud rate of the previous port open.

## 3a. RAM boot

```
sw/tools/qerv_boot.py --bitstream <fs> --linux --mmu --timeout 120 --log <log> --input 'uname -a\n'
```

- `<fs>` is the bitstream that matches the kernel. Omit `--bitstream` only when the boot ROM
  is known to sit at its `> ` prompt. After a reset the ROM autoboots the flash after 2 s,
  so this is rarely the case.
- No-MMU: drop `--mmu`. That uses `images-tang9k/` and the ROM's `b` instead of `B`.
- Another image or DTB: `--load Image@0x80000000 --load my.dtb@0x807ff000 --boot` (add
  `--mmu` for an S-mode boot).
- `--input` types shell commands one character per echo. Give it the commands that prove the
  change (e.g. `grep isa /proc/cpuinfo\n`, `dmesg | grep foo\n`). Avoid `--console`: it is
  interactive and needs a real terminal.
- The tool hash-checks every upload twice and stops on a mismatch, so don't boot after one.
  Success is `[shell prompt after N s]` on its output. The current MMU kernel reaches
  `Run /init` about 12.4 s after the ROM's `B`, plus the upload time. Run it in the background if it may take
  longer than a couple of minutes.

## 3b. SPI flash

1. **Keep what is on the flash now.** `flash_linux.sh` rebuilds
   `images-tang9k-mmu/flash.bin` from the current Image, and that file is the only copy of
   the last image written. Before running it, copy the old one aside if no copy exists yet
   (`cmp` against the `flash_mmu_*.bin` files):
   ```
   cp /mnt/data/build/tang9k_linux/images-tang9k-mmu/flash.bin /mnt/data/build/tang9k_linux/flash_mmu_<old-tag>.bin
   ```
2. **Write**, in the background, with no outer `timeout`:
   ```
   sw/tools/flash_linux.sh mmu > <log> 2>&1
   ```
   - It takes about 1–1.5 min for 3.4 MB when the bridge works. `SPLASH=<image>` sets the
     boot splash picture. `JTAG_FREQ` sets the cable's TCK (default 2.5MHz; slower didn't
     cure the stalls).
     For the no-MMU kernel, run `flash_linux.sh nommu`; its image is
     `images-tang9k/flash.bin`.
   - The Gowin bridge sometimes stalls. The script's watchdog stops an attempt whose
     progress hasn't moved for 60 s, reconfigures the FPGA and tries again, up to 3 times.
     Don't kill the script from outside: that leaves `programmer_cli` holding the cable and
     the flash half-written.
   - Success is exit 0 with `flash written (GAO bridge)` or `flash written (openFPGALoader)`
     at the end of the log.
   - After 3 failed bridge attempts (`GAO bridge: flash write failed after 3 attempts`) the
     script falls back to openFPGALoader `--external-flash` by itself. That path has not
     failed so far, but it takes ~77 min for 3.4 MB (it prints its progress every 10%).
     Tell the user the write is on the slow path and when it should end. If it fails too,
     tell the user the SPI flash is erased or partial, so the board boots no Linux until a
     write succeeds (the boot ROM still starts and a RAM boot still works).
   - `METHOD=bridge` stops after the bridge's attempts instead (exit 1), e.g. to try a USB
     replug first: unplug and replug, then run again before anything opens `/dev/ttyUSB1`
     (the BL702 turns JTAG off while its UART is in use; that this helps is untested).
     `METHOD=openfpgaloader` skips the bridge: on 2026-11-11 it failed about 15 times in a
     row, at any TCK.
3. **Verify.** Afterwards the FPGA no longer runs the SoC (it holds Gowin's bridge, or
   openFPGALoader erased it).
   - If the internal flash holds the matching bitstream (or you write it now, after this,
     with `upload-bitstream`), boot the power-up path:
     ```
     sw/tools/qerv_boot.py --reconfig --autoboot --timeout 120 --log <log> --input 'uname -a\n'
     ```
   - Otherwise, compare the flash with the file, then boot it:
     ```
     sw/tools/qerv_boot.py --bitstream <fs> --hash-flash /mnt/data/build/tang9k_linux/images-tang9k-mmu/flash.bin --flash-boot --timeout 120 --log <log>
     ```
   Success is `[shell prompt after N s]`. With the current system that's about 25 s after
   the ROM prompt, including the flash copy.
4. **Record it.** Copy the new image to `/mnt/data/build/tang9k_linux/flash_mmu_<tag>.bin`.
   Then update "What the board holds now" in CLAUDE.md: the image, its sizes, the date, the
   paired bitstream and the boot time.

## What is on the flash?

The flash starts with a header (`sw/mkflash.py`): `"QRVL"`, Image length, DTB length, and
flags (bit 0 = S-mode), then `"SPLH"`, splash offset and splash length. While Linux runs on
the board, read it without disturbing anything:

```
for a in 0x20000000 0x20000004 0x20000008 0x2000000c 0x20000010 0x20000014 0x20000018; do devmem $a 32; done
```

Compare it with `xxd -l 32 <flash_mmu_*.bin>`. A full comparison needs the boot ROM
(`--hash-flash`, which loads a bitstream and ends the running session).

## Report

Say which Image and DTB (sizes and dates) went where, and how it was verified (shell prompt
time, hash match, the commands' output). For a flash write, also name the saved copy of the
previous image and the bitstream it pairs with.
