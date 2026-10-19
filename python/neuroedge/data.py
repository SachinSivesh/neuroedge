"""Data loading for NeuroEdge.

Real data: BCI Competition IV 2a (MOABB name BNCI2014_001), 2 classes
(left hand vs right hand), 8 motor channels, 250 Hz, two sessions recorded on
different days.  Session 1 = training day, session 2 = test day.

Synthetic data (--synthetic): a small motor-imagery-like generator used only
to test the code without downloading anything.  Never report its numbers.
"""
import os
import sys
import warnings
from pathlib import Path

import numpy as np

# MOABB/MNE print the same harmless deprecation notice for every recording
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", message=".*non-standard config type.*")

FS = 250  # Hz, BCI IV-2a sampling rate

# 8 motor channels, placed symmetrically around the midline
CHANNELS = ["FC3", "FC4", "C3", "C1", "C2", "C4", "CP3", "CP4"]

# Time window used for each trial: 0.5 s to 2.5 s after the cue (500 samples)
TMIN, TMAX = 0.5, 2.5

SUBJECTS = list(range(1, 10))


def data_dir():
    """Folder where the dataset is cached (needs about 1.5 GB).

    Set the NEUROEDGE_DATA environment variable to choose a folder.
    Default: D:/neuroedge_data on Windows if drive D exists, else ~/neuroedge_data.
    """
    path = os.environ.get("NEUROEDGE_DATA")
    if not path:
        if sys.platform.startswith("win") and Path("D:/").exists():
            path = "D:/neuroedge_data"
        else:
            path = str(Path.home() / "neuroedge_data")
    Path(path).mkdir(parents=True, exist_ok=True)
    return path


def _configure_mne():
    import mne

    path = data_dir()
    # Setting both keys stops MNE/MOABB from asking questions during download
    mne.set_config("MNE_DATA", path, set_env=True)
    mne.set_config("MNE_DATASETS_BNCI_PATH", path, set_env=True)
    mne.set_log_level("WARNING")


def to_microvolts(X):
    """Return X in microvolts whatever unit the MOABB version delivers.

    Older MOABB returns volts (|x| ~ 1e-5); newer versions (data from
    nemar.org) already return microvolts (|x| ~ 1-100).  Detected from the
    typical magnitude, so the 16-bit hardware input is never saturated."""
    X = np.asarray(X, dtype=np.float64)
    med = float(np.median(np.abs(X)))
    if med < 1e-3:          # volts
        return X * 1e6
    return X                # already microvolts


def _dataset():
    try:
        from moabb.datasets import BNCI2014_001 as DS
    except ImportError:  # older MOABB versions
        from moabb.datasets import BNCI2014001 as DS
    return DS()


def load_subject(subject, fmin=8.0, fmax=30.0, synthetic=False):
    """Return a dict with two sessions for one subject.

    {"train": (X1, y1), "test": (X2, y2)}
    X has shape (trials, 8 channels, 500 samples) in microvolts.
    y is 0 for left hand, 1 for right hand.
    fmin/fmax: band-pass applied by MNE.  Pass fmin=None to get raw data
    (needed later when our own IIR filter does the filtering).
    """
    if synthetic:
        return synthetic_subject(subject)

    _configure_mne()
    from moabb.paradigms import LeftRightImagery

    kwargs = dict(channels=CHANNELS, tmin=TMIN, tmax=TMAX, resample=FS)
    if fmin is not None:
        kwargs.update(fmin=fmin, fmax=fmax)
    else:
        kwargs.update(fmin=0.5, fmax=100.0)
    paradigm = LeftRightImagery(**kwargs)
    X, labels, meta = paradigm.get_data(dataset=_dataset(), subjects=[subject])

    X = to_microvolts(X)
    y = (np.asarray(labels) == "right_hand").astype(int)
    sessions = sorted(meta["session"].unique())  # e.g. ['0train', '1test']
    if len(sessions) != 2:
        raise RuntimeError(f"expected 2 sessions, got {sessions}")
    out = {}
    for name, sess in zip(("train", "test"), sessions):
        idx = (meta["session"] == sess).to_numpy()
        out[name] = (X[idx], y[idx])
    return out


RAW_TMAX = 2.5      # raw epochs: 0 to 2.5 s after the cue
RAW_SAMPLES = 625   # 2.5 s at 250 Hz
WARMUP = 125        # first 0.5 s lets the IIR filter settle; not used for decoding


def load_raw_subject(subject, synthetic=False):
    """Unfiltered (0.5-100 Hz) epochs for the hardware pipeline, where our own
    IIR filter does the 8-30 Hz band-pass.

    Each trial is 625 samples (0-2.5 s after the cue).  Samples 125-624
    (0.5-2.5 s) form the decoding window, the same window as 01_baseline.
    Returns {"train": (X1, y1), "test": (X2, y2)}, X in microvolts.
    """
    if synthetic:
        return synthetic_subject(subject, n_samples=RAW_SAMPLES, raw=True)

    _configure_mne()
    from moabb.paradigms import LeftRightImagery

    paradigm = LeftRightImagery(channels=CHANNELS, fmin=0.5, fmax=100.0,
                                tmin=0.0, tmax=RAW_TMAX, resample=FS)
    X, labels, meta = paradigm.get_data(dataset=_dataset(), subjects=[subject])
    X = to_microvolts(X[:, :, :RAW_SAMPLES])
    y = (np.asarray(labels) == "right_hand").astype(int)
    sessions = sorted(meta["session"].unique())
    out = {}
    for name, sess in zip(("train", "test"), sessions):
        idx = (meta["session"] == sess).to_numpy()
        out[name] = (X[idx], y[idx])
    return out


# ---------------------------------------------------------------- synthetic
def synthetic_subject(subject, n_trials=144, n_samples=500, drift=True, raw=False):
    """Motor-imagery-like toy data with a day-to-day drift between sessions.

    Two 8-30 Hz sources (left and right motor cortex).  Imagining the left
    hand weakens the right-hemisphere source and vice versa.  Session 2 uses a
    different mixing matrix and channel gains, which mimics a cap placed
    differently on another day.
    """
    rng = np.random.default_rng(1000 + subject)
    t = np.arange(n_samples) / FS
    base_mix = rng.normal(size=(8, 2))
    base_mix[[0, 2, 3, 6], 0] += 2.0  # left-hemisphere channels see source 0
    base_mix[[1, 4, 5, 7], 1] += 2.0  # right-hemisphere channels see source 1

    def session(seed, mix, gains):
        r = np.random.default_rng(seed)
        y = np.repeat([0, 1], n_trials // 2)
        r.shuffle(y)
        X = np.empty((n_trials, 8, n_samples))
        for i, label in enumerate(y):
            amp = np.ones(2)
            amp[1 - label] = 0.7  # contralateral desynchronisation
            src = np.stack([
                amp[k] * np.sin(2 * np.pi * r.uniform(9, 13) * t + r.uniform(0, 6.3))
                for k in range(2)
            ])
            noise = r.normal(scale=1.5, size=(8, n_samples))
            X[i] = gains[:, None] * (mix @ src) * 10 + noise * 10
            if raw:  # out-of-band content the band-pass filter must remove
                X[i] += 40 * np.sin(2 * np.pi * 1.0 * t + r.uniform(0, 6.3))
                X[i] += 15 * np.sin(2 * np.pi * 50.0 * t)
        return X, y

    X1, y1 = session(subject * 7 + 1, base_mix, np.ones(8))
    if drift:
        mix2 = base_mix + rng.normal(scale=1.2, size=base_mix.shape)
        gains2 = rng.uniform(0.3, 3.0, size=8)
    else:
        mix2, gains2 = base_mix, np.ones(8)
    X2, y2 = session(subject * 7 + 2, mix2, gains2)
    return {"train": (X1, y1), "test": (X2, y2)}
