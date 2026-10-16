---
type: "contract"
status: "active"
module: "training-island"
area: "world"
updated: "2026-10-16"
summary: "Учебный остров: папка встроенного синтетического места (TI-К1), фиксированная погода старта (TI-К2), запечённое поле ветра (TI-К3)."
related: ["docs/plan/training-island.md", "docs/guide/location-data.md", "docs/research/air_field_cache.md"]
contracts: [{"id": "TI-К1", "version": 1}, {"id": "TI-К2", "version": 1}, {"id": "TI-К3", "version": 1}]
---
# Контракты модуля training-island

Владелец всех — координатор training-island; меняет только он (версия +1, потребителям — заметка в карточку).
Контрактные тесты — по файлу на контракт: `tests/contracts/test_training_island_k1.gd`, `…_k2.gd`, `…_k3.gd`
(фильтр `training_island`); пишет задача-владелец первым шагом, меняются только вместе с контрактом.

## TI-К1. Встроенное синтетическое место из файлов игры — версия 1

- Владелец данных: TI-1 (`tools/terrain/island/`); владелец загрузки: TI-2. Потребители: `Terrain` (`scripts/terrain/terrain.gd`),
  `Locations` (`scripts/terrain/locations.gd`), `AirRuntime.place_of`, тесты мест, TI-4, TI-5, модуль goals (координаты стартов и посадок).
- id места `training_island`; конфиг `configs/locations/training_island.json`; данные `res://data/locations/training_island/`.
- Конфиг — как у встроенных мест (`name`, `center_lat`, `center_lon`, `utc_offset_h`, `start_sites`, `landing_sites`,
  `start_position_agl_m`, `start_clearing_radius_m`, `render`, `trees` по желанию) плюс:
  - `"bundled": true` — данные места лежат в `res://data/locations/<id>/`, сборщик (`LocationBuilder`) и сеть для места не
    используются, в `res://` ничего не пишется; `dem`, `surface`, `rivers` в конфиге не нужны;
  - `"synthetic": true` — вымышленное место: `Locations.builtin_at` его не возвращает (точка с карты не превращается в остров);
  - `"country": ""` для каталога стартов (`data/places/hg_takeoffs.json`) — пусто для синтетического места.
- Центр: вымышленная точка в открытом море (≈ 43,2° с. ш., 34,0° в. д., `utc_offset_h` 3). Мировые X/Z — как у всех мест
  (`scripts/terrain/geo.gd`: X — восток, −Z — север, начало — центр места). Точка (0, 0) — суша выше 0,5 м (`Terrain.is_sea`).
- Папка данных — формат 4 (`Locations.FORMAT_VERSION`), как у собранного места (`docs/guide/location-data.md`, образец —
  `tests/fixtures/locations/aushkul/`):
  - `meta.json`: `location`, `center_lat`, `center_lon`, `earth_radius_m` (6371008.8), `attribution` (`["Synthetic terrain: Deltaplan project"]`),
    `layers`: `detail` (1601 × 1601, `spacing_m` 25, `origin_x_m`/`origin_z_m` −20000) и `far` (1601 × 1601, 100 м, −80000);
    у слоя `id`, `file`, `width`, `height`, `spacing_m`, `origin_*`, `source` = `"synthetic"`, `water_file`, `min/max_height_m`,
    `height_min_m`, `height_step_m` = 0.03125;
  - высоты `<слой>.webp` — WebP lossless RGB8, `v = (R << 16) | (G << 8) | B`, `h = height_min_m + v·height_step_m`;
    строка j растёт на юг (+Z), столбец i — на восток (+X); `far` содержит `detail` в своём квадрате (вклеен);
  - море — высота ровно 0 м, класс 6 (вода) в `<слой>_surface.webp`, 255 в `<слой>_water.webp` и A = 255 в `detail_detail10.webp`;
  - `<слой>_surface.webp` — L8, класс игры 0..8 (`SurfaceLayer`); `surface.json` — как у собранного места
    (`layers[]`: `id`, `file`, `width`, `height`, `origin_*`, `spacing_m`, `class_fraction`, `detail10`, `built10` по желанию),
    `attribution` = `["Synthetic surface map: Deltaplan project"]`;
  - `detail_detail10.webp` — LA8 4001 × 4001, 10 м: L — доля леса 0..255, A — вода 0..255 (цвет под A = 0 не обнулять);
  - застройка по желанию: `detail_built10.webp` (L8, 10 м) + `built_patches.json` (формат `SurfaceStage`); нет посёлка — файлов нет;
  - `osm_tiles.json` = `{"tiles": []}`;
  - `build.json`: `format_version` 4, `key` = id, `center_lat/lon`, `complete` true, `missing` [], `sources` ["synthetic"], `net_requests` 0.
- Генерация детерминирована: повтор `tools/terrain/island/` с теми же параметрами даёт побитно те же файлы.
- Старты — 3–4 в `start_sites` (id, `name` — ключ `locale/ui.csv`, `lat`, `lon`, `heading_deg`, `weather` по TI-К2); каждый проходит правила
  `tests/terrain/test_locations.gd` (уклон 8–35°, земля в 60 м впереди ниже > 5 м, не в лесу). Посадки — `landing_sites`
  (уклон < 10°, не лес и не вода); у старта «посадка» — посадка-мишень с id `landing_target`.
- Нет папки данных или файла слоя — загрузка места падает с сообщением (как нет рельефа), не сборкой из сети.

## TI-К2. Фиксированная погода старта — версия 1

- Владелец: TI-3. Потребители: меню полёта (`scripts/ui/flight_setup_screen.gd`), запуск полёта (`scripts/game/game.gd`),
  повтор полёта, сеть, TI-4 (условия запекания), TI-5 (подбор наборов), модуль goals (тренировки на острове).
- Ключ `start_sites[].weather` (необязательный) в конфиге места:
  ```json
  "weather": {"wind_from_deg": 270, "wind_speed_ms": 6.0, "start_hour": 12.0, "month": 7, "day": 15,
              "sky": "partly", "temperature_c": 24.0}
  ```
  Все поля обязательны внутри `weather`: `wind_from_deg` — откуда ветер, ° (0 — север, 90 — восток); `wind_speed_ms` — ветер по прогнозу
  у земли, м/с; `start_hour` — час старта (поясное время места), одно из `configs/world.json → time.start_hours` (9, 12, 15, 20); `month`, `day`; `sky` — `"clear"|"partly"|"overcast"`
  (`configs/weather_model.json → sky`); `temperature_c` — максимум у земли, °C.
- Соответствие `FlightSettings`: `wind_from_deg` → `wind_from_deg`, `wind_into_launch` = false, `wind_speed_ms·3.6` → `wind_speed_kmh`,
  `start_hour`, `month`, `day`, `sky`, `temperature_c` — одноимённые.
- Поведение: у выбранного старта есть `weather` → эти поля `FlightSettings` берутся из набора (при выборе старта в меню, при восстановлении
  `user://last_flight.json`, при повторе полёта, в сети и при запуске из командной строки — одно правило, одна функция);
  в меню погода для такого старта не выбирается (видно, какой набор). Нет `weather` — всё как сейчас.
- Время полёта идёт как обычно (погода «фиксирована» на старте, не останавливает часы).

## TI-К3. Запечённое поле ветра — версия 1

- Владелец: TI-4. Потребители: `AirRuntime` (`scripts/atmosphere/air_model/air_runtime.gd`), инструмент `tools/terrain/bake_air.gd`, TI-5.
- Файлы: `res://data/locations/<id>/air/<site_id>.json` (заголовок) + `<site_id>.bin` (тело). Заголовок:
  `{"format": "dp-air-baked", "version": 1, "location": id, "site": site_id, "key": {...}, "model_hash": "<sha256[:16]>",
  "levels": [{"name", "grid": {...как AirCase.meta()...}, "meta": {...}, "arrays": {имя: [смещение, длина_байт, "f16"|"f32"]}}],
  "compression": "zstd", "raw_bytes": N}`. Уровни — от мелкого к грубому, как `AirFieldSet.levels`; массивы уровня — `u`, `v`,
  `w_mech`, `w_conv`, `theta`, `hc`, `heat` (те, что читает `WindField.load_file`); 3D-каналы — float16, по столбцам — float32.
  Тело — `PackedByteArray.compress(FileAccess.COMPRESSION_ZSTD)` от склейки массивов (little-endian).
- `key` — условия, от которых зависит поле старта: `location`, `site`, `weather` (TI-К2 как есть), координаты центра области и окон, хеш данных
  места (`meta.json` + файлы слоёв `detail`), версия формата. В игре поле берётся только при точном совпадении `key`.
- `model_hash` — sha256 исходников модели воздуха (`scripts/atmosphere/air_model/*.gd`, `*.glsl`, секции `air_model`, `air_phase`
  `configs/atmosphere.json`, `configs/weather_model.json`, `configs/surface_heat.json`). В игре не проверяется (в экспорте исходников нет);
  проверяет `tools/terrain/bake_air.gd --check` (код 1 — поле устарело, перепечь) и контрактный тест (предупреждение, не падение).
- Поведение в игре: совпал `key` → поле из файла, без этапа «Рассчитываем ветер»; текущее состояние `AirRuntime` выставлено так, что
  поле старта не пересчитывается сразу; источники термиков построены; затем обычный фоновый пересчёт (сдвиг окон, ход времени).
  Нет файла или `key` не совпал → обычный расчёт и строка в лог. Формат состояния модели воздуха (`AirPicardJob`, `WindField`,
  `AirCase.meta`) этим контрактом не меняется.
- Ошибка распаковки против float32: ≤ 0,01 м/с по u, v, w при ветре до 12 м/с (float16).
