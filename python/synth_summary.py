#!/usr/bin/env python3
"""Summarise a Yosys `stat -top` report: totals and per-module LUT / FF counts."""

import re
import sys


def clean(name):
    name = re.sub(r"\$paramod\$?[0-9a-f]*\\?", "", name.strip())
    return re.sub(r"\\W=s32'([01]+)", lambda m: f" (W={int(m.group(1), 2)})", name)


def main(path):
    text = open(path).read()
    per_module, hierarchy = text.split("design hierarchy")
    luts = sum(int(n) for n in re.findall(r"LUT\d\s+(\d+)", hierarchy))
    ffs = sum(int(n) for n in re.findall(r"FD\w+\s+(\d+)", hierarchy))
    carry = sum(int(n) for n in re.findall(r"CARRY4\s+(\d+)", hierarchy))
    print(f"LUT={luts} FF={ffs} CARRY4={carry} "
          f"({100 * luts / 53200:.1f}% LUT, {100 * ffs / 106400:.1f}% FF of XC7Z020)")

    # instance counts from the hierarchy listing ("  <module>   <count>")
    counts = {}
    for line in hierarchy.split("Number of cells")[0].splitlines():
        m = re.match(r"\s+(\S+)\s+(\d+)$", line)
        if m:
            counts[m.group(1)] = int(m.group(2))

    for block in re.split(r"\n=== ", per_module)[1:]:
        raw = block.split(" ===")[0].strip()
        if not raw:
            continue
        name, n = clean(raw), counts.get(raw, 1)
        n_lut = sum(int(v) for v in re.findall(r"LUT\d\s+(\d+)", block))
        n_ff = sum(int(v) for v in re.findall(r"FD\w+\s+(\d+)", block))
        print(f"    {name:28s} x{n}  LUT={n_lut:5d} FF={n_ff:5d} each")


if __name__ == "__main__":
    main(sys.argv[1])
