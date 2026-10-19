"""Day 2: baseline CSP + LDA, the number NeuroEdge has to beat.

For each of the 9 subjects:
  same-session  : 5-fold cross-validation inside session 1 (what the base
                  paper reports; target is near its ~80% on 2 classes)
  cross-session : train on session 1 (day 1), test on session 2 (day 2) with
                  no recalibration -- this is the drop NeuroEdge must fix
  cross+align   : preview of Wednesday's self-calibration: same as
                  cross-session, but day-2 data is aligned using only its own
                  unlabelled covariances

Output: results/phase1_baseline.csv and a printed table.

    python 01_baseline.py               # all 9 subjects (first run downloads ~1.3 GB)
    python 01_baseline.py --subjects 1 2 3
    python 01_baseline.py --synthetic   # toy data, no download
"""
import argparse
import csv
from pathlib import Path

import numpy as np
from sklearn.model_selection import StratifiedKFold

from neuroedge.data import SUBJECTS, load_subject
from neuroedge.decoder import CSPLDA, covariances

RESULTS = Path(__file__).resolve().parent.parent / "results"


def same_session_cv(covs, y, folds=5, seed=0):
    accs = []
    for tr, te in StratifiedKFold(folds, shuffle=True, random_state=seed).split(covs, y):
        model = CSPLDA().fit(covs[tr], y[tr])
        accs.append((model.predict(covs[te]) == y[te]).mean())
    return float(np.mean(accs))


def run_subject(subject, synthetic):
    data = load_subject(subject, synthetic=synthetic)
    (X1, y1), (X2, y2) = data["train"], data["test"]
    C1, C2 = covariances(X1), covariances(X2)

    same = same_session_cv(C1, y1)
    cross = (CSPLDA().fit(C1, y1).predict(C2) == y2).mean()
    cross_al = (CSPLDA(aligned=True).fit(C1, y1).predict(C2) == y2).mean()
    return dict(subject=subject, same_session=same, cross_session=float(cross),
                cross_aligned=float(cross_al), n_train=len(y1), n_test=len(y2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subjects", type=int, nargs="*", default=SUBJECTS)
    ap.add_argument("--synthetic", action="store_true")
    args = ap.parse_args()

    rows = []
    print(f"{'Subj':>4} {'same-session':>13} {'cross-session':>14} {'cross+align':>12}")
    for s in args.subjects:
        r = run_subject(s, args.synthetic)
        rows.append(r)
        print(f"{s:>4} {r['same_session']:>13.1%} {r['cross_session']:>14.1%} "
              f"{r['cross_aligned']:>12.1%}")

    mean = {k: np.mean([r[k] for r in rows]) for k in ("same_session", "cross_session", "cross_aligned")}
    print(f"{'Mean':>4} {mean['same_session']:>13.1%} {mean['cross_session']:>14.1%} "
          f"{mean['cross_aligned']:>12.1%}")
    print("\nBase paper (Malekmohammadi 2019), 2 classes: 80.55%")

    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / f"phase1_baseline{'_synthetic' if args.synthetic else ''}.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("Saved:", out)


if __name__ == "__main__":
    main()
