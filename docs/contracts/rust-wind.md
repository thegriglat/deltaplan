---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "Граница ветра в Rust: фасад Atmosphere, DpAir (gdext), трейт dp-air, место, описания, разложение, допуски, сборка, чистота."
related: ["docs/plan/rust-wind.md", "docs/contracts/picard-rs.md", "docs/plan/rust-air-integration.md", "docs/plan/rust-ext.md", "docs/plan/air-cascade.md", "tools/research/rust_ext/gdext_probe/README.md", "docs/contracts/rust-wind/fixtures-tolerances.md", "docs/contracts/rust-wind/descriptions.md", "docs/contracts/rust-wind/solver.md"]
contracts: [{"id": "W1", "version": 1}, {"id": "W2", "version": 1}, {"id": "W3", "version": 1}, {"id": "W4", "version": 2}, {"id": "W5", "version": 3}, {"id": "W6", "version": 3}, {"id": "W7", "version": 1}, {"id": "W8", "version": 1}, {"id": "W9", "version": 1}, {"id": "W10", "version": 1}, {"id": "W11", "version": 3}]
---

# Контракты модуля rust-wind

План — `docs/plan/rust-wind.md`. Менять — только координатор: версия +1, запись в «Историю», `task note` потребителям, их правка в том же шаге. Исполнитель, которому контракт мешает, пишет `<ID> contract: <что поменять>`, сам не меняет.

Слои границы (сверху вниз): игра → **фасад `Atmosphere`** (W2, GDScript) → реализация `air.backend = gd` (текущий код) или `rust` → **класс `DpAir`** (W3, крейт `dp-gd`, gdext) → **трейт `AirModel`** (W4, крейт `dp-air`, без Godot). Игра видит только W2. W3 и W4 — одна и та же семантика, W3 — её отображение в типы Godot. Формульная модель (`Formula`) и будущий живой воздух (`Live`) — две реализации W4; смена реализации не меняет W2–W3.

Контрактные тесты (пишутся первыми, красные до кода):
- GDScript — `tests/contracts/test_rust_wind_contracts.gd` (T5, T6 уровня фасада; T7 — чистота W10) — первым шагом RW-2; при `air.backend = rust` тот же файл гоняется второй раз (RW-7).
- Rust — `rust/dp-air/tests/contract.rs` (T5, T6 на трейте, на заглушке и на `Formula`) и `rust/dp-gd/tests/` (версия, разбор массивов) — первым шагом RW-4.
- Версия: константа `Atmosphere.WIND_API_VERSION`, `DpAir.api_version()` и `dp_air::API_VERSION` равны 1 и равны версии W2 здесь; тест сверяет с заголовками этого файла (как `test_air_contracts.gd`: `CONTRACTS` против заголовков `## Wn … (vK)`).

## W1. Соглашения (v1)
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
- **Сеть — не цель** (решение пользователя 2026-10-25): у каждого клиента свой воздух от общей погоды и сида; выгрузки/загрузки состояния воздуха и синхронизации нет. Нынешняя синхронизация термиков и `CloudField` в `net_flight.gd` (`air_forced_sig`, `set_air_forced`, `air_sources_mask`, `apply_net_snapshot`) удаляется в RW-3, не переносится.
- **Колбэков из крейта в Godot нет.** `height_fn`, `surface_fn`, `sun_fn`, `AtmoDay.weather_fn/sun_fn/source_fn` — не часть W3/W4; всё нужное — данными (W5).

## W2. Фасад `Atmosphere` (GDScript) (v1)
Владелец — RW-2 (фасад на текущем коде), RW-7 (выбор реализации). Потребители — `scripts/game/*`, `scripts/glider/*`, визуальные и отладочные потребители из W10, `CalmAir` (`scripts/game/calm_air.gd` реализует тот же набор, ветер 0, состояние READY сразу). Узел игры `air` остаётся `Atmosphere`; всё, что не перечислено ниже, — внутренность реализации (W10).

Константы: `WIND_API_VERSION := 1`; `STATE_EMPTY/LOADING/READY/FAILED`, коды `OK/BAD_INPUT/NO_PLACE/NOT_READY` (W1); `SAMPLE_FULL := 0`, `SAMPLE_MEAN := 1`; смещения полей описаний `CORE_*`, `CLOUD_*`, `CREST_*` и шаги `CORE_STRIDE`, `CLOUD_STRIDE`, `CREST_STRIDE` (W6).

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

**Переходное (только RW-2…RW-12, удаляется в RW-13; в W3/W4 нет):** реализация `gd` может держать прежние входы — `set_ground(height_fn, sun_fn, surface_fn)`, `set_day(AtmoDay)`, `set_wind(...)`, `set_weather(...)` — фасад сам выводит их из `load_place`/`set_conditions` (игра их больше не зовёт после RW-3). `air.backend` (RW-7) — ключ `configs/atmosphere.json` `air.backend: "gd" | "rust"`; нет бинарника расширения → `gd` и строка в журнале (W9).

## W3. Класс `DpAir` (gdext, крейт `dp-gd`) (v1)
Владелец — RW-4 (каркас, заглушка `Calm`), RW-6…12 (наполнение). Потребитель — фасад (реализация `rust`), контрактные тесты.
- `class DpAir extends RefCounted` (один объект на игру; создаёт фасад). Методы — как W2 с теми же именами, кодами и семантикой, только типы Godot без `Dictionary`/`Object` в горячем пути:
  - `api_version() -> int` (= 1); `last_error() -> String`; `state() -> int`; `progress() -> float`; `time_s() -> float`;
  - `configure(configs_json: PackedStringArray /* пары имя, текст */, seed: int) -> int` — имена: `atmosphere`, `weather_model`, `surface_heat`, `weather/<имя>`;
  - `load_place(header_json: String, heights: PackedFloat32Array, water: PackedByteArray, surface_cls: PackedByteArray, surface_moist: PackedFloat32Array) -> int` (W5), `unload_place()`;
  - `set_conditions(json: String) -> int` (W5); `set_sun_direction(to_sun: Vector3)`; `set_static_thermals(list: PackedFloat32Array, mode: int) -> int`;
  - `advance_to(t: float) -> int`; `start_at(t: float) -> int`;
  - `set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int`;
  - `sample_many(points: PackedVector3Array, mode: int) -> PackedFloat32Array`; `cloud_density_many(points) -> PackedFloat32Array`; `cloudbase_msl() -> float`; `background_wind(heights: PackedFloat32Array) -> PackedFloat32Array`; `weather_json() -> String`; `weather_version() -> int` (растёт при каждой смене; фасад по нему шлёт `weather_*`, полная перестройка — `weather_rebuild_version() -> int`); `sun_state() -> Vector4`;
  - описания и отладка — W6, W7 с теми же именами; растры — `cloud_raster_header() -> String` (json) + `cloud_raster_channel(name: String) -> PackedFloat32Array`; `debug_raster_header(name) -> String` + `debug_raster_data(name) -> PackedFloat32Array`; `decompose(pos: Vector3) -> PackedFloat32Array` + `decompose_names() -> PackedStringArray`.
- Вход — срез без копирования (`as_slice()`), выход — одно копирование. Рабочие потоки Rust не трогают объекты Godot.
- **Главный поток не ждёт фон.** Опросы читают последний готовый снимок (подмена указателя, `Arc`), блокировки на время расчёта нет; `advance_to` на главном потоке ≤ 0,5 мс (без учёта фоновой работы). Фоновый пересчёт, подготовка места, `start_at` — в потоках крейта, один `rayon`-пул на процесс, размер — `air.threads` в `configs/atmosphere.json` (`0` — все ядра минус одно).
- Жизненный цикл: выход из игры посреди фоновой работы — работа прерывается при `Drop`/`unload_place`, без зависания больше 1 с.

## W4. Трейт `AirModel` (крейт `dp-air`, без Godot) (v2)
Владелец — RW-4 (трейт, заглушка `Calm`), RW-6…12 (`Formula`), будущий живой воздух (`Live`). Потребители — `dp-gd`, стенд RW-5, `cargo test`, `cargo bench`.
```rust
pub const API_VERSION: u32 = 1;
pub enum State { Empty, Loading, Ready, Failed }
pub enum Code { Ok, BadInput, NoPlace, NotReady }          // W1; Result<(), Error{code, msg}>
pub enum SampleMode { Full, Mean }
pub struct Configs { pub files: Vec<(String, String)> }    // имя, текст json (W5)
pub struct Place { header: PlaceHeader, heights: Vec<f32>, water: Vec<u8>, cls: Vec<u8>, moist: Vec<f32> }  // W5
pub struct Conditions { .. }                                // W5, serde из json
pub struct Focus { pub pos: [f32; 3], pub weight: f32 }
pub struct Status { pub state: State, pub progress: f32, pub time_s: f64, pub reason: String }

pub trait AirModel: Send + Sync {
    fn configure(&mut self, cfg: &Configs, seed: u64) -> Result<(), Error>;
    fn load_place(&mut self, place: Place) -> Result<(), Error>;   // возвращает сразу; подготовка — фон
    fn unload_place(&mut self);
    fn set_conditions(&mut self, c: &Conditions) -> Result<(), Error>;
    fn set_sun_direction(&mut self, to_sun: Option<[f32; 3]>);
    fn set_static_thermals(&mut self, list: &[[f32; 4]], mode: u8) -> Result<(), Error>;
    fn set_focuses(&mut self, f: &[Focus]) -> Result<(), Error>;
    fn advance_to(&mut self, t: f64) -> Result<(), Error>;
    fn start_at(&mut self, t: f64) -> Result<(), Error>;
    fn status(&self) -> Status;
    fn sample_many(&self, pts: &[[f32; 3]], mode: SampleMode, out: &mut [[f32; 4]]);   // out.len() == pts.len()
    fn cloud_density_many(&self, pts: &[[f32; 3]], out: &mut [f32]);
    fn cloudbase_msl(&self) -> f32;
    fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]);
    fn weather_json(&self) -> String;  fn weather_version(&self) -> (u64, u64);  // (мягкая, перестройка)
    fn sun_state(&self) -> [f32; 4];
    fn cores(&self, center: [f32; 3], radius: f32, out: &mut Vec<Core>);           // W6
    fn clouds(&self, center: [f32; 3], radius: f32, out: &mut Vec<Cloud>);
    fn cloud_raster(&self) -> Option<std::sync::Arc<Raster>>;
    fn wave_crests(&self, center: [f32; 2], radius: f32, min_eta: f32, spacing: f32, out: &mut Vec<Crest>);
    fn decompose(&self, p: [f32; 3]) -> Decomposition;                              // W7
    fn debug_raster(&self, name: &str) -> Option<std::sync::Arc<Raster>>;
    fn debug_raster_names(&self) -> Vec<String>;
}
```
- Опросы (`&self`) — из любого потока одновременно; несовпадение длин `out`/`pts` — паники нет: обрабатывается `min` длин, остальное не трогается.
- **v2 (RW-4, ревью):** выходные `Vec` (`cores`, `clouds`, `wave_crests`) **заменяются** — реализация сначала очищает `out` (`clear()`, ёмкость сохраняется), потом пишет.
- **Порядок команд (v2; та же семантика в W2/W3):** `set_conditions`, `set_sun_direction`, `set_static_thermals`, `set_focuses` до `load_place` — `Ok`, вход запоминается и применяется при загрузке; `advance_to`, `start_at` без места — `NoPlace`. `unload_place` сбрасывает место, время, статические термики и фокусы; конфиги, сид, условия и солнце остаются. После `load_place` `time_s = 0`. `t < 0` или не конечно в `advance_to`/`start_at` — `BadInput`.
- **Структуры описаний (v2)** — поля в порядке смещений W6, все `f32`: `Core` — `id, flags, x, z, y_src, top, w, radius, lean_x, lean_z, age_s, life_s, stage, vis_seed, storm` (15); `Cloud` — `id, core_id, x, z, base_msl, top_msl, radius, growth, decay, flags` (10); `Crest` — `x, z, eta, crest` (4); `#[repr(C)]`, чтобы `dp-gd` отдавал их в `PackedFloat32Array` одним копированием. `Raster` — `version: u64, nx, ny: u32, dx, x0, z0: f32` (оси W1), `base_msl, time_s` (для облаков; у отладочных — NaN), `layers: Vec<(String, Vec<f32>)>` (`nx·ny`, строка — к +Z): у растра облаков — `cover, depth, stage, activity, bg_cover, bg_depth` (W6), у отладочного — один слой `data` (W7).
- `dp-air` не зависит от `godot`; `picard_rs` переносится в workspace как крейт (или модуль `dp-air::picard`) с сохранением R6 v3 (`docs/contracts/picard-rs.md`) — расчёт Пикара берётся готовый, не пишется заново (решение пользователя 2026-10-26).
- Реализации: `Calm` (RW-4: всё по W1, ветер 0, сразу Ready — для контрактных тестов и пустого запуска), `Formula` (RW-6…12), `Live` (вне модуля).

## W5. Вход: место, конфиги, условия (v3)
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
- Производные поля (уклоны, линия тени, рельеф гребня, `valley_msl_m`, `mean_msl_m`, сила источников термиков `thermal_source_strength`, нагрев и `surface_flux`, `domain_case`, грубая задача 1200 м) — считает реализация из этих растров (решение пользователя 2026-10-26: «всё тяжёлое считает Rust»). Не хватает данных для производного (например, для `thermal_source_strength_water`) — `contract:` координатору, W5 v2, а не колбэк.
- Высота у реализации — билинейно по `heights`; это заменяет `terrain.height_at` во всех слагаемых ветра. Разница с нынешней высотой — в допусках W8.

**Конфиги** — тексты json как есть (W2 `configure`); схему ключей задаёт сам конфиг, крейт читает нужные секции (`wind`, `turbulence`, `ground`, `lee`, `ridge`, `thermal`, `clouds`, `storm`, `wave`, `air_model`, `air_phase`, `cloud_field`, `seed`, …). Неизвестный ключ — не ошибка; отсутствие обязательного — BAD_INPUT с именем ключа.

**Условия** (`set_conditions`, Dictionary в W2 / json в W3) — ровно один из двух видов:
- Прогноз: `{forecast: {temperature_c, wind_speed_kmh, wind_from_deg, sky: String}, start_hour: float, speed: float (игровых с на с времени t; 1 — реальное), quantum_h: float, wind_ref: {ref_msl: float, gain_per_km: float} | null, overrides: {ключ пресета: значение}, blend_s: float | null, rebuild: bool}` — реализация сама выводит погоду по часу (`WeatherModel.derive`, `AtmoDay`; в `gd` — как сейчас, в крейте — RW-12). `overrides` — то, что игра правит поверх (сейчас `thermal_spacing_m` пикового часа, `game.gd:612`; ветер из настроек вместо `set_wind`).
- Эталон: `{preset: String ("weather/medium") | Dictionary (ключи пресета), start_hour, speed, blend_s, rebuild}` — без вывода по часу (превью, тесты, фикстуры).
- **v2:** в обоих видах — необязательный ключ `inflow_mode: "start" | "inflow"` (по умолчанию `"start"`; сейчас `StartWeather.wind_ref_of`, `air_runtime.gd:957`): `"start"` — ветер условий — у старта, приток подбирается проходами `k`; `"inflow"` — ветер условий — набегающий поток, `k = 1`. Другое значение — BAD_INPUT. Не путать с `wind_ref` прогноза (опорная высота и прирост).
- Посторонний ключ, оба вида сразу или ни одного — BAD_INPUT.
- Сид — только `configure`; статические термики — `set_static_thermals`; солнце — `set_sun_direction`.

## W6. Описания — найденное, а не заданное (v3)
Владелец — RW-2 (из текущего кода), RW-10/RW-11 (из крейта). Поля, шаги `CORE_STRIDE`/`CLOUD_STRIDE`/`CREST_STRIDE`, растр облаков, гребни и инвариант найденного ядра — `docs/contracts/rust-wind/descriptions.md`.

## W7. Разложение для отладки (v1)
Владелец — RW-2 (`gd`), RW-6…12 (крейт). Потребители — `wind_field_debug.gd`, `debug_overlays.gd`, `atmo_fingerprint.gd`, фикстуры W8 (второй набор, по слагаемым), стенд RW-5.
- `decompose(pos: Vector3) -> Dictionary` — `{names: PackedStringArray, vel: PackedVector3Array, sigma: PackedFloat32Array, total: Vector4}`; набор и имена слагаемых — у реализации, не в контракте (у `Formula` ожидаемо: `field`, `analytic`, `ridge`, `thermal`, `storm`, `wave`, `cloud`, `turb`, `gust`; у живой — свои).
- Инварианты: `total` = `sample(pos, SAMPLE_FULL)` побитно в одном `t`; `Σ vel` = `total.xyz` с точностью 1e-4 м/с (вклады уже со своими весами, в т. ч. полосы `a < 1`); `sigma[i]` — справочно, `total.w` — как у `sample`.
- `debug_raster_names() -> PackedStringArray`; `debug_raster(name) -> Dictionary {nx, ny, dx, x0, z0, data: PackedFloat32Array}` — растры для оверлеев (поток тепла F7, карта фаз F4 и т. п.); неизвестное имя → `{}`.
- Отладка не в горячем пути; `Dictionary` допустим.

## W8. Фикстуры T1 и допуски (v1)
Владелец — RW-1 (снимает на текущем коде до правок атмосферы), RW-2 (второй набор — по слагаемым W7). Потребители — `cargo test` (RW-6…12), GDScript-тесты T7. Формат фикстур `tests/fixtures/wind/`, допуски T1 по величинам (решение вопроса 3 плана) и пороги скорости — `docs/contracts/rust-wind/fixtures-tolerances.md`.

## W9. Workspace, сборка, поставка (v1)
Владелец — RW-4. Потребители — все задачи крейта, `tools/build.sh`, главная сессия (сборка). Опора — только проба `tools/research/rust_ext/gdext_probe/` (README, `run.sh`, крейт, минимальный проект; уточнение пользователя 2026-10-26); правила крейта — R3 v4 picard-rs (без asm/интринсиков, `multiversion`, f32 в расчёте и f64 в редукциях, `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`).
- `rust/Cargo.toml` — workspace: `dp-air` (lib, без Godot), `dp-gd` (`cdylib`, `godot = "0.5.5"`, фича `api-4-7`), Пикар из `tools/research/air_cascade/picard_rs/` (переносится, история — `git mv`; исследовательские CLI и тесты сохраняются). В `rust/` — `.gdignore`.
- **Профили** (решение пользователя 2026-10-26):
  - `dev` — `cargo test`, -O0;
  - `tune` — разработка и настройка игры: `inherits = "dev"`, `opt-level = 2`, `debug = true`, без LTO, `codegen-units` по умолчанию, `incremental = true`;
  - `release` — только выпуск: `opt-level = 3`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`.
- `.gdextension` — `res://addons/dp_air/dp_air.gdextension`, `compatibility_minimum = "4.7"`, ключи: `linux.debug.x86_64` → библиотека `tune`, `linux.release.x86_64` → `release`; Windows и macOS — так же (`windows.*.x86_64`, `macos.*` универсальный). Бинарники — `res://addons/dp_air/bin/` (в `.gitignore`), кладёт `tools/build.sh` (или `tools/build_rust.sh tune|release`), в git не идут. Редакторный бинарь Godot берёт ключ `debug` (грабли пробы).
- `tools/build.sh <ОС>` для выпуска собирает `release` под ОС до экспорта; игра в разработке и тесты — `tune`. Windows с Linux — `cargo-xwin` или `cargo-zigbuild` (выбор и проверка — RW-4); macOS — сборка с Linux, если выйдет, иначе вопрос пользователю (шлюз); запуск на Mac — у друга.
- Нет бинарника под ОС → фасад берёт `air.backend = gd` и пишет в журнал «dp_air: нет расширения, ветер на GDScript» (до RW-13); после RW-13 — экран ошибки, не вылет.
- Первый `--import` проекта с расширением падает (грабли пробы) — скрипты и тесты импортируют дважды.
- Дымовой тест поставки: экспортированная сборка Linux, headless, временный профиль: расширение загрузилось, `DpAir.api_version() == 1`, на месте после READY ветер ≠ 0.

## W10. Чистота границы (v1)
Владелец — RW-2 (тест), RW-3 (перевод потребителей). Тест T7 в `tests/contracts/test_rust_wind_contracts.gd`.
- Вне файлов реализации (`scripts/atmosphere/**` кроме перечисленных ниже потребителей, плюс `scripts/atmosphere/air_model/**`) запрещены обращения: `.field.`, `.field\b` у узла воздуха, `.wind.`, `.ground.`, `.cloud_phys`, `.wave.`, `.storm.`, `.air_field`, `_ground_ref`, `_rmin`, `_last_sigma`, `AirRuntime`, `ThermalField`, `WindField`, `WindModel`, `GroundField`, `CloudPhysics`, `CloudField`, `AtmoThermal`, `AirFieldSet`, `step(`, `time_s =`, `set_air_field`, `set_ground`, `set_day`, `set_wind`, `set_weather` (на узле воздуха).
- Потребители внутри `scripts/atmosphere/` подпадают под запрет так же: `cloud_layer.gd`, `cloud_shadow_map.gd`, `cirrus_layer.gd`, `gust_dust.gd`, `dust_devils.gd`, `bird_flock.gd`, `thermal_signs.gd`, `atmo_fingerprint.gd`, `atmosphere_preview.gd`, `wind_field_debug.gd`, `debug_overlays.gd` (где бы ни лежали), а также `bot_pilots.gd`, `net_flight.gd`, `terrain_wind.gd`, `game.gd`.
- Список файлов реализации тест держит явным (RW-2 фиксирует); новый файл реализации — правка теста и W10 через координатора.
- Тесты в `tests/` под запрет не подпадают, но тесты поведения через `Atmosphere` после RW-3 пользуются фасадом (T7).

## W11. Решатель Пикара в крейте (v3)
Владелец — RW-6g, RW-6h. Потребители — RW-6j, RW-6n, фазы RW-6k–6m. R6 v3 + заморозка колонн, отмена, `AllFrozen`/`Cancelled` — `docs/contracts/rust-wind/solver.md`.

## История
- v1 (2026-10-26, RW-0) — заведены до первых исполнителей; допуски T1 (вопрос 3 плана) — W8.
- W4 v2 (2026-10-26, ревью RW-4) — `out` заменяется; порядок команд до места и сброс при `unload_place`; `t < 0` — `BadInput`; поля `Core`/`Cloud`/`Crest`/`Raster`. Потребители: `dp-gd` (RW-4b), `Formula` (RW-6…12), стенд RW-5.
- W6 v2 (2026-10-26, итог RW-1) — `id` в `[0, 2²⁴)`; инвариант ядра — местный избыток подъёма против кольца 2–3·radius, ядра Cb исключены. Потребители: RW-2 (фасад `gd`), RW-4b (общий suite contract.rs), RW-5 (compare — по ближайшему). Уточнение W2 без смены версии (норматив прежний — «без неразрешённой болтанки и порывов»): `SAMPLE_MEAN` — весь ветер, как `SAMPLE_FULL` при выключенной болтанке и порывах (поле, аналитика, термики, гроза, волна, облака), не «`mean_wind_at` + вертикаль поля»; так сняты фикстуры RW-1.
- W5 v2 (2026-10-26, разбор RW-6a) — ключ условий `inflow_mode`. Потребители: RW-4b/dp-air (разбор `Conditions`), RW-2 (фасад), RW-6j.
- W5 v3 (2026-10-26, итог RW-6c) — `loc.climate` в заголовке места (ячейка климата у центра). Потребители: RW-2 (`AirPlaceData`), RW-1b (фикстуры мест), dp-air (`PlaceHeader`, `field_weather` — климат из заголовка вместо трейта `Climate`).
- W11 v1 (2026-10-26, постановка RW-6g) — решатель в крейте: заморозка колонн и отмена поверх R6 v3 (picard-rs закрыт, расширение — здесь).
- W6 v3 (2026-10-26, ревью RW-2) — инвариант найденного ядра только для `w ≥ 1,5 м/с`; охват описаний — вокруг фокусов. Потребители: RW-2, RW-3, RW-10.
- W11 v2 (2026-10-26, итог RW-6g) — равенство замороженных колонн полю заморозки — до `finalize`; `finalize` — как в игре, без маски.
- W11 v3 (2026-10-26, постановка RW-6h) — запасные правила сходимости (`Fallback`, `NonConv`), флаги в `Solved`; `AllFrozen` при отмене до старта — с фоном.
