// The board clock is 27 MHz, but the probe is constrained at 50 MHz so timing-driven
// PnR pushes for the core's achievable Fmax (read "Actual Fmax" in the timing report).
create_clock -name clk -period 20.0 -waveform {0 10.0} [get_ports {clk}]
