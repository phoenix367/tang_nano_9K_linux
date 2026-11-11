#!/usr/bin/env python3
"""Summarize a Gowin PnR run: which bitstream, Fmax per clock against its constraint, total
negative slack, the worst setup paths, hold violations and the resource use.

  python3 .claude/skills/upload-bitstream/scripts/timing_summary.py [PNR_DIR]

PNR_DIR defaults to fpga/impl/pnr (the board build's output). Exit status 1 if any clock
misses its constraint or has negative slack, so the result can gate a load or a flash write.

Guard bands: the SoC's SDC sets a setup clock uncertainty on cpu_clk (1.5 ns; fpga/build.sh
SDC_UNCERT). Gowin's slack and Fmax include it. TNS 0 then means the constraint is met with the
guard band to spare. A build that eats into the guard band but still meets the real clock is
not a failure: each listed path's uncertainty (its tUnc) is added back, the real Fmax is
1 / (1 / Fmax - uncertainty), and only a negative real slack fails.
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

# the setup guard bands in force (the report lists the SDC's constraints)
unc = {(fr, to): float(u) for u, fr, to in re.findall(
    r"set_clock_uncertainty (-?[\d.]+) -setup -from \[get_clocks \{(\S+)\}\] "
    r"-to \[get_clocks \{(\S+)\}\]", t)}

print("\nclock          constraint    Fmax    levels")
real_ok = set()                           # clocks that meet their constraint without the band
for clk, want, got, lvl in re.findall(r"(\S+) ([\d.]+)\(MHz\) ([\d.]+)\(MHz\) (\d+)", t):
    u = unc.get((clk, clk), 0.0)
    real = 1000 / (1000 / float(got) - u)
    miss = real < float(want)
    bad |= miss
    note = ""
    if u:
        note = f"  ({real:.3f} MHz without the {u:g} ns guard band"
        note += ", which this build eats into)" if float(got) < float(want) and not miss else ")"
        if not miss:
            real_ok.add(clk)
    print(f"{clk:14s} {want:>8s}  {got:>8s}  {lvl:>4s}{'  MISSES' if miss else ''}{note}")

neg = [(c, k, v, n) for c, k, v, n in re.findall(r"(\S+) (Setup|Hold) (-?[\d.]+) (\d+)", t)
       if float(v) != 0.0]
n_band = 0                                # endpoints failing only the guard band
if neg:
    print("\nnegative slack:")
    for c, k, v, n in neg:
        if k == "Setup" and c in real_ok:
            n_band += int(n)
            print(f"  {c} {k}: TNS {v} over {n} endpoints (with the guard band; the paths below"
                  " are checked without it)")
        else:
            bad = True
            print(f"  {c} {k}: TNS {v} over {n} endpoints")
else:
    print("\nTNS 0 on every clock (the summary table)")

def section(name, end):
    i = t.find(name)
    return t[i:t.find(end, i)] if i >= 0 else ""

PATH = r"Path(\d+) Path Summary: Slack (-?[\d.]+) .*? From (\S+) To (\S+)"
setup = section("Setup Analysis Report", "Hold Analysis Report")
paths = []                                # (slack, slack without the guard band, from, to)
for m in re.finditer(PATH, setup):
    sl, fr, to = float(m.group(2)), m.group(3), m.group(4)
    nxt = setup.find("Path Summary", m.end())
    tu = re.search(r"-?[\d.]+ (-?[\d.]+) tUnc", setup[m.start():nxt if nxt > 0 else len(setup)])
    paths.append((sl, sl - float(tu.group(1)) if tu else sl, fr, to))
if paths:
    band = any(p[1] != p[0] for p in paths)
    print("\nworst setup paths (slack ns" + (", without the guard band" if band else "")
          + ", from -> to):")
    for sl, rs, fr, to in paths[:4]:
        print(f"  {sl:7.3f}" + (f"  {rs:7.3f}" if band else "") + f"  {fr} -> {to}")
    # Gowin's TNS table can leave a generated clock out (a phase-shifted rPLL output did), so
    # a negative slack in the path list counts too
    if any(rs < 0 for sl, rs, fr, to in paths):
        bad = True
        print("  NEGATIVE setup slack in the path list")
    listed = sum(1 for p in paths if p[0] < 0)
    if n_band > listed:
        bad = True
        print(f"  {n_band} endpoints eat into the guard band but only {listed} are listed:"
              " cannot check the rest")

# The TNS table above can read 0 for hold while the hold path list has negative slacks (the
# Gowin PSRAM IP's calibration flag into its input deserializers, a known IP-internal class
# that user constraints cannot clear; fpga/probe, and the SoC until 2026-11). List them; any
# outside the IP is a real failure.
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
