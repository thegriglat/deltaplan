# AWW-1: до/после по прототипам (контракт W1 v1)

Порог: |Δ| > 5 % или > 0,1 в единицах колонки. Пусто → число и наоборот — тоже строка.

## variant = strong_d_neff против main

| место | старт | колонка | main | после | Δ | Δ, % |
|---|---|---|---|---|---|---|
| training_island | thermal_plain | u2 | 0.343 | 0.869 | +0.526 | 153 |
| training_island | thermal_plain | u10 | 0.442 | 1.310 | +0.868 | 196 |
| training_island | thermal_plain | u50 | 0.388 | 2.495 | +2.107 | 543 |
| training_island | thermal_plain | u100 | 0.320 | 2.668 | +2.348 | 734 |
| training_island | thermal_plain | dir10_deg | 100.655 | 188.710 | +88.055 | 87 |
| training_island | thermal_plain | r10_100 | 1.382 | 0.491 | -0.891 | 64 |
| training_island | thermal_plain | theta_ml_K | -3.603 | 0.021 | +3.624 | 101 |
| training_island | thermal_plain | frozen_frac | 1.000 | 0.000 | -1.000 | 100 |
| training_island | thermal_plain | w_mean10 | 0.252 | 0.364 | +0.112 | 44 |
| training_island | thermal_plain | w_max10 | 0.423 | 0.703 | +0.280 | 66 |
| training_island | thermal_plain | sigma_u10 | 0.902 | 1.061 | +0.159 | 18 |
| training_island | thermal_plain | gust_max10 | 2.494 | 3.137 | +0.643 | 26 |
| training_island | thermal_plain | cloud_base_m | — | 1782.586 | — | — |
| training_island | thermal_plain | cloud_frac | 0.003 | 0.018 | +0.015 | 500 |
| training_island | thermal_plain | therm_n | 31.000 | 11.000 | -20.000 | 65 |
| training_island | thermal_plain | therm_w300 | 3.982 | 1.779 | -2.203 | 55 |
| training_island | thermal_plain | wave_w1500 | 0.037 | 0.020 | -0.017 | 46 |
| training_island | landing_hill | w_mean10 | 0.052 | 0.056 | +0.004 | 8 |
| training_island | lee_bowl | w_mean10 | 0.029 | 0.031 | +0.002 | 7 |

Строк: 19

## variant = theta_h против main

| место | старт | колонка | main | после | Δ | Δ, % |
|---|---|---|---|---|---|---|
| training_island | thermal_plain | u2 | 0.343 | 0.843 | +0.500 | 146 |
| training_island | thermal_plain | u10 | 0.442 | 1.271 | +0.829 | 188 |
| training_island | thermal_plain | u50 | 0.388 | 2.425 | +2.037 | 525 |
| training_island | thermal_plain | u100 | 0.320 | 2.591 | +2.271 | 710 |
| training_island | thermal_plain | dir10_deg | 100.655 | 187.344 | +86.689 | 86 |
| training_island | thermal_plain | r10_100 | 1.382 | 0.491 | -0.891 | 64 |
| training_island | thermal_plain | theta_ml_K | -3.603 | 0.020 | +3.623 | 101 |
| training_island | thermal_plain | w_mean10 | 0.252 | 0.334 | +0.082 | 33 |
| training_island | thermal_plain | w_max10 | 0.423 | 0.661 | +0.238 | 56 |
| training_island | thermal_plain | sigma_u10 | 0.902 | 1.084 | +0.182 | 20 |
| training_island | thermal_plain | gust_max10 | 2.494 | 3.013 | +0.519 | 21 |
| training_island | thermal_plain | cloud_base_m | — | 1782.586 | — | — |
| training_island | thermal_plain | cloud_frac | 0.003 | 0.016 | +0.013 | 433 |
| training_island | thermal_plain | therm_n | 31.000 | 21.000 | -10.000 | 32 |
| training_island | thermal_plain | therm_w300 | 3.982 | 1.995 | -1.987 | 50 |
| training_island | landing_hill | u2 | 0.383 | 0.408 | +0.025 | 7 |
| training_island | landing_hill | u10 | 0.527 | 0.561 | +0.034 | 6 |
| training_island | landing_hill | u50 | 0.499 | 0.530 | +0.031 | 6 |
| training_island | landing_hill | u100 | 0.429 | 0.455 | +0.026 | 6 |
| training_island | landing_hill | dir10_deg | 337.887 | 338.805 | +0.918 | 0 |
| training_island | landing_hill | w_mean10 | 0.052 | 0.056 | +0.004 | 8 |
| training_island | lee_bowl | w_mean10 | 0.029 | 0.031 | +0.002 | 7 |

Строк: 22

