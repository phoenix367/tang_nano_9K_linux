// Timing constraints for fpga/src/tang9k_top.v.
//
// The rPLL makes the SoC clock, 27 MHz * 14 / 9 = 42 MHz (CLKOUT, net clk), and the PSRAM's CK
// clock, the same 90 degrees later (CLKOUTP, net clk_p; fpga/src/gowin_rpll/gowin_rpll.v). If
// the rPLL changes, update -multiply_by/-divide_by and -phase here and TANG9K_CPU_HZ in
// fpga/build.sh.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_generated_clock -name cpu_clk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 14 -divide_by 9 [get_nets {clk}]
create_generated_clock -name ck_clk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 14 -divide_by 9 -phase 90 [get_nets {clk_p}]

// The 27 MHz domain holds only the reset button's debouncer and the power-on counter.
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {cpu_clk ck_clk}]

// A setup guard band on cpu_clk's paths: the placer and the analysis keep 1.5 ns of every
// period in reserve. The report's slack and Fmax include it (each path shows it as tUnc), so
// TNS 0 here means 42 MHz with at least 1.5 ns to spare. fpga/build.sh SDC_UNCERT=<ns> tries
// another value. The PnR is deterministic, and the guard band alone moves the result (the SoC
// with the 16-bit PSRAM controller, 2026-11-11; real Fmax without the guard band): none 39.3 MHz,
// 1.5 ns 45.2, 2.0 ns 42.0, 2.5 ns 44.6, 3.0 ns 42.2. When a change costs timing, retry
// other values.
set_clock_uncertainty 1.5 -setup -from [get_clocks {cpu_clk}] -to [get_clocks {cpu_clk}]
set_clock_uncertainty 1.5 -setup -from [get_clocks {cpu_clk}] -to [get_clocks {ck_clk}]

// List up to 200 setup paths (the default report has 25), so that a build missing its guard
// band shows every failing endpoint to the timing check
// (.claude/skills/upload-bitstream/scripts/timing_summary.py), which adds each path's
// uncertainty back to judge the real 42 MHz.
report_timing -setup -max_paths 200 -max_common_paths 1
