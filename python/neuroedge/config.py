"""Hardware number formats and algorithm settings, in one place.

Both the Python bit-exact model (fixed.py) and the Verilog read these
values: python/06_hardware_model.py writes them into rtl/params/*.vh.
Change a value here, rerun 06, and both sides stay in step.
"""
N_CH = 8                  # EEG channels

# ---- IIR band-pass (8-30 Hz, 2 biquads, Direct Form I) -----------------------
IIR_BAND = (8.0, 30.0)
IIR_ORDER = 2             # scipy butter order -> 2 biquads (4th order)
IIR_COEF_W = 18           # coefficient width, fits a DSP48E1 18-bit input
IIR_FRAC = 15             # coefficient fractional bits
DATA_W = 16               # sample width at filter input/output
IIR_INT_W = 24            # sample width inside the filter (8 guard bits)
IIR_ACC_W = 48            # accumulator width

INPUT_SCALE = 16          # input LSB = 1/16 microvolt (int = round(uV * 16))

# ---- Event encoder: send-on-delta with a noise-tracking threshold -------------
# event if |x - last_sent| >= max(1, (m * K) >> (M_FRAC + K_FRAC))
# m tracks mean |x|: m += ((|x| << M_FRAC) - m) >>> M_SHIFT
M_FRAC = 8                # fractional bits of the mean-|x| tracker
M_W = 24                  # tracker width
M_SHIFT = 9               # tracker time constant 2^9 samples = about 2 s
K_FRAC = 4                # threshold multiplier fractional bits
K_DEFAULT = 1.0           # threshold = K * mean|x|; swept in 04_event_encoder

# ---- Event-driven covariance ------------------------------------------------
ACC_SUM_W = 26            # running sum of held values per channel
COV_W = 48                # covariance accumulator

# ---- Drift monitor: per-channel noise floor vs reference ----------------------
# drift if m * RD > m_ref * RN  or  m * RN < m_ref * RD   (ratio RN/RD)
DRIFT_RN, DRIFT_RD = 3, 2     # 1.5x change in any channel's noise floor
BURST_MAX = 64            # after drift: recalibrate at trial 1,2,4,...,64

# ---- Newton-Schulz inverse square root ----------------------------------------
NS_W = 32                 # matrix element width
NS_FRAC = 20              # fractional bits
NS_ITERS = 16             # iterations (real EEG: 12 at K=1, 16 at K=0; see 03)
RSUM_W = 48               # running covariance sum width

# ---- Back end: features and LDA -----------------------------------------------
N_FILT = 6                # CSP filters
G_W = 24                  # combined (CSP x alignment) filter width
CPRIME_W = 25             # covariance after the CS right shift
LOG_FRAC = 10             # log2 fractional bits
LOG_MANT = 8              # mantissa bits used to address the log LUT
LDA_W_W = 18              # LDA weight width
SCORE_W = 48              # LDA score width

# ---- Demo -----------------------------------------------------------------------
DEMO_SUBJECT = 3          # subject whose parameters go into the RTL (drifts at trial 24)
