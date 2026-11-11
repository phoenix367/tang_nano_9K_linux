#!/usr/bin/env python3
"""Summarize a Gowin PnR run: which bitstream, Fmax per clock against its constraint, total
negative slack, the worst setup paths and the resource use.

  python3 .claude/skills/upload-bitstream/scripts/timing_summary.py [PNR_DIR]

PNR_DIR defaults to fpga/impl/pnr (the board build's output). Exit status 1 if any clock
misses its constraint or has negative slack, so the result can gate a load or a flash write.
"""
import hashlib, html, os, re, sys, time

d = sys.argv[1] if len(sys.argv) > 1 else "fpga/impl/pnr"
fs = os.path.join(d, "tang9k_soc.fs")
tr = os.path.join(d, "tang9k_soc_tr_content.html")
rpt = os.path.join(d, "tang9k_soc.rpt.txt")
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
    print("\nTNS 0 on every clock (setup and hold)")

paths = re.findall(r"Path(\d+) Path Summary: Slack (-?[\d.]+) .*? From (\S+) To (\S+)", t)
if paths:
    print("\nworst setup paths (slack ns, from -> to):")
    for n, sl, a, b in paths[:4]:
        print(f"  {sl:>7s}  {a} -> {b}")

if os.path.exists(rpt):
    print("\nresources:")
    for line in open(rpt, errors="replace"):
        m = re.match(r"\s*(Logic|Register|CLS|BSRAM)\s*\|\s*(\S+)\s*\|\s*(\S+)", line)
        if m:
            print(f"  {m.group(1):9s} {m.group(2):>11s}  {m.group(3)}")

sys.exit(1 if bad else 0)
