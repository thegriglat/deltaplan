---
type: "guide"
status: "active"
module: "game"
area: "game"
updated: "2026-10-15"
summary: "Как Game связывает рельеф, объекты, воздух, погоду из прогноза, солнце и графику: интерфейс воздуха, ход дня, SunClock, пресеты графики."
related: ["docs/guide/game.md", "docs/guide/atmosphere.md", "docs/guide/air-model.md", "docs/guide/terrain.md", "docs/perf/frame_profile.md"]
---
# Мир, воздух, время суток, графика

Часть описания сборки игры (вход — [game.md](../game.md)). Код: `scripts/game/game.gd`, `world_link.gd`, `calm_air.gd`, `cloud_whiteout.gd`, `graphics_presets.gd`, `scripts/world/sun_clock.gd`; устройство самих систем — `docs/guide/terrain.md`, `atmosphere.md`, `air-model.md`.

## Объекты мира

`WorldLink` (`scripts/game/world_link.gd`) при загрузке локации (`link(terrain, air, pilot)`): `terrain.set_wind_sources(mean_wind_at, thermals_near, air_velocity_at, поле)` — ветер для травы и деревьев (поле воздуха берётся у `Atmosphere`, если `is_air_field_on()`), `terrain.set_pilot(glider)` (примятая трава), `RockScatter`/`ShrubScatter` (камни и кусты), просеки `WorldClearings.build_for(id)` → `terrain.set_clearings`, `WorldObjects.setup(terrain, air)` (сцена — `game.json → world_objects_scene`: ветроуказатели, посадки, здания). Та же локация — повторно не строится. `place_camp()` ставит лагерь палаток у старта до расстановки ботов (боты обходят палатки). Атмосфере источники термиков даёт `terrain.thermal_source_strength_at`; дымке — `sky.set_inversion_height_msl(air.get_cloudbase_msl())`. Столкновения — `flight-flow.md`.

## Воздух (заменяемый)

`configs/game.json → air.script` — основная модель (`scripts/atmosphere/atmosphere.gd`), `fallback_script` — `CalmAir`, если основная не загрузилась. Интерфейс: `set_weather(имя | словарь, blend_s)`, `set_wind(км/ч, откуда°, высота старта)`, `set_ground(height_fn, sun_fn)`, `air_velocity_at(pos)`, `step(dt)`, `focus_node`; необязательные — `set_sun_direction`, `load_static_thermals` (из `thermals` конфига локации), `place_thermals_near`, `mean_wind_at`, `thermals_near`, `set_day`, `refresh_now`, `is_air_field_on`.

**Среднее поле ветра.** `AirRuntime` (`scripts/atmosphere/air_model/air_runtime.gd`, `docs/guide/air-model.md` → «Загрузка и пересчёт поля») считает поле по месту, часу, ветру и погоде при загрузке (этап «Рассчитываем ветер по рельефу…») и пересчитывает в полёте каждые `atmosphere.json → air_model.recompute_game_min` (15) игровых минут и при смене условий. Режим — `air_model.enabled`: `auto` (поле, если GPU позволяет; иначе аналитика), `on`, `off` (настройка «Эвристика»). Без GPU, в `headless` и при ошибке остаётся аналитика, в журнале строка `air_model: analytic (<причина>)`. Старт «против ветра»: курс выравнивается по полю — `launch.md`.

**Погода из прогноза (FR-16).** Пилот задаёт на экране «Полёт…» то, что знает из прогноза: температуру днём (`weather_model.json → ui.temperature_c`: 0…40 °C), ветер на старте (от 0 до верхнего предела ветра классов крыльев, `WingCatalog.wind_menu_range`), откуда ветер (встречный или румб) и облачность (`clear` / `partly` / `overcast`). `Game.start` после загрузки рельефа собирает место (`WeatherModel.ground_context`: долина и средняя высота вокруг, дата, широта, пояс) и зовёт `air.set_weather(WeatherModel.derive(прогноз, место, час старта))`; ветер — `air.set_wind(км/ч, курс старта | румб, высота старта)`: выше старта ветер сильнее.

**Ход дня.** Погода, солнце и сила источников термиков — чистые функции времени атмосферы (`AtmoDay`, `docs/guide/atmosphere.md`): `Game` создаёт `AtmoDay` (`_make_day`) и отдаёт его `air.set_day`; погода считается шагом `weather_model.json → diurnal.update_s` (60) и между шагами интерполируется. Так мир одинаков у всех клиентов зоны. Для воздуха без `AtmoDay` (запасной вариант) `Game._update_day_weather` раз в `update_s` мягко ведёт атмосферу к погоде нового часа (`set_weather(w, blend_s)`); дымка — `sky.set_haze_density`. Новый полёт обнуляет время атмосферы: порывы и жизнь термиков у старта зависят только от места, погоды и сида (`Game.world_seed`: «Лететь» — новый случайный, «Ещё раз» его не меняет, `--seed` задаёт). Модель погоды — `docs/guide/atmosphere.md` → «Погода из прогноза».

## Время суток (VR-5)

Единый источник солнца — `SunClock` (`scripts/world/sun_clock.gd`), узел `sky.clock` у `SkyEnvironment`. `Game.start` зовёт `sky.clock.start_flight(terrain.center_lat, center_lon, month, day, start_hour, utc_offset_h локации)`, `Game.tick` — `sky.clock.advance(dt)` (время идёт только в полёте, пауза его держит), «Ещё раз» — `reset()` к времени старта. Час старта выбирается из `world.json → time.start_hours` (9, 12, 15, 20; `--hour` берёт ближайший), дата — месяц и число. Скорость — `world.json → time.speed_options` (×1, ×10, ×60, стоп; в зоне всегда ×1), диапазон `min_hour`…`max_hour` = 6:00–21:00, часы — поясное время места. Пояс берётся так: `world.json → time.utc_offset_h`, если задан (число — один пояс для всех, `"solar"` — местное солнечное; сейчас `null`), иначе `utc_offset_h` в конфиге локации, иначе `round(lon/15)`.

Положение: склонение и часовой угол (NOAA), `SunClock.solar_position(lat, lon, день_года, часы, utc_offset_h)`. Свет по высоте солнца (`time.light`): цвет и яркость солнца, неба, окружения и дымки — в `SkyEnvironment._apply_sun`.

Как подписаться (рельеф, свои шейдеры): взять `sky.clock.to_sun()` при старте и слушать `sky.clock.sun_changed(to_sun: Vector3)` — единичный вектор НА солнце (север −Z, восток +X), высота не ниже `time.min_light_elevation_deg` (2°); сигнал — при сдвиге ≥ `EMIT_STEP_DEG` = 0,05°. Облака и перистые берут направление с `DirectionalLight3D` сами. Воздух (`set_sun_direction` — тени облаков на источниках) и источники термиков идут за солнцем по часам: `Game._on_sun_changed` — тени облаков для воздуха и солнце по классам поверхности с запаздыванием прогрева (`SurfaceHeating` → `Terrain.set_class_sun`: камни и деревни греют и вечером). Сила и высота термиков по времени дня — `WeatherModel.derive(…, час)`. Кадры: `tools/shots/tod_shot.tscn -- --out=<папка> [--hours=7,13,19]`. Тест — `tests/world/test_sun_clock.gd`. «Подождать час» — `flight-flow.md`.

## Графика

`game.json → graphics` и `graphics_presets` (`low`, `medium`, `high`): каждый пресет — правки конфигов (облака, деревья и их дальность, дальность теней, SSAO/glow, трава, рельеф `variant`) и окна (MSAA, доля разрешения 3D `scale_3d`, FSR, атлас и качество теней); выбор в настройках пишется в `user://configs`. **Автовыбор по видеокарте** (`graphics_autodetect`, включён): при первом запуске, если пресет не выбран, встроенная или программная видеокарта (тип устройства либо подстрока из `low_if_adapter_contains`: Intel, UHD, Iris, Vega, Radeon Graphics, llvmpipe, Mali, Apple и др.) получает «Низкое»; иначе пресет не выбирается (`GraphicsPresets.ensure_detected`, строка `Графика: видеокарта «…» → пресет …` в журнале). Окно и кадры (QL-13) — `menus-settings.md`.

Замеры. Старая таблица FPS по четырём местам (NFR-1/NFR-2, снята до compute-облаков, травы и модели воздуха) здесь убрана как устаревшая. Актуальный профиль кадра на low/medium/high — `docs/perf/frame_profile.md` (`tools/bench/frame_profile.sh`); кадры по отметкам — `tools/bench/frame_bench.sh`, время загрузки — `tools/bench/load_bench.sh`, старт до полёта — `tools/bench/startup_bench.sh` (`--perf`, `cli-tests.md`).
