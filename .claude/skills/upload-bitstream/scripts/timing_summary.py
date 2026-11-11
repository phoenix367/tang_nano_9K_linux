#!/usr/bin/env python3
"""Summarize a Gowin PnR run: which bitstream, Fmax per clock against its constraint, total
negative slack, the worst setup paths, hold violations and the resource use.

  python3 .claude/skills/upload-bitstream/scripts/timing_summary.py [PNR_DIR]

PNR_DIR defaults to fpga/impl/pnr (the board build's output). Exit status 1 if any clock
misses its constraint or has negative slack, so the result can gate a load or a flash write.
"""
import hashlib, html, os, re, sys, time

d = sys.argv[1] if len(sys.argv) > 1 else "fpga/impl/pnr"
# the project's name: tang9k_soc for the board build, anything for a probe
fss = sorted(f for f in os.listdir(d) if f.endswith(".fs")) if os.path.isdir(d) else []
name = fss[0][:-3] if fss else "tang9k_soc"
fs = os.path.join(d, name + ".fs")
tr = os.path.join(d, name + "_tr_content.html")
rpt = os.path.join(d, name + ".rpt.txt")
for f in (fs, tr):
    if not os.path.exists(f):
        sys.exit(f"{f} not found: build first (SMODE=1 VIDEO=1 fpga/build.sh)")

def stamp(f):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(f)))

md5 = hashlib.md5(open(fs, "rb").read()).hexdigest()
print(f"bitstream  {fs}  {stamp(fs)}  md5 {md5}")
print(f"report     {tr}  {stamp(tr)}")
if abs(os.path.getmtime(fs) - os.path.getmtime(tr)) > 600:
    print("WARNING: the report and the bitstream are more than 10 min apart; not the same run?")

t = re.sub(r"<[^>]+>", " ", open(tr).read())
t = re.sub(r"\s+", " ", html.unescape(t))
bad = False

print("\nclock          constraint    Fmax    levels")
for clk, want, got, lvl in re.findall(r"(\S+) ([\d.]+)\(MHz\) ([\d.]+)\(MHz\) (\d+)", t):
    miss = float(got) < float(want)
    bad |= miss
    print(f"{clk:14s} {want:>8s}  {got:>8s}  {lvl:>4s}{'  MISSES' if miss else ''}")

neg = [(c, k, v, n) for c, k, v, n in re.findall(r"(\S+) (Setup|Hold) (-?[\d.]+) (\d+)", t)
       if float(v) != 0.0]
if neg:
    bad = True
    print("\nnegative slack:")
    for c, k, v, n in neg:
        print(f"  {c} {k}: TNS {v} over {n} endpoints")
else:
    print("\nTNS 0 on every clock (the summary table)")

def section(name, end):
    i = t.find(name)
    return t[i:t.find(end, i)] if i >= 0 else ""

PATH = r"Path(\d+) Path Summary: Slack (-?[\d.]+) .*? From (\S+) To (\S+)"
paths = re.findall(PATH, section("Setup Analysis Report", "Hold Analysis Report"))
if paths:
    print("\nworst setup paths (slack ns, from -> to):")
    for n, sl, a, b in paths[:4]:
        print(f"  {sl:>7s}  {a} -> {b}")
    # Gowin's TNS table can leave a generated clock out (a phase-shifted rPLL output did), so
    # a negative slack in the path list counts too
    if any(float(sl) < 0 for n, sl, a, b in paths):
        bad = True
        print("  NEGATIVE setup slack in the path list")

# The TNS table above can read 0 for hold while the hold path list has negative slacks (the
# PSRAM IP's calibration flag into its input deserializers, a known IP-internal class that
# user constraints cannot clear). List them; any outside the IP is a real failure.
hold = [(float(sl), a, b) for n, sl, a, b in
        re.findall(PATH, section("Hold Analysis Report", "Recovery Analysis Report"))
        if float(sl) < 0]
if hold:
    ip = [h for h in hold if h[1].startswith("psram/") and h[2].startswith("psram/")]
    other = [h for h in hold if h not in ip]
    print(f"\nnegative hold slack on {len(hold)} of the listed paths (worst {min(hold)[0]:.3f} ns):")
    if ip:
        print(f"  {len(ip)} inside the PSRAM IP (known, IP-internal; accepted)")
    for sl, a, b in other:
        print(f"  {sl:7.3f}  {a} -> {b}  OUTSIDE THE IP")
    bad |= bool(other)

if os.path.exists(rpt):
    print("\nresources:")
    for line in open(rpt, errors="replace"):
        m = re.match(r"\s*(Logic|Register|CLS|BSRAM)\s*\|\s*(\S+)\s*\|\s*(\S+)", line)
        if m:
            print(f"  {m.group(1):9s} {m.group(2):>11s}  {m.group(3)}")

sys.exit(1 if bad else 0)
