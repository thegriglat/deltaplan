---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-05"
summary: "SY-10: рельеф мест дельтаплана (каталог S6, 363 места -> 304 в корпусе S1 v4 real/hg_v1) квадратом как в игре; деление train/holdout; сверка с кодом игры"
related: ["docs/contracts/air-synth.md", "docs/plan/air-synth.md", "tools/research/air_synth/hg_sites/README.md", "tools/research/air_synth/solver/README.md"]
---
# SY-10: рельеф мест дельтаплана (S1 v4)

Вход — каталог SY-9 `../hg_sites/sites.json` (363 места; центр квадрата = старт с наибольшей высотой, S6). Выход — корпус
`~/air_synth_data/real/hg_v1` (**304 места**, 59 МБ) и `~/air_synth_data/real/game_hg` (4 места игры, 0,8 МБ; прежний `real/game` SY-6 не тронут).
Источник — Terrain Tiles (Mapzen/AWS Open Data, Terrarium; условия и атрибуция — `terrain_real.yaml`/SY-6 `out/cut_manifest.json`, ASSETS.md);
код SY-6/П6 использован только запуском (`terrain_cut.layer_zoom/plan_layer/decode_png/fetch_tiles`, не правился).

## Квадрат — как в игре (не как SY-6)
SY-6 и П6 передискретизируют слой билинейно на сетку 25 м и берут клетки ровно 400 м; игра для произвольной точки делает иначе
(`scripts/terrain/terrarium_loader.gd`, `scripts/atmosphere/air_model/air_place.gd`, `configs/world.json → runtime_terrain`). Набор строит **так же**
(`pack_hg.py`: `geometry()` — планировка слоя, `window()` — окно узлов, `build_relief()` — клетки):
- центр = координата старта (`build_location(lat, lon)`); слой `detail`: Terrarium z12, на широтах, где шаг < 18 м, z11 (`layer_zoom`; в каталоге z12 у всех мест);
- узлы = пиксели web-mercator, шаг `s = 2π·6378137·cos φ/(256·2^z)` (18–38 м), **без сглаживания и без передискретизации** (сглаживание σ 0,8 есть только у
  встроенных мест из `data/terrain`, Copernicus — у точки по координатам его нет);
- клетка решателя = блочное среднее `f × f` узлов, `f = round(400/s)` (`AirPlace.block_mean`), область 96 × 96 клеток от x0 = y0 = −19 200 м
  (узел `i0 = round((x0 − origin_x)/s)`). **Клетка = f·s, а не 400 м** (385–414 м, медиана 400,5; у Аскарово 388,6 м) — игра передаёт решателю `dx = 400` как есть;
  область = 96·f·s (36,9–39,7 км) и сдвинута относительно старта до ~±0,5 км;
- h100 (384 × 384, нужен контракту S1) — точное площадное перебинирование тех же узлов на 4 × 4 подъячеек клетки: блочное среднее h100 4 × 4 = h400 игры
  (до квантования); решатель берёт h400 как блочное среднее h100 (`R.grid_domain`), поэтому поля решателя соответствуют клеткам игры.
**Сверка кодом игры** (`game_block_check.gd/.tscn`: godot headless, `TerrariumLoader._plan_layer` + `assemble` + `AirPlace.block_mean` по тем же тайлам): 4 точки (z12, f = 12…22) —
расхождение hc400 с Python **0,0 м** (побитно) — `out/game_block_check.txt`.
**Находка (код игры не правился):** на 5 из 367 точек (широты 50,7–51,0° с f = 17, и −33,7°) f·s > 400 м, область 96·f·s не помещается в слой 40 км —
игра пишет «AirPlace: область вне слоя рельефа» и возвращает пустой случай (подтверждено запуском в точке 50,673; 16,210). Для набора окно сдвинуто внутрь слоя
(≤ 7 узлов ≈ 170 м, флаг `clamped_px` в `out/geometry.json`); Онгудай (50,79°) среди них.

## Отбор и деление
- Исключены места по порогам П6 (`terrain_real.yaml`): доля узлов ≤ 0,5 м > 0,05 (море) — 43, перепад h400 > 3000 м — 19 (3 — по обоим), итого 59 из 363 (причины — `out/excluded.json`;
  Франция 32). Решатель без воды (water=None), поэтому прибрежные квадраты не берутся. Осталось 304.
- Деление (`split_hg.py`, зерно 20261005; `out/split_summary.json`): места ближе 20 км к местам игры → holdout, stratum `near_game` (в каталоге таких нет); остальные —
  компоненты односвязной кластеризации 50 км целиком train или holdout (поэтому каждое отложенное ≥ 50 км от любого обучающего: минимум **51,3 км**);
  отложены **20 мест** из малых компонент (≤ 3 места) по кругу по 15 регионам (Франция: Альпы/Юра, восток, запад–север, Пиренеи, Корсика, заморская; Италия юг; Альпы AT/CH/SI/IT; Иберия;
  Скандинавия; Британия; Иран; Корея; Северная Америка; Бразилия); обучающих **284** (stratum — их регион). `train_order` пуст, `split_seed` — атрибут корня.
- Квантили перепада h400, м: train p10/50/90 = 298/1262/2454, holdout 266/1163/2588 (`out/split_summary.json`).

## Воспроизведение
```bash
cd tools/research/air_synth/hg_real; PY=../../air_nn_pilot/.venv/bin/python        # нужны PIL, yaml (venv air_nn_pilot)
$PY pack_hg.py plan                      # тайлы окон -> ~/sy10_data/tiles.json (10 820 тайлов z12, ~1,1 ГБ)
$PY pack_hg.py fetch                     # вежливо: 8 потоков, пауза 0,02 с, User-Agent игры, ~16 мин
$PY pack_hg.py pack --workers 8          # корпусы real/hg_v1, real/game_hg, out/*.json (~1 мин)
$PY pack_hg.py clean                     # сырьё удалить (сделано: 1,1 ГБ)
../corpus/.venv/bin/python -m pytest -q tests      # без PIL/yaml геометрические тесты пропускаются; полный — $PY -m pytest
XDG_DATA_HOME=$(mktemp -d) godot --headless --path <копия> res://tools/research/air_synth/hg_real/game_block_check.tscn -- lat lon <raw> out.f64   # сверка с игрой
```
Выходы: `out/hg_summary.json` (пути, размеры, `h400_vs_game_blockmean_max_abs_m` = 0,075 — шаг квантования/2, клетки f·s, `raw_deleted`), `out/split_summary.json`,
`out/excluded.json`, `out/geometry.json` (на место: z, s, f, клетка, область, сдвиг центра, clamped_px).
