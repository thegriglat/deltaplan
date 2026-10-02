# Перекалибровка Askervein по (λ/h, α, z0) с профилем мачты RS

Итог — `docs/research/air-model-tune.md`, раздел «Перекалибровка (λ/h, α, z0) с профилем RS»; числа — `out/fit.json`.

| Файл | Что |
|---|---|
| `config.json` | сетка (λ/h 0,02–0,6 лог × 9, α 0,12–0,27 × 11, z0 0,01–0,09 лог × 5), высоты RS, наблюдаемые профиля и σ, априорное z0 (только вариант `all_z0prior`), точки проверки сетки |
| `run_grid.py` | прогоны air.py (обёртка `morris/model.py`, прочие факторы — номинал: hb, adv2, local_k, Pr_t = 1) → `out/runs_<сетка>.jsonl`, продолжение с места, замок GPU на прогон |
| `fit.py` | χ² = 39 разгонов AM-09 (σ и поправки сетки/области из `tune/out/fit_s1.json`) + 8 точек профиля RS; кубическая интерполяция по сетке, iminuit (MIGRAD, MINOS), профили χ², карты Δχ²(λ/h, α) → `out/fit.json`, `out/chi2_maps.npz`, `out/fig_*.png` |

Профиль RS: S(z)/S(24 м, чашки AES). Чашки 15 (σ 3 %), 34, 49 м (σ 2 %); змей BRE 48, 70, 116, 178, 267 м (σ 4 %).
Чашки 3–8 м ниже центра первой клетки 25-м сетки (модель там постоянна) — не берутся; змей на 30 м (11,9 м/с при чашках ≈ 10,6) с чашками не согласуется — не берётся.

Воспроизведение (из `tools/research/recal`; venv как в `morris/README.md`):
```bash
PY=../tune/.venv/bin/python
/home/greg/deltaplan/tools/job.sh start recal-grid 9000 $PY run_grid.py grid   # 495 прогонов, 68 мин GPU
$PY run_grid.py test; $PY run_grid.py check25; $PY run_grid.py check12      # AM-09 и проверка сетки 12,5 м
$PY fit.py > out/fit.log
```
Замеры: 495 прогонов, все ok; 4075 с решателя на RTX 4070 SUPER (1,5 ч по часам с ожиданием замка GPU).

Данные: Askervein — Zenodo 4095052 (CC BY 4.0), `tools/research/data/askervein` (ASSETS.md).
