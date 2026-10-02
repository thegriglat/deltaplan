---
type: "research"
status: "closed"
module: ""
updated: "2026-10-03"
summary: "Б1 — совместная калибровка Askervein + Perdigão (волна Б, контракт C10 v2) — Этап 1 (постановка и сопоставимость) и этап 2 (пачка, совместная подгонка, проверка у лучшей точки, регрессия А2) сделаны; записка — docs/archive/plan/air-model-b1.md."
related: []
conclusion: ""
data: "tools/research/cases/b1/"
applied_in: ""
---
# Б1 — совместная калибровка Askervein + Perdigão (волна Б, контракт C10 v2)

Этап 1 (постановка и сопоставимость) и этап 2 (пачка, совместная подгонка, проверка у лучшей точки, регрессия А2) сделаны;
записка — `docs/archive/plan/air-model-b1.md`.
Модули случаев — `../askervein.py` (NAME `ask`, подслучай `tu03b`), `../perdigao.py` (NAME `pd`, `ne`, `sw`); общие
правила постановки (предложение для `scheme.py` / C10 v3) — `../rules.py`. Решатель (`air3d/air.py`, `solver.py`) не менялся.

| Файл | Что |
|---|---|
| `inflow.py` | данные притока для правила насыщения профиля: RS Askervein (чашки, змей до 267 м), RHI-лидары Perdigão над гребнем → `out/inflow.json`, `out/fig_inflow.png` |
| `ctl.py` | пробные (`probe` → `out/probe_runs.jsonl`: правило U10) и контрольные прогоны у номинала (`ctl` → `out/ctl_runs.jsonl`): 2-й порядок dx, 1-й порядок (схема игры), dx·2/3, dx/2 (не помещается в 12 ГБ — строки `error`), область ×1,5 (вместе/`side`/`top`), устойчивость (Perdigão), λ 15/150 м; поля номинала и 1-го порядка — `out/fields_*.npz` |
| `analyze1.py` | итог контроля: `out/grid.json` (grid_corr, sig_grid, Δ_обл, Δ_уст по наблюдаемым — читают модули случаев), `out/ctl_table.md`, `out/ctl_summary.json`, `out/fig_ctl_obs.png`, `out/fig_ctl_sections.png` |
| `batch.py` | план пачки калибровки (`plan` — оценка времени по пробным) и прогоны (`run` → `out/runs_ask.jsonl` 315, `out/runs_pd.jsonl` 450) |
| `fit.py` | совместная подгонка → `out/fit.json`, `out/fit_table.md`, `out/fig_fit_{profile_lam,map_lf_lam,residuals,profiles}.png` |
| `best.py` | проверка у лучшей точки (`run`: лучшая точка, local_k выкл, 1-й порядок, dx·2/3 → `out/best_runs.jsonl`; `table` → `out/best_table.md`, `out/best.json`, `out/fig_best_sections.png`); поля `fields_*_best/adv1.npz` (adv1 — уже лучшей точки, поля 1-го порядка у номинала перезаписаны) |
| `a2_table.py` | регрессия матрицы А2 (`tools/research/a2pre/run.py b1` → `a2pre/out/matrix_b1.jsonl`) против базы А2 → `out/a2_regression.md`, `.json` |

## Воспроизведение
Из `tools/research/cases/b1` (venv калибровки с CuPy; замок GPU `/tmp/heat_ca_gpu.lock` — на прогон):
```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
(cd ../perdigao && $PY terrain.py --size 9000)        # рельеф 9 км для контроля области (кеш тайлов ~/.cache/deltaplan_terrain)
$PY inflow.py
/home/greg/deltaplan/tools/job.sh start b1-probe 1800 $PY ctl.py probe   # 3 прогона, ~1 мин
/home/greg/deltaplan/tools/job.sh start b1-ctl 5400 $PY ctl.py ctl       # 26 прогонов, ~21 мин GPU (RTX 4070 SUPER)
$PY analyze1.py; $PY analyze1.py      # второй проход: σ наблюдаемых читают out/grid.json (Δ_уст)
cd .. && grep '"case": "ask"' b1/out/ctl_runs.jsonl > /tmp/b1_ask.jsonl && grep '"case": "pd"' b1/out/ctl_runs.jsonl > /tmp/b1_pd.jsonl
$PY check_c10.py askervein /tmp/b1_ask.jsonl; $PY check_c10.py perdigao /tmp/b1_pd.jsonl   # 9 и 20 строк, 0 нарушений
$PY b1/batch.py plan                   # этап 2: оценка пачки
cd b1
/home/greg/deltaplan/tools/job.sh start b1-grid 21600 $PY batch.py run ask pd   # 765 прогонов, 3,9 ч GPU
$PY fit.py                                                                     # ~10 мин CPU
/home/greg/deltaplan/tools/job.sh start b1-best 3600 $PY best.py run; $PY best.py table   # 12 прогонов, 9 мин
(cd ../../a2pre && /home/greg/deltaplan/tools/job.sh start b1-a2 7200 $PY run.py b1)       # 48 цепочек, 18 мин
$PY a2_table.py
```
Замеры этапа 1: 29 прогонов ctl + 3 probe, решатель 6–112 с на прогон; dx/2 (32–37 млн клеток) — OutOfMemoryError на 12 ГБ.

## Данные и лицензии
Askervein — Zenodo 4095052 (CC BY 4.0); Perdigão — ISFS NCAR/EOL (doi:10.26023/ZDMJ-D1TY-FG14), лидары DTU
(Menke et al. 2019, ACP 19, 2713, CC BY 4.0), рельеф Copernicus GLO-30, лес ESA WorldCover 2021 (CC BY 4.0) —
подробно `../perdigao/README.md`, `tools/research/data/*/README.md`, `ASSETS.md`. `terrain10_9km.npz` (1,9 МБ) — производная
от Copernicus/WorldCover, как `terrain10.npz`.
