---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "W3 rust-wind: класс DpAir (gdext, dp-gd) — методы W2 в типах Godot, потоки, жизненный цикл, описания W6; v6 — без режима поля."
related: ["docs/contracts/rust-wind.md", "docs/contracts/rust-wind/trait.md", "docs/plan/rust-wind.md"]
contracts: [{"id": "W3", "version": 8}]
---

# W3. Класс `DpAir` (gdext, крейт `dp-gd`) (v8)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W3). Менять — только координатор.
Владелец — RW-4 (каркас, заглушка `Calm`), RW-6…12 (наполнение). Потребитель — фасад (реализация `rust`), контрактные тесты.
- `class DpAir extends RefCounted` (один объект на игру; создаёт фасад). Методы — как W2 с теми же именами, кодами и семантикой, только типы Godot без `Dictionary`/`Object` в горячем пути:
  - `api_version() -> int` (= версии W2; с v5 — 4); `last_error() -> String`; `state() -> int`; `progress() -> float`; `time_s() -> float`;
  - v3: `stage() -> String` (идентификатор этапа W4 v4; подпись для экрана — фасад), `iters() -> int` — как `status().iters` W2 v3.
  - `configure(configs_json: PackedStringArray /* пары имя, текст */, seed: int) -> int` — имена: `atmosphere`, `weather_model`, `surface_heat`, `weather/<имя>`;
  - `load_place(header_json: String, heights: PackedFloat32Array, water: PackedByteArray, surface_cls: PackedByteArray, surface_moist: PackedFloat32Array) -> int` (W5), `unload_place()`;
  - v2: `add_baked_field(header_json: String, data: PackedByteArray) -> int` — запечённое поле места (W5 v4, формат TI-К3 v3) сразу после `load_place`, до READY (позже — BAD_INPUT); `set_cache_dir(path: String) -> int` — каталог кеша полей реализации (абсолютный путь; фасад даёт `ProjectSettings.globalize_path("user://air_cache")`), крейт сам читает и пишет туда свои файлы (запись — временный файл и переименование); пусто — без кеша;
  - `set_conditions(json: String) -> int` (W5); `set_sun_direction(to_sun: Vector3)`; `set_static_thermals(list: PackedFloat32Array, mode: int) -> int`;
  - `advance_to(t: float) -> int`; `start_at(t: float) -> int`;
  - `set_focuses(points: PackedVector3Array, weights: PackedFloat32Array) -> int`;
  - `sample_many(points: PackedVector3Array, mode: int) -> PackedFloat32Array`; `cloud_density_many(points) -> PackedFloat32Array`; `cloudbase_msl() -> float`; `background_wind(heights: PackedFloat32Array) -> PackedFloat32Array`; `weather_json() -> String`; `weather_version() -> int` (растёт при каждой смене; фасад по нему шлёт `weather_*`, полная перестройка — `weather_rebuild_version() -> int`); `sun_state() -> Vector4`;
  - описания и отладка — W6, W7 с теми же именами; растры — `cloud_raster_header() -> String` (json) + `cloud_raster_channel(name: String) -> PackedFloat32Array`; `debug_raster_header(name) -> String` + `debug_raster_data(name) -> PackedFloat32Array`; `decompose(pos: Vector3) -> PackedFloat32Array` + `decompose_names() -> PackedStringArray`.
- Вход — срез без копирования (`as_slice()`), выход — одно копирование. Рабочие потоки Rust не трогают объекты Godot.
- **Главный поток не ждёт фон.** Опросы читают последний готовый снимок (подмена указателя, `Arc`), блокировки на время расчёта нет; `advance_to` на главном потоке ≤ 0,5 мс (без учёта фоновой работы). Фоновый пересчёт, подготовка места, `start_at` — в потоках крейта, один `rayon`-пул на процесс, размер — `air.threads` в `configs/atmosphere.json` (`0` — все ядра минус одно).
- Жизненный цикл: выход из игры посреди фоновой работы — работа прерывается при `Drop`/`unload_place`, без зависания больше 1 с.
- **v4 (RW-7, 2026-10-29):**
  - `set_field_enabled(on: bool) -> int` — как W4 v5 (режим поля, W2 «Режим поля»).
  - **Выдача поля фасаду (переходное: пока термики, болтанка и прочие слагаемые на GDScript читают каналы поля; удаляется, когда последний такой потребитель уйдёт в крейт, не позже RW-13).** `field_export() -> int` закрепляет снимок последней подачи поля (целевой набор уровней, к которому идёт подмена, — не смесь на середине подмены) и возвращает его номер `field_version` (`0` — поля нет). `field_export_header() -> String` — заголовок TI-К3 v3 этого снимка (как `field::baked::encode_baked`: каналы `f32` без потерь, все уровни набора — область и окна 100/50 м) плюс поля верхнего уровня `field_version: int`, `blend_s: float` (за сколько подменить прежнее поле; `0` — сразу: первое поле после загрузки, `start_at`, включение), `blend_t0: float` (`t` начала подмены в крейте); снимка нет — `""`. `field_export_data() -> PackedByteArray` — тело снимка (`zstd`, как `encode_baked`); снимка нет — пусто. Заголовок и тело — одного снимка до следующего `field_export()`. Не горячий путь (зовётся, когда номер подачи сменился; номер — `field_version() -> int` без закрепления, дёшево).
  - Номер подачи растёт при каждой подаче поля: `load_place` (снимок пуст), загрузка (расчёт, запечённое, кеш), `start_at`, пересчёт на сроке, смена условий, сдвиг окон, а также `set_field_enabled(false)` (снимок пуст) и `unload_place` (пуст).
- **v5 (RW-12z, 2026-10-29):** `api_version() = 4`. Добавлено:
  - `cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array` — `OBJ_STRIDE = 22` `f32` на запись (W6 v4); одно копирование из `Vec<ObjRecord>` (W4 v6); `radius < 0` — без ограничения; `t` не конечно — как текущее `t`.
  - `wave_info() -> PackedFloat32Array` — два числа `[enabled, wavelength_m]`.
  - `surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array` — длина `min`; вход — срезами без копирования.
  - Все три читают последний снимок и не ждут фон (как `sample_many`).
  - Переходное `field_export*`/`field_version` (v4) остаётся до RW-13: после RW-12z фасад берёт снимок только для отладки и превью (`air_field`), горячий путь его не читает.

- **v6 (2026-10-29, решение пользователя: упрощённый режим ветра убрать):** `api_version() = 5`. `set_field_enabled` удалён (W4 v7); номер подачи по `set_field_enabled(false)` больше не растёт — такого вызова нет. Поле на месте считается всегда.
- **v7 (2026-10-29, итог RW-P11):** `add_baked_field` удалён (W5 v9). `set_cache_dir` и кеш полей — без изменений. `api_version()` не меняется (= W2 v5).
- **v8 (2026-10-30, решение пользователя: экран загрузки):** `api_version() = 6`. Добавлено `run() -> int`, `runs() -> int` — как `status().run/runs` W2 v6 (из `Status::run/runs` W4 v9), читаются из главного потока без блокировок, как `iters()`.
