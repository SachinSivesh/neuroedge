# NeuroEdge results

## 1. Baseline (software CSP + LDA, 8 channels, 2 classes)

| Subject | Same-session | Day 1 -> day 2 |
|---|---|---|
| S1 | 84.7% | 91.7% |
| S2 | 63.2% | 54.2% |
| S3 | 94.5% | 97.9% |
| S4 | 70.8% | 63.2% |
| S5 | 52.0% | 50.7% |
| S6 | 67.4% | 62.5% |
| S7 | 61.9% | 56.9% |
| S8 | 97.2% | 95.1% |
| S9 | 93.1% | 87.5% |
| **Mean** | **76.1%** | **73.3%** |

Base paper (Malekmohammadi 2019, same dataset, 2 classes): 80.55%

## 2. Day-2 accuracy and calibration work (hardware model, K = 1.0)

| Policy | Mean accuracy | Recalibrations | Calibration MACs |
|---|---|---|---|
| No recalibration | 72.1% | 0.0 | 0 |
| Every trial (software) | 73.5% | 144.0 | 3,594,240 |
| Burst at power-on | 72.5% | 7.0 | 174,720 |
| **NeuroEdge (drift-triggered)** | 73.7% | 7.9 | 196,907 |
| Oracle (all of day 2, not causal) | 73.7% | 0.0 | 0 |

## 3. Event-driven covariance

Mean event rate 23.0% of samples; 2.5x fewer covariance multiply-accumulates than an every-sample unit.

| K | Events kept | MAC reduction | Accuracy |
|---|---|---|---|
| 0.0 | 98.9% | 0.6x | 75.0% |
| 0.25 | 66.8% | 0.8x | 75.3% |
| 0.5 | 44.8% | 1.3x | 74.3% |
| 0.75 | 31.4% | 1.8x | 73.1% |
| 1.0 | 23.0% | 2.5x | 73.7% |
| 1.5 | 13.5% | 4.2x | 68.7% |
| 2.0 | 8.6% | 6.5x | 65.7% |
| 3.0 | 3.9% | 13.8x | 53.6% |

## 4. Fixed-point loss

Float 73.5% vs bit-exact integer 73.7%: -0.2 points.

