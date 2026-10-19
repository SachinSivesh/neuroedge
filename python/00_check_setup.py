"""Day 1 check: is the setup working, and can we see motor imagery in the data?

Run in PyCharm (right-click -> Run).  First run downloads BCI IV-2a subject 1
(about 150 MB) into the data folder printed below.

Expected result: imagining the LEFT hand lowers 8-30 Hz power over the RIGHT
hemisphere (C4), and imagining the RIGHT hand lowers it over C3.  If the plot
shows that, the data, filtering and labels are all correct.

    python 00_check_setup.py               # real data
    python 00_check_setup.py --synthetic   # no download, toy data
"""
import argparse
import platform
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from neuroedge.data import CHANNELS, FS, data_dir, load_subject

RESULTS = Path(__file__).resolve().parent.parent / "results"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--subject", type=int, default=1)
    args = ap.parse_args()

    print("Python  :", platform.python_version())
    for mod in ("numpy", "scipy", "sklearn", "matplotlib", "mne", "moabb", "pyriemann"):
        try:
            print(f"{mod:<8}: {__import__(mod).__version__}")
        except ImportError:
            print(f"{mod:<8}: NOT INSTALLED")
    print("Data dir:", data_dir())

    data = load_subject(args.subject, synthetic=args.synthetic)
    X, y = data["train"]
    print(f"\nSubject {args.subject}, session 1: {X.shape[0]} trials, "
          f"{X.shape[1]} channels, {X.shape[2]} samples ({X.shape[2] / FS:.1f} s)")
    print(f"Left trials: {(y == 0).sum()}, right trials: {(y == 1).sum()}")

    # Log band power (data is already 8-30 Hz filtered)
    power = np.log(X.var(axis=2))  # (trials, channels)
    c3, c4 = CHANNELS.index("C3"), CHANNELS.index("C4")

    rows = []
    for name, idx in (("C3 (left hemisphere)", c3), ("C4 (right hemisphere)", c4)):
        left, right = power[y == 0, idx].mean(), power[y == 1, idx].mean()
        rows.append((name, left, right))
        print(f"{name:<22} left-hand imagery: {left:6.3f}   right-hand imagery: {right:6.3f}")

    ok = (rows[0][2] < rows[0][1]) and (rows[1][1] < rows[1][2])
    print("\nContralateral power drop seen on both sides:", "YES" if ok else
          "NO (normal for some subjects; try --subject 3 or 8)")

    RESULTS.mkdir(exist_ok=True)
    fig, ax = plt.subplots(figsize=(6, 4))
    x = np.arange(2)
    ax.bar(x - 0.18, [r[1] for r in rows], 0.36, label="Left-hand imagery")
    ax.bar(x + 0.18, [r[2] for r in rows], 0.36, label="Right-hand imagery")
    ax.set_xticks(x, [r[0] for r in rows])
    ax.set_ylabel("log 8-30 Hz power")
    ax.set_title(f"Subject {args.subject}: power drops on the opposite side")
    lo = min(min(r[1:]) for r in rows)
    ax.set_ylim(lo - 0.3, None)
    ax.legend()
    fig.tight_layout()
    out = RESULTS / f"00_c3c4_power_s{args.subject}{'_synthetic' if args.synthetic else ''}.png"
    fig.savefig(out, dpi=130)
    print("Plot saved:", out)


if __name__ == "__main__":
    main()
