// Timing constraints for fpga/src/tang9k_top.v. Adapted from tang_nano_9K_ov7670's
// camera_control.sdc (same PSRAM IP).
//
// memory_clk = 27 MHz * 28 / 9 = 84 MHz (rPLL); SoC clock = the IP's clk_out = 42 MHz.
// If the rPLL is regenerated for another frequency, update -multiply_by/-divide_by here and
// TANG9K_CPU_HZ in fpga/build.sh.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_generated_clock -name memory_clk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 28 -divide_by 9 [get_nets {memory_clk}]

// clk_out comes from the IP's internal CLKDIV (instance "clkdiv" in the ov7670 build).
// Without this the analyzer treats it as unconstrained.
create_generated_clock -name cpu_clk -source [get_nets {memory_clk}] -master_clock memory_clk -divide_by 2 [get_pins {psram/clkdiv/CLKOUT}]

// memory_clk -> cpu_clk inside the IP crosses a 2:1 ratio: the data has one cpu_clk period.
set_multicycle_path 2 -setup -from [get_clocks {memory_clk}] -to [get_clocks {cpu_clk}]
set_multicycle_path 1 -hold  -from [get_clocks {memory_clk}] -to [get_clocks {cpu_clk}]

// The 27 MHz reference only clocks the IP's power-up/reset sequencing.
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {cpu_clk}]
