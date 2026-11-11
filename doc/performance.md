# Performance on the board

What the system does per cycle under Linux, measured on the Tang Nano 9K with the qperf suite
(`perf/board/`). The CPU's instruction costs and the cache, PSRAM and TLB come from user-space
loops. The kernel's costs come from system calls, context switches, fork, exec and page
faults. The timer tick's share of the CPU is measured too.

- **Measured:** 2026-11-11 and -12.
- **Board:** `tang9k_soc_unc.fs` at 42 MHz (SMODE=1 VIDEO=1, the 16-bit PSRAM controller, a
  16 KB direct-mapped write-back cache with 32-byte lines).
- **Kernel:** #7, Linux 6.18.7: HZ 100, periodic tick, `PREEMPT_NONE`, uClibc-ng user space,
  booted from the flashes.
- **Raw output:** `perf/board/results/2026-11-11_2351.txt`. A second full run and five runs of
  the latency curve give the ranges below.

## Summary

- **CPU:** every instruction costs the simulation's cycles plus 1, or plus 2 for a load or a
  store. That is 13 cycles for an ALU op, 21 for a branch or shift, 24 for a load, store or
  multiply, 56 for a divide: about 2 million instructions per second in ordinary code.
- **The timer tick and an SD-card poll take 35–45% of a busy CPU.**
  - The tick takes ~25%: each 100 Hz tick runs ~4,500 kernel instructions (~107K cycles,
    ~500 cache misses), and evicts most of the running program's working set.
  - Polling the empty microSD slot, once a second, takes another 10–20%.
  - On average a program gets 0.5–0.75 of its best-case speed.
- **Memory:** a dependent load costs ~26.5 cycles in the cache and ~55.7 from PSRAM.
  - The step comes exactly at 16 KB, the cache size.
  - The data TLB covers 512 KB; beyond that page walks add ~7 cycles.
  - Streaming is limited by the CPU, not the PSRAM: loads from PSRAM run at 3.7 MB/s, 94% of
    the in-cache rate, out of the PSRAM's 74.7 MB/s.
- **The kernel is slow on this CPU:**

  | Operation | Cost |
  | --- | --- |
  | system call | 136 µs (5.7K cycles) |
  | pipe round trip | 9–20 ms |
  | fork | ~80 ms |
  | exec of a BusyBox command | ~180 ms |
  | anonymous page fault | 3.3 ms (138K cycles) |

  fork and exec dominate interactive use: every shell command that isn't a builtin pays both.
- **Direct-mapped conflicts:** two lines collide when their physical addresses agree in bits
  13:5, so results depend on where things land in physical memory. A `memcpy` between pages
  of the same colour runs 30% slower.

## CPU

Cycles per instruction from inline-asm loops of 32 and 64 copies: (t64 − t32) / 32 cancels
the loop overhead. Each loop runs in ~1 ms chunks, and the fastest chunk is taken, so the
timer tick drops out. The data word the loads and stores use sits at a page offset that
can't share a cache line with the loop code.

| Class | Board | Simulation, 1-cycle bus (`perf/serv_cpi`) |
| --- | --- | --- |
| add, lui, CSR read (`rdtime`), fence (a no-op) | 13 | 12 |
| slt, slli, srli by 1, branch taken or not, jal | 21 | 20 |
| srli by 16 / by 31 | 25 / 28 | 24 / 27 |
| lw, lb, sw, sb | 24 | 22 |
| mul, mulh | 24 | 23 |
| div | 56 | 55 |
| amoadd.w | 29 | 26 |
| lr.w + sc.w | 51 | 46–47 |

The board adds one cycle to every instruction fetch: a cache hit takes one cycle more than
the simulation's ideal bus. Loads and stores pay that once more on the data access, and an
AMO pays it more times still.

Both runs gave the same figures to within 0.1 cycle; the stores varied by 1.3 cycles.

C workloads:

| Workload | best | avg |
| --- | --- | --- |
| CRC32, table-driven, 1 KB of data | 235 KB/s | 116–118 KB/s |
| `qsort` of 2048 ints (libc) | | 1.02–1.03 s |

## The timer tick and the SD-card poll

What a busy loop loses on the board (`os.tick`: 0.5 ms chunks for 2 s):

| | Share of the time lost | Cycles per tick period | Cache misses per tick |
| --- | --- | --- | --- |
| As booted (4 runs) | 35–45% | 147K–189K | 667–834 |
| `mmc_spi` unbound (2 runs) | 24.6–26.8% | 103K–112K | 483–515 |

Two things take that time.

- **The SD-card poll, 10–20%.**
  - The slot has no card-detect line, and `of_mmc_spi.c` then sets `MMC_CAP_NEEDS_POLL`.
    It doesn't read the `non-removable` property.
  - So the MMC core rescans the slot every second. In an empty slot, each rescan tries a
    full card initialization at up to four clock rates over SPI.
  - The CPU waits on every SPI byte. The SPI core also updates a dozen 64-bit statistics per
    transfer, each guarded by a seqcount on a 32-bit kernel.
  - The cost varies with the retries. The slot has been empty on recent boots.
- **The tick itself, ~25%:** 103–112K cycles, about 4,500 instructions.

Where the tick's cycles go comes from a simulation profile: 369 ticks under a busy loop, with
the SD poll and the loop's own system calls taken out (recipe below). It gives 107K cycles
per tick, matching the board.

| Part | Cycles per tick | Instructions | Share | Biggest pieces (cycles per tick) |
| --- | --- | --- | --- | --- |
| Scheduler tick and PELT load tracking | 34.3K | 1,481 | 32% | `decay_load` 5.8K (11 calls), `__update_load_avg_se` 4.2K, `__update_load_avg_cfs_rq` 3.6K, `update_curr` 2.8K, `update_rq_clock` 2.4K |
| Timekeeping | 31.9K | 1,372 | 30% | `memcpy` 11.0K (5 calls), `__timekeeping_advance` 7.3K, `timekeeping_update_from_shadow` 2.6K, `timekeeping_cycles_to_ns` 1.9K |
| IRQ dispatch | 8.6K | 312 | 8% | `__radix_tree_lookup` 1.4K: the RISC-V intc registers a tree IRQ domain |
| Timers, hrtimers, softirq | 6.2K | 251 | 6% | `__hrtimer_run_queues` 1.2K, `run_posix_cpu_timers` 1.1K |
| Timer interrupt and rearming it | 5.7K | 232 | 5% | `clockevents_program_event` 1.7K, `get_cycles64` 1.2K |
| 64-bit shifts in libgcc | 5.4K | 268 | 5% | `__lshrdi3` 2.5K, `__ashldi3` 2.5K |
| Trap entry and exit | 4.6K | 185 | 4% | `handle_exception` 1.6K, `ret_from_exception` 1.0K |
| CPU time accounting | 2.5K | 96 | 2% | |
| SBI shim in the boot ROM | 1.3K | 73 | 1% | the M-mode timer interrupt handed to S, then `set_timer` |
| Other: run-queue lock, EEVDF pick, RCU | 6.9K | 272 | 7% | |
| **Total** | **107K** | **4,544** | | 23.6 cycles per instruction |

- **The path is ordinary Linux code.**
  - About 4,500 instructions is what a tick costs on a 32-bit CPU. On this one, at ~24 cycles
    each, it takes 2.6 ms, a quarter of the 10 ms period. A 100-MIPS core would spend 0.4%.
  - The SBI round trip through the boot ROM, an early suspect, is 1%.
- **64-bit arithmetic on a 32-bit CPU inflates it:**
  - PELT decays its sums with 64-bit fixed-point multiplies, 11 times per tick.
  - Every tick copies the whole `struct timekeeper` out of its shadow copy. It also updates
    two latched fast timekeepers, each with two copies of `tk_read_base`: 5 `memcpy`
    calls, 11K cycles. The source notes the first copy "could be avoided by switching
    pointers".
  - Variable 64-bit shifts are libgcc calls because the kernel is built with `-Os`
    (`CONFIG_CC_OPTIMIZE_FOR_SIZE`). That also leaves one-line helpers out of line.
- **The tick flushes the cache.**
  - Its ~500 misses mean its code and data take about as much as the whole 16 KB cache.
  - A program finds its working set gone after every tick and has to refill it. That's why
    CRC32 averages 0.49 of its best (2.04× slower), more than the time lost alone would
    explain.
- **It runs when idle too:** the kernel is built with `CONFIG_HZ_PERIODIC`.

The profile:

```
CONFIG=mmu VIDEO=1 PC_PROF=1 PROF_FROM='; done' INPUT='while :; do :; done\n' \
  MAX_CYCLES=1100000000 sim/soc/run.sh               # ~14 min; the prompt at 900M cycles
python3 sim/soc/profile.py $WORK/soc_w4-mmu-video.pcprof <linux>/System.map --mmu
```

- The per-PC fetch counts also give call counts: the fetches of a function's first
  instruction.
- hush's `while :; do :; done` isn't pure user code: it calls `waitid()` on every iteration,
  ~420 times a second. Those calls are taken out above.

## Kernel paths

"avg" is a long run's mean, the time a program actually sees. "best" is the fastest single
run; its misses come from the SoC's counters.

| Operation | avg | best | best: cycles, cache misses |
| --- | --- | --- | --- |
| `getppid()` system call | 185–188 µs | 136–141 µs | 5.7K–5.9K, 12–18 |
| `clock_gettime(CLOCK_MONOTONIC)` | 349–358 µs | 271 µs | 11.4K, 10–12 |
| `sched_yield` round trip with a second process (2 switches) | 5.8–6.4 ms | 0.85 ms | 36K, ~200 |
| 1-byte pipe round trip between two processes (4 syscalls, 2 switches) | 19.4–20.1 ms | 9.0–9.3 ms | 380K–390K, ~2,250 |
| `fork` + `_exit` + `waitpid` | 81.5 ms | 75–76 ms | 3.2M, ~16,700 |
| `vfork` + exec `/bin/true` (BusyBox) + `waitpid` | 185–228 ms | 175–179 ms | 7.4M–7.5M, ~38,000 |
| first write to an anonymous page (mmap/munmap included) | 3.4–7.3 ms | 3.3 ms | 138K, ~700 |
| tmpfs write, 128 KB in 4 KB calls | 583–585 KB/s | | |
| tmpfs read, 128 KB in 4 KB calls | 707–1,130 KB/s | | |

- **Sleep and wakeup are expensive.** A pipe round trip costs ten times a `sched_yield`
  round trip with the same number of switches. The difference is the sleep and wakeup path,
  with its scheduler bookkeeping in 64-bit arithmetic on a 32-bit CPU.
- **`clock_gettime` costs twice a `getppid`:** the time conversion is 64-bit multiplies and
  divides in software.
- **A page fault** zeroes the page (4 KB of stores, 128 write-allocate misses) and takes about
  700 misses in all.
- **The `sched_yield` average** is far above its best: two runnable tasks share the CPU by the
  scheduler's slices, not by each yield.
- **No debug options:** the kernel config has none that would explain these costs.
  `SECCOMP` is on, which costs nothing without filters.

## Memory latency

A pointer chase: each line of the working set holds the address of the next, in random
order, and the loop does 16 dependent loads per iteration.
- The working set is built from pages of consecutive colours, as contiguous memory would be.
- Lines that would share a cache line with the chase code are left out (a few per page).
- Best of 40 runs of ~1 ms; five runs of the curve.

| Working set | Cycles per load (typical, range) | Misses per load |
| --- | --- | --- |
| 2 KB | 26.6 (26.5–30.5) | 0.00 |
| 4 KB | 26.5 (26.4–27.9) | 0.00–0.03 |
| 8 KB | 28.0 (27.4–36.1) | 0.01–0.02 |
| 12 KB | 28.6 (28.1–31.3) | 0.02–0.10 |
| 16 KB | 28.3 (28.2–29.9) | 0.02–0.07 |
| 20 KB | 39.1 (38.7–39.6) | 0.41–0.43 |
| 24 KB | 46.6 (46.6–46.7) | 0.67–0.68 |
| 32 KB | 55.6 (one run 69.6) | 1.00–1.01 |
| 64 KB – 512 KB | 55.6–57.6 | 1.01 |
| 1 MB | 62.6 (62.5–63.0) | 1.06–1.08 |

- **A hit:** 24 cycles for the `lw`, ~2 for the loop's share, and up to ~2 more when the load
  changes pages. Each bus keeps a one-page micro-TLB; a miss in it costs 2 cycles at the
  main TLB.
- **A miss to PSRAM** adds ~29 cycles: one 18-cycle burst for the 32-byte line plus the
  cache's and the arbiter's own cycles.
- **Above 16 KB the direct-mapped cache misses on every line whose set holds more than one:**
  - 20 KB (5 pages): the first and fifth pages share a colour, so 2 of 5 pages miss;
  - 24 KB: 4 of 6 pages;
  - from 32 KB on, all of them.
  In a random order each line is visited once per lap, so a shared set misses every time.
- **TLB:** the data half of the TLB has 128 direct-mapped entries, 512 KB. At 1 MB two pages
  share each entry, and the page walks add ~7 cycles per load.
- **Outliers:** single runs at 8 KB and 2 KB came out 4–8 cycles slow with no extra cache
  misses, and one 32 KB run at 69.6. These were not explained.

## Bandwidth

Best runs. The 1 MB tests stream through the buffer in 8 KB pieces, so every piece comes
from PSRAM.

| Test | In the cache (8 KB) | From/to PSRAM (1 MB) | Misses per 32 B |
| --- | --- | --- | --- |
| word loads, 8 per iteration | 3.92 MB/s | 3.66 MB/s | 0.17 / 1.04 |
| word stores | 5.82–5.83 MB/s | 5.11–5.14 MB/s | 0.02 / 1.04, 0.23 write-backs |
| libc `memset` | 5.24–5.30 MB/s | 4.70–4.71 MB/s | 0.03 / 1.04 |
| libc `memcpy`, pages of different colours | 1.73 MB/s (4 KB) | 1.32–1.33 MB/s (512 KB) | 0.08 / 2.2–2.4 |
| libc `memcpy`, pages of the same colours | | 0.93 MB/s | 14, 6.2 write-backs |
| `/dev/fb0` stores, uncached (`0x9070_0000`) | | 5.83–5.84 MB/s | 0 |
| `/dev/fb0` loads, uncached | | 2.83 MB/s | 0 |

- **The CPU limits every stream.** A line of loads costs ~343 cycles of instructions and a
  miss adds ~24, so PSRAM reads run at 94% of the in-cache rate. The PSRAM itself moves a
  line every 18 cycles, 74.7 MB/s, shared with the video DMA.
- **uClibc's `memcpy` copies at less than half the rate of a load loop.** It is C, compiled
  to move one word per step with a jump each time.
- **A `memcpy` between pages of the same colour thrashes:** each load evicts the
  destination line and each store the source line, 14 misses per 32 bytes. Pages that are
  any multiple of 16 KB apart physically have the same colour, and the page allocator often
  hands out consecutive frames, so this happens in practice.
- **Uncached stores are posted:** they cost the same as cached ones. An uncached load waits
  for its PSRAM read, about 17 cycles more.

## Direct-mapped conflicts: how much placement matters

The first version of the suite didn't control placement, and its numbers were noise:
- `lw` took 37.5 cycles and `lb` 24 in the same run: the data word shared cache lines with
  the `lw` loop's code;
- the chase came out slower at 2 KB than at 4 KB, and at 16 KB than at 24 KB;
- a hot 8 KB buffer missed on almost every line: its two pages had the same colour.

Kernel paths move with the program's own layout too. The first build measured `getppid` at
1.19 ms average; the next build, with only test code changed, at 0.185 ms. That was most
likely its syscall loop sharing cache sets with the kernel's entry path. It was seen once
and not reproduced on purpose.

## What it points at

1. **The SD poll and the tick are the largest levers.**
   - **Stop polling the empty slot, 10–20% of the CPU.** A small kernel patch could make
     `of_mmc_spi.c` honour `non-removable`, so the card is scanned once at boot; the cost is
     SD hot-plug. Unbinding the driver at runtime does the same:
     `echo spi0.0 > /sys/bus/spi/drivers/mmc_spi/unbind`.
   - **Tick less often.** At 50 Hz the tick's ~25% would halve. 100 Hz is the lowest choice
     in `kernel/Kconfig.hz`, so a lower rate needs a small patch there.
   - **Make each tick cheaper.** Building with `-O2` instead of `-Os` would inline the 64-bit
     shifts and the small helpers, but a larger kernel costs RAM. The timekeeper copies and
     PELT are generic kernel code.
2. **An assembly `memcpy` and `memset` for uClibc on RV32** (8 loads, then 8 stores per line)
   should about double `memcpy`.
3. **fork, exec and page faults** cost 0.08–0.2 s each; every non-builtin shell command pays
   them. Fewer forks are the cheapest win: the greeting script already avoids them
   (CLAUDE.md, "Greeting").
4. **Conflict misses** make any result depend on placement. Two ways to make the cache more
   robust:
   - **associativity:** a 2-way cache costs logic and a second tag compare;
   - **page colouring** in the kernel's page allocator.
   Only 2 block RAMs are free, so the cache can't simply grow.

## How it was measured

```
perf/board/run.py                     # boot as at power-up, upload qperf, run all (~2.5 min)
perf/board/run.py --attach cpu os     # a running board; only these tests
```

`perf/board/README.md` describes the tool. The method in brief:
- **Units:** rates are decimal (1 KB/s = 1,000 B/s, 1 MB/s = 10^6 B/s). qperf prints KB/s
  of 1,024 bytes; the figures here are converted.
- **Time:** the `time` CSR (the CLINT's mtime, 1 MHz); cycles assume 42 MHz.
- **best vs avg:** best is the fastest of many short runs, well under the 10 ms tick, so the
  tick drops out. avg is a long run's mean.
- **Counters:** cache misses and write-backs come from SYSCON words 5 and 6 through
  `/dev/mem`. They count the whole system. A best run's counts are taken only from a run
  that no interrupt reached around the counter reads: a tick there would add its misses but
  not its time.
- **Page colours:** the mem tests read physical frame numbers from `/proc/self/pagemap` and
  build each buffer from pages of chosen colours, moved into place with `mremap`.
- **Upload:**
  - The binary goes to `/tmp` over the UART at 8 KB/s, with an md5 check.
  - BusyBox `script` (the HDMI console mirror) is stopped meanwhile. It writes the UART's
    input to a non-blocking pty and drops what doesn't fit.
