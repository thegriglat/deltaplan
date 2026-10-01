# Моррис: что двигает каждую наблюдаемую (вариант «все»; S = μ*/порог)

## Askervein, разгон по точкам

- **Askervein ASW85** (порог 0.045): двигают — alpha_mul 1.8, closure 1.7, nu_const 1.1, z0_mul 1.1; слабо — local_k 0.58, lam_frac 0.37
- **Askervein ASW50** (порог 0.046): двигают — alpha_mul 1.5, closure 1.5; слабо — z0_mul 0.99, nu_const 0.91, local_k 0.53, adv2 0.35, lam_frac 0.33
- **Askervein ASW35** (порог 0.065): двигают — alpha_mul 1.2, closure 1.1; слабо — adv2 0.62, z0_mul 0.36, local_k 0.32, nu_const 0.30
- **Askervein ASW20** (порог 0.004): двигают — closure 27.3, alpha_mul 22.7, nu_const 12.2, adv2 7.7, local_k 5.4, lam_frac 2.8, z0_mul 2.6, limiter 2.4, cs_h 1.4; слабо — k_fa 0.73, lam 0.52
- **Askervein ASW10** (порог 0.042): двигают — closure 3.9, alpha_mul 3.6, adv2 2.0, nu_const 1.9; слабо — local_k 0.78, lam_frac 0.35
- **Askervein HT** (порог 0.067): двигают — alpha_mul 2.5, closure 2.2, adv2 1.2; слабо — nu_const 0.96, local_k 0.64
- **Askervein ANE10** (порог 0.046): двигают — local_k 3.4, adv2 1.6, alpha_mul 1.4, closure 1.3; слабо — nu_const 0.88, lam_frac 0.47, z0_mul 0.34
- **Askervein ANE20** (порог 0.044): двигают — local_k 4.3, nu_const 1.3, closure 1.3, adv2 1.2; слабо — alpha_mul 0.84, lam_frac 0.60
- **Askervein ANE40** (порог 0.083): двигают — local_k 1.3; слабо — nu_const 0.60, closure 0.53, adv2 0.50, alpha_mul 0.42, lam_frac 0.34
- **Askervein AASW10** (порог 0.0435): двигают — alpha_mul 3.0, closure 3.0, nu_const 1.4, adv2 1.2; слабо — local_k 0.51
- **Askervein AASW20** (порог 0.0365): двигают — closure 3.3, alpha_mul 2.9, nu_const 1.5, adv2 1.1; слабо — local_k 0.63, limiter 0.34, lam_frac 0.33
- **Askervein AASW30** (порог 0.025): двигают — closure 3.6, alpha_mul 3.3, nu_const 1.2; слабо — local_k 0.83, adv2 0.82, z0_mul 0.54, lam_frac 0.49, limiter 0.43
- **Askervein AASW40** (порог 0.023): двигают — alpha_mul 2.6, closure 1.8, adv2 1.1; слабо — z0_mul 0.94, local_k 0.76, nu_const 0.60, lam_frac 0.49, limiter 0.32
- **Askervein AASW50** (порог 0.0375): двигают — alpha_mul 1.6, closure 1.5, z0_mul 1.0; слабо — nu_const 0.79, local_k 0.53, adv2 0.42, lam_frac 0.34
- **Askervein AASW60** (порог 0.0385): двигают — closure 2.0, alpha_mul 1.8, z0_mul 1.2, nu_const 1.2; слабо — local_k 0.59, lam_frac 0.39
- **Askervein AASW70** (порог 0.033): двигают — alpha_mul 2.3, closure 2.2, z0_mul 1.4, nu_const 1.4; слабо — local_k 0.69, lam_frac 0.46
- **Askervein CP** (порог 0.0521805): двигают — alpha_mul 3.1, closure 2.8, adv2 1.2, nu_const 1.2; слабо — local_k 0.51
- **Askervein AANE10** (порог 0.0435): двигают — alpha_mul 3.4, closure 2.3, adv2 2.0; слабо — local_k 0.93, nu_const 0.78, lam_frac 0.38, z0_mul 0.35
- **Askervein AANE20** (порог 0.035): двигают — local_k 3.0, closure 1.2, nu_const 1.0, adv2 1.0, alpha_mul 1.0; слабо — lam_frac 0.53
- **Askervein AANE30** (порог 0.026): двигают — local_k 2.7, adv2 1.6, nu_const 1.4, alpha_mul 1.4, closure 1.3; слабо — lam_frac 0.78
- **Askervein AANE40** (порог 0.0445): двигают — alpha_mul 1.0; слабо — adv2 0.99, local_k 0.91, closure 0.78, nu_const 0.49, lam_frac 0.34
- **Askervein AANE60** (порог 0.044): двигают — adv2 1.8, local_k 1.5, alpha_mul 1.3, closure 1.0; слабо — nu_const 0.91, lam_frac 0.57
- **Askervein BNW10** (порог 0.115): двигают — alpha_mul 1.4, closure 1.2; слабо — adv2 0.68, nu_const 0.53, local_k 0.34
- **Askervein BNW20** (порог 0.0665): двигают — alpha_mul 2.0, closure 1.8; слабо — local_k 0.94, adv2 0.89, nu_const 0.66
- **Askervein BSE10** (порог 0.059): двигают — alpha_mul 2.8, closure 2.8, adv2 1.3, nu_const 1.2; слабо — local_k 0.85
- **Askervein BSE20** (порог 0.058): двигают — closure 3.2, alpha_mul 3.1, adv2 1.6, nu_const 1.4; слабо — local_k 0.77
- **Askervein BSE30** (порог 0.0465): двигают — closure 3.6, alpha_mul 3.5, adv2 1.8, nu_const 1.6; слабо — local_k 0.69
- **Askervein BSE50** (порог 0.0475): двигают — alpha_mul 3.4, closure 2.6, nu_const 1.0, adv2 1.0; слабо — local_k 0.54
- **Askervein BSE60** (порог 0.046): двигают — alpha_mul 3.8, closure 3.3, nu_const 1.4, adv2 1.2; слабо — local_k 0.54, limiter 0.31
- **Askervein BSE70** (порог 0.045): двигают — alpha_mul 3.6, closure 2.9, nu_const 1.1; слабо — adv2 0.84, local_k 0.51
- **Askervein BSE80** (порог 0.0375): двигают — alpha_mul 4.2, closure 3.5, nu_const 1.3, adv2 1.2; слабо — local_k 0.61, lam_frac 0.36, z0_mul 0.32
- **Askervein BSE90** (порог 0.0435): двигают — alpha_mul 3.5, closure 3.0, nu_const 1.1; слабо — adv2 0.97, local_k 0.53, lam_frac 0.33, z0_mul 0.33, limiter 0.32
- **Askervein BSE100** (порог 0.0375): двигают — alpha_mul 3.6, closure 3.2, adv2 1.2, nu_const 1.0; слабо — local_k 0.58, limiter 0.42, z0_mul 0.42, lam_frac 0.37
- **Askervein BSE110** (порог 0.041): двигают — alpha_mul 3.2, closure 2.7; слабо — adv2 0.67, nu_const 0.65, local_k 0.58, z0_mul 0.38, lam_frac 0.37
- **Askervein BSE150** (порог 0.04): двигают — alpha_mul 2.5, closure 1.1; слабо — z0_mul 0.56, local_k 0.53, nu_const 0.46, adv2 0.43, lam_frac 0.34
- **Askervein BSE170** (порог 0.04): двигают — alpha_mul 2.4, closure 1.1; слабо — local_k 0.50, nu_const 0.37, z0_mul 0.32, lam_frac 0.30
- **Askervein HT_prof15** (порог 0.05): двигают — alpha_mul 3.1, closure 2.8, adv2 1.8, nu_const 1.4; слабо — local_k 0.83
- **Askervein HT_prof24** (порог 0.05): двигают — alpha_mul 2.6, closure 2.1, adv2 2.0, nu_const 1.2; слабо — local_k 0.78
- **Askervein HT_prof34** (порог 0.05): двигают — alpha_mul 2.2, adv2 1.9, closure 1.7, nu_const 1.1; слабо — local_k 0.72

## Askervein, χ² по группам

- **χ² наветр.** (порог 4): двигают — closure 8.8, alpha_mul 5.2, z0_mul 4.3, nu_const 3.3, local_k 1.6, adv2 1.2; слабо — lam_frac 0.90
- **χ² вершина** (порог 4): двигают — closure 16.9, alpha_mul 15.4, nu_const 11.0, adv2 7.5, local_k 3.4, z0_mul 1.3, lam_frac 1.0; слабо — limiter 0.54
- **χ² подветр.** (порог 4): двигают — local_k 5.2, alpha_mul 4.9, adv2 4.3, closure 3.0, nu_const 1.7, lam_frac 1.1; слабо — z0_mul 0.70
- **χ² линия B** (порог 4): двигают — alpha_mul 27.7, closure 26.0, nu_const 13.3, adv2 7.8, local_k 4.1, z0_mul 3.6, lam_frac 1.5, limiter 1.1; слабо — k_fa 0.53, cs_h 0.37
- **χ² Askervein, всего** (порог 4): двигают — closure 54.4, alpha_mul 47.1, nu_const 25.2, adv2 20.7, local_k 10.9, z0_mul 6.5, lam_frac 2.9, limiter 1.9; слабо — k_fa 0.82, cs_h 0.65

## Проверки пилота (синтетика)

- **хребет: разгон на 2H** (порог 0.02): двигают — alpha_mul 2.2; слабо — local_k 0.90, nu_const 0.59, closure 0.48
- **хребет: разгон на 2,5H** (порог 0.02): двигают — alpha_mul 1.3; слабо — local_k 0.63, closure 0.57, adv2 0.34
- **хребет: |w|/U на 2H** (порог 0.01): двигают — local_k 2.1, alpha_mul 1.3; слабо — adv2 0.86, lam_frac 0.83, z0_mul 0.44, closure 0.35, nu_const 0.31
- **хребет: |w|/U на 2,5H** (порог 0.01): двигают — local_k 2.0; слабо — alpha_mul 0.95, lam_frac 0.76, adv2 0.74, nu_const 0.48, closure 0.42, z0_mul 0.36
- **хребет: разгон у бровки 10 м** (порог 0.05): двигают — closure 4.8, local_k 3.6, adv2 2.8, nu_const 2.3, z0_mul 2.3, lam_frac 1.5, alpha_mul 1.1; слабо — lam 0.50, limiter 0.34
- **хребет: разгон у бровки 50 м** (порог 0.05): двигают — local_k 3.0, adv2 3.0, closure 1.6, lam_frac 1.2, z0_mul 1.1, nu_const 1.1; слабо — alpha_mul 0.83, lam 0.37
- **за гребнем: S20 в 2L** (порог 0.05): двигают — closure 2.1, local_k 2.0, lam_frac 1.3; слабо — lam 0.67, adv2 0.59, z0_mul 0.47, nu_const 0.39
- **за гребнем: S20 в 4L** (порог 0.05): двигают — local_k 3.4, lam_frac 1.9, closure 1.8, z0_mul 1.4, nu_const 1.3; слабо — adv2 1.00, alpha_mul 0.36, lam 0.31
- **за гребнем: S50 в 2L** (порог 0.05): двигают — local_k 2.4, closure 2.2, lam_frac 1.6; слабо — lam 0.99, adv2 0.67, nu_const 0.56, z0_mul 0.49, alpha_mul 0.34
- **за гребнем: S50 в 4L** (порог 0.05): двигают — lam_frac 2.2, closure 2.2, local_k 1.9, z0_mul 1.2, adv2 1.1, nu_const 1.1; слабо — lam 0.62, alpha_mul 0.37
- **за гребнем: мин. u20 (ротор <0)** (порог 0.05): двигают — local_k 6.1, closure 4.5, lam_frac 2.7, nu_const 2.5, adv2 1.2, lam 1.2; слабо — alpha_mul 0.58, z0_mul 0.34
- **за гребнем: мин. w50/U** (порог 0.02): двигают — local_k 7.7, lam_frac 2.9, nu_const 2.4, closure 1.5, lam 1.1, adv2 1.1; слабо — z0_mul 0.44
- **седловина ×, 20 м** (порог 0.1): двигают — closure 5.9, nu_const 4.3, tau_cool 3.3, alpha_mul 2.7; слабо — z0_mul 0.87, adv2 0.83
- **седловина ×, 50 м** (порог 0.1): двигают — closure 4.7, nu_const 3.7, tau_cool 3.0, alpha_mul 2.8; слабо — z0_mul 0.73, adv2 0.69
- **за седловиной S50** (порог 0.05): двигают — alpha_mul 6.9, tau_cool 6.0, closure 4.9, nu_const 3.5, adv2 2.5, z0_mul 1.0; слабо — —
- **косой ветер w45/w0, 50 м** (порог 0.05): двигают — ничто; слабо — —
- **косой ветер w45/w0, 100 м** (порог 0.05): двигают — ничто; слабо — —
- **w у склона 0°, 50 м, м/с** (порог 0.05): двигают — alpha_mul 5.4, adv2 2.1, closure 1.8; слабо — local_k 0.85, z0_mul 0.65, lam_frac 0.60, nu_const 0.46, cs_h 0.35
- **разгон у гребня 20 м, 0°** (порог 0.03): двигают — closure 3.5, adv2 2.1, alpha_mul 1.8, nu_const 1.8; слабо — local_k 0.89, z0_mul 0.80
- **разгон у гребня 20 м, 45°** (порог 0.03): двигают — closure 3.4, nu_const 1.9, alpha_mul 1.5, adv2 1.1; слабо — z0_mul 0.48, local_k 0.39, lam_frac 0.34

## Нагрев: Онгудай 12:00

- **Онгудай 12:00 штиль: подъём у старта (200 м)** (порог 0.1): двигают — heat_mode 14.8, closure 5.0, local_k 4.6, nu_const 3.5, limiter 2.3, k_fa 2.2, tau_cool 2.1, pr_t 1.7, k_smooth_m 1.6, adv2 1.4, z0_mul 1.3, lam 1.3; слабо — —
- **Онгудай 12:00 штиль: ветер 50 м над стартом** (порог 0.3): двигают — heat_mode 3.6, tau_cool 1.9, closure 1.6, local_k 1.5, pr_t 1.5, adv2 1.3; слабо — z0_mul 0.99, nu_const 0.97, k_fa 0.67, k_smooth_m 0.65, lam_frac 0.42
- **Онгудай 12:00 штиль: w 50 м над стартом** (порог 0.1): двигают — heat_mode 2.7, closure 1.9, tau_cool 1.8, local_k 1.5, adv2 1.4, k_fa 1.0; слабо — z0_mul 0.97, pr_t 0.88, nu_const 0.64, limiter 0.53, k_smooth_m 0.41, lam 0.35
- **Онгудай 12:00 штиль: θ′ 50 м над стартом** (порог 0.2): двигают — tau_cool 4.4, heat_mode 2.0; слабо — closure 0.87, pr_t 0.63, local_k 0.59, k_fa 0.39, nu_const 0.37, adv2 0.33, z0_mul 0.30
- **Онгудай 12:00 штиль: область: w200 p99** (порог 0.1): двигают — heat_mode 7.4, local_k 2.1, closure 1.3; слабо — adv2 0.95, tau_cool 0.88, pr_t 0.83, nu_const 0.82
- **Онгудай 12:00 штиль: область: w200 p1** (порог 0.1): двигают — tau_cool 1.9, closure 1.2; слабо — heat_mode 0.85, local_k 0.85, adv2 0.74, nu_const 0.43
- **Онгудай 12:00 штиль: седловина Каянчи S50** (порог 0.3): двигают — heat_mode 2.1, tau_cool 1.7, local_k 1.6, pr_t 1.4, limiter 1.3, z0_mul 1.2, adv2 1.1, closure 1.0; слабо — k_fa 0.54, k_smooth_m 0.51, nu_const 0.50, lam 0.47, lam_frac 0.34
- **Онгудай 12:00 3 м/с: подъём у старта (200 м)** (порог 0.1): двигают — heat_mode 9.5, closure 3.9, local_k 2.6, adv2 2.1, tau_cool 1.3, alpha_mul 1.2, pr_t 1.1, nu_const 1.0; слабо — limiter 0.60, lam_frac 0.36
- **Онгудай 12:00 3 м/с: ветер 50 м над стартом** (порог 0.3): двигают — closure 2.5, adv2 2.3, heat_mode 2.2, tau_cool 1.9, alpha_mul 1.4, nu_const 1.1; слабо — local_k 0.83, lam_frac 0.33, limiter 0.33, pr_t 0.32
- **Онгудай 12:00 3 м/с: w 50 м над стартом** (порог 0.1): двигают — closure 2.9, adv2 1.9, heat_mode 1.7, nu_const 1.2; слабо — local_k 0.64, alpha_mul 0.48, tau_cool 0.36, pr_t 0.32
- **Онгудай 12:00 3 м/с: θ′ 50 м над стартом** (порог 0.2): двигают — heat_mode 1.8; слабо — closure 0.65, tau_cool 0.57, local_k 0.56, nu_const 0.50, adv2 0.39, pr_t 0.32
- **Онгудай 12:00 3 м/с: область: w200 p99** (порог 0.1): двигают — heat_mode 2.7, adv2 1.3, alpha_mul 1.2, closure 1.0; слабо — local_k 0.92, tau_cool 0.92, nu_const 0.53, pr_t 0.32
- **Онгудай 12:00 3 м/с: область: w200 p1** (порог 0.1): двигают — closure 1.2, heat_mode 1.2, adv2 1.1; слабо — tau_cool 0.76, alpha_mul 0.63, nu_const 0.40, local_k 0.37
- **Онгудай 12:00 3 м/с: седловина Каянчи S50** (порог 0.3): двигают — heat_mode 2.3, adv2 2.0, tau_cool 1.8, local_k 1.3, alpha_mul 1.3, closure 1.3, nu_const 1.2; слабо — pr_t 0.50

## Цена: итерации

- **askervein: ln(итераций)** (порог 0.2): двигают — local_k 4.2, lam_frac 3.0, closure 1.4; слабо — nu_const 0.84, alpha_mul 0.56, z0_mul 0.32
- **ridge: ln(итераций)** (порог 0.2): двигают — local_k 2.2, lam_frac 1.1; слабо — nu_const 0.90, closure 0.88, adv2 0.50, alpha_mul 0.44, lam 0.39
- **saddle: ln(итераций)** (порог 0.2): двигают — tau_cool 1.7, alpha_mul 1.3; слабо — adv2 0.87, closure 0.55
- **oblique: ln(итераций)** (порог 0.2): двигают — nu_const 3.0, closure 3.0, local_k 1.3; слабо — lam_frac 0.40
- **heat0: ln(итераций)** (порог 0.2): двигают — tau_cool 5.9, heat_mode 5.9, adv2 4.2, local_k 3.6, closure 3.2, k_smooth_m 2.3, lam_frac 2.2, nu_const 2.2, pr_t 1.4, lam 1.2; слабо — k_fa 0.82, limiter 0.73, cs_h 0.70, z0_mul 0.65
- **heat3: ln(итераций)** (порог 0.2): двигают — heat_mode 4.8, adv2 3.5, nu_const 3.4, tau_cool 3.2, local_k 2.7, closure 1.7, lam_frac 1.2, alpha_mul 1.0; слабо — cs_h 0.74, pr_t 0.43

## По факторам: сколько наблюдаемых двигает (S ≥ 1 / 0,3–1), без цены

- **lam_frac**: 13 / 32 — за гребнем: S50 в 2L, за гребнем: S20 в 2L, за гребнем: S50 в 4L, за гребнем: мин. w50/U, χ² Askervein, всего, Askervein ASW20, хребет: разгон у бровки 50 м, за гребнем: S20 в 4L, χ² подветр., χ² вершина, хребет: разгон у бровки 10 м, за гребнем: мин. u20 (ротор <0) …
- **lam**: 3 / 9 — Онгудай 12:00 штиль: подъём у старта (200 м), за гребнем: мин. w50/U, за гребнем: мин. u20 (ротор <0)
- **cs_h**: 1 / 3 — Askervein ASW20
- **pr_t**: 4 / 8 — Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 штиль: ветер 50 м над стартом, Онгудай 12:00 3 м/с: подъём у старта (200 м), Онгудай 12:00 штиль: седловина Каянчи S50
- **k_fa**: 2 / 6 — Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 штиль: w 50 м над стартом
- **z0_mul**: 16 / 27 — Онгудай 12:00 штиль: подъём у старта (200 м), Askervein ASW85, за гребнем: S50 в 4L, Askervein AASW50, χ² Askervein, всего, Askervein AASW70, Askervein ASW20, хребет: разгон у бровки 50 м, за гребнем: S20 в 4L, χ² вершина, хребет: разгон у бровки 10 м, χ² наветр. …
- **alpha_mul**: 56 / 10 — Askervein BSE80, Askervein BSE60, Онгудай 12:00 3 м/с: ветер 50 м над стартом, Askervein BNW10, Askervein ASW85, Askervein CP, Askervein BSE100, Askervein AANE30, Askervein HT, Askervein AANE40, Askervein BSE110, Askervein AASW20 …
- **tau_cool**: 12 / 5 — Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 3 м/с: ветер 50 м над стартом, Онгудай 12:00 штиль: область: w200 p1, Онгудай 12:00 штиль: ветер 50 м над стартом, седловина ×, 20 м, Онгудай 12:00 штиль: θ′ 50 м над стартом, седловина ×, 50 м, Онгудай 12:00 3 м/с: седловина Каянчи S50, Онгудай 12:00 штиль: w 50 м над стартом, Онгудай 12:00 3 м/с: подъём у старта (200 м), за седловиной S50, Онгудай 12:00 штиль: седловина Каянчи S50
- **zi_min**: 0 / 0
- **k_smooth_m**: 1 / 3 — Онгудай 12:00 штиль: подъём у старта (200 м)
- **adv2**: 47 / 24 — Askervein BSE80, Askervein BSE60, Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 3 м/с: ветер 50 м над стартом, Askervein CP, Askervein BSE100, Askervein AANE30, Askervein HT, Онгудай 12:00 штиль: ветер 50 м над стартом, за гребнем: S50 в 4L, Онгудай 12:00 3 м/с: w 50 м над стартом, Онгудай 12:00 3 м/с: область: w200 p1 …
- **closure**: 68 / 8 — Askervein BSE80, за гребнем: S50 в 2L, Askervein BSE60, Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 3 м/с: ветер 50 м над стартом, Askervein BNW10, Askervein ASW85, Askervein CP, Онгудай 12:00 штиль: область: w200 p1, Askervein BSE100, Askervein AANE30, Askervein HT …
- **nu_const**: 45 / 30 — Askervein BSE80, Askervein BSE60, Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 3 м/с: ветер 50 м над стартом, Askervein ASW85, Askervein CP, Askervein BSE100, Askervein AANE30, за гребнем: S50 в 4L, Онгудай 12:00 3 м/с: w 50 м над стартом, Askervein AASW20, седловина ×, 20 м …
- **local_k**: 29 / 44 — за гребнем: S50 в 2L, Онгудай 12:00 штиль: подъём у старта (200 м), хребет: |w|/U на 2,5H, Askervein AANE30, за гребнем: S20 в 2L, Онгудай 12:00 штиль: ветер 50 м над стартом, за гребнем: S50 в 4L, Askervein AANE60, Askervein ANE40, Онгудай 12:00 штиль: область: w200 p99, за гребнем: мин. w50/U, χ² Askervein, всего …
- **heat_mode**: 13 / 1 — Онгудай 12:00 штиль: подъём у старта (200 м), Онгудай 12:00 3 м/с: ветер 50 м над стартом, Онгудай 12:00 штиль: ветер 50 м над стартом, Онгудай 12:00 3 м/с: w 50 м над стартом, Онгудай 12:00 3 м/с: область: w200 p1, Онгудай 12:00 штиль: область: w200 p99, Онгудай 12:00 3 м/с: θ′ 50 м над стартом, Онгудай 12:00 штиль: θ′ 50 м над стартом, Онгудай 12:00 3 м/с: область: w200 p99, Онгудай 12:00 3 м/с: седловина Каянчи S50, Онгудай 12:00 штиль: w 50 м над стартом, Онгудай 12:00 3 м/с: подъём у старта (200 м) …
- **limiter**: 5 / 11 — Онгудай 12:00 штиль: подъём у старта (200 м), χ² Askervein, всего, Askervein ASW20, Онгудай 12:00 штиль: седловина Каянчи S50, χ² линия B

## Масштаб 3: ТКЭ Askervein (поля 12,5 / 25 / 50 м)

- **12p5: χ² ТКЭ наветр.**: двигают — ничто; слабо — —
- **12p5: χ² ТКЭ вершина**: двигают — field_sigma_w_per_ustar 315.9; слабо — —
- **12p5: χ² ТКЭ подветр.**: двигают — field_sigma_w_per_ustar 120.4, field_sigma_u_per_du 3.3, field_deficit_attached 3.1, width 1.9, field_descent_slope 1.9, field_sigma_w_per_du 1.7; слабо — —
- **12p5: χ² ТКЭ всего**: двигают — field_sigma_w_per_ustar 436.4, field_sigma_u_per_du 3.3, field_deficit_attached 3.1, width 1.9, field_descent_slope 1.9, field_sigma_w_per_du 1.7; слабо — —
- **12p5: σ_w за гребнем ANE10_10, м/с**: двигают — field_sigma_w_per_ustar 6.1; слабо — —
- **12p5: признак отрыва ANE10_10**: двигают — field_deficit_attached 2.8, width 1.0; слабо — —
- **12p5: σ_w за гребнем ANE20_10, м/с**: двигают — field_sigma_w_per_ustar 4.9, field_deficit_attached 1.4; слабо — field_sigma_w_per_du 0.96, width 0.78
- **12p5: признак отрыва ANE20_10**: двигают — field_deficit_attached 6.6, width 2.0; слабо — —
- **12p5: σ_w за гребнем ANE40_10, м/с**: двигают — field_deficit_attached 4.8, field_sigma_w_per_du 3.1, field_sigma_w_per_ustar 1.8, width 1.8; слабо — field_descent_slope 0.96
- **12p5: признак отрыва ANE40_10**: двигают — field_deficit_attached 5.5, width 2.1; слабо — field_descent_slope 0.74
- **25: χ² ТКЭ наветр.**: двигают — field_sigma_w_per_ustar 102.6; слабо — —
- **25: χ² ТКЭ вершина**: двигают — ничто; слабо — —
- **25: χ² ТКЭ подветр.**: двигают — field_sigma_u_per_du 6.1, field_sigma_w_per_ustar 5.7, field_deficit_attached 3.8, field_sigma_w_per_du 2.9, field_descent_slope 2.1, width 2.1; слабо — —
- **25: χ² ТКЭ всего**: двигают — field_sigma_w_per_ustar 107.2, field_sigma_u_per_du 6.1, field_deficit_attached 3.8, field_sigma_w_per_du 2.9, field_descent_slope 2.1, width 2.1; слабо — —
- **25: σ_w за гребнем ANE10_10, м/с**: двигают — field_sigma_w_per_ustar 3.9; слабо — field_deficit_attached 0.98, width 0.63, field_sigma_w_per_du 0.60
- **25: признак отрыва ANE10_10**: двигают — field_deficit_attached 5.8, width 1.0; слабо — field_descent_slope 0.36
- **25: σ_w за гребнем ANE20_10, м/с**: двигают — field_deficit_attached 5.5, field_sigma_w_per_du 4.3, width 2.3, field_sigma_w_per_ustar 1.1; слабо — —
- **25: признак отрыва ANE20_10**: двигают — field_deficit_attached 4.6, width 2.3; слабо — —
- **25: σ_w за гребнем ANE40_10, м/с**: двигают — field_sigma_w_per_du 5.0, field_deficit_attached 3.9, width 2.2, field_descent_slope 1.7; слабо — field_sigma_w_per_ustar 0.82
- **25: признак отрыва ANE40_10**: двигают — field_deficit_attached 3.3, width 2.3, field_descent_slope 1.0; слабо — —
- **50a: χ² ТКЭ наветр.**: двигают — ничто; слабо — field_sigma_w_per_ustar 0.98
- **50a: χ² ТКЭ вершина**: двигают — ничто; слабо — —
- **50a: χ² ТКЭ подветр.**: двигают — field_sigma_w_per_ustar 35.3, field_sigma_u_per_du 18.4, field_deficit_attached 14.4, field_descent_slope 12.9, width 12.0, field_sigma_w_per_du 9.4; слабо — —
- **50a: χ² ТКЭ всего**: двигают — field_sigma_w_per_ustar 36.3, field_sigma_u_per_du 18.4, field_deficit_attached 14.4, field_descent_slope 12.9, width 12.0, field_sigma_w_per_du 9.4; слабо — —
- **50a: σ_w за гребнем ANE10_10, м/с**: двигают — field_sigma_w_per_ustar 4.6, field_deficit_attached 1.5, field_sigma_w_per_du 1.1; слабо — width 0.98, field_descent_slope 0.41
- **50a: признак отрыва ANE10_10**: двигают — field_deficit_attached 5.9, width 1.9, field_descent_slope 1.1; слабо — —
- **50a: σ_w за гребнем ANE20_10, м/с**: двигают — field_deficit_attached 5.8, field_sigma_w_per_du 5.5, width 3.4, field_descent_slope 1.8; слабо — field_sigma_w_per_ustar 0.33
- **50a: признак отрыва ANE20_10**: двигают — field_deficit_attached 3.6, width 2.4; слабо — field_descent_slope 0.91
- **50a: σ_w за гребнем ANE40_10, м/с**: двигают — field_sigma_w_per_du 5.9, field_deficit_attached 5.7, width 4.4, field_descent_slope 3.9; слабо — —
- **50a: признак отрыва ANE40_10**: двигают — field_deficit_attached 2.9, width 2.2, field_descent_slope 2.0; слабо — —
