"""Small helpers shared by the experiment scripts."""
import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

from .data import SUBJECTS

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "results"


def parse_args(description, extra=None):
    ap = argparse.ArgumentParser(description=description)
    ap.add_argument("--synthetic", action="store_true",
                    help="toy data, no download (for testing code only)")
    ap.add_argument("--subjects", type=int, nargs="*", default=SUBJECTS)
    if extra:
        extra(ap)
    return ap.parse_args()


def out_path(name, synthetic, ext):
    RESULTS.mkdir(exist_ok=True)
    return RESULTS / f"{name}{'_synthetic' if synthetic else ''}.{ext}"


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print("Saved:", path)


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))
