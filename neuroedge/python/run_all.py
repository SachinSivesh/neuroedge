"""Run every step in order (right-click -> Run in PyCharm).

    python run_all.py              # real data, all 9 subjects (~15-25 min first time)
    python run_all.py --synthetic  # toy data, checks the code in ~3 minutes
    python run_all.py --from 4     # restart from step 4

Steps:
  test_model           self-test of the bit-exact model (no data)
  00 check_setup       packages + first EEG plot
  01 baseline          CSP + LDA, the number to beat
  02 iir_design        filter coefficients + RTL test vectors
  03 self_calibration  Newton-Schulz + label-free alignment
  04 event_encoder     threshold sweep: work saved vs accuracy
  05 drift_recal       drift-triggered recalibration
  06 hardware_model    integer model for all subjects + RTL parameters/vectors
  07 summary           tables and headline figure
(08_demo_replay.py is run by hand: it opens a live window.)
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
STEPS = [
    (-1, "test_model.py", False),
    (0, "00_check_setup.py", False),
    (1, "01_baseline.py", True),
    (2, "02_iir_design.py", False),
    (3, "03_self_calibration.py", True),
    (4, "04_event_encoder.py", True),
    (5, "05_drift_recalibration.py", True),
    (6, "06_hardware_model.py", True),
    (7, "07_summary.py", True),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--from", dest="start", type=int, default=-1)
    ap.add_argument("--subjects", type=int, nargs="*")
    args = ap.parse_args()

    for num, script, takes_subjects in STEPS:
        if num < args.start:
            continue
        cmd = [sys.executable, str(HERE / script)]
        if args.synthetic and num >= 0:
            cmd.append("--synthetic")
        if args.subjects and takes_subjects:
            cmd += ["--subjects", *map(str, args.subjects)]
        print(f"\n{'=' * 70}\n>>> {script}\n{'=' * 70}", flush=True)
        t0 = time.time()
        if subprocess.run(cmd, cwd=HERE).returncode != 0:
            sys.exit(f"\nStopped: {script} failed. Fix the error above, then rerun with --from {num}")
        print(f"[{script} done in {time.time() - t0:.0f} s]")
    print("\nAll steps finished. Results are in the results folder; "
          "RTL parameters and test vectors in rtl/params and vectors.")


if __name__ == "__main__":
    main()
