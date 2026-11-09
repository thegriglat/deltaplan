# LT-5: модель слоя смешения за гребнем (прототип)

- `spec.json` — константы и формулы (`ltm-spec` v1); каждая константа: `ltl` (id в `../lit/lit_numbers.csv`), `derived` или `assumption`.
- `proto.py` — прототип (Python 3 + numpy 2.x; venv не нужен). `--selftest` — без внешних данных; `--sections DIR` — 18 разрезов LTS v1.
- `model_obs.py` (LT-6) — сверка с мачтами LTO без поля: `proto.py --obs` -> `out/obs_compare.csv`, `out/obs_compare.json`; читает `../obs/lee_obs.csv`, `../../cases/perdigao/out/terrain10_9km.npz`, `masts.csv`, `../../data/perdigao/cases/*windowmean.csv`, `../../data/askervein/*` (все в git). Вывод — `docs/research/lee_turb/model_obs.md`.
- `make_tables.py` — `out/sections*.json` -> `out/tables.md`.
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
python3 -W ignore -I proto.py --sections ~/data/lee_turb/lts_baseline --out out --xr-over-h 2.8
python3 -W ignore -I proto.py --sections ~/data/lee_turb/lts_baseline --out out --xr-over-h 5
python3 -W ignore -I proto.py --sections ~/data/lee_turb/lts_baseline --out out --power 2
python3 -W ignore -I proto.py --sections ~/data/lee_turb/lts_baseline --out out --u2-field
python3 -W ignore -I make_tables.py
```
Разрезы `*.lts.csv` (~60 МБ, вне git) — результат `dp-stand lee` ветки lee-turb/LT-2 (`tools/research/lee_turb/stand/run_baseline.sh`).
Прогон ~25 с на набор. Данные — собственные расчёты проекта; лицензий внешних данных нет (числа LTL — см. `../lit/README.md`).
