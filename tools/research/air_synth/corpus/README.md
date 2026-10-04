---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-04"
summary: "Корпус air-synth: чтение/запись S1/S2 (corpus_io.py), запуск корпуса (run_corpus.py), тесты, замер времени"
related: ["docs/contracts/air-synth.md"]
---
# Корпус air-synth (SY-1)

Контракты S1/S2/S3 — `docs/contracts/air-synth.md`, схема — `proto/air_synth/v1/corpus.proto`. Данные — вне git, `$AIR_SYNTH_DATA` (по умолчанию `~/air_synth_data`).

- Окружение: `./setup_env.sh` (uv, `.venv` не коммитится; numpy scipy numba fastscapelib h5py pytest). Тесты: `.venv/bin/python -m pytest -q tests` (контракт S1 v3/S2 v2, детерминизм по числу процессов, продолжение после kill, `--theta-cloud`).
- `corpus_io.py` (HDF5): `quantize`/`to_float` (offset 2500, scale 0,15, вне int16 — ошибка), `encode_relief`, `write_part`, `write_conditions_part` (временное имя `.tmp` → fsync → `os.replace`), `build_view` (VDS `corpus.h5`/`conditions.h5`, детерминированно), `Corpus` (`h100/h400(id)`, `summary/params/place(id)`, `iter_batches`; без вида читает части), `Conditions` (`table`, `for_relief`, `validate_refs`), `write_reliefs` (готовые рельефы, в т. ч. реальные места с `place`, для SY-6).
- `run_corpus.py`: `gen --out DIR --n N --corpus-seed S --workers W [--shard-size 100] [--generator МОДУЛЬ] [--theta-cloud файл.json]`, `view DIR`, `sample DIR --n 50 --seed 1`, `bench`. Продолжение — той же командой; несовпадение параметров с `manifest.json` — отказ. Процесс на часть (spawn, `OMP_NUM_THREADS=1`); время частей — `timing.jsonl`.
- `proto_generator.py`: обёртка прототипа Fastscape по S3 v3 (только для замера).
- Замер (`bench/bench_proto.json`): `OMP_NUM_THREADS=1 .venv/bin/python run_corpus.py bench --warmup --shards 3 --shard-size 1 --workers 3 --json bench/bench_proto.json`.

## SY-7: корпус fs1_10k (частичный) и доработки
- Запуск: `dp job start sy7_gen 16000 .venv/bin/python run_corpus.py gen --out ~/air_synth_data/corpus/fs1_10k --n 10000 --corpus-seed 20261004 --workers 16 --theta-cloud ../tune/out/theta_cloud.json`
  (веса облака — равные, `--cloud-weights equal` по умолчанию, `file` — по полю weights; режим записан в manifest). Продолжение — той же командой.
- **Статус: 64 из 100 частей (6400 рельефов, id 0…6399, 1,3 ГБ), генерация остановлена по решению пользователя 05.10 (SIGTERM, ~3,1 ч на 16 процессах).** Вид `corpus.h5` пересобран по готовым частям (`complete = False`). Сводка — `out_corpus/gen_summary.json`.
- Рельеф вне диапазона int16 (S1 v3) не обрезается: перегенерация с зерном `corpus_seed + попытка·1e9`, эффективное зерно — `gen/params.corpus_seed`, список — `manifest.json: range_rejected_ids` (86 из 6400 = 1,3 %; по трём-четырём случаям в части).
- `run_corpus.py stats DIR --n 60 --seed 1 --json out_corpus/stats_sample.json` — 17 наблюдаемых SY-5 выборки против 367 реальных квадратов (флаг out: медиана вне [p5, p95]).
- Проверки облака (NaN/inf, разные t_total_yr — отказ), восстановление без manifest по атрибутам первой части, `clipped_places` (`Corpus.clipped_places`).
- `conditions.py`: по умолчанию `make` — набор P2 без отбора (`draw_p2`: час/облачность по кругу от rid·k+cid, каждый 12-й штиль), `--mechanical-only` — отбор механических; `summary --conditions DIR --out json`; общая `reject_fraction` в вид и manifest. Наборы h1_p2/h1_mech на корпусе НЕ построены (остановлено).
- H7 (`../solver/h7_run.py`): `--ids auto5`, `--conditions DIR`, `--base-m`; на настоящем корпусе не запускался.
