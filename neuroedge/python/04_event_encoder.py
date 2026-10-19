"""Step 4: how much work can event-driven processing skip? (contribution 2)

Sweeps the encoder threshold K (threshold = K x running mean |x|).
For each K: event rate, covariance multiply-accumulates per trial against a
conventional every-sample unit, and day-2 accuracy of the full NeuroEdge
decoder (drift-triggered self-calibration on).

Picks the largest K whose mean accuracy stays within 2 points of K = 0;
put that value in config.py as K_DEFAULT.

Outputs: results/04_event_sweep.csv, results/04_event_sweep.png
"""
import numpy as np
import matplotlib.pyplot as plt

from neuroedge import pipeline as pl, fixed as fx
from neuroedge.common import out_path, parse_args, write_csv
from neuroedge.data import RAW_SAMPLES, WARMUP

K_SWEEP = pl.K_SWEEP


def main():
    args = parse_args(__doc__)
    frame_macs = fx.frame_based_macs(RAW_SAMPLES - WARMUP)
    rows = []
    for s in args.subjects:
        fe = pl.run_frontend(s, K_SWEEP, args.synthetic)
        for i, K in enumerate(K_SWEEP):
            p = pl.train(fe["R1"][i], fe["y1"], fe["m_final1"][i], fe["K_ints"][i])
            r = pl.run_day2(p, fe["R2"][i], fe["m_end2"][i], fe["y2"], "drift")
            n_frames = fe["events2"].shape[1] * (RAW_SAMPLES - WARMUP)
            rate = fe["events2"][i].sum() / (n_frames * fe["events2"].shape[2])
            macs = fe["macs2"][i].mean()
            rows.append(dict(subject=s, K=K, event_rate=float(rate), macs_per_trial=float(macs),
                             mac_reduction=frame_macs / macs, accuracy=r["acc"]))
        print(f"S{s}: " + "  ".join(f"K{r['K']}: {r['event_rate']:.0%}/{r['accuracy']:.0%}"
                                    for r in rows[-len(K_SWEEP):]))

    summ = []
    for K in K_SWEEP:
        sel = [r for r in rows if r["K"] == K]
        summ.append(dict(K=K, rate=np.mean([r["event_rate"] for r in sel]),
                         red=np.mean([r["mac_reduction"] for r in sel]),
                         acc=np.mean([r["accuracy"] for r in sel])))
    print(f"\nFrame-based covariance: {frame_macs} MACs per trial")
    print(f"{'K':>5} {'event rate':>11} {'MAC reduction':>14} {'accuracy':>9}")
    for m in summ:
        print(f"{m['K']:>5} {m['rate']:>11.1%} {m['red']:>13.1f}x {m['acc']:>9.1%}")
    ok = [m for m in summ if m["acc"] >= summ[0]["acc"] - 0.02]
    best = max(ok, key=lambda m: m["K"])
    print(f"\nRecommended K_DEFAULT = {best['K']} ({best['red']:.1f}x fewer MACs, "
          f"{best['acc']:.1%} vs {summ[0]['acc']:.1%} at K=0)")

    write_csv(out_path("04_event_sweep", args.synthetic, "csv"), rows)
    fig, a1 = plt.subplots(figsize=(6.5, 4))
    rate = [m["rate"] * 100 for m in summ]
    a1.plot(rate, [m["acc"] * 100 for m in summ], "o-", c="C0", label="accuracy")
    for m, x in zip(summ, rate):
        a1.annotate(f"K={m['K']}", (x, m["acc"] * 100), fontsize=7,
                    textcoords="offset points", xytext=(3, 4))
    a1.set_xlabel("events kept (% of samples)")
    a1.set_ylabel("day-2 accuracy (%)", color="C0")
    a2 = a1.twinx()
    a2.plot(rate, [m["red"] for m in summ], "s--", c="C1")
    a2.set_ylabel("fewer covariance MACs (x)", color="C1")
    a1.set_title("Event-driven covariance: work saved vs accuracy")
    fig.tight_layout()
    fig.savefig(out_path("04_event_sweep", args.synthetic, "png"), dpi=130)


if __name__ == "__main__":
    main()
