#!/usr/bin/env python3
"""Print one utilization/Fmax row per fit-probe results directory.

    python3 fit/summarize.py fit/*/results/*

Reads the PnR report (<name>.rpt.txt) and timing report (<name>_tr_content.html) that
fit/run_probe.sh copies into each results directory.
"""
import glob
import html
import os
import re
import sys


def one(pattern, text):
    m = re.search(pattern, text)
    return m.groups() if m else None


def summarize(d):
    rpt = glob.glob(os.path.join(d, "*.rpt.txt"))
    tr = glob.glob(os.path.join(d, "*_tr_content.html"))
    if not rpt or not tr:
        return None
    t = open(rpt[0]).read()
    row = {"probe": os.path.relpath(d, os.path.dirname(os.path.abspath(__file__)))}
    g = one(r"Logic\s*\|\s*(\d+)/(\d+)\s*\|\s*(\d+)%", t)
    row["logic"] = f"{g[0]}/{g[1]} ({g[2]}%)" if g else "?"
    g = one(r"LUT,ALU,ROM16\s*\|\s*\d+\((\d+) LUT, (\d+) ALU", t)
    row["lut"], row["alu"] = g if g else ("?", "?")
    g = one(r"SSRAM\(RAM16\)\s*\|\s*(\d+)", t)
    row["ssram"] = g[0] if g else "0"
    g = one(r"Logic Register as FF\s*\|\s*(\d+)/", t)
    row["ff"] = g[0] if g else "?"
    g = one(r"CLS\s*\|\s*\d+/\d+\s*\|\s*(\d+)%", t)
    row["cls"] = f"{g[0]}%" if g else "?"
    g = one(r"BSRAM\s*\|\s*(\d+)/", t)
    row["bsram"] = g[0] if g else "0"
    g = one(r"DSP\s*\|\s*(\d+)/", t)
    row["dsp"] = g[0] if g else "0"

    x = open(tr[0]).read()
    x = html.unescape(re.sub(r"\|+", "|", re.sub("<[^>]+>", "|", x)))
    blk = x[x.find("Max Frequency Summary"):]
    blk = blk[:blk.find("Total Negative Slack")]
    m = re.search(r"\|\d+\|\s*\|([^|]+)\|\s*\|(?:Base|Generated)?\|?\s*\|?"
                  r"([0-9.]+)\(MHz\)\|\s*\|([0-9.]+)\(MHz\)\|\s*\|(\d+)\|", blk)
    row["fmax"] = f"{float(m.group(3)):.1f} MHz ({m.group(4)} lvl)" if m else "?"
    return row


def main():
    dirs = [d for a in sys.argv[1:] for d in sorted(glob.glob(a)) if os.path.isdir(d)]
    if not dirs:
        sys.exit(__doc__)
    cols = ["probe", "logic", "lut", "alu", "ssram", "ff", "cls", "bsram", "dsp", "fmax"]
    rows = [r for r in map(summarize, dirs) if r]
    w = {c: max(len(c), *(len(r[c]) for r in rows)) for c in cols}
    print("  ".join(c.ljust(w[c]) for c in cols))
    for r in rows:
        print("  ".join(r[c].ljust(w[c]) for c in cols))


if __name__ == "__main__":
    main()
