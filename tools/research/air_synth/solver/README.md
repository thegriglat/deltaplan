---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-05"
summary: "SY-8: счёт решателя P2 по рельефам × условиям p2c12 (S5 v2) — скрипты, команды, пробный прогон и оценка"
related: ["docs/contracts/air-synth.md", "docs/plan/air-synth.md"]
---
# SY-8: счёт решателя P2 (S5 v2)

Файлы: `s5_io.py` (формат S5 v2: части, вид VDS, план, чтение), `solve_corpus.py` (счёт, продолжение, `progress.json`),
`make_p2c12.py` (набор условий p2c12 — 12 условий как `terrain` P2, без отбора), `run_trial.sh`, `run_all.sh`,
`tests/test_contract_s5.py`, `tests/test_solve_corpus.py` (3 настоящих решения на мини-корпусе, под замком GPU).
Решатель и обрамление — как H7 (`model_place.py`, `airlite_gen.solve_case`: область, решения h и m, max_outer 1000, цель «среднее поздних»).
Контекст места решателя подменяется условиями случая из таблицы S2 (lat/lon, пояс, месяц/день), поправки рельефа — `ground_context`.
Разошедшееся решение: нечисла -> 0, статус 2 (иначе NaN — ошибка записи).

## Воспроизведение
```bash
# окружение: ../../air_nn_pilot/setup_env.sh (+ h5py, pytest)
PY=../../air_nn_pilot/.venv/bin/python
OMP_NUM_THREADS=1 $PY make_p2c12.py --relief-corpus ~/air_synth_data/real/p6v3 --plan real --out ~/air_synth_data/conditions/p6v3_p2c12
OMP_NUM_THREADS=1 $PY make_p2c12.py --relief-corpus ~/air_synth_data/corpus/fs1_10k --plan model --out ~/air_synth_data/conditions/fs1_360_p2c12
$PY -m pytest -q tests
tools/dp job --lock gpu start sy8-trial 3000 tools/research/air_synth/solver/run_trial.sh     # пробный: 2 × 12 случаев
tools/dp job --lock gpu start sy8-solve 200000 tools/research/air_synth/solver/run_all.sh     # весь счёт; продолжение — той же командой
```
Результат: `~/air_synth_data/solve/{p6v3,fs1_360}__p2c12__<версия решателя>/`; сводка — `out_solve/progress.json`.

## Пробный прогон (2 × 12 случаев равномерно по плану, 3 воркера, `out_solve/trial_summary.json`)
Версия решателя s0-939a467. Wall на случай ≈ 12 с (по 3 воркерам), у воркера 31–34 с; несошедшихся (max 1000) 25–33 %, разошедшихся 0;
объём 1,2 ГБ на 1000 случаев. Оценка 8640 случаев: ≈ 29 ч, ≈ 10,5 ГБ (< 3 суток).
