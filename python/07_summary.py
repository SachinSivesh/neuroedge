"""Step 7: one summary of all results, ready for slides and the paper.

Reads the CSVs written by steps 01-06 and writes:
  results/summary.md    tables in Markdown (paste into slides / paper draft)
  results/summary.png   the headline figure: accuracy and work saved
"""
import numpy as np
import matplotlib.pyplot as plt

from neuroedge import config as cfg, pipeline as pl
from neuroedge.common import RESULTS, out_path, parse_args, read_csv

BASE_PAPER = 0.8055   # Malekmohammadi et al. 2019, BCI IV-2a, 2 classes


def col(rows, key):
    return np.array([float(r[key]) for r in rows])


def main():
    args = parse_args(__doc__)
    tag = "_synthetic" if args.synthetic else ""
    need = [f"phase1_baseline{tag}.csv", f"05_drift{tag}.csv", f"06_hardware_model{tag}.csv"]
    missing = [n for n in need if not (RESULTS / n).exists()]
    if missing:
        raise SystemExit(f"Run the earlier steps first; missing: {missing}")
    base = read_csv(RESULTS / need[0])
    drift = read_csv(RESULTS / need[1])
    hw = read_csv(RESULTS / need[2])
    ev = read_csv(RESULTS / f"04_event_sweep{tag}.csv") if (RESULTS / f"04_event_sweep{tag}.csv").exists() else []

    md = ["# NeuroEdge results" + (" (SYNTHETIC - do not report)" if args.synthetic else ""), ""]
    md += ["## 1. Baseline (software CSP + LDA, 8 channels, 2 classes)", "",
           "| Subject | Same-session | Day 1 -> day 2 |", "|---|---|---|"]
    md += [f"| S{r['subject']} | {float(r['same_session']):.1%} | {float(r['cross_session']):.1%} |" for r in base]
    md += [f"| **Mean** | **{col(base, 'same_session').mean():.1%}** | **{col(base, 'cross_session').mean():.1%}** |",
           "", f"Base paper (Malekmohammadi 2019, same dataset, 2 classes): {BASE_PAPER:.2%}", ""]

    pols = ["never", "every", "start", "drift", "oracle"]
    names = {"never": "No recalibration", "every": "Every trial (software)",
             "start": "Burst at power-on", "drift": "**NeuroEdge (drift-triggered)**",
             "oracle": "Oracle (all of day 2, not causal)"}
    md += [f"## 2. Day-2 accuracy and calibration work (hardware model, K = {cfg.K_DEFAULT})", "",
           "| Policy | Mean accuracy | Recalibrations | Calibration MACs |", "|---|---|---|---|"]
    ns = pl.ns_macs()
    for p in pols:
        rec = col(drift, f"{p}_recals").mean()
        md.append(f"| {names[p]} | {col(drift, p).mean():.1%} | {rec:.1f} | {rec * ns:,.0f} |")
    md.append("")

    md += ["## 3. Event-driven covariance", "",
           f"Mean event rate {col(hw, 'event_rate').mean():.1%} of samples; "
           f"{col(hw, 'mac_reduction').mean():.1f}x fewer covariance multiply-accumulates "
           "than an every-sample unit.", ""]
    if ev:
        md += ["| K | Events kept | MAC reduction | Accuracy |", "|---|---|---|---|"]
        for K in sorted({float(r["K"]) for r in ev}):
            sel = [r for r in ev if float(r["K"]) == K]
            md.append(f"| {K} | {col(sel, 'event_rate').mean():.1%} | "
                      f"{col(sel, 'mac_reduction').mean():.1f}x | {col(sel, 'accuracy').mean():.1%} |")
        md.append("")

    fl, fx_ = col(hw, "float_oracle").mean(), col(hw, "fixed_oracle").mean()
    md += ["## 4. Fixed-point loss", "",
           f"Float {fl:.1%} vs bit-exact integer {fx_:.1%}: {100 * (fl - fx_):.1f} points.", ""]
    path = out_path("summary", args.synthetic, "md")
    path.write_text("\n".join(md) + "\n")
    print("\n".join(md))
    print("Saved:", path)

    fig, (a, b) = plt.subplots(1, 2, figsize=(10, 4))
    bars = {"Base paper\n(static)": BASE_PAPER,
            "Day 2,\nno recal": col(drift, "never").mean(),
            "Day 2,\nNeuroEdge": col(drift, "drift").mean(),
            "Day 2,\noracle": col(drift, "oracle").mean()}
    a.bar(list(bars), [v * 100 for v in bars.values()], color=["C7", "C3", "C0", "C2"])
    for i, v in enumerate(bars.values()):
        a.text(i, v * 100 + 1, f"{v:.1%}", ha="center", fontsize=9)
    a.set_ylim(40, 100)
    a.set_ylabel("accuracy (%)")
    a.set_title("Self-calibration recovers day-2 accuracy")
    recs = [col(drift, f"{p}_recals").mean() for p in ("every", "drift")]
    cov_red = col(hw, "mac_reduction").mean()
    b.bar(["Covariance MACs\n(event vs frame)", "Recalibrations\n(drift vs every trial)"],
          [cov_red, recs[0] / max(recs[1], 1e-9)], color=["C1", "C4"])
    for i, v in enumerate([cov_red, recs[0] / max(recs[1], 1e-9)]):
        b.text(i, v * 1.02, f"{v:.1f}x less", ha="center", fontsize=9)
    b.set_ylabel("work reduction (x)")
    b.set_title("Work saved")
    fig.tight_layout()
    fig.savefig(out_path("summary", args.synthetic, "png"), dpi=140)


if __name__ == "__main__":
    main()
