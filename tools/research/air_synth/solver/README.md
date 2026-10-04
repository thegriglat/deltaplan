# SY-4 / H7: цена случая решателя P2 на модельном рельефе

Решатель — `tools/research/air3d` (код не правится), обрамление — `air_nn_pilot/airlite_gen.solve_case` (область 96×96×400 м,
решения h и m, предел итераций `terrain.max_outer` = 1000, цель «среднее поздних» П1 v3 — `configs/dataset.yaml`).

Файлы: `model_place.py` (S4: g100 → место решателя, `register`, `solver_version`), `reliefs.py` (источники: `proto`, `corpus` HDF5 S1 v3),
`h7_run.py` (прогон, продолжение по `out_h7/cases.jsonl`), `h7_summary.py` (→ `out_h7/h7_cost.json`, `h7_cases.csv`),
`gen_proto_reliefs.py` (4 рельефа прототипа → `proto_reliefs.npz`), `bench.sh` (кривая воркеров + 48 случаев), `tests/test_s4.py`.

## Воспроизведение
```bash
cd tools/research/air_synth/solver
# окружение: ../../air_nn_pilot/setup_env.sh, затем uv pip install --python ../../air_nn_pilot/.venv/bin/python h5py pytest
OMP_NUM_THREADS=1 /home/greg/deltaplan/tools/research/air_synth/terrain_stats/.venv/bin/python gen_proto_reliefs.py   # рельефы (4 × 15 с)
../../air_nn_pilot/.venv/bin/python -m pytest -q tests
tools/dp job --lock gpu start h7main 3000 env OMP_NUM_THREADS=1 ../../air_nn_pilot/.venv/bin/python h7_run.py --source proto --workers 2
tools/dp job --lock gpu start h7bench 3000 ./bench.sh
../../air_nn_pilot/.venv/bin/python h7_summary.py; ../../air_nn_pilot/.venv/bin/python h7_summary.py --dir out_h7/ext12
# рельефы корпуса (позже): h7_run.py --source corpus --corpus-dir $AIR_SYNTH_DATA/corpus/<имя> --ids 1,2,3 --out out_h7_corpus
```
Высоты прототипа — от уровня эрозии (min 51…117 м), к ним добавлена база 1000 м (как BASE синтетики пилота).
Условия: U10 ~ U[3, 8] м/с, час и облачность по кругу, 3 на рельеф (seed 20261005). Ограничение: корпусной загрузчик
проверен только на искусственном h5, не на настоящем корпусе.
