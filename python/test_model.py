"""Self-test of the bit-exact model (run any time: python test_model.py).

Checks the fast vectorised model against slow reference code written in the
same order as the Verilog state machines, plus basic maths properties.
No dataset needed.
"""
import math

import numpy as np

from neuroedge import config as cfg, fixed as fx
from neuroedge.data import WARMUP


def ref_frontend(Xf, K, m_init):
    """Scalar reference, one channel sample at a time, like event_encoder.v
    feeding event_cov.v (frame buffer, then row MACs, then end-of-frame)."""
    T, C, N = Xf.shape
    L = [0] * C               # encoder: last sent value
    Hc = [0] * C              # covariance unit: its copy of the held values
    m = [int(v) for v in m_init]
    out_R, out_macs = [], []
    for t in range(T):
        A = [0] * C
        S = [[0] * C for _ in range(C)]
        R = [[0] * C for _ in range(C)]
        macs = 0
        for n in range(N):
            active = n >= WARMUP
            fire, val = [0] * C, [0] * C
            for c in range(C):                       # encoder, one sample per cycle
                x = int(Xf[t, c, n])
                th = max((m[c] * K) >> (cfg.M_FRAC + cfg.K_FRAC), 1)
                fire[c] = int(abs(x - L[c]) >= th)
                m[c] = m[c] + (((abs(x) << cfg.M_FRAC) - m[c]) >> cfg.M_SHIFT)
                if fire[c]:
                    L[c] = x
                val[c] = x
            for c in range(C):                       # covariance FSM, row by row
                if fire[c]:
                    if active:
                        for j in range(C):
                            R[c][j] += Hc[c] * (A[j] - S[c][j])
                            S[c][j] = A[j]
                            macs += 1
                    Hc[c] = val[c]
            if active:
                for j in range(C):
                    A[j] += Hc[j]
        for c in range(C):                           # flush
            for j in range(C):
                R[c][j] += Hc[c] * (A[j] - S[c][j])
                macs += 1
        out_R.append(R)
        out_macs.append(macs)
    return np.array(out_R), np.array(out_macs), m


def main():
    rng = np.random.default_rng(7)
    sos, q = fx.iir_design()

    # 1. IIR: vectorised stream == per-channel runs (no state mixing)
    x = rng.integers(-20000, 20000, size=(2000, 8))
    y = fx.iir_stream(x, q)
    for c in range(8):
        assert np.array_equal(fx.iir_stream(x[:, c:c + 1], q)[:, 0], y[:, c])
    print("IIR channel independence ........ OK")

    # 2. Front end: vectorised == scalar reference (RTL order)
    Xf = fx.iir_stream(rng.integers(-3000, 3000, size=(2 * 625, 8)), q)
    Xf = Xf.reshape(2, 625, 8).transpose(0, 2, 1)
    m0 = rng.integers(1000, 50000, size=8)
    for K in (0, 8, 16, 40):
        R_ref, mac_ref, m_ref = ref_frontend(Xf, K, m0)
        fe = fx.frontend_session(Xf, [K], m0)
        assert np.array_equal(fe["R"][0], R_ref), f"R mismatch K={K}"
        assert np.array_equal(fe["macs"][0], mac_ref), f"MAC mismatch K={K}"
        assert np.array_equal(fe["m_final"][0], np.array(m_ref)), f"m mismatch K={K}"
    print("Front end == RTL-order reference  OK")

    # 3. Event covariance is EXACT for the held (reconstructed) signal
    K = 16
    rec = fx.frontend_session(Xf, [K], m0, record=True)
    held = rec["trace"]["L"].reshape(2, 625, 8)
    for t in range(2):
        h = held[t, WARMUP:].astype(object)
        direct = np.array([[sum(h[:, i] * h[:, j]) for j in range(8)] for i in range(8)])
        assert np.array_equal(rec["R"][0][t].astype(object), direct)
    print("Event covariance exact ........... OK")

    # 4. Newton-Schulz approaches the exact inverse square root
    A = rng.normal(size=(8, 8))
    Rm = (A @ A.T + 0.5 * np.eye(8)) * 1e6
    Rn, k = fx.ns_normalise(Rm.astype(np.int64))
    Zf = fx.ns_inv_sqrt(Rn, 20) / float(1 << cfg.NS_FRAC)
    w, V = np.linalg.eigh(Rn / float(1 << cfg.NS_FRAC))
    exact = (V / np.sqrt(w)) @ V.T
    err = np.linalg.norm(Zf - exact) / np.linalg.norm(exact)
    assert err < 1e-3, err
    print(f"Newton-Schulz error {err:.1e} ........ OK")

    # 5. log2 LUT accuracy
    worst = max(abs(fx.log2_fixed(u) / (1 << cfg.LOG_FRAC) - math.log2(u))
                for u in rng.integers(1, 1 << 62, size=2000, dtype=np.int64))
    assert worst < 0.01, worst
    print(f"log2 LUT worst error {worst:.4f} ...... OK")
    print("\nAll model checks passed.")


if __name__ == "__main__":
    main()
