"""Step 8: live demo, replaying day 2 of the demo subject trial by trial.

Opens a window with three panels that update every trial:
  1. the current trial's C3 / C4 signal, with a dot for every event the
     encoder sends (everything without a dot is skipped work)
  2. running accuracy: NeuroEdge vs the same decoder with no recalibration,
     with the drift detection and every recalibration marked
  3. covariance multiply-accumulates so far: event-driven vs every-sample

    python 08_demo_replay.py                 # live window
    python 08_demo_replay.py --speed 100     # ms per trial (default 250)
    python 08_demo_replay.py --gif           # also save results/demo.gif

Run 06_hardware_model.py first (it caches everything this needs).
"""
import argparse

import numpy as np

from neuroedge import config as cfg, fixed as fx, pipeline as pl
from neuroedge.data import CHANNELS, FS, RAW_SAMPLES, WARMUP


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", type=int, default=cfg.DEMO_SUBJECT)
    ap.add_argument("--K", type=float, default=cfg.K_DEFAULT)
    ap.add_argument("--speed", type=int, default=250, help="milliseconds per trial")
    ap.add_argument("--gif", action="store_true")
    ap.add_argument("--synthetic", action="store_true")
    args = ap.parse_args()

    import matplotlib
    if args.gif:
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation, PillowWriter

    print("Preparing (first time takes a minute)...")
    prep = pl.prepare_subject(args.subject, args.synthetic)
    fe = pl.run_frontend(args.subject, [args.K], args.synthetic)
    p = pl.train(fe["R1"][0], fe["y1"], fe["m_final1"][0], fe["K_ints"][0])
    neuro = pl.run_day2(p, fe["R2"][0], fe["m_end2"][0], fe["y2"], "drift")
    never = pl.run_day2(p, fe["R2"][0], fe["m_end2"][0], fe["y2"], "never")
    rec = fx.frontend_session(prep["Xf2"].astype(np.int64), [p["K_int"]], p["m_ref"], record=True)
    fire = rec["trace"]["mask"].reshape(-1, RAW_SAMPLES, cfg.N_CH)
    Xf2, y2 = prep["Xf2"].astype(float) / cfg.INPUT_SCALE, prep["y2"]
    T = len(y2)
    ev_macs = np.cumsum(fe["macs2"][0])
    fr_macs = np.cumsum(np.full(T, fx.frame_based_macs(RAW_SAMPLES - WARMUP)))
    ok_n = np.cumsum(neuro["preds"] == y2) / np.arange(1, T + 1)
    ok_0 = np.cumsum(never["preds"] == y2) / np.arange(1, T + 1)
    c3, c4 = CHANNELS.index("C3"), CHANNELS.index("C4")
    t_ax = (np.arange(WARMUP, RAW_SAMPLES)) / FS

    fig = plt.figure(figsize=(11, 7.5))
    gs = fig.add_gridspec(3, 1, height_ratios=[1.3, 1, 1], hspace=0.6)
    a1, a2, a3 = (fig.add_subplot(gs[i]) for i in range(3))
    title = fig.suptitle("", fontsize=13, fontweight="bold")

    def draw(t):
        a1.clear()
        for idx, off, col in ((c3, 0, "C0"), (c4, -1, "C1")):
            sig = Xf2[t, idx, WARMUP:]
            scale = np.abs(Xf2[:, idx, WARMUP:]).max() / 2.2
            a1.plot(t_ax, sig / scale + off * 2.2, lw=0.8, c=col, label=CHANNELS[idx])
            e = fire[t, WARMUP:, idx].astype(bool)
            a1.plot(t_ax[e], sig[e] / scale + off * 2.2, ".", ms=3, c="k")
        rate = fire[t, WARMUP:].mean()
        a1.set_yticks([])
        a1.set_xlabel("time after cue (s)")
        a1.set_title(f"Trial {t + 1}: dots = events sent ({rate:.0%} of samples), the rest is skipped",
                     fontsize=10)
        a1.legend(loc="upper right", fontsize=8)

        a2.clear()
        x = np.arange(1, t + 2)
        a2.plot(x, ok_n[:t + 1] * 100, c="C0", lw=2, label="NeuroEdge (self-calibrating)")
        a2.plot(x, ok_0[:t + 1] * 100, c="C3", lw=1.5, label="no recalibration")
        for d in neuro["drift_at"]:
            if d <= t:
                a2.axvline(d + 1, c="r", lw=1.5)
        for r in neuro["recal_at"]:
            if r <= t:
                a2.axvline(r + 1, c="gray", ls=":", lw=1)
        a2.set_xlim(0.5, T)
        a2.set_ylim(30, 100)
        a2.set_ylabel("running accuracy (%)")
        a2.set_title("red line = drift detected, dotted = on-chip recalibration "
                     f"({sum(r <= t for r in neuro['recal_at'])} so far)", fontsize=10)
        a2.legend(loc="lower right", fontsize=8)

        a3.clear()
        a3.plot(x, fr_macs[:t + 1] / 1e6, c="C7", label="every-sample covariance")
        a3.plot(x, ev_macs[:t + 1] / 1e6, c="C2", lw=2, label="NeuroEdge event-driven")
        a3.set_xlim(0.5, T)
        a3.set_ylim(0, fr_macs[-1] / 1e6 * 1.05)
        a3.set_xlabel("trial")
        a3.set_ylabel("MACs (millions)")
        a3.set_title(f"Work so far: {fr_macs[t] / ev_macs[t]:.1f}x fewer multiply-accumulates",
                     fontsize=10)
        a3.legend(loc="upper left", fontsize=8)

        truth = "RIGHT" if y2[t] else "LEFT"
        dec = "RIGHT" if neuro["preds"][t] else "LEFT"
        mark = "correct" if dec == truth else "wrong"
        title.set_text(f"NeuroEdge  |  imagined {truth} hand  ->  decoded {dec}  ({mark})")
        title.set_color("green" if dec == truth else "red")

    anim = FuncAnimation(fig, draw, frames=T, interval=args.speed, repeat=False)
    if args.gif:
        out = pl.ROOT / "results" / "demo.gif"
        anim.save(out, writer=PillowWriter(fps=max(1, 1000 // args.speed)))
        print("Saved:", out)
    else:
        plt.show()


if __name__ == "__main__":
    main()
