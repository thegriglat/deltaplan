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


# SY-10: места дельтаплана — условия hgw24 (S2 v4) и счёт (S5 v4)

Файлы: `make_hgw24.py` (набор условий), `s5_io.py` (+ `plan_hg`, группа `game`, столбец `rank`, `weather_cfg/weather_override/cfg_from_row` — подмена погоды),
`solve_corpus.py --plan hg` (+ пробные случаи по корзинам), `run_hg.sh` (весь счёт), `run_trial_hg.sh`, тесты `tests/test_hgw24.py`, `tests/test_hgw24_gpu.py` (GPU, под замком),
`tests/test_contract_s5.py` (S5 v4; v2 читается). Рельеф и деление мест — `../hg_real/README.md`.

**Возмущения погоды без правки air3d.** `weather.Day` читает конфиг `weather.CFG` при каждом вызове; на время одного случая модуль подменяет `CFG` копией
(`s5_io.weather_override`): `upper_air.temp_c += dt_upper_k` (t_u), `upper_air.lapse_k_per_km = lapse_k_per_km` (gam), `diurnal.inversion_depth_m ×= inv_depth_m`,
`diurnal.range_k ×= inv_range_k` (в столбцах таблицы — множители), облачность — запись `sky["hgw"] = {cover, heat = 1 − 0,75·cover}` (читают `Day` и `wind_prof.for_hour`),
dt_surface уже внутри `t_max_c` (= климат(месяц, широта) + dt_surface, обрезка 0…40 °C меню). z_lcl, θ_s, z_i, θ̄(z), dθ/dz пересчитывает `Day`. Для южных мест месячные
таблицы сдвигаются на 6 месяцев (дата + 6 мес. даёт тот же сезон). Без столбцов hgw24 (v2/v3) подмены нет — путь прежний (побитно). Тесты: `test_hgw24.py` (θ_fa, gam, z_i, H,
нейтральные возмущения = исходный конфиг побитно), `test_hgw24_gpu.py` (три настоящих решения: нулевые возмущения — поля побитно как без них; возмущения меняют H и θ′).
Производные условий (`conditions.derive`) считаются под тем же конфигом и тем же контекстом места, что у решателя (`model_place.context` по h100).

## Воспроизведение
```bash
PY=../../air_nn_pilot/.venv/bin/python; D=~/air_synth_data; export OMP_NUM_THREADS=1
$PY make_hgw24.py --relief-corpus $D/real/hg_v1  --out $D/conditions/hg_v1_hgw24     # 7296 условий, 13 с
$PY make_hgw24.py --relief-corpus $D/real/game_hg --out $D/conditions/game_hgw24     # 96 условий
$PY -m pytest -q tests/test_contract_s5.py tests/test_hgw24.py
tools/dp lock gpu sy10-test -- $PY -m pytest -q tests/test_hgw24_gpu.py                # ~12 с
tools/dp job --lock gpu start sy10-trial 3000 $PWD/run_trial_hg.sh                     # 24 случая, корзины час × ветер
tools/dp job --lock gpu start sy10-solve 200000 $PWD/run_hg.sh                         # весь счёт: game -> holdout -> train; продолжение — той же командой
```
Результат: `$D/solve/game__hgw24__s0-939a467/`, `$D/solve/hg_v1__hgw24__s0-939a467/` (S5 v4); сводка — `out_solve_hg/progress.json`.

## Пробный прогон (24 случая, 3 воркера, `out_solve_hg/trial_summary.txt`)
Воркер ≈ 13,0 с на случай, по стенному времени ≈ 4,3–4,8 с (SY-8 с p2c12 измерил ≈ 12 с: условия дельтаплана сходятся быстрее; сошлось 87 % решений с нагревом, разошедшихся 0);
утро 18 с, день 7 с, вечер 14 с; слабый ветер 8 с, сильный 18 с. Объём 1,17 ГБ на 1000 случаев. Всего (304 + 4) × 24 = 7392 случая ≈ 9–10 ч, ≈ 8,6 ГБ → 24 условия на место (порог 36 ч не достигнут).
Распределение условий hgw24 (7296 условий) — `out_solve_hg_conditions_summary.json`: утро/день/вечер 33/34/33 %, слабый ветер (< 2 м/с) 9,7 %, механический режим (w*/U < 0,5) 87,7 %,
классы устойчивости A…F: 171/1292/1605/3481/359/388. **Оговорка:** при градиенте свободной атмосферы 8–9 К/км и тёплом дне z_i над землёй > 3000 м в 20 % условий (до 11 км) —
выше потолка области решателя (максимум рельефа + 3000 м); это следствие распределения S2 v4, не ошибка кода.

# SY-12: счёт по hg_v2 (геометрия C2 v7)
`run_trial_hg2.sh` (пробные 20 случаев, `out_solve_hg2/progress.json`), `run_hg2.sh` (весь счёт: game2 → holdout → train; ставить только по команде координатора после первого обучения SY-11):
`tools/dp job --lock gpu start sy12-solve 200000 tools/research/air_synth/solver/run_hg2.sh`. Условия: `make_hgw24.py --relief-corpus ~/air_synth_data/real/hg_v2 --out ~/air_synth_data/conditions/hg_v2_hgw24`
(и `game_hg2` → `game2_hgw24`). Результат: `solve/game2__hgw24__<версия>`, `solve/hg_v2__hgw24__<версия>`. Оценка полного счёта — по пробному прогону (см. журнал SY-12).
