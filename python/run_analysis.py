#!/usr/bin/env python3
"""Run the Block 1/2/5 analysis: break-even table, alert-quality sweep (RQ3),
field-study detectability check (RQ1) and a provenance report.

    python3 run_analysis.py --samples 100 --out ../build/analysis

Every output carries the validation level (V1) and the number of PLACEHOLDER
inputs it rests on. Results are not publishable until placeholders are
replaced (python/astronova/inputs.py).
"""

import argparse
import csv
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from astronova import environment as E    # noqa: E402
from astronova import evaluate as V       # noqa: E402
from astronova import inputs as I         # noqa: E402


def banner():
    counts, placeholders = V.provenance()
    status = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    return (f"V1 (model only). Inputs by status: {status}. "
            f"{len(placeholders)} PLACEHOLDER inputs -- illustrative, not results.")


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


def field_null_examples():
    """RQ1 check: how many upsets would a ground-level field study expect from a
    GLE #77-class event, and how significant would the excess be? Exposure
    figures are hypothetical; enter the real ones from [6] and [7]."""
    ev = next(e for e in I.EVENTS if "77" in e.name)
    t = np.arange(0, 2 * 1440)
    rows = []
    for site in (I.SITES[0], I.SITES[2]):
        nm = E.event_profile(ev, t, 360)
        excess_h = float(np.sum(E.enhancement(nm, site) - 1.0)) / 60.0
        rate = E.lambda_ref_per_h() / 32 * E.site_factor(site)          # per Mbit
        for mbit, label in ((1e3, "1 Gbit SRAM (hypothetical)"), (1e6, "1 Tbit DRAM-scale (hypothetical)")):
            for window_h in (24.0,):
                d = E.field_detectability(rate, mbit, excess_h, window_h)
                rows.append({"site": site.name, "exposure": label, "window_h": window_h,
                             "excess_integral_h": round(excess_h, 3),
                             "expected_background": d["background"],
                             "expected_excess": d["excess"], "z": d["z"]})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--samples", type=int, default=50)
    ap.add_argument("--sweep-samples", type=int, default=8)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=os.path.join("..", "build", "analysis"))
    ap.add_argument("--no-sweep", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    note = banner()
    print(note)

    # provenance ---------------------------------------------------------
    write_csv(os.path.join(a.out, "inputs.csv"), [
        {"group": g, "name": n, "nominal": p.nom, "low": p.lo, "high": p.hi, "unit": p.unit,
         "status": p.status, "source": p.source} for g, n, p in I.all_params()])

    # break-even (RQ2) ---------------------------------------------------
    def prog(i, n):
        print(f"\r  Monte Carlo {i}/{n}", end="", file=sys.stderr, flush=True)
    mc = V.monte_carlo(a.samples, a.seed, progress=prog)
    print(file=sys.stderr)
    rows = V.summarize(mc)
    write_csv(os.path.join(a.out, "breakeven.csv"), rows)
    print(f"\nBreak-even, fleet {I.FLEET_SIZES[-1]:,}, median over {a.samples} samples "
          "(net fleet failures averted per year vs P0 | of which GLE | energy saving vs P1):")
    for r in rows:
        if r["fleet"] == I.FLEET_SIZES[-1]:
            print(f"  {r['site'][:42]:42s} {r['policy']}  {r['averted_per_yr']:+10.3g} | "
                  f"{r['gle_averted_per_yr']:+9.3g} | {100 * r['energy_saving_vs_P1']:5.1f}%  {r['verdict']}")

    # alert quality (RQ3) ------------------------------------------------
    if not a.no_sweep:
        site = I.SITES[-1]
        pods, fars = (0.25, 0.5, 0.75, 1.0), (0.0, 0.3, 0.6, 0.9)
        sw = V.alert_quality_sweep(site, pods, fars, n_samples=a.sweep_samples)
        write_csv(os.path.join(a.out, "alert_quality.csv"), [
            {"site": site.name, "pod": p, "far": f, "net_averted_per_yr": v[0],
             "gle_averted_per_yr": v[1], "energy_saving_vs_P1": v[2]} for (p, f), v in sw.items()])
        print(f"\nAlert quality at '{site.name}', fleet 100,000: GLE failures averted per year")
        print("  POD \\ FAR " + "".join(f"{f:>10}" for f in fars))
        for p in pods:
            print(f"  {p:9}" + "".join(f"{sw[(p, f)][1]:10.3g}" for f in fars))

    # field-study detectability (RQ1) --------------------------------------
    fn = field_null_examples()
    write_csv(os.path.join(a.out, "field_null.csv"), fn)
    print("\nRQ1 detectability of a GLE #77-class event in a 24 h window (hypothetical exposures):")
    for r in fn:
        print(f"  {r['site'][:40]:40s} {r['exposure']:34s} background {r['expected_background']:9.3g}"
              f"  excess {r['expected_excess']:8.3g}  z = {r['z']:.2f}")

    # figure -------------------------------------------------------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("\n(matplotlib not installed: no figure)")
        return
    sites = [s.name for s in I.SITES]
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.8), sharey=True)
    for ax, pol in zip(axes, V.ADAPTIVE):
        m = np.array([[next(r["gle_averted_per_yr"] for r in rows
                            if r["site"] == s and r["fleet"] == n and r["policy"] == pol)
                       for n in I.FLEET_SIZES] for s in sites])
        im = ax.imshow(np.log10(np.maximum(m, 1e-9)), cmap="viridis", vmin=-9, vmax=2, aspect="auto")
        for i in range(m.shape[0]):
            for j in range(m.shape[1]):
                ax.text(j, i, f"{m[i, j]:.1g}", ha="center", va="center",
                        color="white" if m[i, j] < 1e-3 else "black", fontsize=8)
        ax.set_xticks(range(len(I.FLEET_SIZES)), [f"{n:,}" for n in I.FLEET_SIZES])
        ax.set_title(f"{pol}: {V.POLICY_NAMES[pol]}", fontsize=10)
        ax.set_xlabel("fleet size")
    axes[0].set_yticks(range(len(sites)), [s[:38] for s in sites], fontsize=8)
    fig.colorbar(im, ax=axes, label="log10 GLE failures averted per year")
    fig.suptitle("GLE failures averted vs static baseline -- " + note, fontsize=8)
    path = os.path.join(a.out, "gle_averted.png")
    fig.savefig(path, dpi=130, bbox_inches="tight")
    print(f"\nwrote {a.out}/: inputs.csv breakeven.csv alert_quality.csv field_null.csv gle_averted.png")


if __name__ == "__main__":
    main()
