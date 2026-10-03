---
type: "research"
status: "active"
module: "ann2"
updated: "2026-10-04"
summary: "Код и команды AN-1 (предел данных): ошибка P2 против шума цели решателя."
related: ["docs/research/ann2_data_limit.md"]
---
# ann2 — исследования модуля (AN-1: предел данных)

Код читает и импортирует `tools/research/air_nn_pilot/` (не правит). Данные пилота — `/home/greg/air_nn_data/pilot`
(лицензии — как у пилота, см. его README; новых внешних данных нет). Снимки решателя (361 МБ, 56 случаев) —
`/home/greg/air_nn_data/ann2/an1/snaps/<id>.npz` (ключи: `it`, `uv60` (n,2,96,96) float32, `hist` невязки, `conv_it`, `final60`),
в репозиторий не кладутся; возмущённые решения — `out/perturb/` (35 МБ, в .gitignore).

Python — venv пилота (`/home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python`; torch, CuPy), из этого каталога:

```
# 1. ошибка сети P2 по клеткам, все наборы (GPU-замок берёт сам скрипт), ~1 мин
dp job start an1cells 1800 $V eval_cells.py          # → out/cells_cases.json
python3 analyze_cases.py                              # → out/tables.json, out/tables.md
# 2. выборка случаев и пересчёт решателем со всеми снимками (17 с на случай, под замком GPU)
python3 pick_sample.py                                # → out/sample.json (12), out/sample48.json (56)
dp job --lock gpu start an1snap48 3000 $V snaps.py --list out/sample48.json   # продолжает после прерывания
# 3. ошибка сети против разброса и дрейфа цели по клеткам
$V snap_analysis.py && python3 snap_tables.py         # → out/snap_cases.json, out/snap_tables.{json,md}
# 4. чувствительность цели к сдвигу условий (U10 × 1,02; +1°)
dp job --lock gpu start an1pert 2400 $V perturb.py --list out/sample.json
$V perturb_tables.py                                  # → out/perturb_cases.json, out/perturb_tables.md
```
Вывод и таблицы — `docs/research/ann2_data_limit.md`.
