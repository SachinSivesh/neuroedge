"""Step 3: label-free self-calibration (contributions 1 and 4).

A. Newton-Schulz convergence: how many multiply-only iterations does the
   on-chip inverse square root need?  (error vs exact eigen-decomposition)
B. Does unsupervised alignment fix the day-1 -> day-2 drop?
   Policies (integer hardware model, every-sample covariance, K = 0):
     never   day-1 model as is
     start   NeuroEdge burst at power-on: recalibrate at trials 1,2,4..64
     every   recalibrate after every trial (software approach, needs a divider)
     oracle  align with all of day 2 in advance (upper bound, not causal)

Outputs: results/03_ns_convergence.csv/.png, results/03_self_calibration.csv/.png
"""
import numpy as np
import matplotlib.pyplot as plt

from neuroedge import config as cfg, fixed as fx, pipeline as pl
from neuroedge.common import out_path, parse_args, write_csv
from neuroedge.decoder import inv_sqrtm

POLICIES = ["never", "start", "every", "oracle"]
MAX_IT = 20


def ns_errors(R1):
    Rn, _ = fx.ns_normalise(R1.sum(axis=0) // len(R1))
    exact = inv_sqrtm(Rn / float(1 << cfg.NS_FRAC))
    errs = [np.linalg.norm(fx.ns_inv_sqrt(Rn, it) / float(1 << cfg.NS_FRAC) - exact)
            / np.linalg.norm(exact) for it in range(1, MAX_IT + 1)]
    return errs, float(np.linalg.cond(Rn.astype(float)))


def main():
    args = parse_args(__doc__)
    conv_rows, acc_rows, err_curves = [], [], []
    for s in args.subjects:
        fe = pl.run_frontend(s, [0.0], args.synthetic)
        R1, R2, y1, y2 = fe["R1"][0], fe["R2"][0], fe["y1"], fe["y2"]
        errs, cond = ns_errors(R1)
        err_curves.append(errs)
        need = next((i + 1 for i, e in enumerate(errs) if e < 1e-3), None)
        conv_rows.append(dict(subject=s, condition_number=round(cond, 1),
                              iters_to_0p1pct=need,
                              err_at_cfg_iters=errs[cfg.NS_ITERS - 1]))
        p = pl.train(R1, y1, fe["m_final1"][0], fe["K_ints"][0])
        row = dict(subject=s, train_acc=p["train_acc"])
        for pol in POLICIES:
            r = pl.run_day2(p, R2, fe["m_end2"][0], y2, pol)
            row[pol] = r["acc"]
            row[f"{pol}_recals"] = r["n_recal"]
        acc_rows.append(row)
        print(f"S{s}: cond {cond:7.1f}, NS iters for 0.1% error: {need}  | " +
              "  ".join(f"{pol} {row[pol]:.1%}" for pol in POLICIES))

    mean = {pol: np.mean([r[pol] for r in acc_rows]) for pol in POLICIES}
    print("\nMean day-2 accuracy: " + "  ".join(f"{p} {v:.1%}" for p, v in mean.items()))
    worst = max((r["iters_to_0p1pct"] or MAX_IT + 1) for r in conv_rows)
    print(f"NS iterations needed (worst subject): {worst}; config uses {cfg.NS_ITERS}"
          + ("  <-- raise NS_ITERS in config.py" if worst > cfg.NS_ITERS else ""))

    write_csv(out_path("03_ns_convergence", args.synthetic, "csv"), conv_rows)
    write_csv(out_path("03_self_calibration", args.synthetic, "csv"), acc_rows)

    fig, ax = plt.subplots(figsize=(6, 4))
    for s, e in zip(args.subjects, err_curves):
        ax.semilogy(range(1, MAX_IT + 1), e, alpha=0.7, label=f"S{s}")
    ax.axhline(1e-3, ls="--", c="gray")
    ax.axvline(cfg.NS_ITERS, ls=":", c="k")
    ax.set_xlabel("Newton-Schulz iterations")
    ax.set_ylabel("relative error vs exact")
    ax.set_title("Multiply-only inverse square root converges")
    ax.legend(fontsize=7, ncol=3)
    fig.tight_layout()
    fig.savefig(out_path("03_ns_convergence", args.synthetic, "png"), dpi=130)

    fig, ax = plt.subplots(figsize=(7, 4))
    x = np.arange(len(acc_rows))
    for i, pol in enumerate(POLICIES):
        ax.bar(x + (i - 1.5) * 0.2, [r[pol] for r in acc_rows], 0.2, label=pol)
    ax.set_xticks(x, [f"S{r['subject']}" for r in acc_rows])
    ax.set_ylabel("day-2 accuracy")
    ax.set_ylim(0.4, 1.0)
    ax.axhline(0.5, c="gray", lw=0.8)
    ax.set_title("Cross-session accuracy with label-free alignment")
    ax.legend(ncol=4, fontsize=8)
    fig.tight_layout()
    fig.savefig(out_path("03_self_calibration", args.synthetic, "png"), dpi=130)


if __name__ == "__main__":
    main()
