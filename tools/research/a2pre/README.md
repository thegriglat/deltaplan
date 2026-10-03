---
type: "research"
status: "closed"
module: ""
updated: "2026-10-03"
summary: "Разведка перед А2: сходимость и цена решателя воздуха на новых параметрах — Записка с выводом — docs/archive/plan/air-model-a2pre.md."
related: []
conclusion: ""
data: "tools/research/a2pre/"
applied_in: ""
---
# Разведка перед А2: сходимость и цена решателя воздуха на новых параметрах

Записка с выводом — `docs/archive/plan/air-model-a2pre.md`. Решатель (`tools/research/air3d/air.py`, после А1:
Pr_t = 0,85, θ′_d, h при const) не правился: меняются только `A.Params`.

| Файл | Что |
|---|---|
| `run.py` | драйвер одной пачки: `matrix` (наборы параметров × цепочка 400 → 100 → 50 м и область 200 м × условия × heat_mode), `morris` (несошедшиеся точки Морриса heat0, подвыборка, old и new), `trial` (оценка времени) |
| `analyze.py` | одна обработка: `out/tables.md`, `out/summary.json`, `out/fig_*.png` |
| `out/matrix.jsonl` | по строке на сценарий: по каждому решению статус, итерации, время, мс/итер, история невязок (каждые 10 итераций), плато, баланс тепла, ключевые числа, где невязка |
| `out/morris_rerun.jsonl` | то же для точек Морриса (+ исходные статусы из `~/deltaplan-wf-morris/tools/research/morris/out/runs/heat0.jsonl`) |
| `out/matrix_maps.npz`, `out/morris_maps.npz` | карты max по z невязки θ′ и w, профиль невязки θ′ по высоте в конце каждого решения |
| `out/trial.jsonl` | 2 пробные точки Морриса (оценка времени: тяжёлая цепочка 94–111 с) |

**Моррис отложен** (решение пользователя, 30.09.2026): стадия `morris` остановлена после 2 из 64 цепочек;
`out/morris_rerun.jsonl` (2 строки) и `out/morris_maps.npz` — прерванные данные, не обрабатываются. Повторный
анализ несошедшихся точек Морриса — в волне Б после совместной калибровки Askervein + Perdigão, если её итог
будет неудовлетворительным (код `run.py morris`, `analyze.py: morris()` оставлен).

Наборы (прочее — `Params()` = `AirCase.p` игры: 1-й порядок, hb, local_k, k_relax 0,5, heat_sweeps 4):
`old` — λ/h 0,25, α 0,14, z0 0,1 м, max_profile 1,8 (игра сейчас); `new` — λ/h 0,031, α 0,235, z0 0,09 м,
max_profile 2,0 (перекалибровка Askervein, `tools/research/recal`); `lam` — только λ/h 0,031; `new_z003` — `new` с
z0 0,03 м.

Воспроизведение (из этого каталога; venv с CuPy — `tools/research/morris/README.md`):
```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
$PY run.py trial                                                   # ~3,5 мин GPU
/home/greg/deltaplan/tools/dp job start a2pre 3600 $PY run.py matrix   # 36 сценариев, 18 мин GPU; замок GPU на сценарий
/home/greg/deltaplan/tools/dp job wait a2pre 3600
$PY analyze.py        # только матрица → out/tables.md, out/summary.json, out/fig_*.png
```
Прерванная пачка продолжается повторным запуском (готовые ключи пропускаются).

Данные: рельеф Онгудая — `data/terrain/` (ASSETS.md); погода часа — `configs/` игры через `air3d/weather.py`.
Исходные прогоны Морриса — вне этой ветки, `~/deltaplan-wf-morris/tools/research/morris/out/runs/` (не трогать).

## А2 — сходимость в штиль (01.10.2026)

Записка — `docs/archive/plan/air-model-a2.md`. Итог: `k_relax` 0,5 → 0,1 (в `air.py → Params` и `AirCase.p`), плюс пропуск
прохода θ′_d у решения без нагрева (air.py и GPU). Решатель в остальном не менялся.

| Файл | Что |
|---|---|
| `run.py a2 [варианты]` | матрица А2: old и new × варианты `A2_VARIANTS` (kr25, hs8, kr25hs8, kr10, kr15, top3000 — потолок окна 3000 м над рельефом, только диагностика) → `out/matrix_a2.jsonl`; карты невязки `out/matrix_a2_maps.npz` (17 МБ) — не в git, локально в `~/deltaplan-wf/tools/research/a2pre/out/` (копия модуля) |
| `run.py scan` | отбор ещё дешёвых численных параметров (`SCAN`: k_relax 0,1, dtau_th 600/300, dtau_per_m 0,2/0,15, mom_sweeps 4, vcycles 2) на двух трудных cbl-случаях → `out/scan_a2.jsonl` |
| `run.py a2trial` | одна цепочка (оценка времени) |
| `analyze_a2.py` | одна обработка: `out/a2_tables.md`, `out/a2_summary.json`, `out/fig_a2_hist.png`, `out/fig_a2_cost.png` |
| `out/bench/` | логи GPU-тестов `test_air_` и bench `test_air_picard_bench` (400/200 м, QUICK и полный): `before_*` — игра до А2, `skip_*` — только пропуск θ′_d, `after_*` — итог А2 |
| `out/runs_check25_a2.jsonl`, `out/askervein_chi2_a2.json` | Askervein check25 после А2 (χ² 68,06/44, как до) |

Порядок: kr25, hs8, kr25hs8, top3000 — первая пачка (варианты из задания); по `scan` выяснилось, что сводит оба
трудных случая только k_relax 0,1, — вторая пачка kr10, kr15. Файлы kr10/kr15 посчитаны уже с пропуском θ′_d в
air.py (итерации те же, время решений без нагрева ниже).

```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
/home/greg/deltaplan/tools/dp job start a2-matrix 7200 $PY run.py a2      # 132 сценария; ~1,5 ч GPU при общем GPU
$PY run.py scan                                                            # 14 сценариев, ~35 мин
$PY analyze_a2.py
# игра: GPU-тесты и bench (под замком GPU)
flock /tmp/heat_ca_gpu.lock ../../gpu_tests.sh --filter=test_air_
AIR_PICARD_BENCH=1 AIR_PICARD_BENCH_DX=200 AIR_PICARD_BENCH_QUICK=1 flock /tmp/heat_ca_gpu.lock ../../gpu_tests.sh --filter=test_air_picard_bench
```
Пачка продолжается с места (готовые ключи пропускаются). Наборы `PSETS` задают k_relax 0,5 явно (значение до А2),
варианты его переопределяют, поэтому матрицы воспроизводятся и после смены значения по умолчанию в `Params`.
