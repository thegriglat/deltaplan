---
type: "research"
status: "closed"
module: "lee-turb"
area: "air"
updated: "2026-11-10"
summary: "LT-5…LT-7: прототип модели слоя смешения за гребнем (spec.json, proto.py)"
related: ["docs/research/lee_turb.md"]
conclusion: ""
data: ""
applied_in: ""
---

# LT-5..LT-7: модель слоя смешения за гребнем (прототип)

- `spec.json` — константы и формулы (`ltm-spec` v1); каждая константа: `ltl` (id в `../lit/lit_numbers.csv`), `derived` или `assumption`.
- `proto.py` — прототип (Python 3 + numpy 2.x; venv не нужен). `--selftest` — без внешних данных; `--sections DIR` — 18 разрезов LTS v1.
- `model_obs.py` (LT-6) — сверка с мачтами LTO без поля: `proto.py --obs` -> `out/obs_compare.csv`, `out/obs_compare.json`; читает `../obs/lee_obs.csv`, `../../cases/perdigao/out/terrain10_9km.npz`, `masts.csv`, `../../data/perdigao/cases/*windowmean.csv`, `../../data/askervein/*` (все в git). Вывод — `docs/research/lee_turb/model_obs.md`.
- LT-7 (решение Q1): линия слоя `y_c = q·z½ + (1−q)·запас` (`field_center`, `yc_fallback` в `proto.py`), B только под линией (`below_weight`); `run_section` считает варианты `old, lt5, A_fb, A_new, B_fb, B_new`; `model_obs.py` — `old, A2, N, N5`.
- `make_tables.py` — `out/sections.json`, `out/obs_compare.json` -> `out/tables.md` (T1–T5, M0–M3).
- `ridges_ref.json` — шесть гребней LT-2 (имя, клетка поля, H, направление) — только для имён/размера клетки.
- `out/` — результаты (json с числами, tables.md).
- Вывод: `summary.md`; формулы и таблицы: `docs/research/lee_turb/model.md`.

## Воспроизведение
```
cd tools/research/lee_turb/model
python3 -I proto.py --selftest
python3 -I model_obs.py --selftest
python3 -I proto.py --obs                 # LT-6: out/obs_compare.csv
python3 -W ignore -I proto.py --sections ~/data/lee_turb/lts_baseline --out out
python3 -W ignore -I make_tables.py
```
Разрезы `*.lts.csv` (~60 МБ, вне git) — результат `dp-stand lee` ветки lee-turb/LT-2 (`tools/research/lee_turb/stand/run_baseline.sh`).
Прогон ~40 с. Чувствительности LT-5 (`--xr-over-h`, `--power`, `--u2-field`) в коде остались, их таблицы LT-5 удалены как устаревшие. Данные — собственные расчёты проекта; лицензий внешних данных нет (числа LTL — см. `../lit/README.md`).
