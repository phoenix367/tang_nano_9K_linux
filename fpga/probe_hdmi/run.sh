#!/usr/bin/env bash
# Build the HDMI colour-bar probe (doc/video_plan.md V0) and load it into the FPGA's SRAM
# (volatile: the internal flash design comes back at power-up or with qerv_boot.py --reconfig).
#   fpga/probe_hdmi/run.sh [--no-load]
# Build output: fpga/probe_hdmi/build/ (ignored by git).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
mkdir -p "$B"
cat > "$B/probe.sdc" <<SDC
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_generated_clock -name hdmi_fclk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 14 -divide_by 3 [get_nets {fclk}]
create_generated_clock -name pix_clk -source [get_nets {fclk}] -master_clock hdmi_fclk -divide_by 5 [get_pins {div/CLKOUT}]
SDC
cat > "$B/probe.gprj" <<PRJ
<?xml version="1" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project>
    <Template>FPGA</Template>
    <Version>5</Version>
    <Device name="GW1NR-9C" pn="GW1NR-LV9QN88PC6/I5">gw1nr9c-004</Device>
    <FileList>
        <File path="$REPO/rtl/video/tmds_encoder.v" type="file.verilog" enable="1"/>
        <File path="$REPO/rtl/video/video_out.v" type="file.verilog" enable="1"/>
        <File path="$REPO/rtl/video/hdmi_phy_gowin.v" type="file.verilog" enable="1"/>
        <File path="$REPO/fpga/src/gowin_rpll/gowin_rpll_video.v" type="file.verilog" enable="1"/>
        <File path="$HERE/hdmi_probe_top.v" type="file.verilog" enable="1"/>
        <File path="$HERE/hdmi_probe.cst" type="file.cst" enable="1"/>
        <File path="$B/probe.sdc" type="file.sdc" enable="1"/>
    </FileList>
</Project>
PRJ
export GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}" GPRJ="$B/probe.gprj" TOP=hdmi_probe_top STAGE=all
for try in 1 2; do
  "$REPO/scripts/gw_run.sh" > "$B/build.log" 2>&1 || true
  grep -q "License verification failed" "$B/build.log" || break
done
FS="$B/impl/pnr/probe.fs"
[[ -f "$FS" ]] || { grep -E "ERROR|Error" "$B/build.log" | head -20; exit 1; }
grep -E "^\s+(Logic|BSRAM|Register as FF)" "$B/impl/pnr/probe.rpt.txt" | head -3 || true
[[ "${1:-}" == --no-load ]] && exit 0
openFPGALoader -b tangnano9k "$FS"
