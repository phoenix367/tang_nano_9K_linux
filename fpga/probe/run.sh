#!/usr/bin/env bash
# Build the PSRAM calibration probe for one memory_clk, load it into SRAM, print the beacon.
#   fpga/probe/run.sh TAG IDIV_SEL FBDIV_SEL ODIV_SEL [IP_NETLIST]
#   e.g. fpga/probe/run.sh f135 0 4 4      (27 * 5 / 1 = 135 MHz)
#        fpga/probe/run.sh f078 8 25 8     (27 * 26 / 9 = 78 MHz)
# memory_clk = 27 * (FBDIV_SEL + 1) / (IDIV_SEL + 1); VCO = memory_clk * ODIV_SEL must be
# 400-1200 MHz. TAG is 4 characters. IP_NETLIST defaults to the SoC's PSRAM IP.
# Build output: fpga/probe/build/TAG/ (ignored by git).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TAG="$1" IDIV="$2" FBDIV="$3" ODIV="$4"
IP="${5:-$REPO/fpga/src/psram_memory_interface_hs_2ch/psram_memory_interface_hs_2ch.v}"
B="$HERE/build/$TAG"
mkdir -p "$B"
cat > "$B/probe_cfg.v" <<CFG
\`define PROBE_TAG "$TAG"
\`define PROBE_IDIV $IDIV
\`define PROBE_FBDIV $FBDIV
\`define PROBE_ODIV $ODIV
CFG
MUL=$((FBDIV + 1)) DIVI=$((IDIV + 1))
cat > "$B/probe.sdc" <<SDC
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_generated_clock -name memory_clk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by $MUL -divide_by $DIVI [get_nets {memory_clk}]
create_generated_clock -name cpu_clk -source [get_nets {memory_clk}] -master_clock memory_clk -divide_by 2 [get_pins {psram/clkdiv/CLKOUT}]
set_multicycle_path 2 -setup -from [get_clocks {memory_clk}] -to [get_clocks {cpu_clk}]
set_multicycle_path 1 -hold  -from [get_clocks {memory_clk}] -to [get_clocks {cpu_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {cpu_clk}]
SDC
cat > "$B/probe.gprj" <<PRJ
<?xml version="1" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project>
    <Template>FPGA</Template>
    <Version>5</Version>
    <Device name="GW1NR-9C" pn="GW1NR-LV9QN88PC6/I5">gw1nr9c-004</Device>
    <FileList>
        <File path="$B/probe_cfg.v" type="file.verilog" enable="1"/>
        <File path="$IP" type="file.verilog" enable="1"/>
        <File path="$HERE/psram_probe_top.v" type="file.verilog" enable="1"/>
        <File path="$HERE/psram_probe.cst" type="file.cst" enable="1"/>
        <File path="$B/probe.sdc" type="file.sdc" enable="1"/>
    </FileList>
</Project>
PRJ
export GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}" GPRJ="$B/probe.gprj" TOP=psram_probe_top STAGE=all
for try in 1 2; do
  "$REPO/scripts/gw_run.sh" > "$B/build.log" 2>&1 || true
  grep -q "License verification failed" "$B/build.log" || break
done
FS="$B/impl/pnr/probe.fs"
[[ -f "$FS" ]] || { grep -E "ERROR" "$B/build.log" | head; exit 1; }
python3 "$HERE/beacon.py" "$FS"
