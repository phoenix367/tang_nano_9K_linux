# I2C and microSD

Two peripherals added after the video work (2026-11-11), both in the I/O region behind
`soc_top`'s I/O register stage, in every build (not behind a parameter).

## I2C: the OpenCores master from the ov7670 project

- **RTL:** `rtl/i2c/` is the OpenCores I2C master (Richard Herveille's `i2c_master_top`,
  byte and bit controllers), copied from `~/projects/tang_nano_9K_ov7670/src/i2c`.
  - Three mechanical changes, noted in each file's header: the `timescale` include and the
    Icarus-only `#1` delays and `$dumpvars` are gone, and `i2c_master_defines.v` is inlined.
  - The logic is unchanged.
  - The ov7670 project's `i2c_control_fsm.v` (its camera-register sequencer) is not used:
    Linux drives the core directly.
- **Bus:** `0x1130_0000`, 8-bit registers at word offsets (PRERlo, PRERhi, CTR, TXR/RXR,
  CR/SR). The core acks one cycle after the request and writes in its ack cycle, while
  `soc_top`'s `io_*` registers still hold the request.
- **Interrupt:** PLIC source 2 (`plic #(.SOURCES(2))`, DT `riscv,ndev = <2>`).
- **Pins:** SDA 25, SCL 26, the ov7670 project's pins. They are open drain with the FPGA's
  weak pull-ups; devices usually bring their own.
- **Linux:** mainline `i2c-ocores`, no patch.
  - DT: `opencores,i2c-ocores` with `reg-shift = <2>`, `reg-io-width = <4>`,
    `opencores,ip-clock-frequency = <42000000>`, `clock-frequency = <100000>`.
  - Config: `CONFIG_I2C`, `CONFIG_I2C_CHARDEV`, `CONFIG_I2C_OCORES`.
  - busybox: `i2cdetect`, `i2cget`, `i2cset`, `i2cdump`, `i2ctransfer` on `/dev/i2c-0`.
- **Tests:**
  - `verif/i2c/run.sh` (seconds) runs the core against `rtl/sim/i2c_eeprom_model.v`, a
    24C02-like clocked slave at 0x50. It uses the driver's register sequences: prescale,
    a pointer + 3-byte write, a pointer write + repeated start + 4-byte read, a NACK from an
    absent address, and the interrupt with IACK.
  - The SoC simulation (`sim/soc/tb_soc.v`) has the same EEPROM model on its I2C lines.

## microSD: an SPI master and mmc_spi

- **Why SPI mode:** the card's native 4-bit mode would need command/data state machines,
  CRC on four lines and a Linux host driver. The CPU, not the card, limits the transfer
  rate, so SPI mode with mainline `mmc_spi` is enough.
- **RTL:** `rtl/soc/spi_master.v` at `0x1140_0000`:
  - mode 0, MSB first, one chip select;
  - SCK = 42 MHz / (2 · (DIV + 1));
  - 8- and 32-bit data registers.
  - Every access but a STATUS read waits on the bus while a transfer is in progress. The
    driver therefore never polls: it writes to start and reads to collect. A chip-select
    write lands only after the last bit.
  - MISO is sampled at the end of each bit, in the clock that drives SCK low. The card's
    output then has a whole SCK period (47 ns at 21 MHz) to arrive.
  - **Hardware CRC** (CRC register, `0x10`): the SD data-block CRC16 (CRC-ITU-T,
    x^16 + x^12 + x^5 + 1, initial value 0) of the bits sent (bits 31:16) and received (15:0).
    It is computed as the bits shift; a write restarts both, and a read waits for the
    transfer in progress.
  - Register layout: in the file header.
- **Pins:** CLK 36, MOSI (CMD) 37, CS (DAT3) 38, MISO (DAT0) 39, from litex-boards
  `sipeed_tang_nano_9k.py`. The slot has no card-detect line.
- **Linux:**
  - `patches/linux/0005-spi-qerv-sd-card-spi-master.patch`: `drivers/spi/spi-qerv.c`
    (`CONFIG_SPI_QERV`, DT `qerv,tang9k-spi` with `clock-frequency`). It moves 4 bytes per
    access where it can.
    - It restarts the CRC with each data transfer (more than 2 bytes) and keeps the result.
    - It adds two optional hooks to `include/linux/spi/spi.h`:
      `spi_controller.rx_crc_itu_t()` returns the CRC of a transfer's received data, and
      `spi_transfer.tx_crc_itu_t` sends the CRC of the previous transfer's data instead of
      `tx_buf`.
  - `patches/linux/0006-mmc-mmc_spi-hardware-crc.patch`: mmc_spi uses those hooks instead of
    `crc_itu_t()` when the controller has them. A read whose data needed bit-shifting falls
    back to software.
  - `mmc_spi` on top, as `mmc-spi-slot` at `spi-max-frequency = <21000000>`. With no
    card-detect interrupt, mmc_spi polls for the card once a second.
  - Config: `CONFIG_BLOCK` (it was off), `CONFIG_MMC`, `CONFIG_MMC_BLOCK`,
    `CONFIG_MMC_SPI`, `CONFIG_SPI`, `CONFIG_VFAT_FS` with code page 437 and ISO 8859-1. No
    swap, loop devices or extra I/O schedulers.
  - busybox: `mkfs.vfat`.
- **Tests:** `verif/spi/run.sh` (seconds) uses a mode-0 slave model with an output delay. It
  checks:
  - 8- and 32-bit transfers both ways (byte order);
  - back-to-back writes;
  - waits while busy (STATUS doesn't wait);
  - CS changing only between bytes;
  - the SCK period per DIV;
  - MOSI setup;
  - a 30 ns slave at 21 MHz;
  - the CRCs: the CRC-16/XMODEM check value (0x31C3 for "123456789") sent, 0x7FA1 for a
    512-byte block of 0xFF, the slave's bytes against a reference, and a CRC read waiting
    for the transfer in progress.

  Six mutants each fail it:
  - sampling MISO at the rising edge;
  - CTRL writes not waiting;
  - the wrong byte order;
  - the TX CRC fed from the next bit;
  - the wrong CRC polynomial;
  - a CRC read not waiting.

## Timing: the AMO unit's SC compare (found with these peripherals)

- **The problem:** with I2C and SPI in (73% logic), the build reached 38.4–39.9 MHz against
  42 MHz with every place/route option. Over-constraining the SDC (`SDC_MEM_MULT=29/30` in
  `fpga/build.sh`) made it worse.
- **The cause:** in most failing paths, the AMO unit's SC reservation compare
  (`res_adr == i_cpu_adr[31:2]`, a 30-bit carry chain) sat between the MMU's translated
  address and the core's ack. Synthesis shared that logic with the ack path.
- **The fix** (`rtl/qerv/amo_unit.v`): the compare is registered, and an SC spends one cycle
  in a new state `S_SCCHK`.
  - Cost: one cycle per SC.
  - Result: Fmax 45.7 MHz (TNS 0) at 74% logic, BSRAM 24/26.
  - With the hardware CRC (+7 LUTs) the next build placed at 42.25 MHz, still TNS 0. Its
    worst paths are SERV-internal and the video DMA: placement variance.
  - Tests: directed 16/16 in both modes; riscv-tests stage 1 51/51 and stage 2 64/64, at
    both widths.

## Board results (2026-11-11, UART-loaded MMU kernel; bitstream now `/mnt/data/build/tang9k_linux/tang9k_soc_crc.fs`)

- **SD card:** a 4 GB SDHC card is detected as `mmcblk0` with one partition, and mounts
  read-only as VFAT. No SPI or CRC errors.
- **SPI clock:** the CTRL register reads DIV 0 (21 MHz) after transfers.
- **Read speed** for 1 MB (2,048 blocks):

  | | Software CRC | Hardware CRC (now) | CRC off (`mmc_core.use_spi_crc=0`) |
  | --- | --- | --- | --- |
  | raw, `iflag=direct` | 18.2 s (56 KB/s) | 10.8 s (95 KB/s) | 10.6 s (97 KB/s) |
  | buffered (file reads) | 23.0 s (44 KB/s) | 14.2 s (72 KB/s) | 13.8 s (74 KB/s) |

- **Hardware CRC checks:**
  - A throwaway kernel whose driver reported the CRC with one bit flipped got
    `I/O error, dev mmcblk0, sector 0, 1, 2, ...` for every block. Card initialization still
    succeeded, because the mmc core turns the SPI CRC on only after reading the card's
    registers (some SDHC cards send bad CRCs on short blocks).
  - With the real kernel: two reads of a 6.2 MB file, and of the first raw MB, gave the same
    MD5 sums, with no I/O errors.

- **Where the time goes:** a tick profile of a 1 MB read, before the driver's aligned fast
  path (`CONFIG_PROFILING` with `profile=5`, `/proc/profile` dumped with busybox
  `od -D`), 10.7 ms per block:
  - `crc_itu_t` 34%: the mmc core checks each block's CRC16 in software, ~300 cycles a
    byte;
  - `qerv_spi_transfer_one` 26%: the unaligned helpers took 28 instructions a word. The
    aligned path now takes 8;
  - the SPI core's per-message bookkeeping ~25%: statistics, message optimize, three
    `spi_sync` calls per block in mmc_spi.
- **CRC is on by default.** It is the only check of the data on the wire. With the hardware
  CRC it costs 2–3% of read time; in software it cost 40%.
- **I2C on the board:** `i2cdetect -y 0` runs cleanly (3.6 s) and finds nothing: no device is
  connected to pins 25/26. The read/write path is verified in simulation: the SoC sim with
  the EEPROM model runs `i2cdetect`, `i2cget`, `i2cset` and `i2cdump` and gets the expected
  values.
- **Cost:**
  - Kernel: +500 KB. Block layer ~180 KB, MMC core ~130 KB, FAT/NLS ~73 KB, SPI and I2C
    cores ~30 KB each. BFQ is off (it was 36 KB).
  - `free` after boot: 1,916 KB available (2,820 KB before).
  - `Run /init`: 12.5 s of kernel time (10.3 s before). About 0.6 s is block-layer setup;
    about 1.6 s is the card detection and partition scan. That runs in a workqueue but
    shares the one CPU with the remaining initcalls.
  - The shell comes 17.9 s after a UART-loaded `B` (15.7 s before).
- **`df` and the FAT:** without `usefree`, the first statfs (`df`) after a mount counts the
  free clusters by reading the whole FAT.
  - On this card (4 GB FAT32) that was 3.9 MB over SPI: about 3.5 minutes.
  - It is in uninterruptible I/O wait, so Ctrl-C does nothing and the shell looks hung.
  - The FAT filled the buffer cache: free memory dropped to ~350 KB, and the console echo
    lagged by up to 3 s.
  - `usefree` takes the count from the FAT32 info sector instead: mount 0.8 s, `df` 0.6 s.
    The counts matched on this card.
  - The MMU rootfs has `/etc/fstab` (`rootfs-overlay/etc/fstab`) with
    `/dev/mmcblk0p1 /mnt vfat noauto,usefree`, so `mount /mnt` mounts the card.
  - A card mounted read-write when the board is reset keeps FAT's dirty flag. Linux then
    warns at every mount ("Volume was not properly unmounted") and leaves the flag alone
    until an fsck clears it; busybox has no `fsck.vfat`. `poweroff` unmounts (inittab
    `umount -a -r`).

## Open problem: writes come back as zeros (2026-11-11, under investigation)

**Don't write to the card yet.**

- **Test:** a 512 KB random file from `/tmp` was copied to `/mnt` with `cp` + `sync`,
  taking 9.3 s. After `drop_caches` it read back with a different MD5.
  - The first 448 KB (7 × 64 KB, mmc_spi's largest request) reads as zeros, through both
    buffered and `iflag=direct` single-block reads.
  - The last 64 KB (the request written at `sync`) is correct.
  - Repeated reads give the same result, and no errors are logged.
- **What this shows:** the card accepted every block, and with CRC on it checks each block's
  CRC16. With the hardware TX CRC, though, that CRC covers only the bits actually shifted
  out. So it would also match a block that was all zeros when it left the SPI master.
- **Not yet known:** whether the zeros were sent, written elsewhere, or lost in the card.
  Whether the file's FAT chain is right is not checked either.
- **What was written:** only the test file `/mnt/qerv_wtest.bin` and the FAT/directory
  updates for it.

## Not done

- Fixing the write path (above). `verif/spi` checks the TX CRC values, but no test covers
  mmc_spi's write sequence against a card model.
- The no-MMU kernel's DT has neither controller.
