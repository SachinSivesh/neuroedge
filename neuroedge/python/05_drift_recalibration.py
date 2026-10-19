"""Step 5: drift-triggered recalibration (contribution 3).

At the chosen threshold K, compares how often each policy recalibrates and
how accurate it is on day 2:
  never   no recalibration
  every   after every trial (software baseline, needs a divider)
  start   burst at power-on only
  drift   NeuroEdge: the encoder's noise-floor tracker detects drift and
          triggers a burst at trials 1,2,4,...,64
  oracle  all of day 2 in advance (upper bound)
plus a sweep of the drift ratio (how big a noise-floor change counts as drift).

Outputs: results/05_drift.csv, results/05_drift_ratio.csv, results/05_drift.png
"""
import numpy as np
import matplotlib.pyplot as plt

from neuroedge import config as cfg, pipeline as pl
from neuroedge.common import out_path, parse_args, write_csv

POLICIES = ["never", "every", "start", "drift", "oracle"]
RATIOS = [(11, 10), (5, 4), (3, 2), (2, 1)]


def main():
    args = parse_args(__doc__, lambda ap: ap.add_argument("--K", type=float, default=cfg.K_DEFAULT))
    rows, ratio_rows = [], []
    for s in args.subjects:
        fe = pl.run_frontend(s, [args.K], args.synthetic)
        p = pl.train(fe["R1"][0], fe["y1"], fe["m_final1"][0], fe["K_ints"][0])
        row = dict(subject=s)
        for pol in POLICIES:
            r = pl.run_day2(p, fe["R2"][0], fe["m_end2"][0], fe["y2"], pol)
            row[pol] = r["acc"]
            row[f"{pol}_recals"] = r["n_recal"]
            if pol == "drift":
                row["drift_trials"] = " ".join(map(str, r["drift_at"]))
        rows.append(row)
        for rn, rd in RATIOS:
            r = pl.run_day2(p, fe["R2"][0], fe["m_end2"][0], fe["y2"], "drift", rn, rd)
            ratio_rows.append(dict(subject=s, ratio=rn / rd, accuracy=r["acc"],
                                   recals=r["n_recal"], drifts=len(r["drift_at"])))
        print(f"S{s}: " + "  ".join(f"{pol} {row[pol]:.0%} ({row[pol + '_recals']})"
                                    for pol in POLICIES) + f"  drift at {row['drift_trials']}")

    ns = pl.ns_macs()
    print(f"\nOne recalibration = {ns} MACs (Newton-Schulz {cfg.NS_ITERS} iterations + G = F x Z)")
    print(f"{'policy':>7} {'accuracy':>9} {'recals':>7} {'calib MACs':>11}")
    for pol in POLICIES:
        acc = np.mean([r[pol] for r in rows])
        rec = np.mean([r[f"{pol}_recals"] for r in rows])
        print(f"{pol:>7} {acc:>9.1%} {rec:>7.1f} {rec * ns:>11.0f}")
    print("\nDrift ratio sweep:")
    for rn, rd in RATIOS:
        sel = [r for r in ratio_rows if r["ratio"] == rn / rd]
        print(f"  {rn}/{rd}: accuracy {np.mean([r['accuracy'] for r in sel]):.1%}, "
              f"recals {np.mean([r['recals'] for r in sel]):.1f}")

    write_csv(out_path("05_drift", args.synthetic, "csv"), rows)
    write_csv(out_path("05_drift_ratio", args.synthetic, "csv"), ratio_rows)

    fig, (a, b) = plt.subplots(1, 2, figsize=(9, 3.8))
    accs = [np.mean([r[p] for r in rows]) * 100 for p in POLICIES]
    recs = [np.mean([r[f"{p}_recals"] for r in rows]) for p in POLICIES]
    a.bar(POLICIES, accs, color=["C7", "C1", "C2", "C0", "C3"])
    a.set_ylim(min(accs) - 10, 100)
    a.set_ylabel("mean day-2 accuracy (%)")
    a.set_title("Accuracy")
    b.bar(POLICIES, recs, color=["C7", "C1", "C2", "C0", "C3"])
    b.set_yscale("symlog")
    b.set_ylabel("recalibrations per session")
    b.set_title("Calibration work")
    fig.suptitle(f"Drift-triggered recalibration (K = {args.K})")
    fig.tight_layout()
    fig.savefig(out_path("05_drift", args.synthetic, "png"), dpi=130)


if __name__ == "__main__":
    main()
