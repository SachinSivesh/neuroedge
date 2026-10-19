"""Floating-point golden model of the NeuroEdge decoder.

Pipeline (same order as the hardware):
    band-passed EEG -> covariance -> [alignment] -> CSP filters -> log-variance -> LDA

Written with plain NumPy/SciPy on purpose: every step here becomes a
hardware block, so nothing is hidden inside a library call.
"""
import numpy as np
from scipy.linalg import eigh
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis


# ------------------------------------------------------------ covariance
def covariances(X):
    """Per-trial channel covariance. X: (trials, ch, samples) -> (trials, ch, ch)."""
    Xc = X - X.mean(axis=2, keepdims=True)
    return np.einsum("nct,ndt->ncd", Xc, Xc) / X.shape[2]


# ------------------------------------------------------------ alignment
def inv_sqrtm(C):
    """Exact inverse matrix square root of a symmetric positive-definite matrix."""
    w, V = np.linalg.eigh(C)
    return (V / np.sqrt(w)) @ V.T


def alignment_matrix(covs):
    """Euclidean alignment reference: R^-1/2 with R = mean covariance.

    Uses no labels, so it can run on test-day data (self-calibration).
    """
    return inv_sqrtm(covs.mean(axis=0))


def align(covs, W):
    """Apply alignment: C -> W C W^T."""
    return W @ covs @ W.T


# ------------------------------------------------------------ CSP + LDA
def csp_fit(covs, y, n_filters=6):
    """Common Spatial Patterns. Returns (n_filters, ch) spatial filters."""
    Ca = covs[y == 0].mean(axis=0)
    Cb = covs[y == 1].mean(axis=0)
    w, V = eigh(Ca, Ca + Cb)  # generalised eigenproblem, ascending eigenvalues
    order = np.argsort(np.abs(w - 0.5))[::-1]  # most discriminative first
    return V[:, order[:n_filters]].T


def log_var(covs, F):
    """Log of the variance of each CSP-filtered signal: log(diag(F C F^T))."""
    return np.log(np.einsum("fc,ncd,fd->nf", F, covs, F))


class CSPLDA:
    """CSP + LDA with optional unsupervised alignment."""

    def __init__(self, n_filters=6, aligned=False):
        self.n_filters = n_filters
        self.aligned = aligned

    def fit(self, covs, y):
        if self.aligned:
            covs = align(covs, alignment_matrix(covs))
        self.F = csp_fit(covs, y, self.n_filters)
        self.lda = LinearDiscriminantAnalysis().fit(log_var(covs, self.F), y)
        return self

    def predict(self, covs, align_ref=None):
        """align_ref: covariances used to estimate the test-day alignment
        (unlabelled).  Defaults to the covariances being predicted."""
        if self.aligned:
            ref = covs if align_ref is None else align_ref
            covs = align(covs, alignment_matrix(ref))
        return self.lda.predict(log_var(covs, self.F))
