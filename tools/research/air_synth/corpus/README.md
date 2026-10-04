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
