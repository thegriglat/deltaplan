---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "W12 rust-wind: погода в крейте — dp_air::weather (климат, ход дня, температуры, небо), класс DpWeather (dp-gd) и тонкая обёртка GD."
related: ["docs/contracts/rust-wind.md", "docs/contracts/rust-wind/input.md", "docs/contracts/rust-wind/dpair.md", "docs/research/rust-wind-stage3/rw14-weather.md"]
contracts: [{"id": "W12", "version": 1}]
---
Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W12). Менять — только координатор.

# W12. Погода: `dp_air::weather`, `DpWeather` (v1)

Владелец — RW-14c (крейт), RW-14d (`dp-gd`), RW-14e (обёртка GD). Потребители — меню (`flight_settings.gd`, `flight_setup_screen.gd`), `goal_estimator.gd`, `achievement_feed.gd`, `egg_place.gd`, `game.gd`, `DpAir` (W3 v9, `attach_weather`), `cargo test` (эталоны RW-14b). Проект и обоснование — `docs/research/rust-wind-stage3/rw14-weather.md` (разделы «Предложение контракта», «Эталоны»). Решения: перенос погоды в крейт, второй реализации в GDScript нет (пользователь, 2026-10-30); dp-air чистая — без Godot, путей и понятий игры (пользователь, 2026-10-30); сетки распаковывает игра (координатор, 2026-10-30).

**1. Крейт `dp_air::weather`** (без Godot, без путей, без чтения файлов).
- `Weather` — неизменяемая, `Send + Sync`, делится через `Arc<Weather>`. `Weather::new(cfgs: &Configs, grids: ClimateGrids) -> Result<Weather, Error>`; `Configs` — те же секции, что принимает `configure` (W5): ключи — имена секций данных (`weather_model`, `surface_heat`, `atmosphere`, `weather/<пресет>`), а не пути файлов.
- `ClimateGrids::from_bytes(items: &[(&str, &[u8])]) -> ClimateGrids` — сетки **уже распакованными байтами** (сжатие снимает игра/`dp-gd`; в `dp-air` нет зависимости `brotli`); имена — ключи сеток из `weather_model` (как у `ClimateGrid` GD). Состояния сетки — `data`/`stub`/`none` как в GD; битый заголовок или неверный размер → `none`; нет сетки → запасные значения конфига (`climate.fallback`), не ошибка.
- Функции (смысл и входы — как у одноимённых GD, эталоны E1–E10): `climate_at(lat, lon, month, day) -> ClimateCell`; `climate_place(ctx) -> ClimatePlace`; `typical_max_c(month, day, lat, lon)` (NaN lat/lon — таблица); `diurnal_range_k`; `diurnal_state(t_max, hour, ctx)`; `sunrise_h`, `sunset_h`; `sky_params(sky) -> (cover, sky_heat)`; `derive(forecast, ctx, hour) -> Map`; `haze_k_rh(t, td)`; `air_temp_c(hour, t_max, z, ctx)`; `water_temp_c(month, day, z, ctx)`; `temp_at_altitude(weather, alt_msl, month, day)`; `monthly`; `quantum_h`; `hour_at(start_hour, speed, t, world_time)`; `sun_direction(lat, month, day, hour, utc_offset_h)`; `reference_context()`; `ground_context(raster, …)`; `valley_of(samples, percentile)`.
- Зажим температуры — физический диапазон модели `weather_model.limits.temperature_c: [min, max]` (новый ключ, те же числа, что `ui.temperature_c`); крейт `ui.*` не читает. Ползунок меню берёт свой `ui.temperature_c` в GD.
- Единицы: °C, м MSL, км/ч в прогнозе (единицы входа), час места десятичный; `NaN` в `hour` — «разгар дня» (как GD); `NaN` в `valley_msl_m`/`utc_offset_h` — не задано. Числа на выходе конечны.
- Равенство GD: эталоны `rust/dp-air/tests/data/RW-14b/` E1–E5, E7–E10 — допуск W8 `1e-6 + 1e-5·|ref|`; E6 — только замер (см. W5 v10, долина).

**2. Класс `DpWeather`** (`dp-gd`, `RefCounted`; состояние — только `Arc<Weather>`). Все методы — чистые функции, без блокировок, из любого потока; словари — JSON-строкой (один разбор в GD).
- `configure(configs_json: PackedStringArray, grid_names: PackedStringArray, grid_bytes: Array[PackedByteArray]) -> int` — конфиги как у `DpAir.configure`, сетки распакованными байтами; коды W1; до `configure` остальные методы возвращают NaN / `""` / `{}`.
- `typical_max_c(month, day, lat, lon) -> float`; `diurnal_state(t_max, hour, ctx_json) -> String`; `sunrise_h(t_max, ctx_json)`, `sunset_h(t_max, ctx_json) -> float`; `sky_params(sky: String) -> PackedFloat32Array` (`[cover, sky_heat]`); `derive(forecast_json, ctx_json, hour) -> String` (как `weather_json`: ключи пресета + `_derived`); `air_temp_c(hour, t_max, z, ctx_json)`, `water_temp_c(month, day, z, ctx_json)`, `temp_at_altitude(weather_json, alt_msl, month, day) -> float`; `climate_cell(lat, lon, month, day) -> String`; `reference_context() -> String`; `quantum_h() -> float`; `hour_at(start_hour, speed, t, world_time) -> float`; `valley_of(samples: PackedFloat32Array, percentile) -> float`.
- Один экземпляр на игру; `DpAir.attach_weather(w)` (W3 v9) передаёт тот же `Arc`, климат не читается дважды.

**3. Обёртка GD** `scripts/atmosphere/weather.gd` (`class_name Weather`, статические методы): читает конфиги и файлы сеток (`FileAccess`, пути знает игра), распаковывает, создаёт `DpWeather` лениво один раз; каждый метод — один вызов `DpWeather` и разбор JSON. Расчётов погоды в GDScript нет. Меню (`ui.*`, `sky.options`, румбы), сигналы `weather_changed`/`weather_updated`, подписи — в GD.

**4. Чего нет.** Чтения файлов и путей в крейте; понятий игры (меню, достижения, старты, пасхалки — `valley_of` принимает пробы высоты, а не «пасхалку»); второй реализации погоды в GDScript после RW-14g.

## История
- **v1 (2026-10-30, проект RW-14a, решения пользователя и координатора 2026-10-30):** первая версия. Потребители: RW-14c (крейт), RW-14d (`DpWeather`, `attach_weather`, `place_context`), RW-14e (обёртка, перевод потребителей), RW-14h (порт GD-тестов), RW-P13 (`CONTRACTS.W12 = 1` в `tests/contracts/test_rust_wind_contracts.gd`).
