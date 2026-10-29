---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "Граница ветра в Rust: фасад Atmosphere, DpAir (gdext), трейт dp-air, место, описания, разложение, допуски, сборка, чистота."
related: ["docs/plan/rust-wind.md", "docs/contracts/picard-rs.md", "docs/plan/rust-air-integration.md", "docs/plan/rust-ext.md", "docs/plan/air-cascade.md", "tools/research/rust_ext/gdext_probe/README.md", "docs/contracts/rust-wind/fixtures-tolerances.md", "docs/contracts/rust-wind/descriptions.md", "docs/contracts/rust-wind/solver.md", "docs/contracts/rust-wind/trait.md", "docs/contracts/rust-wind/dpair.md", "docs/contracts/rust-wind/facade.md"]
contracts: [{"id": "W1", "version": 2}, {"id": "W2", "version": 4}, {"id": "W3", "version": 5}, {"id": "W4", "version": 6}, {"id": "W5", "version": 8}, {"id": "W6", "version": 4}, {"id": "W7", "version": 1}, {"id": "W8", "version": 2}, {"id": "W9", "version": 2}, {"id": "W10", "version": 2}, {"id": "W11", "version": 11}]
---

# Контракты модуля rust-wind

План — `docs/plan/rust-wind.md`. Менять — только координатор: версия +1, запись в «Историю», `task note` потребителям, их правка в том же шаге. Исполнитель, которому контракт мешает, пишет `<ID> contract: <что поменять>`, сам не меняет.

Слои границы (сверху вниз): игра → **фасад `Atmosphere`** (W2, GDScript) → реализация (до этапа 3 — смешанная: поле Пикара из крейта, прочие слагаемые на GDScript; переключателя `gd | rust` нет, решение пользователя 2026-10-27) → **класс `DpAir`** (W3, крейт `dp-gd`, gdext) → **трейт `AirModel`** (W4, крейт `dp-air`, без Godot). Игра видит только W2. W3 и W4 — одна и та же семантика, W3 — её отображение в типы Godot. Формульная модель (`Formula`) и будущий живой воздух (`Live`) — две реализации W4; смена реализации не меняет W2–W3.

Контрактные тесты (пишутся первыми, красные до кода):
- GDScript — `tests/contracts/test_rust_wind_contracts.gd` (T5, T6 уровня фасада; T7 — чистота W10) — первым шагом RW-2; с RW-7 он идёт на реализации с полем из крейта (второго прогона нет).
- Rust — `rust/dp-air/tests/contract.rs` (T5, T6 на трейте, на заглушке и на `Formula`) и `rust/dp-gd/tests/` (версия, разбор массивов) — первым шагом RW-4.
- Версия: константа `Atmosphere.WIND_API_VERSION`, `DpAir.api_version()` и `dp_air::API_VERSION` равны версии W2 здесь (с W2 v4 — 4); тест сверяет с заголовками этого файла (как `test_air_contracts.gd`: `CONTRACTS` против заголовков `## Wn … (vK)`).

## W1. Соглашения (v2)
Владелец — координатор. Потребители — все слои.
- **Оси мира:** X — восток, −Z — север, Y — вверх; **Y = высота над уровнем моря (MSL)**, метры (`docs/guide/architecture.md`). AGL на границе не передаётся: где нужна высота над землёй — реализация берёт её из рельефа места (W5).
- **Скорость** — м/с в осях мира: `(vx, vy, vz)`, `vy` — вертикальная (подъём > 0). км/ч — только во входе прогноза (W5, `wind_speed_kmh`), как сейчас.
- **Направление ветра** во входе — `from_deg`, откуда дует: 0 — с севера, по часовой. Ветер с севера дует к +Z (`WindModel.dir = (−sin d, 0, cos d)`, `wind_model.gd:111`).
- **Сетки растров** (W5, W6): узлы, `origin_x`, `origin_z` — координаты узла (0, 0) в осях мира, `spacing` м, `width` — узлов по X, `height` — узлов по Z; строка `j` растёт к +Z (север → юг), индекс `j * width + i`. Внутренние сетки реализации (`y = −Z`, как в `WindField`) наружу не выходят.
- **Время** `t` — секунды игрового времени от начала полёта на месте (`Atmosphere.time_s` сейчас), `float` (f64 в Rust). Час суток выводит реализация из условий (W5: `start_hour`, `speed`). Реальное время кадра на границе не появляется.
- **σ** — среднеквадратичная скорость **неразрешённой** болтанки в точке, м/с (≥ 0, изотропная оценка, как `_last_sigma` сейчас). У живого воздуха крупные вихри — в скорости, σ — только подсеточная часть.
- **Числа на выходе всегда конечны.** NaN/±inf во входной точке → для неё `(0, 0, 0, σ = 0)`. Точка вне области места → конечный ответ реализации (у `Formula` — аналитика без поля), без разрыва на краю (T2).
- **Ошибки.** Ни один вызов не роняет игру (`panic = "abort"` в релизе — значит, входы проверяет граница до расчёта). Команды (W2/W3) возвращают `int`-код: `0` OK, `1` BAD_INPUT (вход отвергнут, состояние не изменилось), `2` NO_PLACE (место не загружено), `3` NOT_READY (идёт загрузка/разгон, команда принята в очередь или не нужна). Текст — `last_error() -> String` (последняя ошибка, пусто — нет). Опросы ошибок не возвращают — отдают определённый ответ (ниже по каждому).
- **Состояние** `state`: `0` EMPTY (нет места), `1` LOADING (подготовка места или разгон `start_at`), `2` READY, `3` FAILED (подготовка не удалась; опросы работают по запасному пути реализации — у `Formula` аналитика без поля, — `last_error()` объясняет). FAILED не заразен: следующий `load_place` начинает с нуля.
- **Детерминизм.** Один вход (место, конфиги, условия, сид, фокусы, последовательность `advance_to`) → одни выходы. От числа потоков (2/4/20) выход не зависит в допусках W8; желательно побитно. Ради тестов и отладки, не ради сети.
- **Детерминированный режим (v2):** ключ `air.deterministic` в `configs/atmosphere.json` (по умолчанию `false`; тесты, стенд, фикстуры — `true`). При `true` всё, что делается в фоне (пересчёт поля на сроке, проходы `k`, окна), подаётся в игровой момент, заданный только игровым временем и входом (срок `recompute_game_min` и т. п.): `advance_to` на этом моменте ждёт готовности фоновой задачи. При `false` (игра) главный поток не ждёт (W3), подача — по готовности, и выход зависит от скорости машины. Тот же порядок держит генератор фикстур RW-1b.
- **Сеть — не цель** (решение пользователя 2026-10-25): у каждого клиента свой воздух от общей погоды и сида; выгрузки/загрузки состояния воздуха и синхронизации нет. Нынешняя синхронизация термиков и `CloudField` в `net_flight.gd` (`air_forced_sig`, `set_air_forced`, `air_sources_mask`, `apply_net_snapshot`) удаляется в RW-3, не переносится.
- **Колбэков из крейта в Godot нет.** `height_fn`, `surface_fn`, `sun_fn`, `AtmoDay.weather_fn/sun_fn/source_fn` — не часть W3/W4; всё нужное — данными (W5).

## W2. Фасад `Atmosphere` (GDScript) (v4)
Владелец — RW-2 (фасад), RW-7 (режим поля), RW-12z (переход на `DpAir`). Потребители — `scripts/game/*`, `scripts/glider/*`, визуальные и отладочные потребители (W10), `CalmAir`. Методы, константы, сигналы, история v2–v4 — `docs/contracts/rust-wind/facade.md`.

## W3. Класс `DpAir` (gdext, крейт `dp-gd`) (v5)
Владелец — RW-4 (каркас, заглушка `Calm`), RW-6…12 (наполнение), RW-7 (режим поля, выдача поля фасаду), RW-12z (описания W6 v4 на фасаде). Потребитель — фасад, контрактные тесты. Методы, потоки, жизненный цикл, история v2–v4 — `docs/contracts/rust-wind/dpair.md`.

## W4. Трейт `AirModel` (крейт `dp-air`, без Godot) (v6)
Владелец — RW-4 (трейт, `Calm`), RW-6…12 (`Formula`), живой воздух (`Live`). Потребители — `dp-gd`, стенд RW-5, `cargo test`, `cargo bench`. Трейт, типы, порядок команд, структуры описаний — `docs/contracts/rust-wind/trait.md`.

## W5. Вход: место, конфиги, условия (v8)
Владелец — RW-2 (сборка `AirPlaceData`), RW-4 (разбор в крейте). Потребители — W2–W4, фикстуры W8. `AirPlaceData`, конфиги, условия и история версий v2–v8 — `docs/contracts/rust-wind/input.md`.

## W6. Описания — найденное, а не заданное (v4)
Владелец — RW-2 (из текущего кода), RW-10/RW-11 (из крейта). Поля, шаги `CORE_STRIDE`/`CLOUD_STRIDE`/`CREST_STRIDE`, растр облаков, гребни и инвариант найденного ядра — `docs/contracts/rust-wind/descriptions.md`.

## W7. Разложение для отладки (v1)
Владелец — RW-2 (`gd`), RW-6…12 (крейт). Потребители — `wind_field_debug.gd`, `debug_overlays.gd`, `atmo_fingerprint.gd`, фикстуры W8 (второй набор, по слагаемым), стенд RW-5.
- `decompose(pos: Vector3) -> Dictionary` — `{names: PackedStringArray, vel: PackedVector3Array, sigma: PackedFloat32Array, total: Vector4}`; набор и имена слагаемых — у реализации, не в контракте (у `Formula` ожидаемо: `field`, `analytic`, `ridge`, `thermal`, `storm`, `wave`, `cloud`, `turb`, `gust`; у живой — свои).
- Инварианты: `total` = `sample(pos, SAMPLE_FULL)` побитно в одном `t`; `Σ vel` = `total.xyz` с точностью 1e-4 м/с (вклады уже со своими весами, в т. ч. полосы `a < 1`); `sigma[i]` — справочно, `total.w` — как у `sample`.
- `debug_raster_names() -> PackedStringArray`; `debug_raster(name) -> Dictionary {nx, ny, dx, x0, z0, data: PackedFloat32Array}` — растры для оверлеев (поток тепла F7, карта фаз F4 и т. п.); неизвестное имя → `{}`.
- Отладка не в горячем пути; `Dictionary` допустим.

## W8. Фикстуры T1 и допуски (v2)
Владелец — RW-1 (снимает на текущем коде до правок атмосферы), RW-2 (второй набор — по слагаемым W7). Потребители — `cargo test` (RW-6…12), GDScript-тесты T7. Формат фикстур `tests/fixtures/wind/`, допуски T1 по величинам (решение вопроса 3 плана) и пороги скорости — `docs/contracts/rust-wind/fixtures-tolerances.md`.

## W9. Workspace, сборка, поставка (v2)
Владелец — RW-4. Потребители — все задачи крейта, `tools/build.sh`, главная сессия (сборка). Опора — только проба `tools/research/rust_ext/gdext_probe/` (README, `run.sh`, крейт, минимальный проект; уточнение пользователя 2026-10-26); правила крейта — R3 v4 picard-rs (без asm/интринсиков, `multiversion`, f32 в расчёте и f64 в редукциях, `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`).
- `rust/Cargo.toml` — workspace: `dp-air` (lib, без Godot), `dp-gd` (`cdylib`, `godot = "0.5.5"`, фича `api-4-7`), Пикар из `tools/research/air_cascade/picard_rs/` (переносится, история — `git mv`; исследовательские CLI и тесты сохраняются). В `rust/` — `.gdignore`.
- **Профили** (решение пользователя 2026-10-26):
  - `dev` — `cargo test`, -O0;
  - `tune` — разработка и настройка игры: `inherits = "dev"`, `opt-level = 2`, `debug = true`, без LTO, `codegen-units` по умолчанию, `incremental = true`;
  - `release` — только выпуск: `opt-level = 3`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`.
- `.gdextension` — `res://addons/dp_air/dp_air.gdextension`, `compatibility_minimum = "4.7"`, ключи: `linux.debug.x86_64` → библиотека `tune`, `linux.release.x86_64` → `release`; Windows и macOS — так же (`windows.*.x86_64`, `macos.*` универсальный). Бинарники — `res://addons/dp_air/bin/` (в `.gitignore`), кладёт `tools/build.sh` (или `tools/build_rust.sh tune|release`), в git не идут. Редакторный бинарь Godot берёт ключ `debug` (грабли пробы).
- `tools/build.sh <ОС>` для выпуска собирает `release` под ОС до экспорта; игра в разработке и тесты — `tune`. Windows с Linux — `cargo-xwin` или `cargo-zigbuild` (выбор и проверка — RW-4); macOS — сборка с Linux, если выйдет, иначе вопрос пользователю (шлюз); запуск на Mac — у друга.
- Нет бинарника под ОС → поле Пикара не считается (как отказ поля: ветер без поля — аналитика и прочие слагаемые), журнал «dp_air: нет расширения, ветер без поля» (до RW-13, v2: прежний запасной `air.backend = gd` убран вместе с переключателем); после RW-13 — экран ошибки, не вылет.
- Первый `--import` проекта с расширением падает (грабли пробы) — скрипты и тесты импортируют дважды.
- Дымовой тест поставки: экспортированная сборка Linux, headless, временный профиль: расширение загрузилось, `DpAir.api_version()` = версии W2, на месте после READY ветер ≠ 0.

## W10. Чистота границы (v2)
Владелец — RW-2 (тест), RW-3 (перевод потребителей). Тест T7 в `tests/contracts/test_rust_wind_contracts.gd`.
- Вне файлов реализации (`scripts/atmosphere/**` кроме перечисленных ниже потребителей, плюс `scripts/atmosphere/air_model/**`) запрещены обращения: `.field.`, `.field\b` у узла воздуха, `.wind.`, `.ground.`, `.cloud_phys`, `.wave.`, `.storm.`, `.air_field`, `_ground_ref`, `_rmin`, `_last_sigma`, `AirRuntime`, `ThermalField`, `WindField`, `WindModel`, `GroundField`, `CloudPhysics`, `CloudField`, `AtmoThermal`, `AirFieldSet`, `step(`, `time_s =`, `set_air_field`, `set_ground`, `set_day`, `set_wind`, `set_weather` (на узле воздуха).
- Потребители внутри `scripts/atmosphere/` подпадают под запрет так же: `cloud_layer.gd`, `cloud_shadow_map.gd`, `cirrus_layer.gd`, `gust_dust.gd`, `dust_devils.gd`, `bird_flock.gd`, `thermal_signs.gd`, `atmo_fingerprint.gd`, `atmosphere_preview.gd`, `wind_field_debug.gd`, `debug_overlays.gd` (где бы ни лежали), а также `bot_pilots.gd`, `net_flight.gd`, `terrain_wind.gd`, `game.gd`.
- Список файлов реализации тест держит явным (RW-2 фиксирует); новый файл реализации — правка теста и W10 через координатора.
- Тесты в `tests/` под запрет не подпадают, но тесты поведения через `Atmosphere` после RW-3 пользуются фасадом (T7).

- **v2 (решение пользователя 2026-10-27):** `dp-air` — самостоятельная библиотека погоды и воздуха: без Godot и без игрового — камеры, сети, ботов, игроков, UI, меню, экранов загрузки (в типах, именах и логике). Вход — место, конфиги, условия, время, фокусы как точки с весами; всё игровое — только в `dp-gd` и Godot. Проверка: `cargo tree -p dp-air -e normal` без `godot`; ревьюер задач крейта проверяет это правило при каждой правке `dp-air`.
## W11. Решатель Пикара в крейте (v11)
Владелец — RW-6g, RW-6h. Потребители — RW-6j, RW-6n, фазы RW-6k–6m. R6 v3 + заморозка колонн, отмена, `AllFrozen`/`Cancelled` — `docs/contracts/rust-wind/solver.md`.

## История
- v1 (2026-10-26, RW-0) — заведены до первых исполнителей; допуски T1 (вопрос 3 плана) — W8.
- W4 v2 (2026-10-26, ревью RW-4) — `out` заменяется; порядок команд до места и сброс при `unload_place`; `t < 0` — `BadInput`; поля `Core`/`Cloud`/`Crest`/`Raster`. Потребители: `dp-gd` (RW-4b), `Formula` (RW-6…12), стенд RW-5.
- W6 v2 (2026-10-26, итог RW-1) — `id` в `[0, 2²⁴)`; инвариант ядра — местный избыток подъёма против кольца 2–3·radius, ядра Cb исключены. Потребители: RW-2 (фасад `gd`), RW-4b (общий suite contract.rs), RW-5 (compare — по ближайшему). Уточнение W2 без смены версии (норматив прежний — «без неразрешённой болтанки и порывов»): `SAMPLE_MEAN` — весь ветер, как `SAMPLE_FULL` при выключенной болтанке и порывах (поле, аналитика, термики, гроза, волна, облака), не «`mean_wind_at` + вертикаль поля»; так сняты фикстуры RW-1.
- W5 v2 (2026-10-26, разбор RW-6a) — ключ условий `inflow_mode`. Потребители: RW-4b/dp-air (разбор `Conditions`), RW-2 (фасад), RW-6j.
- W5 v3 (2026-10-26, итог RW-6c) — `loc.climate` в заголовке места (ячейка климата у центра). Потребители: RW-2 (`AirPlaceData`), RW-1b (фикстуры мест), dp-air (`PlaceHeader`, `field_weather` — климат из заголовка вместо трейта `Climate`).
- W5 v4, W3 v2 (2026-10-26, постановка RW-6p) — запечённые поля места данными (`AirPlaceData.baked`, `DpAir.add_baked_field`), кеш полей — каталог реализации (`DpAir.set_cache_dir`). Потребители: RW-6p (разбор, выбор, кеш в dp-air), RW-6j/RW-7 (dp-gd и фасад), RW-2-фасад (`AirPlaceData.baked` — в RW-7).
- W11 v1 (2026-10-26, постановка RW-6g) — решатель в крейте: заморозка колонн и отмена поверх R6 v3 (picard-rs закрыт, расширение — здесь).
- W6 v3 (2026-10-26, ревью RW-2) — инвариант найденного ядра только для `w ≥ 1,5 м/с`; охват описаний — вокруг фокусов. Потребители: RW-2, RW-3, RW-10.
- W11 v2 (2026-10-26, итог RW-6g) — равенство замороженных колонн полю заморозки — до `finalize`; `finalize` — как в игре, без маски.
- W11 v3 (2026-10-26, постановка RW-6h) — запасные правила сходимости (`Fallback`, `NonConv`), флаги в `Solved`; `AllFrozen` при отмене до старта — с фоном.
- W1 v2 (2026-10-26, постановка RW-6j) — детерминированный режим `air.deterministic`.
- W11 v4 (2026-10-26, постановка RW-6r) — C_d стенки по столбцу (`Case.cd_col`); отсчёт порогов запасных правил как в игре.
- W11 v5 (2026-10-26, ревью RW-6r, итог RW-6m) — `cd_col` с ореолом; счёт итераций и останов по `max_iters` как в игре; `FrozenField.thd` необязателен.
- W11 v6 (2026-10-26, ревью RW-6j) — отмена и в подготовке решения.
- W4 v3, W5 v5 (2026-10-26, постановка RW-6t) — `AirModel::add_baked_field`/`set_cache_dir` (как W3 v2), `header.model_hash`. Потребители: RW-6t (Formula, dp-gd), RW-7 (фасад).
- W11 v7 (2026-10-26, RW-6n) — граница от родителя (`Case.nest`) и старт окна (`SolveOpts.init_cycles`). Потребители: RW-6n, RW-6o.
- W5 v6 (2026-10-26, ревью RW-6t) — `start_sites[].id/weather`, `header.data_hash`; выбор запечённого как `baked_lookup`; W5 вынесен в `rust-wind/input.md`. W11 v8 — отмена до вызова всегда `Cancelled`. Потребители: RW-7 (фасад и разбор в крейте).
- W2 v2 (2026-10-26, итог RW-3a) — `status().stage/field_on`, `place_from_terrain`, порядок переименования `weather`, переходные входы. Потребители: RW-3b, RW-3c, RW-7.
- W11 v9, W5 v7 (2026-10-27, итог RW-6q, решение пользователя о таймауте) — стенки и клетки земли обнуляются при тёплом старте как `K_BC`; `loc.climate_lag` (климат на дату сдвига воды); `air.timeout_s` удалён — поле в крейте без предела по времени. Потребители: RW-6v (крейт, фасад, места фикстур), RW-6q (T1), RW-7.
- Уточнение W1/W3 без смены версии (2026-10-27, RW-0f): `WIND_API_VERSION`, `api_version()`, `API_VERSION` = версии W2 (2 с W2 v2), не 1 — так требовало и правило W1 «равны версии W2». Потребители: RW-0f (крейт, dp-gd), RW-3a (константы фасада и `CalmAir`).
- W9 v2, уточнение W1 (2026-10-27, решение пользователя: переключатель `gd | rust` убран) — поле в игре только из крейта (RW-7); нет расширения — ветер без поля, не запасной GD-расчёт. Потребители: RW-7, RW-3a/3c (тесты фасада).
- W2 v3, W3 v3, W4 v4, W10 v2 (2026-10-27, решения пользователя) — счётчик итераций этапа в статусе (`iters`, W3 `stage()`/`iters()`, W4 `Status.stage/iters`); `dp-air` без игрового. Версия API = 3. Потребители: RW-6y (крейт, dp-gd, константы версий и контрактные тесты), RW-3c (реализация `gd` и экран загрузки), RW-7.
- W11 v10 (2026-10-27, итог RW-6y) — `SolveOpts.progress` (счётчик итераций по ходу решения) для `Status.iters` W4 v4. Потребители: RW-6y, RW-3c (через `DpAir.iters()`).
- W3 v4, W4 v5, уточнение W2 без смены версии (2026-10-29, постановка RW-7) — режим поля `set_field_enabled` (W2 «Режим поля»: `auto` в headless — без поля), переходная выдача поля фасаду `field_export*`/`field_version` (TI-К3 v3 без потерь) для GDScript-слагаемых до их переноса. Версия API не меняется (= W2 v3). Потребители: RW-7a (крейт, `dp-gd`, контрактные тесты), RW-7b (фасад).
- W5 v8 (2026-10-29, разбор RW-8a) — сырая ячейка климата `loc.climate_cell`/`climate_cell_lag` (поправки на высоту — в крейте), конфиг `world` в `configure`. Потребители: RW-12b (фасад `AirPlaceData`, крейт `derive`/`ClimateGrid.place`, места фикстур), RW-10c (правило скал, `surface.thermal.edge_*`), RW-12c (`AtmoDay`, часы 6…21).
- W11 v11 (2026-10-29, итог RW-U2) — θ′_d замороженных колонн решения с нагревом := θ′ механизма (`thd = Some(th)`), K — своего случая; θ′, θ′_d во всех не-неизвестных клетках — как `K_BC`. Потребители: RW-U4 (`dp-air` assembly, `picard_rs` граница, тесты), RW-7 (без изменений интерфейса).
- W8 v2 (2026-10-29, ответ пользователя на Q1, итоги RW-6z/U1/U2, предложения RW-8a) — допуск T1 поля по классам клеток (`mech` 1 % |U| + 0,01 м/с, `conv` как v1, `nonconv` 15 %), статус решателя эталона `meta.solver`, эталоны с ошибкой GPU (landing_hill, thermal_slope); число ядер ≤ 2 на момент и ≤ 3 %, `above_base` после RW-11, случай `off`, `cases/<имя>.weather.json`. Потребители: RW-6u (T1 по классам, перепечатка landing_hill), RW-2c, RW-10*, RW-11*, RW-12* (эталоны этапа 3).
- W6 v4 (2026-10-29, проект RW-11a) — объекты-облака `cloud_objects` (шаг 22, момент `t`), `wave_info`, `surface_gust_many`, `Core.storm`; методы W2–W4 — с RW-12z. Потребители: RW-11d, RW-11e, RW-8/9, RW-12z; `tests/contracts/test_rust_wind_contracts.gd` `CONTRACTS.W6 = 4` — первая задача, трогающая файл (RW-11e).
- W2 v4, W3 v5, W4 v6 (2026-10-29, переход фасада RW-12z; проект RW-12y — `docs/research/rust-wind-stage3/rw12z.md`) — W2 вынесен в `rust-wind/facade.md`; методы W6 v4 `cloud_objects`/`wave_info`/`surface_gust_many` во всех трёх слоях, `ObjRecord` в корне крейта, `thermals_near` из `cores`, формулировка `start_at` (как GD, равенство прогону с 0 — без облачной петли), режим `off` в крейте, порог `weather_version`, реализация фасада — `DpAir` целиком. Версия API = 4. Потребители: RW-12u (версия 4, методы трейта с умолчаниями), RW-12v (`Formula`), RW-12w (`dp-gd`), RW-12x (фасад, `test_rust_wind_contracts.gd`), RW-12z (`cloud_layer.gd`, `gust_dust*.gd`, храповик; RW-11e влита сюда); в rw12z.md — 12za…12zd соответственно (12za шаг 1 = RW-12u).
