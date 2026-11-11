#!/usr/bin/env bash
# Build the 16-bit PSRAM controller probe for one CK phase, load it into the FPGA's SRAM (not
# the flash) and print its result lines.
#   fpga/probe_psram16/run.sh [PSDA] [SECONDS]
#   e.g. fpga/probe_psram16/run.sh 0100      (CK 90 degrees behind clk, the default)
#        fpga/probe_psram16/run.sh 0010      (45 degrees)
# On the board 0001..0111 (22.5..157.5 degrees) pass, 0000 fails.
# PSDA is the rPLL CLKOUTP phase in 22.5-degree steps (4 binary digits); it must stay below
# 180 degrees (rtl/psram/hyperram_x16.v). LINES (env) is the test size in 32-byte lines
# (default 262144 = all 8 MB). Build output: fpga/probe_psram16/build/<tag>/ (ignored by git).
# The board keeps running the probe until it is reset or reconfigured (qerv_boot.py --reconfig
# or a power cycle brings back the flash design).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PSDA="${1:-0100}" SECS="${2:-12}"
[[ "$PSDA" =~ ^[01]{4}$ ]] || { echo "PSDA must be 4 binary digits" >&2; exit 2; }
DEG10=$(( 2#$PSDA * 225 ))                    # tenths of a degree
DIR=$(printf "p%03d" $(( DEG10 / 10 )))
B="$HERE/build/$DIR"
# Each build's lines start with its own 4-digit tag: the USB bridge can deliver seconds of the
# previous design's output after a load, and the reader keeps only this build's lines.
TAG=$(printf "%04x" $(( ($(date +%s) * 7 + RANDOM) & 0xffff )))
mkdir -p "$B"
cat > "$B/probe_cfg.v" <<CFG
\`define PROBE_TAG "$TAG"
\`define PROBE_PSDA "$PSDA"
\`define PROBE_LINES ${LINES:-262144}
CFG
cat > "$B/probe.sdc" <<SDC
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_generated_clock -name clk -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 14 -divide_by 9 [get_nets {clk}]
create_generated_clock -name clk_p -source [get_ports {clk_27m}] -master_clock clk27 -multiply_by 14 -divide_by 9 -phase $(( DEG10 / 10 )).$(( DEG10 % 10 )) [get_nets {clk_p}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {clk clk_p}]
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
        <File path="$REPO/rtl/psram/hyperram_x16.v" type="file.verilog" enable="1"/>
        <File path="$HERE/psram16_probe_top.v" type="file.verilog" enable="1"/>
        <File path="$HERE/psram16_probe.cst" type="file.cst" enable="1"/>
        <File path="$B/probe.sdc" type="file.sdc" enable="1"/>
    </FileList>
</Project>
PRJ
export GOWIN_PATH="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}" GPRJ="$B/probe.gprj" TOP=psram16_probe_top STAGE=all
rm -rf "$B/impl"                              # never load a stale bitstream after a failed run
for try in 1 2; do
  "$REPO/scripts/gw_run.sh" > "$B/build.log" 2>&1 || true
  grep -q "License verification failed" "$B/build.log" || break
done
FS="$B/impl/pnr/probe.fs"
[[ -f "$FS" ]] || { grep -E "ERROR" "$B/build.log" | head; exit 1; }
python3 "$REPO/.claude/skills/upload-bitstream/scripts/timing_summary.py" "$B/impl/pnr" 2>/dev/null \
  | sed -n '/^clock/,/^$/p;/negative/,/^$/p' || true
[[ "${BUILD_ONLY:-0}" == 1 ]] && exit 0
# load into SRAM and collect the lines (the probe repeats them every 40 ms once done)
echo "phase $(( DEG10 / 10 )).$(( DEG10 % 10 )) degrees, tag $TAG"
python3 - "$FS" "$SECS" "$TAG" <<'PY'
import subprocess, sys, time
import serial
fs, secs, tag = sys.argv[1], float(sys.argv[2]), sys.argv[3]
serial.Serial("/dev/ttyUSB1", 1000000).close()      # the BL702 applies the previous open's rate
s = serial.Serial("/dev/ttyUSB1", 1000000, timeout=0.05)
subprocess.run(["openFPGALoader", "-b", "tangnano9k", fs], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)                                     # the old design's last lines, still in
s.reset_input_buffer()                              # the bridge, arrive just after the load
end, buf = time.time() + secs, b""
while time.time() < end:
    buf += s.read(4096)
seen = []
for l in buf.decode(errors="replace").split("\r\n"):
    if l.startswith(tag) and l not in seen and len(l) > 80:
        seen.append(l)
print("\n".join(sorted(seen)) if seen else "no result lines (test still running, or no UART output)")
PY
