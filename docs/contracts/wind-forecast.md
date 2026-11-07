---
type: "contract"
status: "active"
module: "wind-forecast"
area: "air"
updated: "2026-11-08"
summary: "Ветер условий = прогноз (10 м над ровной открытой местностью, приток k = 1, один проход); показ «на старте X м/с» из готового поля."
related: ["docs/plan/wind-forecast.md", "docs/contracts/rust-wind/input.md", "docs/contracts/training-island.md", "docs/contracts/air-model/runtime-calibration.md", "docs/guide/air-model/runtime.md"]
contracts: [{"id": "WF-К1", "version": 2}, {"id": "WF-К2", "version": 2}]
---
# Контракты модуля wind-forecast

Владелец всех — координатор wind-forecast; меняет только он (версия +1, потребителям — заметка в карточку).
Контрактные тесты — `tests/contracts/test_wind_forecast_k1.gd`, `…_k2.gd` (фильтр `wind_forecast`); пишет
задача-владелец первым шагом, меняются только вместе с контрактом. Перечень мест файл:строка — аудит WF-1,
`tools/research/wind_forecast/README.md` (§Места, §Запечённые поля и кеш, §Список правок).

## WF-К1. Смысл ветра условий — версия 2
Владелец — задача «Убрать подгонку». Потребители — `AirRuntime`/`DpAir` (условия W5), `StartWeather` (TI-К2),
кеш поля (FL-К1), запечённые поля (TI-К3), меню, наборы стартов.
- Ветер условий (меню, наборы стартов, прогноз; `u10`, `wind_from_deg`, `wind_speed_kmh`/`wind_speed_ms`) — ветер на
  10 м над ровной открытой местностью (стандарт ВМО), то есть приток на границе области с множителем `k = 1`.
- Поле над стартом — результат расчёта; к ветру условий не подгоняется. Загрузка — один проход, `k = 1` всегда
  (решение пользователя 2026-11-08).
- Удаляется (совместимость не нужна; v2 — по аудиту WF-1):
  - условия W5: ключ `inflow_mode` — теперь посторонний ключ → BAD_INPUT (W5 v12);
  - крейт: проходы подбора `k` (`max_passes`, `INFLOW_P`, `next_k`, `k_mem`, `pass_tol`), `inflow_k` в `JobIn`,
    `SolvedField`, `extra`/`meta` записи кеша; `JobReport` — без полей проходов подбора (`planned`, `pass_failed`,
    журнал k); `PassReport` фаз решения остаётся, проход один (`passes.len() == 1`);
  - ключ кеша поля крейта (`field/runtime.rs`): без `"inflow"`; `CACHE_FORMAT` 2 → 3 (старые записи отвергаются);
  - наборы стартов (TI-К2 v3): поле `wind_ref` (`"start"|"inflow"`) удалено из `configs/locations/*.json`, источников
    (`tools/terrain/island/weather_sets.json`, `tools/terrain/volcano/make_config.py`) и разбора `StartWeather`;
  - запечённое поле (TI-К3) снято целиком: `scripts/atmosphere/air_model/air_baked_field.gd` и
    `tests/contracts/test_training_island_k3.gd` удаляются; `model_hash`/`code_hash` (+ `code_hash_of_sources`)
    переносятся без изменения поведения в `scripts/atmosphere/air_model_hash.gd` (класс `AirModelHash`), вызов
    `scripts/atmosphere/air_place_data.gd:240` — оттуда; фикстура `tests/fixtures/wind/baked/` удаляется.
- Шлюз Q1 (до решения не трогать): `wind_ref: {ref_msl, gain_per_km}` прогноза (W5), `game.gd:596`,
  `terms/weather_link.rs`, `formula.rs` `default_ref_msl` и их тесты.
- Инвариант: поле при одном проходе `k = 1` совпадает с прежним режимом `"inflow"` побитно или в допуске W8 v3.

## WF-К2. «На старте X м/с» — версия 2
Владелец — задача «На старте X м/с». Потребитель — экран запуска полёта (место справки по управлению).
- Величина — горизонтальная скорость ветра на 10 м над точкой старта из готового поля (то же поле, что у полёта),
  м/с, округление до 0,1; направление — откуда дует, градусы/румб, если уместно на экране.
- Поля нет (считается) или работает аналитика — строки нет или честное «ветер у старта считается»; число не
  выдумывается из ветра меню.
- Источник (v2): `air.mean_wind_at(Vector3(x, ground + 10, z))` фасада (как `scripts/game/achievement_feed.gd:137-150`),
  скорость — длина (x, z), направление — откуда дует; только когда поле подано (`Atmosphere.is_air_field_on()`), иначе — правило выше.
- Место: подсказка старта `scenes/main.gd` `_start_hint` (текст — `scripts/ui/controls_screen.gd`, ключи `start_hint_*`
  в `locale/ui.csv`); из текста ясно, что меню — прогноз, а у старта — результат расчёта.

## История
- v2 (2026-11-08, аудит WF-1): WF-К1 — точный перечень удаляемого, TI-К3 снят, W5 v12 без `inflow_mode`, кеш
  формата 3; WF-К2 — источник значения и место показа.
