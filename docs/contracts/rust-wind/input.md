---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "W5 rust-wind: вход реализации — AirPlaceData (место, растры, климат, запечённые поля, хеши), конфиги, условия"
related: ["docs/contracts/rust-wind.md", "docs/plan/rust-wind.md"]
contracts: [{"id": "W5", "version": 6}]
---
Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W5). Менять — только координатор.
# W5. Вход: место, конфиги, условия (v6)
Владелец — RW-2 (сборка `AirPlaceData` из `AirRuntime.place_of`, `air_runtime.gd:270`), RW-4 (разбор в крейте). Потребители — W2–W4, фикстуры W8.

**`AirPlaceData`** (`RefCounted`, `scripts/atmosphere/air_place_data.gd`, создаёт RW-2) — то, что крейт получает один раз при загрузке:
- `header` (json в W3):
  - `version: 1`; `loc: {id: String, center_lat, center_lon: float (град), utc_offset_h: float, month: int, day: int, climate: {tx_c: float (°C, дневной максимум HH5), dtr_k: float (К, суточная амплитуда), z_cell_m: float (м, средняя высота ячейки HH1, 0 — нет), has_hh1: bool, has_hh5: bool}}` (v3: климат места — `ClimateGrid.place` у центра места на `month/day`, считает фасад при сборке `AirPlaceData`; нет сетки — `has_* = false` и запасные значения, как сейчас; крейт файлы климата не читает);
  - `grid: {origin_x, origin_z, spacing, width, height}` — сетка W1 (сейчас слой `detail` 25 м `HeightLayer`); покрывает область поля (квадрат 38,4 км у центра) и ≥ 2 км запаса вокруг для аналитики (`GroundField`, просмотр с наветра до 1600 м);
  - `surface_classes: {имя: код}` — коды `cls` как в `AirPlace.Surface` (`air_place.gd`); список фиксирует RW-2 в тесте;
  - `start_sites: [{x, z, h_msl}]` — старты места (для отладки и фокуса по умолчанию).
- `heights: PackedFloat32Array` — `width × height`, м MSL, узлы сетки; NaN недопустим (BAD_INPUT).
- `water: PackedByteArray` — та же сетка, 0/1.
- `surface_cls: PackedByteArray`, `surface_moist: PackedFloat32Array` (0..1) — та же сетка.
- v4: `baked: Array` — запечённые поля места (TI-К3 v3, `docs/contracts/training-island.md`: `data/locations/<id>/air/*.json` + `.bin`, f16, zstd) как есть: `[{header_json: String, data: PackedByteArray}]`; фасад читает файлы места при сборке `AirPlaceData`, реализация выбирает подходящее по условиям (как `AirRuntime.baked_lookup`) — без файлового доступа к данным игры; нет — пусто.
- v5: `header.model_hash: String` (необязательный, по умолчанию `""`) — хеш модели воздуха, как его сейчас считает `AirRuntime` для запечённых полей и кеша (до RW-13 — хеш GD-модели, считает фасад); реализация сравнивает его с `model_hash` заголовков запечённых полей и кладёт в ключ кеша; пусто — запечённые поля и кеш не используются (расчёт всегда).
- Производные поля (уклоны, линия тени, рельеф гребня, `valley_msl_m`, `mean_msl_m`, сила источников термиков `thermal_source_strength`, нагрев и `surface_flux`, `domain_case`, грубая задача 1200 м) — считает реализация из этих растров (решение пользователя 2026-10-26: «всё тяжёлое считает Rust»). Не хватает данных для производного (например, для `thermal_source_strength_water`) — `contract:` координатору, W5 v2, а не колбэк.
- Высота у реализации — билинейно по `heights`; это заменяет `terrain.height_at` во всех слагаемых ветра. Разница с нынешней высотой — в допусках W8.

**Конфиги** — тексты json как есть (W2 `configure`); схему ключей задаёт сам конфиг, крейт читает нужные секции (`wind`, `turbulence`, `ground`, `lee`, `ridge`, `thermal`, `clouds`, `storm`, `wave`, `air_model`, `air_phase`, `cloud_field`, `seed`, …). Неизвестный ключ — не ошибка; отсутствие обязательного — BAD_INPUT с именем ключа.

**Условия** (`set_conditions`, Dictionary в W2 / json в W3) — ровно один из двух видов:
- Прогноз: `{forecast: {temperature_c, wind_speed_kmh, wind_from_deg, sky: String}, start_hour: float, speed: float (игровых с на с времени t; 1 — реальное), quantum_h: float, wind_ref: {ref_msl: float, gain_per_km: float} | null, overrides: {ключ пресета: значение}, blend_s: float | null, rebuild: bool}` — реализация сама выводит погоду по часу (`WeatherModel.derive`, `AtmoDay`; в `gd` — как сейчас, в крейте — RW-12). `overrides` — то, что игра правит поверх (сейчас `thermal_spacing_m` пикового часа, `game.gd:612`; ветер из настроек вместо `set_wind`).
- Эталон: `{preset: String ("weather/medium") | Dictionary (ключи пресета), start_hour, speed, blend_s, rebuild}` — без вывода по часу (превью, тесты, фикстуры).
- **v2:** в обоих видах — необязательный ключ `inflow_mode: "start" | "inflow"` (по умолчанию `"start"`; сейчас `StartWeather.wind_ref_of`, `air_runtime.gd:957`): `"start"` — ветер условий — у старта, приток подбирается проходами `k`; `"inflow"` — ветер условий — набегающий поток, `k = 1`. Другое значение — BAD_INPUT. Не путать с `wind_ref` прогноза (опорная высота и прирост).
- Посторонний ключ, оба вида сразу или ни одного — BAD_INPUT.
- Сид — только `configure`; статические термики — `set_static_thermals`; солнце — `set_sun_direction`.
- **v6 (ревью RW-6t; эталон — `air_runtime.gd` `_baked_site` 428, `baked_lookup` 448, `AirBakedField.make_key`, `place_hash`):**
  - `start_sites[i]` += `id: String` и `weather: Dictionary` — набор погоды старта (TI-К2), как `_baked_site`: из места, пусто — из `Locations.config(<id места>).start_sites`; нет — `{}`; считает фасад.
  - `header.data_hash: String` (необязательный, по умолчанию `""`) — `AirBakedField.place_hash(Locations.data_dir(<id места>))`, считает фасад.
  - Выбор запечённого — как `baked_lookup`: старт в 1 м от фокуса → его `id`, `weather` и ключ `make_key(loc, center, site.id, site.weather, site.position, data_hash, window_levels_m)`; сравнение — `key_diff` с ключом файла. Пустой `data_hash` или `weather` — запечённое не берётся (причина в `Status.reason`/журнале), расчёт.
