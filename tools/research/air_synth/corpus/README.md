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

- Окружение: `./setup_env.sh` (uv, `.venv` не коммитится). Тесты: `.venv/bin/python -m pytest -q tests` (контракт S1/S2, детерминизм по числу процессов, продолжение после kill, `--theta-cloud`).
- `corpus_io.py`: `quantize`, `to_float`, `make_relief` (g400 = блочное среднее до квантования, сводки), `write_shard` (tmp/ → fsync → rename), `build_index`, `Corpus` (`get(id[, cond_id])` через seek, `iter_shards`, `validate_refs` для условий).
- `run_corpus.py`: `gen --out DIR --n N --corpus-seed S --workers W [--shard-size 100] [--generator МОДУЛЬ] [--theta-cloud файл.json]`, `index DIR`, `sample DIR --n 50 --seed 1`, `bench`. Продолжение — той же командой; несовпадение n / seed / shard-size / версии генератора / облака — отказ. Рабочий процесс на шард (spawn, `OMP_NUM_THREADS=1`); время шардов — `timing.jsonl` в каталоге корпуса.
- `proto_generator.py`: обёртка прототипа Fastscape по S3 (только для замера).
- Замер (`bench/bench_proto.json`): `OMP_NUM_THREADS=1 .venv/bin/python run_corpus.py bench --warmup --shards 3 --shard-size 1 --workers 3 --json bench/bench_proto.json`.
