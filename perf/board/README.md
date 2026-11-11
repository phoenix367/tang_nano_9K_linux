# On-board performance tests (qperf)

`qperf.c` measures the CPU, the kernel and the memory system under the MMU Linux on the
board. `run.py` builds it with Buildroot's toolchain (static, uClibc-ng), boots the board,
uploads the binary to `/tmp` over the UART, runs it and saves the output under `results/`.

```
perf/board/run.py                     # boot as at power-up (both flashes), run everything (~2.5 min)
perf/board/run.py --attach            # the board already sits at a shell prompt
perf/board/run.py cpu mem.latency     # only tests whose names start with these
perf/board/run.py --boot '--bitstream X.fs --linux --mmu'   # another boot (qerv_boot.py args)
```

Nothing is written to either flash, and the kernel image stays as it is. A binary already in
`/tmp` with the right md5 isn't sent again. Raw UART and boot logs go to `$WORK/qperf/`.

## Method

- **best vs avg.** "best" is the fastest of many ~1 ms runs, well under the 10 ms tick
  period: the hardware or the kernel path alone. "avg" is a long run's mean: what a program
  gets once the timer tick has taken its share. `cpu.*` and `mem.*` report best; `os.*`
  report avg with best in the details.
- **Instruction classes:** inline-asm loops of 32 and 64 copies; (t64 − t32) / 32 cancels the
  loop. The loops' data word sits at a page offset that can't share a cache line with their
  code.
- **Time:** the `time` CSR (CLINT mtime, 1 MHz). Cycles assume 42 MHz.
- **Counters:** SYSCON words 5 and 6 (cache misses and write-backs) through `/dev/mem`. They
  count the whole system, so best runs only take them from runs that no interrupt touched.
- **Page colours:** the 16 KB direct-mapped cache is as large as 4 pages, so lines collide by
  physical address bits 13:5: the frame's low 2 bits (its colour) and the page offset.
  Random frames give random conflicts. The mem tests read frame numbers from
  `/proc/self/pagemap` and build buffers from pages of chosen colours, moved into place with
  `mremap`:
  - consecutive colours, like contiguous memory;
  - chase lines that would share a cache line with the chase code are left out.
  Without that, the curve was noise: 2 KB came out slower than 4 KB, and 16 KB slower than
  24 KB.
- **Upload:** the shell stops busybox `script` (the HDMI console mirror) while
  `head -c N < /dev/ttyS0` takes the bytes.
  - `script` writes to a non-blocking pty and drops what doesn't fit, so through it uploads
    lost bytes.
  - 8 KB/s works. At 16 KB/s bytes were still lost, with no UART overruns counted.

## Results

`doc/performance.md` has the results and what they mean: cycles per instruction class, the
timer tick's share of the CPU, kernel paths, memory latency and bandwidth, and the page-colour
effects. The raw output of each run is in `results/`.
