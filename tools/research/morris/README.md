# Моррис: чувствительность модели воздуха

Итог и выводы — `docs/air_model_sensitivity.md`.

| Файл | Что |
|---|---|
| `model.py` | 16 факторов (диапазоны), 6 случаев (Askervein, хребет, седловина, косой ветер, Онгудай 12:00 штиль / 3 м/с), наблюдаемые; (подкласс `MAir` — Pr_t, h при const — удалён в А1: теперь в air.py) |
| `plan.py` | план Морриса (SALib, оптимизированные траектории, p = 4) → `out/plan.json` |
| `run_points.py` | прогоны по траекториям, по строке на (случай, точку) в `out/runs/<случай>.jsonl`, продолжение с места, замок GPU на точку |
| `s3_plan.py`, `turb_morris.gd`, `run_s3.sh` | масштаб 3: план по параметрам `atmosphere.json`, Godot headless на полях Askervein → `out/s3_runs.json` |
| `run_all.sh` | план + обе пачки через `tools/job.sh` |
| `analyze.py` | одна пакетная обработка: `out/morris.json`, `out/morris_table.csv`, `out/lists.md`, `out/fig_*.png` |

Воспроизведение (из корня копии; venv `tools/research/tune/.venv`: `uv pip install "cupy-cuda12x[ctk]==14.2.0" numpy matplotlib scipy iminuit zstandard brotli SALib`):
```bash
sh tools/research/morris/run_all.sh 12
/home/greg/deltaplan/tools/job.sh wait morris 28800; /home/greg/deltaplan/tools/job.sh wait morris-s3 7200
tools/research/tune/.venv/bin/python tools/research/morris/analyze.py
```
Замеры этой серии: 1230 прогонов (205 точек × 6 случаев), 5,3 ч GPU (RTX 4070 SUPER), 7,4 ч по часам.
Поля масштаба 3 — `fields/` (≈ 180 МБ, вне git), пересоздаются `run_s3.sh`.

Данные и лицензии: Askervein — Zenodo 4095052 (CC BY 4.0; уже в `tools/research/data/askervein`, ASSETS.md);
рельеф Онгудая — как в `data/terrain/` (ASSETS.md). SALib — MIT (только инструмент, в игру не входит).
