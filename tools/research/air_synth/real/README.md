---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-05"
summary: "Реальные места air-nn v3 (360 + 4 места игры) в корпусе S1 v3 (HDF5): конвейер П6, упаковка, команды воспроизведения"
related: ["docs/contracts/air-synth.md", "docs/plan/air-synth.md"]
---
# SY-6: реальные места air-nn v3 в корпусе S1 v3 (HDF5)

Только рельеф, решатель не запускался. Конвейер П6 пилота air-nn (`tools/research/air_nn_pilot/terrain_cut.py`, код не правился)
с конфигом `terrain_real.yaml` (= `configs/terrain.yaml` пилота; отличия: `data_root`, `ref_cuts` — 4 места игры).
Состав совпал с v3 побитно (все признаки систем и частей, `systems_match_v3 = true`, макс. расхождение 0).

Воспроизведение (из копии репозитория; `AIR_NN_DATA=/home/greg/sy6_data` — временный каталог вне git, после упаковки удалён):
```bash
cd tools/research/air_synth/real && uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.in
cd ../../air_nn_pilot; export AIR_NN_DATA=/home/greg/sy6_data
PY=../air_synth/real/.venv/bin/python; C=../air_synth/real/terrain_real.yaml
$PY terrain_cut.py --config $C screen && $PY terrain_cut.py --config $C select      # screen ~16 мин, тайлы z5/z8 0,75 ГБ
$PY terrain_cut.py --config $C fetch                                                # 19 007 тайлов z12/z11, 24 мин, 1,2 ГБ
$PY terrain_cut.py --config $C cut --workers 6 && $PY terrain_cut.py --config $C figures   # 61 с
cd ../air_synth/real; AIR_SYNTH_DATA=~/air_synth_data ../corpus/.venv/bin/python pack_real.py pack   # корпус + out/real_summary.json
../corpus/.venv/bin/python pack_real.py clean                                       # удалить raw/ tiles/ tmp/
../corpus/.venv/bin/python -m pytest -q tests
```
Выход: `~/air_synth_data/real/p6v3/` (360 мест, 73,5 МБ), `real/game/` (askarovo, aushkul, altai, ongudai, part=game, 0,8 МБ).
Места игры — Terrarium z12 в центре места, тем же путём, а не Copernicus из `data/terrain` (там сглаживание и другой источник).

Отступления/особенности:
- Выбросы Terrarium: у `t_0164` 2 узла g100 ниже −2415 м (−3244 м; кодировка S1 v3 −2415…7415) — обрезаны до границы
  на уровне g100; g400 этого места из обрезанного g100 отличается от `hc400` П6 до 51,8 м в одной клетке (см. `clipped_places`).
  У остальных 359 мест g400 = hc400 ≤ 1e-6 м до квантования.
- Данные: Terrain Tiles (Mapzen/AWS Open Data), условия и атрибуция — `out/cut_manifest.json` (`license`, `attribution`).
