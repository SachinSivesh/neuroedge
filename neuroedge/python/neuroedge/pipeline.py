"""Training on day 1 and online decoding of day 2, with the integer model.

Front-end results are cached in results/cache so the experiment scripts can
share them (the front end is the slow part: it runs sample by sample).
"""
from pathlib import Path

import numpy as np
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis

from . import config as cfg
from . import fixed as fx
from .data import load_raw_subject
from .decoder import csp_fit

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "results" / "cache"


K_SWEEP = [0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]  # thresholds simulated together


def _tag(synthetic):
    return "_synthetic" if synthetic else ""


# ============================================================ cached stages
def prepare_subject(subject, synthetic=False):
    """Raw epochs -> 16-bit integers -> integer IIR filter (cached)."""
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"filtered_s{subject}{_tag(synthetic)}.npz"
    if path.exists():
        d = np.load(path)
        return {k: d[k] for k in d.files}
    data = load_raw_subject(subject, synthetic=synthetic)
    _, q = fx.iir_design()
    out = {}
    for i, name in ((1, "train"), (2, "test")):
        X, y = data[name]
        Xi = fx.to_int_input(X)
        out[f"X{i}"] = Xi.astype(np.int16)
        out[f"Xf{i}"] = fx.iir_session(Xi, q).astype(np.int16)
        out[f"y{i}"] = y
    np.savez_compressed(path, **out)
    return out


def run_frontend(subject, K_values, synthetic=False):
    """Event front end on both days for several thresholds K (cached).

    Day 1 starts with an empty noise-floor tracker; day 2 starts from day 1's
    final tracker value (stored on chip as the drift reference)."""
    K_ints = [fx.k_to_int(K) for K in K_values]
    key = "-".join(str(k) for k in K_ints)
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"frontend_s{subject}{_tag(synthetic)}_K{key}.npz"
    # reuse any cached run that already contains all requested thresholds
    for cand in [path] + sorted(CACHE.glob(f"frontend_s{subject}{_tag(synthetic)}_K*.npz")):
        if not cand.exists():
            continue
        d = np.load(cand)
        have = list(d["K_ints"])
        if all(k in have for k in K_ints):
            idx = [have.index(k) for k in K_ints]
            return {k: (d[k] if k in ("y1", "y2") else d[k][idx]) for k in d.files}
    union = sorted(set(K_SWEEP) | set(K_values))
    if list(K_values) != union:
        # compute the whole standard sweep once; every script then reuses it
        full = run_frontend(subject, union, synthetic)
        have = list(full["K_ints"])
        idx = [have.index(k) for k in K_ints]
        return {k: (v if k in ("y1", "y2") else v[idx]) for k, v in full.items()}
    prep = prepare_subject(subject, synthetic)
    fe1 = fx.frontend_session(prep["Xf1"].astype(np.int64), K_ints,
                              np.zeros(cfg.N_CH, dtype=np.int64))
    out = {f"{k}1": v for k, v in fe1.items()}
    # each K starts day 2 from its own day-1 reference
    fe2 = fx.frontend_session(prep["Xf2"].astype(np.int64), K_ints, fe1["m_final"])
    out.update({f"{k}2": v for k, v in fe2.items()})
    out["K_ints"] = np.array(K_ints)
    out["y1"], out["y2"] = prep["y1"], prep["y2"]
    np.savez_compressed(path, **out)
    return out


# ============================================================ training
def _bits(x):
    return int(np.ceil(np.log2(max(float(x), 1e-12))))


def train(R1, y1, m_ref, K_int, iters=cfg.NS_ITERS):
    """Fit every on-chip parameter from day-1 trial covariances.

    Returns a dict of integer parameters (what goes into the RTL) plus the
    day-1 training accuracy."""
    n = len(y1)
    Rmean = R1.sum(axis=0) // n
    Rn, k1 = fx.ns_normalise(Rmean)
    Z1 = fx.ns_inv_sqrt(Rn, iters)

    # C' shift: day-1 covariances use at most CPRIME_W-3 bits (2 bits headroom)
    CS = max(0, _bits(np.abs(R1).max() + 1) - (cfg.CPRIME_W - 3))
    Cp = np.array([[sat_shift(R, CS) for R in R1]]).reshape(n, cfg.N_CH, cfg.N_CH).astype(float)

    # CSP on day-1 covariances aligned with the on-chip Newton-Schulz result
    W1 = fx.alignment_real(Z1, k1)
    F = csp_fit(W1 @ Cp @ W1.T, y1, cfg.N_FILT)

    # Fixed-point CSP filters: G = F_int x Z1 >> NS_FRAC uses G_W-3 bits
    Zr = Z1 / float(1 << cfg.NS_FRAC)
    FF = (cfg.G_W - 3) - _bits(np.abs(F @ Zr).max())
    F_int = np.round(F * 2.0 ** FF).astype(np.int64)
    assert np.abs(F_int).max() < (1 << (cfg.G_W - 1)), "F does not fit G_W bits"
    G1 = fx.g_from(F_int, Z1)

    feats = np.array([fx.backend_features(R, G1, k1, CS) for R in R1], dtype=float)
    lda = LinearDiscriminantAnalysis().fit(feats / (1 << cfg.LOG_FRAC), y1)
    w, b = lda.coef_[0], lda.intercept_[0]
    WF = (cfg.LDA_W_W - 2) - _bits(np.abs(w).max())
    w_int = np.round(w * 2.0 ** WF).astype(np.int64)
    b_int = int(round(b * 2.0 ** (WF + cfg.LOG_FRAC)))

    pred = np.array([fx.lda_score(f, w_int, b_int) > 0 for f in feats.astype(np.int64)])
    return dict(K_int=K_int, CS=CS, F_int=F_int, FF=FF, Z1=Z1, k1=k1, G1=G1,
                w_int=w_int, b_int=b_int, WF=WF, m_ref=np.asarray(m_ref, dtype=np.int64),
                iters=iters, train_acc=float((pred == y1).mean()))


def sat_shift(R, CS):
    return fx.sat(np.asarray(R, dtype=np.int64) >> CS, cfg.CPRIME_W)


# ============================================================ day-2 decoding
def run_day2(p, R2, m_end2, y2, policy="drift", rn=cfg.DRIFT_RN, rd=cfg.DRIFT_RD,
             iters=None):
    """Decode day 2 trial by trial, causally.

    policy:
      never   keep the day-1 alignment
      drift   NeuroEdge: when the noise floor drifts, recalibrate at trials
              1, 2, 4, ..., 64 after the drift (mean = sum >> log2 n, no divider)
      start   same burst, but started blindly at power-on (no drift detector)
      every   recalibrate after every trial with the mean of all trials so far
              (needs a divider; the usual software approach)
      oracle  align with the mean of ALL day-2 trials before decoding
              (not causal: upper bound only)
    Each trial is decided with the alignment that existed BEFORE its own data
    was used, so no trial helps decode itself (except in 'oracle').
    """
    iters = iters or p["iters"]
    Z, k, G = p["Z1"], p["k1"], p["G1"]
    m_ref = p["m_ref"].copy()
    burst, n, Rsum = policy == "start", 0, np.zeros_like(R2[0])
    if policy == "oracle":
        Rn, k = fx.ns_normalise(R2.sum(axis=0) // len(R2))
        Z = fx.ns_inv_sqrt(Rn, iters)
        G = fx.g_from(p["F_int"], Z)
    preds, recal_at, drift_at, scores = [], [], [], []
    for t, R in enumerate(R2):
        f = fx.backend_features(R, G, k, p["CS"])
        s = fx.lda_score(f, p["w_int"], p["b_int"])
        scores.append(s)
        preds.append(int(s > 0))
        recal = False
        # Drift is only checked between bursts; the reference noise floor is
        # re-taken when a burst ends, once the tracker has settled.
        if policy == "drift" and not burst and fx.drift(m_end2[t], m_ref, rn, rd):
            burst, n, Rsum = True, 0, np.zeros_like(R)
            drift_at.append(t)
        if policy in ("drift", "start") and burst:
            Rsum = Rsum + R
            n += 1
            if n & (n - 1) == 0:  # power of two
                Z, k = fx.ns_calibrate(Rsum, n.bit_length() - 1, iters)
                recal = True
            if n == cfg.BURST_MAX:
                burst = False
                m_ref = m_end2[t].copy()
        elif policy == "every":
            Rsum = Rsum + R
            n += 1
            Rn, k = fx.ns_normalise(Rsum // n)
            Z = fx.ns_inv_sqrt(Rn, iters)
            recal = True
        if recal:
            G = fx.g_from(p["F_int"], Z)
            recal_at.append(t)
    preds = np.array(preds)
    return dict(acc=float((preds == y2).mean()), preds=preds, scores=np.array(scores),
                recal_at=recal_at, drift_at=drift_at, n_recal=len(recal_at))


def ns_macs(iters=cfg.NS_ITERS):
    """MACs for one recalibration: 3 matrix products per iteration + G = F x Z."""
    c = cfg.N_CH
    return iters * 3 * c ** 3 + cfg.N_FILT * c * c
