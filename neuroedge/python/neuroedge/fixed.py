"""Bit-exact integer model of the NeuroEdge hardware.

Every function here is the specification of one Verilog block.  The RTL must
produce exactly the same integers; the testbenches check this with vectors
exported by 06_hardware_model.py.

Shifts: Python's >> on negative integers floors, exactly like Verilog's >>>
on signed values, so (v + half) >> F is the same round-half-up in both.

Blocks (in signal order):
    iir_*          8-30 Hz band-pass, 2 Direct Form I biquads per channel
    frontend_*     send-on-delta event encoder + event-driven covariance
    ns_*           Newton-Schulz inverse square root (self-calibration)
    g_from         combined CSP x alignment filters
    backend_*      quadratic-form features, log2, LDA decision
    drift          noise-floor drift test
"""
import numpy as np
from scipy import signal

from . import config as cfg
from .data import WARMUP


# ============================================================== helpers
def sat(v, width):
    """Saturate (numpy array or int) to a signed width-bit range."""
    hi, lo = (1 << (width - 1)) - 1, -(1 << (width - 1))
    if isinstance(v, np.ndarray):
        return np.clip(v, lo, hi)
    return hi if v > hi else lo if v < lo else v


def rshift_round(v, f):
    """Round-half-up right shift: (v + 2^(f-1)) >> f."""
    return (v + (1 << (f - 1))) >> f if f > 0 else v


def to_int_input(x_uv):
    """Microvolts -> 16-bit ADC-style integers (LSB = 1/16 uV)."""
    return np.clip(np.round(x_uv * cfg.INPUT_SCALE), -32768, 32767).astype(np.int64)


# ============================================================== IIR
def iir_design():
    """Return float SOS and the quantised integer coefficients
    q[s] = [b0, b1, b2, a0(=2^FRAC), a1, a2]."""
    sos = signal.butter(cfg.IIR_ORDER, cfg.IIR_BAND, btype="bandpass",
                        fs=250, output="sos")
    q = np.round(sos * (1 << cfg.IIR_FRAC)).astype(np.int64)
    q[:, 3] = 1 << cfg.IIR_FRAC
    assert np.all(np.abs(q) < (1 << (cfg.IIR_COEF_W - 1))), "IIR coefficient overflow"
    for row in q / (1 << cfg.IIR_FRAC):
        assert np.all(np.abs(np.roots(row[3:])) < 1), "quantised IIR unstable"
    return sos, q


def iir_stream(x, q):
    """Filter a continuous multi-channel stream.

    x: int array (frames, channels), DATA_W-bit samples.  Filter state carries
    across the whole stream, exactly like the hardware.
    Returns int array of the same shape.
    """
    guard = cfg.IIR_INT_W - cfg.DATA_W
    n_sec = len(q)
    ch = x.shape[1]
    st = np.zeros((n_sec, 4, ch), dtype=np.int64)  # x1, x2, y1, y2
    out = np.empty_like(x)
    coef = [tuple(int(c) for c in row) for row in q]
    acc_lim = 1 << (cfg.IIR_ACC_W - 1)
    for n in range(x.shape[0]):
        s = x[n] << guard
        for i, (b0, b1, b2, _, a1, a2) in enumerate(coef):
            x1, x2, y1, y2 = st[i].copy()  # copy: st[i] is overwritten below
            acc = b0 * s + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            assert np.all(np.abs(acc) < acc_lim)
            y = sat(rshift_round(acc, cfg.IIR_FRAC), cfg.IIR_INT_W)
            st[i, 0], st[i, 1], st[i, 2], st[i, 3] = s, x1, y, y1
            s = y
        out[n] = sat(rshift_round(s, guard), cfg.DATA_W)
    return out


def iir_session(X_int, q):
    """Filter a whole session.  X_int: (trials, ch, samples).  Trials are
    played back to back as one stream (the filter never resets)."""
    T, C, N = X_int.shape
    stream = X_int.transpose(0, 2, 1).reshape(T * N, C)
    return iir_stream(stream, q).reshape(T, N, C).transpose(0, 2, 1)


# ============================================================== front end
def k_to_int(K):
    return int(round(K * (1 << cfg.K_FRAC)))


def frontend_session(Xf, K_ints, m_init, record=False):
    """Event encoder + event-driven covariance over one session.

    Xf: filtered int samples (trials, ch, samples), played as one stream.
    K_ints: list of threshold multipliers (integer, K_FRAC fractional bits);
            all are simulated in parallel (independent copies of the hardware).
    m_init: initial noise-floor tracker per channel (M_FRAC fractional bits).
    The covariance is accumulated over samples WARMUP..end of each trial.

    Returns dict of arrays, first axis = K value:
        R      (nK, trials, ch, ch) trial covariance sums (exact for the held signal)
        events (nK, trials, ch)     events inside the decoding window
        macs   (nK, trials)         multiply-accumulates done by the covariance unit
        m_end  (nK, trials, ch)     noise-floor tracker at each trial end
        m_final(nK, ch)
    record=True (single K only) also returns per-frame traces for RTL vectors.
    """
    T, C, N = Xf.shape
    nK = len(K_ints)
    Kv = np.asarray(K_ints, dtype=np.int64)[:, None]
    L = np.zeros((nK, C), dtype=np.int64)          # last sent value (= held value H)
    m = np.asarray(m_init, dtype=np.int64)
    m = np.tile(m, (nK, 1)) if m.ndim == 1 else m.copy()  # (ch,) or (nK, ch)
    R_all = np.zeros((nK, T, C, C), dtype=np.int64)
    ev_all = np.zeros((nK, T, C), dtype=np.int64)
    mac_all = np.zeros((nK, T), dtype=np.int64)
    m_end = np.zeros((nK, T, C), dtype=np.int64)
    sh = cfg.M_FRAC + cfg.K_FRAC
    trace = {"mask": [], "L": []} if record else None

    for t in range(T):
        A = np.zeros((nK, C), dtype=np.int64)      # running sums of held values
        S = np.zeros((nK, C, C), dtype=np.int64)   # A snapshot at each channel's last event
        R = np.zeros((nK, C, C), dtype=np.int64)
        macs = np.zeros(nK, dtype=np.int64)
        for n in range(N):
            x = Xf[t, :, n]
            # ---- event encoder (all channels in parallel)
            th = np.maximum((m * Kv) >> sh, 1)
            ev = np.abs(x - L) >= th
            m = m + (((np.abs(x) << cfg.M_FRAC) - m) >> cfg.M_SHIFT)
            active = n >= WARMUP
            # ---- event-driven covariance: close the interval of each channel
            # that fires, using the OLD held value, then start a new interval
            if active and ev.any():
                d = A[:, None, :] - S                          # (nK, C, C)
                R += np.where(ev[:, :, None], L[:, :, None] * d, 0)
                S = np.where(ev[:, :, None], A[:, None, :], S)
                macs += 8 * ev.sum(axis=1)
                ev_all[:, t] += ev
            L = np.where(ev, x, L)
            if active:
                A += L                                         # end of frame
            if record:
                trace["mask"].append(ev[0].copy())
                trace["L"].append(L[0].copy())
        # ---- trial end: flush every open interval (64 MACs)
        R += L[:, :, None] * (A[:, None, :] - S)
        macs += C * C
        R_all[:, t] = R
        mac_all[:, t] = macs
        m_end[:, t] = m
    out = dict(R=R_all, events=ev_all, macs=mac_all, m_end=m_end, m_final=m)
    if record:
        out["trace"] = {k: np.array(v) for k, v in trace.items()}
    return out


def frame_based_macs(n_frames):
    """MACs for a conventional covariance unit (upper triangle every sample)."""
    return n_frames * cfg.N_CH * (cfg.N_CH + 1) // 2


# ============================================================== Newton-Schulz
def _mm(A, B, frac=cfg.NS_FRAC, width=cfg.NS_W):
    """Fixed-point matrix multiply: sat((A @ B + half) >> frac)."""
    P = A.astype(np.int64) @ B.astype(np.int64)
    return sat(rshift_round(P, frac), width)


def ns_normalise(Rmean):
    """Scale a mean covariance into NS format: Rn = Rmean / 4^k, eigenvalues < 1.

    k = (p + 2) >> 1 where p = floor(log2(trace)), so trace/4^k is in (1/4, 1/2].
    Returns (Rn in Q.NS_FRAC, k)."""
    tr = int(np.trace(Rmean))
    assert tr > 0
    p = tr.bit_length() - 1
    k = (p + 2) >> 1
    sh = 2 * k - cfg.NS_FRAC
    Rn = (Rmean >> sh) if sh >= 0 else (Rmean << -sh)
    return sat(Rn.astype(np.int64), cfg.NS_W), k


def ns_inv_sqrt(Rn, iters=cfg.NS_ITERS):
    """Coupled Newton-Schulz: Y -> Rn^(1/2), Z -> Rn^(-1/2), multiply-adds only.

        P = Z Y ;  T = (3I - P) >>> 1 ;  Y = Y T ;  Z = T Z
    """
    one = 1 << cfg.NS_FRAC
    eye = np.eye(cfg.N_CH, dtype=np.int64)
    Y = Rn.astype(np.int64)
    Z = eye * one
    for _ in range(iters):
        P = _mm(Z, Y)
        T = (3 * one * eye - P) >> 1
        Y, Z = _mm(Y, T), _mm(T, Z)
    return Z


def ns_calibrate(Rsum, lg, iters=cfg.NS_ITERS):
    """What the hardware calibration unit does: mean of 2^lg trial covariances
    (a shift, no divider), normalise, Newton-Schulz.  Returns (Z, k)."""
    Rmean = Rsum >> lg
    Rn, k = ns_normalise(Rmean)
    return ns_inv_sqrt(Rn, iters), k


def g_from(F_int, Z):
    """Combined filters G = F x Z (CSP filters folded with the alignment)."""
    return sat(_mm(F_int, Z), cfg.G_W)


def alignment_real(Z, k):
    """The real-valued alignment matrix W = Z * 2^-NS_FRAC * 2^-k."""
    return Z / float(1 << cfg.NS_FRAC) / float(2 ** k)


# ============================================================== back end
def log_lut():
    m = np.arange(1 << cfg.LOG_MANT)
    return np.round(np.log2(1 + m / (1 << cfg.LOG_MANT)) * (1 << cfg.LOG_FRAC)).astype(np.int64)


LUT = log_lut()


def log2_fixed(u):
    """log2 of a positive integer in LOG_FRAC fixed point: leading-one
    position plus a LUT on the next LOG_MANT bits.  u <= 0 returns 0."""
    u = int(u)
    if u <= 0:
        return 0
    p = u.bit_length() - 1
    mb = cfg.LOG_MANT
    mant = (u >> (p - mb)) if p >= mb else (u << (mb - p))
    mant &= (1 << mb) - 1
    return (p << cfg.LOG_FRAC) + int(LUT[mant])


def backend_features(R, G, k, CS):
    """Integer features f_i = log2(g_i C' g_i^T) - 2k  (LOG_FRAC fixed point).

    C' = sat(R >>> CS), t_j = sum_k C'_jk g_ik, u_i = sum_j g_ij t_j.
    """
    Cp = [[int(sat(int(R[j, kk]) >> CS, cfg.CPRIME_W)) for kk in range(cfg.N_CH)]
          for j in range(cfg.N_CH)]
    f = []
    for i in range(G.shape[0]):
        g = [int(v) for v in G[i]]
        t = [sum(Cp[j][kk] * g[kk] for kk in range(cfg.N_CH)) for j in range(cfg.N_CH)]
        u = sum(g[j] * t[j] for j in range(cfg.N_CH))
        f.append(log2_fixed(u) - (k << (cfg.LOG_FRAC + 1)))
    return f


def lda_score(f, w_int, b_int):
    return sum(int(a) * int(b) for a, b in zip(w_int, f)) + int(b_int)


# ============================================================== drift
def drift(m, m_ref, rn=cfg.DRIFT_RN, rd=cfg.DRIFT_RD):
    """True if any channel's noise floor moved by more than rn/rd either way."""
    m = np.asarray(m, dtype=np.int64)
    r = np.asarray(m_ref, dtype=np.int64)
    return bool(np.any((m * rd > r * rn) | (m * rn < r * rd)))
