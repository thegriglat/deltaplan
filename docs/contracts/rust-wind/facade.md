---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "W2 rust-wind: фасад Atmosphere (GDScript) — настройка, место, время, фокусы, опрос, описания; v6 — номер прогона в status."
related: ["docs/contracts/rust-wind.md", "docs/contracts/rust-wind/dpair.md", "docs/contracts/rust-wind/trait.md", "docs/contracts/rust-wind/descriptions.md", "docs/research/rust-wind-stage3/rw12z.md"]
contracts: [{"id": "W2", "version": 6}]
---

# W2. Фасад `Atmosphere` (GDScript) (v6)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W2). Менять — только координатор.
Владелец — RW-2 (фасад на текущем коде), RW-7 (выбор реализации). Потребители — `scripts/game/*`, `scripts/glider/*`, визуальные и отладочные потребители из W10, `CalmAir` (`scripts/game/calm_air.gd` реализует тот же набор, ветер 0, состояние READY сразу). Узел игры `air` остаётся `Atmosphere`; всё, что не перечислено ниже, — внутренность реализации (W10).

Константы: `WIND_API_VERSION` (= версии API, W4 `API_VERSION`; с v4 — 4); `STATE_EMPTY/LOADING/READY/FAILED`, коды `OK/BAD_INPUT/NO_PLACE/NOT_READY` (W1); `SAMPLE_FULL := 0`, `SAMPLE_MEAN := 1`; смещения полей описаний `CORE_*`, `CLOUD_*`, `CREST_*` и шаги `CORE_STRIDE`, `CLOUD_STRIDE`, `CREST_STRIDE` (W6).

**Настройка и место**
- `configure(seed: int) -> int` — до первого `load_place`. Фасад сам читает конфиги ветра (`configs/atmosphere.json`, `configs/weather_model.json`, `configs/surface_heat.json`, `configs/weather/*.json`) как текст и передаёт реализации как есть (W5). `seed < 0` → `seed` из `configs/atmosphere.json`.
- `load_place(place: AirPlaceData) -> int` — растры места один раз (W5). Возвращает сразу; тяжёлая подготовка (вход поля, грубый старт, источники термиков) — асинхронно, `state` = LOADING. Повторный вызов = `unload_place()` + загрузка.
- `unload_place() -> void` — сброс всего, что связано с местом (поле, кэши, термики, облака); `state` = EMPTY. Ссылок на данные старого места после вызова нет (класс вылета CR-17).
- `set_conditions(cond: Dictionary) -> int` — погода и ход дня (W5, ключи строго по списку). Не горячий путь. Меняет погоду мягко (подмена за `blend_s` реализации), если место загружено; полная перестройка — только при новом `load_place` или ключе `rebuild: true`.
- `set_sun_direction(to_sun: Vector3) -> void` — единичный вектор на солнце (осей W1); игра зовёт при `sky.clock.sun_changed`. Не задан — реализация считает солнце сама по дате, месту и часу.
- `set_static_thermals(list: PackedFloat32Array, mode: int) -> int` — шаг 4: `[x_m, z_m, strength_ms, radius_m]`; `mode`: `0` dynamic, `1` static, `2` both (как `set_thermal_mode`). Пустой список + `mode = 0` — только динамические.

**Время и готовность**
- `advance_to(t: float) -> int` — продвинуть воздух до `t`. `t` < текущего → BAD_INPUT, состояние не меняется; `t` = текущему → OK, ничего не меняется. Зовётся раз в тик игры (сейчас `air.step(wdt)` в `Game.tick`, `game.gd:272`; сеть — `net.world_dt`). Скачки (ожидание часа, догон по сети) — не через `advance_to`, а `start_at`.
- `start_at(t: float) -> int` — состояние на момент `t`, равное прогону с 0 (`Atmosphere.start_at` сейчас). Асинхронно: `state` = LOADING до готовности; игра ждёт READY на экране загрузки. Допустим в любой момент после `load_place`.
- `pump(budget_us: int) -> void` — дать реализации время главного потока (реализация `gd`: шаги `load_refresh_step` и т. п.; `rust` — ничего не делает). Игра зовёт каждый кадр, пока `state` = LOADING.
- `status() -> Dictionary` — `{state: int, progress: float 0..1, time_s: float, reason: String}`; `is_ready() -> bool` = `state == READY`.
- До READY опросы дают определённый ответ: EMPTY — нули; LOADING — конечный ответ без поля (у `Formula` — аналитика и термики, если готовы); два опроса на одном `t` равны всегда.
- Сигналы: `state_changed(state: int)`; `weather_changed()` — полная перестройка (новое место, `rebuild`); `weather_updated()` — мягкая смена погоды (то, что сейчас ловят `game.gd:178`, `dust_devils.gd`, `gust_dust.gd`).

**Фокусы**
- `set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int` — точки внимания (пилот, боты, другие игроки) с весом > 0; индекс 0 — игрок; размеры равны, иначе BAD_INPUT. Игра зовёт перед `advance_to`, если фокусы сдвинулись. Детализацию у точки выбирает реализация (окна, генерация термиков вокруг, коробки живого воздуха). Пусто — фокус в (0, 0) места. `focus_node`/`set_focus(node)` и `AirRuntime.set_focus` уходят (RW-3).

**Опрос**
- `sample_many(points: PackedVector3Array, mode: int = SAMPLE_FULL) -> PackedFloat32Array` — длина 4N: `[vx, vy, vz, σ]` на точку, в порядке входа. `SAMPLE_FULL` — полный ветер (поле, аналитика, термики, гроза/волны/облака, болтанка и порывы). `SAMPLE_MEAN` — без неразрешённой болтанки и порывов (σ всё равно отдаётся); то же, что `SAMPLE_FULL` при выключенных болтанке и порывах (у `gd` — `air_velocity_at` при `turbulence_enabled = false`; так сняты фикстуры RW-1); прежние `mean_wind_at` + вертикаль (`debug_overlays.gd:282`, `terrain_wind.gd`) переходят на него. Пустая пачка → пустой массив.
- `sample(pos: Vector3, mode: int = SAMPLE_FULL) -> Vector4` — одна точка, `(vx, vy, vz, σ)`; для редких вызовов.
- Обёртки фасада (без пары в W3): `air_velocity_at(pos) -> Vector3` = `sample(pos).xyz` (на нём `air_fn` модели полёта и прочих, `game.gd:409`); `mean_wind_at(pos) -> Vector3` = `sample(pos, SAMPLE_MEAN).xyz`; `turbulence_intensity_at(pos) -> float` = `sample(pos).w`; `thermals_near(pos, radius) -> Array[Dictionary]` — из `cores` (W6) в прежнем виде (`terrain_wind.gd:158`).
- `cloud_density_many(points: PackedVector3Array) -> PackedFloat32Array` (0..1 на точку) и обёртка `cloud_density_at(pos) -> float` (`game.gd:232`, `sun_glare.gd`, `cloud_whiteout`).
- `cloudbase_msl() -> float` (м MSL; обёртка `get_cloudbase_msl()`).
- `background_wind(heights_msl: PackedFloat32Array) -> PackedFloat32Array` — длина 2N `[vx, vz]`: фоновый (синоптический) ветер по высоте без рельефа и термиков; для визуальных потребителей (`cirrus_layer.gd`, дрейф облаков, `gust_dust.gd`, `bird_flock.gd`) вместо `wind.vec2_at(h)`/`wind.dir`/`speed_at`.
- `weather() -> Dictionary` — выведенная погода (ключи пресета + `_derived`, как сейчас `atmo.weather`; копия, только чтение); меняется только с сигналами `weather_*`. Видимое: `cirrus_cover`, `haze_k`, `_derived.valley_msl_m`, `lens_level_above_crest_m` и т. п.
- `sun_state() -> Vector4` — `(to_sun.x, to_sun.y, to_sun.z, insolation 0..1)` на текущий `t` (вместо `get_insolation`).

**Описания и отладка** — W6, W7 (методы фасада: `cores`, `clouds`, `cloud_raster`, `cloud_raster_version`, `wave_crests`, `decompose`, `debug_raster`, `debug_raster_names`).

**v2 (итог RW-3a):**
- `status()` += `stage: String` (подпись этапа для экрана загрузки, «» — нет) и `field_on: bool` (реализация ведёт поле Пикара; вместо `is_air_field_on()`); прежние ключи RW-3a `wind`/`wind_progress` → `stage`/`progress` (RW-3c).
- **v3 (решение пользователя 2026-10-27):** `status()` += `iters: int` — число итераций решателя поля, выполненных в текущем этапе `stage` (с начала этапа; этап без итераций — 0); в пределах этапа не убывает, обновляется не реже чем через 10 итераций; новый этап — с 0. Экран подготовки воздуха показывает его рядом с этапом (хотя бы десятками): на медленном CPU видно, что расчёт идёт; `progress` у итерационного решателя заранее не известен.
- `static place_from_terrain(terrain, …) -> AirPlaceData` — сборка входа W5 корутиной по кадрам (`await`), без второго снимка поверхности; единственный путь игры к `AirPlaceData`.
- `weather()` — до RW-3c рядом живёт поле `weather` и переходный `get_weather()`; RW-3c последним шагом делает поле внутренним, `get_weather()` → `weather()` у всех читателей.
- `mean_wind_at(pos)` = `sample(pos, SAMPLE_MEAN).xyz` (с вертикалью), как в v1; кому нужна горизонталь — берёт x, z сам.
- Фокусы: индекс 0 — игрок; боты и игроки сети — по желанию игры, `gd` использует только индекс 0.
- Переходное до RW-13 (в W3/W4 нет): `refresh_scale` (ускорение догона на экране ожидания), `start_at` без места — синхронно, `focus_node`/`set_focus`/`get_focus` и `configure(Variant, Variant)` — только для тестов и превью до RW-3c.

**Переходное (только RW-2…RW-12, удаляется в RW-13; в W3/W4 нет):** реализация `gd` может держать прежние входы — `set_ground(height_fn, sun_fn, surface_fn)`, `set_day(AtmoDay)`, `set_wind(...)`, `set_weather(...)` — фасад сам выводит их из `load_place`/`set_conditions` (игра их больше не зовёт после RW-3). Переключателя `air.backend` нет (W9 v2): поле — только из крейта (RW-7).
- **Режим поля (уточнение 2026-10-29, без смены версии; RW-7; удалён в v5):** прежний метод фасада `set_air_mode(mode: String)` (`"auto" | "on" | "off"`, пункт настроек «Эвристика») и ключ `air_model.enabled` в `configs/atmosphere.json` отображаются в `DpAir.set_field_enabled` (W3 v4): `off` → `false`; `on` → `true`; `auto` → `true`, кроме headless (`DisplayServer.get_name() == "headless"`) — там `false`, как сейчас: в headless-тестах поле не считается, тесты, которым оно нужно, ставят `on`.

- **v4 (2026-10-29, переход фасада RW-12z; проект — `docs/research/rust-wind-stage3/rw12z.md`):**
  - Константы += `OBJ_STRIDE := 22` и смещения `OBJ_ID … OBJ_STORM_K` (0…21, W6 v4); `WAVE_INFO_ENABLED := 0`, `WAVE_INFO_LENGTH := 1`. `WIND_API_VERSION = 4`.
  - `cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array` — объекты-облака для рисования, `OBJ_STRIDE` на запись (поля, охват — W6 v4). `t` — момент атмосферы; вне окна `[now − fade_out_s, now]` — ближайшая граница. Нет места или не READY — пусто.
  - `wave_info() -> PackedFloat32Array` — `[enabled, wavelength_m]` (W6 v4); нет места или не READY — `[0, 0]`.
  - `surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array` — порыв на 10 м для пыли, м/с, длина `min(len(xz), len(t))`; ветер и `convective_turbulence_ms` — на момент вызова, `t` — только фаза шума (W6 v4). Не READY — нули. Зовётся пачками (клетки видимой пыли), не по точке.
  - `thermals_near(pos, radius) -> Array[Dictionary]` — обёртка над `cores(pos, radius)`: словарь на ядро с ключами `x`, `z` (м), `y_src`, `top`, `w`, `radius`, `age_s`, `life_s`, `stage`, `id`, `static` (бит 0 флагов), `has_cloud` (бит 1), `is_cb` (бит 2); охват — как у `cores` (W6), а не «все термики поля».
  - `start_at(t)`: «равное прогону с 0» заменяется на — состояние как `Atmosphere.start_at` опорной ревизии GD (W8): детерминировано (одно `t` — один ответ; два опроса на одном `t` равны); без облачной петли (облака выключены) — равно прогону с 0; с облаками — поле облаков после `start_at` — сброс на входах момента `t` с разгоном, термики — без тени облаков на момент сборки (как GD; `cover` до 0,07, число термиков до 2 % против прогона с 0 — RW-10f, RW-11d). Контрактный тест T6 — равенство прогону с 0 на конфигурации без облаков; с облаками — детерминизм.
  - Режим поля `off`: крейт считает аналитику (`WindModel`, линия тени, склоновый подъём, подветренный поток) без поля и без полосы края; термики, облака, гроза и волны включены.
  - Реализация — `DpAir` целиком: `sample_many`/`sample`, `cloud_density_many`, `cloudbase_msl`, `background_wind`, `weather` (разбор `weather_json` по `weather_version`), `sun_state`, `cores`, `clouds`, `cloud_raster(_version)`, `wave_crests`, `decompose`, `debug_raster*` — из крейта; `pump` — пустой; `status().field_on` — по `DpAir`. Сигналы `weather_updated`/`weather_changed` — по росту первого/второго числа `weather_version` (W4 v6).
  - Переходное: после RW-12z у фасада и тестов-потребителей нет `air.wind`, `air.ground`, `air.cloud_phys`, `air.storm`, `air.wave`, `air.field`, `set_ground/set_day/set_wind/set_weather/set_air_field`, `step`; файлы GDScript-слагаемых удаляет RW-13. `refresh_scale`, `focus_node`, `configure(Variant, Variant)` — как в v2, до RW-13.

- **v5 (2026-10-29, решение пользователя: упрощённый режим ветра убрать):** `WIND_API_VERSION = 5`. Режима поля нет: удалены `set_air_mode`, ключ `air_model.enabled` в `configs/atmosphere.json` и его чтение, пункт настроек «Ветер над рельефом» (`settings_wind_model*`) и сохранённое значение, ветка `off` в фасаде, `DpAir.set_field_enabled` (W3 v6). Поле Пикара на месте считается всегда, в том числе в headless (тесты, которым поле не нужно, берут `CalmAir` или маленькое место/запечённое поле). Остаются, это не режим: FAILED (подготовка не удалась — опросы по запасному пути, W1) и «нет расширения — ветер без поля» (W9, до RW-13). Абзац «Режим поля» и пункт v4 «Режим поля `off`» не действуют.
- **v6 (2026-10-30, решение пользователя: экран загрузки):** `WIND_API_VERSION = 6`. `status()` += `run: int`, `runs: int` (W4 v9): прогон — вход задачи поля в этап с итерациями решателя (`coarse`, `solve_mech`, `solve_heat`, в каждом проходе `max_passes`); `iters` при каждом входе считается с нуля. `run` — номер текущего прогона с 1 (0 — этапа с итерациями сейчас нет); `runs` — число прогонов по текущему плану задачи, `runs ≥ run` (может вырасти, когда понадобился следующий проход; 0 — этапа с итерациями нет). `CalmAir`: `run = runs = 0`. Экран загрузки (`scripts/game/game.gd`): подпись этапа — своей строкой; итерации — отдельной строкой «Итерация: N»; при `runs > 1` — «Прогон r из n · Итерация: N».
