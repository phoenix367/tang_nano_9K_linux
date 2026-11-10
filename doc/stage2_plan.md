# Stage 2 plan: SV32 MMU Linux on QERV

Status (2026-11-10): **met on the board.** The SV32 kernel boots in S-mode under the boot ROM's
SBI shim to `~ #` in 55 s (UART-loaded, 36 MHz), with fork, pipelines and shared busybox text.
Stage 1 (no-MMU M-mode Linux) is in `doc/stage1_plan.md`.

## Progress

- **S2-M0 software:** `CONFIG=mmu sw/build.sh` builds `images-tang9k-mmu/{Image,tang9k-mmu.dtb}`
  (Image 2.74 MB, static busybox 423 KB). `CONFIG_EFI` must be off: it defaults to y with MMU
  and forces `RISCV_ISA_C` on (its "MZ" header is a compressed instruction).
- **S2-M1 privilege (SERV `SMODE=1`):**
  - `verif/qerv/tests/s2_priv.S` passes in lockstep with `iss.py --smode` at W=4/W=1, 0/1
    wait states.
  - riscv-tests on the stage-2 core: rv32si-p 5/6 (`dirty` skipped: it needs MPRV),
    rv32ui/um/ua-p all pass.
  - Fit: core 1,560 logic (stage 1: 1,313).
- **S2-M2 MMU (`rtl/qerv/sv32_mmu.v`):**
  - `verif/qerv/tests/s2_mmu.S` passes in lockstep (permissions, SUM/MXR, A/D, reserved
    PTEs, misaligned superpage, sfence, LR/SC/AMO, delegated faults).
  - riscv-tests `rv32ui-v` (demand-paged SV32, riscv-tests env/v) 41/41 at W=4.
  - Fit: core + MMU 1,827 logic (22%), 829 FF, 3 BSRAM (RF + 2 TLB), Fmax 41.5 MHz. With the
    timing restructure and the micro-TLB (`fit/qerv_linux/run_fit.sh 4 1`): 1,960 logic
    (23%), 956 FF, Fmax 46.7 MHz.
- **Bugs found on the way:**
  - The RF writes of a trap's epc/tval trail the counter, and their RF address depends on
    the trap target. That target came from the privilege, which changes at the end of the
    trap, so the last nibble of sepc went to mepc. Fixed with `tpriv`.
  - The data-fault trap flag must stay up until the next fetch, like the misaligned one.
  - After a faulting dbus ack SERV keeps `dbus_cyc` up two more cycles; the MMU took that
    as a new request, and its walk later faulted onto the ibus in the middle of the trap
    stage. Fixed with a DONE state and a latched request bus.
  - Level-sensitive interrupts in SMODE: SERV's edge detection on the combined MTI|STI line
    could lose an MTI while a delegated STI keeps the line high.
  - The first SoC build missed timing (29 MHz). The TLB tag compare drove the physical
    address combinationally (LOOK issued the request), and the PTE check sat right behind
    the SoC's read-data mux. The request now goes out from ACC with the registered PPN, and
    PTEs are registered and checked in PCHK (one extra cycle per access).
  - The micro-TLB fast path (below) first missed 42 MHz (38.7 MHz): its VPN compare gated
    the ibus strobe, and `servile_arbiter` selects the address with that strobe, so the
    compare fed the cache RAM address and the whole read-data mux. The MMU now merges
    fetches, data and PTE reads onto one physical bus (out through the AMO unit on the dbus
    port; the ibus port is idle), selected by the core's registered `ibus_cyc` and the walk
    state. `qerv_cpu` reports physical fetches on `o_dbg_fetch`/`o_dbg_pc` for the testbench
    trace and the SoC profiler.
- **S2-M3 SoC:**
  - `SMODE=1 fpga/build.sh`: logic 4,932/8,640 (58%), BSRAM 13/26, cpu_clk Fmax 39.7 MHz
    against 36. The worst path is the stage-1 arbiter / read-mux path again.
  - The CLINT exports mtime to the CPU.
  - `CONFIG=mmu sim/soc/run.sh` boots the kernel to `~ #` in Verilator: 2.24G cycles (83.0 s
    at 27 MHz), 93.6M instructions. Stage 1 was 1.89G cycles / 80.3M instructions. That run
    used the MMU before the timing restructure, which is functionally the same.
- **S2-M4 board** (`qerv_boot.py --bitstream ... --linux --mmu`):
  - Timing: `Run /init` at 51.5 s, `~ #` at 55.0 s (stage 1: 43 s). About 45 s of it is the
    kernel between `workingset` and the 8250 probe (initramfs unpacking).
  - `/proc/cpuinfo`: `mmu : sv32`.
  - `free`: 3,352 KB free, 2,916 KB available (stage 1: 2,408 / 1,960).
  - Processes: `sh -c` forks a child, `sleep 2 & sleep 1 & ps; wait` runs three processes
    at once, and three-stage pipelines work.
  - `/proc/self/maps` shows busybox text mapped r-xp from the page cache (shared, not
    copied).
  - **Boot from SPI flash:** `sw/tools/flash_linux.sh mmu` writes the image (header flag =
    S-mode) in 57 s. The boot ROM's hash of the flash matches the file. With the bitstream
    loaded and no command sent, the ROM autoboots after 2 s: the flash copy is done 5.6 s
    after the prompt and `~ #` comes at 60.6 s.
  - **Standalone:** the stage-2 bitstream is in the FPGA's internal flash (openFPGALoader
    `-f`, 12 s). After a reconfigure from it (as at power-on), the board autoboots Linux to
    `~ #` with no host commands.
- **Boot time** (MMU kernel; "B" is the time from the `B` command, "power-on" the time
  from the boot ROM prompt to `~ #`):

  | Step | B | Power-on |
  | --- | --- | --- |
  | First boot (36 MHz) | 55.0 s | 60.6 s |
  | `CONFIG_LEGACY_PTYS` off (`pty_init`: 44 s, found with `initcall_debug`) | 20.6 s | |
  | `__div64_32` with hardware divides (kernel patch) | 20.2 s | |
  | 42 MHz CPU (memory_clk 84 MHz) + RNG seeded from the DT | 14.1 s | 19.3 s |
  | Micro-TLB: last page per bus, skips the TLB lookup (2 cycles per access) | 12.0 s | 17.1 s |

  The micro-TLB moved `Run /init` from 10.37 s to 8.87 s of kernel time. In the simulated
  profile, the same kernel functions lost 2–2.7 cycles per instruction (memcpy 23.2 → 20.8,
  `__update_load_avg_se` 27.2 → 24.5). Build: logic
  4,913/8,640 (57%), BSRAM 14/26 (the boot ROM is 4 KB = 2 blocks), cpu_clk Fmax 42.004 MHz
  against 42; the worst paths are now the reset fan-out.

  The stage-1 kernel also gained: 43 s down to 20.6 s from the pty change, measured on the
  stage-2 CPU (which also runs it, with `b`).

## Goal and definition of done

Boot a mainline RV32 Linux **with MMU** (SV32, S-mode kernel, U-mode user space) to a busybox
shell on the Tang Nano 9K, on the same SoC: QERV + MDU, 16 KB cache, 8 MB PSRAM.

Done means:
- `~ #` on the board's UART with an S-mode kernel, `mmu-type = "riscv,sv32"`.
- Real processes: `fork` (not just `vfork`), shared busybox text, a two-stage pipeline
  (`ls | wc`) that the no-MMU system could not fit.
- The directed tests, riscv-tests `rv32ui-v` (all user tests under virtual memory) and
  `rv32si-p` pass in lockstep with the ISS.

Out of scope: PMP, illegal-instruction traps, hardware A/D update, ASIDs, Sstc, interrupts
other than the timer, SMP.

## Design decisions

1. **Keep QERV and extend it.** A different core (VexRiscv with MMU) would be faster, but it
   needs a SpinalHDL toolchain and gives up the verified stage-1 core. QERV keeps its
   bit-serial datapath. The MMU is a separate parallel block on the memory side.
2. **SBI firmware in the boot ROM, not OpenSBI.** On RV32 the kernel must start on a 4 MB
   (megapage) boundary. OpenSBI in RAM at 0x8000_0000 would push the kernel to 0x8040_0000
   and leave it 4 of the 8 MB. A ROM-resident M-mode shim needs no RAM except a scratch page
   at the top of PSRAM, excluded from the DT memory node.
3. **SBI v0.1 (legacy) only.** `CONFIG_RISCV_SBI_V01` is still in 6.18. The shim implements:
   - set_timer (EID 0x00), console_putchar/getchar (0x01/0x02), shutdown (0x08);
   - every other EID returns `SBI_ERR_NOT_SUPPORTED`, so Linux sees spec v0.1.
4. **Timer through the firmware, no Sstc.**
   - The M timer interrupt sets `mip.STIP` and clears `mie.MTIE`.
   - The kernel's set_timer ecall writes `mtimecmp`, clears STIP and sets MTIE.
   - This is two M-mode traps per tick: under 1% of the CPU at HZ=100.
5. **`time`/`timeh` CSRs in hardware**, read from the CLINT's mtime. Linux's clocksource
   uses `rdtime`, and SERV cannot trap and emulate it (it has no illegal-instruction trap).
6. **Svade, not Svadu.** The walker never writes PTEs. A=0, or a store with D=0, raises a page
   fault, and Linux sets the bits (`handle_pte_fault`). The walker stays read-only.
7. **Delegate to S-mode:**
   - exceptions: misaligned (0, 4, 6), breakpoint (3), ecall from U (8), page faults
     (12, 13, 15);
   - interrupt: the S timer (5).

   The kernel already emulates misaligned accesses (`RISCV_EMULATED_UNALIGNED_ACCESS`).
8. **TLB:**
   - One direct-mapped TLB in BSRAM, indexed by {fetch/data, VPN low bits} so code and data
     don't evict each other.
   - Megapage leaves are stored as the 4 KB page that was touched (no separate superpage
     TLB). A miss under a megapage costs a one-level walk.
   - `sfence.vma` clears it by sweeping the entries. Linux flushes on every context switch
     (no ASIDs), and the sweep is a few hundred cycles against ~20 per instruction.
9. **Walks go through the L1 cache**, so recently used PTEs hit.
10. **Kernel config:**
    - `STRICT_KERNEL_RWX` off, so the linear map keeps megapages: one-level walks and fewer
      page-table pages.
    - Same size trims as stage 1.
11. **Toolchain:**
    - uClibc-ng with MMU and static busybox. This is the same libc and soft-float setup that
      stage 1 proved; it only drops elf2flt.
    - Separate output tree `br-tang9k-mmu`.

## CPU changes (SERV fork, `LINUX` parameter grows an S-mode level)

| Area | Change |
| --- | --- |
| Privilege | 2-bit mode (U=0, S=1, M=3); `mstatus.MPP` 2 bits; `SPP` |
| mstatus/sstatus | SIE, SPIE, SPP, SUM, MXR (sstatus is a masked view of mstatus) |
| Delegation | `medeleg` (bits 0,3,4,6,8,12,13,15), `mideleg` (bit 5) |
| S CSRs | `stvec`, `sscratch`, `sepc`, `stval` in the RF (slots 36–39, next to the M ones); `scause` like `mcause`; `satp` (MODE + PPN[19:0]) as a parallel register for the MMU |
| Interrupts | `mip.STIP` writable from M; `sie`/`sip` views. Enable rules: M interrupts are taken in M only if MIE is set, and always below M; the delegated STI is taken in S only if SIE is set, and always in U |
| Instructions | `sret` (the mret path with S state); `sfence.vma` → MMU flush; `wfi` stays a no-op |
| Traps | a delegated trap writes the S CSRs and jumps to stvec. Page faults: the data side reuses the misaligned-access trap path (address already in bufreg → tval). Fetch faults reuse the interrupt path (the fetched word is replaced by a trap, and tval = PC) |
| time | `time`/`timeh` read a 64-bit mtime input from the CLINT |

## MMU (`rtl/qerv/sv32_mmu.v`, between the core's ibus/dbus and one physical bus)

- **When it translates:** only when priv ≤ S and `satp.MODE` = 1. M-mode is untranslated
  (MPRV is not implemented).
- **Micro-TLB:** each bus (fetch, data) keeps its last translated page: VPN, PPN and the
  D/U/X/W/R flags. A request in that page whose cached flags allow it under the current
  privilege, SUM, MXR and access type goes out straight from IDLE, at no extra cost over an
  untranslated access. Only the strobe depends on the VPN compare: the physical address is
  always the micro-TLB PPN plus the offset. The entries refill on every TLB hit and clear
  with the TLB (`sfence.vma`, reset). `s2_mmu.S` test 11 covers same-page accesses with
  changed rights and an sfence with the entry still live.
- **Lookup** (micro-TLB miss): one BSRAM read, then a tag/permission check. It adds 2
  cycles to the access (a load/store is ~22 cycles).
- **Permissions:**
  - V; R/W/X; U against priv; SUM for S loads/stores to U pages (S never executes U pages);
    MXR.
  - A=0 → fault; a store with D=0 → fault.
  - Reserved encodings (W without R) → fault.
  - A misaligned megapage leaf → fault.
- **Walker:** two reads at most, issued as normal bus reads into the cache. The PTE is checked
  as it is filled into the TLB.
- **Faults:** reported to the core with the access type: fetch → 12, load → 13, store/AMO
  → 15.

## Verification

- **ISS** (`verif/qerv/iss.py`): add S-mode, delegation, sret, the satp/SV32 walk with Svade
  faults, `sfence.vma` and the time CSR. Stays the lockstep reference.
- **Directed tests** (`verif/qerv/tests/`):
  - privilege changes, delegated vs. M traps and interrupts;
  - 4 KB and megapage mappings, every fault type, SUM/MXR;
  - a PTE change seen only after `sfence.vma`.
- **riscv-tests:** `rv32si-p-*` and `rv32ui-v-*` (the user tests run on demand-paged virtual
  memory). Both are in the submodule already.
- **SoC:** boot the MMU kernel in Verilator (sim/soc), then on the board via `qerv_boot.py`.

## Milestones

- **S2-M0 software:**
  - `tang9k_mmu_defconfig`, kernel config, DT;
  - SBI shim and boot path in the boot ROM.

  It can't be tested before the CPU exists (there is no MMU-capable emulator here), so its
  first run is S2-M3.
- **S2-M1 privilege:** S-mode, CSRs, delegation, sret, the time CSR. Done when the ISS,
  directed tests and `rv32si-p` pass at W=4 and W=1.
- **S2-M2 MMU:** TLB + walker + faults + sfence. Done when `rv32ui-v` and the MMU directed
  tests pass. Followed by a fit probe.
- **S2-M3 SoC:** firmware in the boot ROM, mtime into the CPU, and the MMU kernel booting to
  a shell in Verilator.
- **S2-M4 board.**

## Budget

Logic now: 4,276/8,640 (50%), BSRAM 11/26. Estimates:

| Part | Logic |
| --- | --- |
| CPU S-mode + CSRs | 400–600 |
| MMU (TLB control, walker, checks, satp) | 500–800 |
| time CSR path | ~50 |
| TLB storage | 2 BSRAM |

That lands at roughly 5.3–5.8k (61–67%). The fit probe after S2-M2 checks this before
SoC integration.

## Risks

| Risk | Mitigation |
| --- | --- |
| The MMU kernel + initramfs don't fit 8 MB | Measure at S2-M3; same trims as stage 1. With MMU, busybox text is shared, so processes are cheaper than in stage 1 |
| Boot time grows (TLB misses, more kernel work) | Measure in simulation; enlarge the TLB (BSRAM is free) |
| SERV's serial CSR datapath makes delegation awkward | Keep S state in parallel flops where cheaper; the ISS lockstep catches mistakes |
| riscv-tests `dirty` expects hardware D updates | Svade is allowed by the spec; adapt or skip that test with a note |
| No MMU-capable reference emulator | The ISS is the reference; the riscv-tests `v` environment exercises the walker heavily |
