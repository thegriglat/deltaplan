---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-12y: правки W2 v4 / W3 v5 / W4 v6, разбиение RW-12z на 4 задачи, красные тесты, сомнения по задачам."
conclusion: "Фасад переходит за 4 задачи: 12za (dp-air: трейт + подключение Terms в Formula), 12zb (dp-gd), 12zc (atmosphere.gd), 12zd (потребители и чистота); главная находка — Formula пока не подаёт место, поле и облака в Terms, поэтому ядро работы — в 12za, а RW-11e в прежнем виде невыполнима до 12zb"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3/cards.md", "docs/research/rust-wind-stage3/w6v4.md", "docs/research/rust-wind-stage3/uncertain.md", "docs/contracts/rust-wind.md", "docs/contracts/rust-wind/dpair.md", "docs/contracts/rust-wind/trait.md", "docs/contracts/rust-wind/descriptions.md"]
---

# Проект перехода фасада (RW-12y → RW-12z)

Снимок кода: `feature/rust-wind` на `387b2df18` (RW-8s влит; RW-9 — «доработка», в ветке модуля слота `Analytic` ещё нет). Строки кода — по этому снимку. Контракты менять — только координатор; ниже — готовый текст для него. Размеры — оценка по чтению, не замер.

## 1. Что есть сейчас (факты, от которых зависит проект)

1. **Сумма уже на Rust, но «пустая».** `Formula::sample_many` считает `terms::sum(&pb.terms, &pb.fs, pb.place, …)` (`formula.rs:1092`). `Terms` же собирается из `Terms::default()` и получает от `Formula` только: `configure`, `set_conditions`, `set_sun_direction`, `set_static_thermals`, `set_focuses`, `advance`/`start_at`, `unload_place` (`formula.rs:1100–1200`).
2. **Formula НЕ вызывает** `Terms::set_place` (погода по часу, `weather_link.rs:112`), `set_thermal_place` (земля и сила источников термиков, `terms/mod.rs:328`), `set_air_field` (уровни поля → источники термиков, `:314`), `set_cloud_inputs` (`:281`), и не выставляет `wind.ref_msl`. Эти вызовы сейчас делают только тесты крейта (`tests/terms_*.rs`). Без них термики, облака и погода «по ходу дня» в игре не заработают, сколько ни меняй фасад. Это главный объём RW-12z на стороне Rust.
3. **Заглушки трейта** (`formula.rs:1389–1443`): `cloud_density_many`, `cloudbase_msl`, `background_wind`, `weather_json`, `weather_version`, `cores`, `clouds`, `cloud_raster`, `wave_crests`, `debug_raster*`; `sun_state` — без прогрева. Готовые pub-функции есть почти на каждую (таблица в §2).
4. **`DpAir` (dp-gd)** уже отдаёт все методы W3 v4 (в т. ч. `sample_many`, `cores`, `clouds`, `wave_crests`, `cloud_raster_*`, `decompose*`), не отдаёт `cloud_objects`, `wave_info`, `surface_gust_many`. `API_VERSION = 3` (`dp-air/src/lib.rs:33`; в `trait.md` листинг `API_VERSION: u32 = 1` устарел).
5. **Фасад `atmosphere.gd` (2 602 строки) — смесь:** поле и условия уходят в `DpAir` (`_dp_*`), но `sample_many`, `cores`, `clouds`, `cloud_density_many`, `background_wind`, `sun_state`, `weather`, `cloud_raster`, `wave_crests`, `decompose`, `debug_raster` считаются из GDScript-внутренностей (`air_velocity_at` 919, `sample_many` 2157, `cores` 2247, `cloud_raster` 2344 …), шаг — `step` (861), сборка — `_f_build` (1643).
6. **Мимо фасада** остаются: `cloud_layer.gd` (`atmo.field.thermals`, `atmo.cloud_phys.model`, `atmo.storm`, `atmo.wave`, `atmo.cloud_phys.field`; 15 обращений в базе храповика чистоты), `gust_dust.gd:45` + `atmosphere.gd:2584` (`WindModel` в `GustDustModel`), тесты `test_forecast_game.gd:43` (`air.wind.ref_msl`), `test_ridge_starts.gd:207`, `test_start_air_gpu.gd:62` (`air.ground.sample`).

## 2. Правки контрактов (текст для координатора)

Версии: W2 v3 → **v4**, W3 v4 → **v5**, W4 v5 → **v6**; `WIND_API_VERSION` = `DpAir.api_version()` = `dp_air::API_VERSION` = **4** (сейчас 3). W6 остаётся v4 (его текст уже описывает эти вызовы: «вводятся с версией W2 v4/W3 v5/W4 v6 в RW-12z»); в заголовок W6 — только пометка «методы введены в W2 v4». Остальные W не меняются.

### 2.1. W2 v4 (фасад `Atmosphere`)

Добавить в «Константы»: `OBJ_STRIDE := 22` и смещения `OBJ_ID … OBJ_STORM_K` (0…21 по W6 v4); `WAVE_INFO_ENABLED := 0`, `WAVE_INFO_LENGTH := 1`.

Добавить в «Описания и отладка» (после перечня W6/W7):

> - `cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array` — объекты-облака для рисования, `OBJ_STRIDE = 22` (поля и охват — W6 v4). `t` — момент атмосферы; вне окна `[now − fade_out_s, now]` — ближайшая граница. Нет места или не READY — пусто.
> - `wave_info() -> PackedFloat32Array` — `[enabled, wavelength_m]` (W6 v4); нет места или не READY — `[0, 0]`.
> - `surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array` — порыв на 10 м для пыли, м/с, длина `min(len(xz), len(t))`; ветер и `convective_turbulence_ms` — на момент вызова, `t` — только фаза шума (W6 v4). Не READY — нули. Вызывается с бо́льшими пачками (по клеткам видимой пыли), не по точке.

Изменить:

> - `mean_wind_at(pos)` = `sample(pos, SAMPLE_MEAN).xyz` — без изменений; `thermals_near(pos, radius)` = обёртка над `cores(pos, radius)`: словарь на ядро с ключами `x, z` (м), `y_src`, `top`, `w`, `radius`, `age_s`, `life_s`, `stage`, `is_cb` (бит 2 флагов), `static` (бит 0), `has_cloud` (бит 1), `id`. Это переходной состав (читатели: `terrain_wind.gd:158`, `world_link.gd:90`, птицы, тесты); охват — как у `cores` (W6 v3), а не «все термики поля» как у `ThermalField.near` до v4.
> - `start_at(t)`: формулировка «состояние на момент `t`, равное прогону с 0» заменить на: «термики, погода, ход дня, гроза, волны и поле — как прогон с 0 (для детерминизма: одно `t` — один ответ); **поле облаков** (`cloud_raster`, `cloud_density_many`, подсос и тень облаков в `thermal`) после `start_at` — состояние сброса поля на входах момента `t` с разгоном (`begin_spinup`), как в GDScript, а не результат прогона с 0 (`cover` расходится до 0,07 — RW-11d; та же особенность у `gd`)». Два опроса на одном `t` по-прежнему равны всегда. Контрактный тест T6 сравнивает «после `start_at(t)`» с «прогоном с 0» для `sample_many(MEAN)` вне облаков и для `cores`, но для облачных величин — только детерминизм и допуск `cover ≤ 0,1`.
> - `sample_many`/`sample`: без изменений в сигнатуре; в «Опрос» добавить: «в режиме поля `off` (W2 «Режим поля») крейт считает аналитику (`WindModel`, линия тени, склоновый подъём) без поля и без полосы края; термики, облака, гроза и волны включены» (по RW-9; пока слот `Analytic` не влит, текст не добавлять).
> - «Переходное»: после RW-12z исчезают из реализации `gd` и из тестов-потребителей `air.wind`, `air.ground`, `air.cloud_phys`, `air.storm`, `air.wave`, `air.field`, `set_ground/set_day/set_wind/set_weather/set_air_field`, `step`; сами файлы GDScript-слагаемых удаляет RW-13 (на них ещё ссылаются тесты: `ThermalField`/`AtmoThermal` — 17 файлов тестов, `CloudField` — 12, `AirThermals` — 14). Ссылка на `refresh_scale`, `focus_node`, `configure(Variant, Variant)` — как было, до RW-13.
> - `status()`/`pump`: `pump` с RW-12z — пустой (реализации `gd` нет); `status().field_on` — по `DpAir`.

### 2.2. W3 v5 (`DpAir`)

> **v5 (RW-12z).** `api_version() = 4`. Добавлено:
> - `cloud_objects(center: Vector3, radius: float, t: float) -> PackedFloat32Array` — `OBJ_STRIDE = 22` `f32` на запись, как W6 v4; одно копирование из `Vec<ObjRecord>` (`#[repr(C)]`, 22 × `f32`) в массив; `radius < 0` — без ограничения; `t` не конечно — как `now`.
> - `wave_info() -> PackedFloat32Array` — два числа.
> - `surface_gust_many(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array` — длина `min`; вход — срезами без копирования (`Vector2` — `[f32; 2]`, `f64` — срез).
> - Все три читают последний снимок, не ждут фон (как `sample_many`).
> - Переходное `field_export*`/`field_version` (W3 v4) **остаётся до RW-13**: читатели — GDScript-слагаемые, которые удалит RW-13 (`wind_field_debug.gd`, `air_field_cache.gd`, отладочные разрезы); срок «не позже RW-13» не меняется. После RW-12z фасад подаёт снимок только отладке и `air_field` для превью; горячий путь его не читает.

### 2.3. W4 v6 (трейт `AirModel`)

```rust
pub const API_VERSION: u32 = 4;                     // листинг W4 v1 («= 1») исправить
// terms::objects::ObjRecord → переносится в crate root: #[repr(C)] struct ObjRecord (22 × f32), pub const OBJ_STRIDE: usize = 22
pub trait AirModel {
    // … как v5, плюс (по умолчанию — «ничего»: Calm)
    fn cloud_objects(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<ObjRecord>) { out.clear() }
    fn wave_info(&self) -> [f32; 2] { [0.0; 2] }                       // [enabled, wavelength_m]
    fn surface_gust_many(&self, xz: &[[f32; 2]], t: &[f64], out: &mut [f32]) { out.iter_mut().for_each(|o| *o = 0.0) }
}
```

Текст гарантий (добавить к «Опросы»):

> - **v6 (RW-12z).** `Formula` выдаёт все опросы из `Terms` (ядра, облака, плотность, растр, гребни, объекты, `wave_info`, `surface_gust_many`, погоду, солнце, фон) вместо заглушек. Нет места или состояние не `Ready`: `cores/clouds/cloud_objects/wave_crests` — пусто (`out.clear()`), `cloud_raster` — `None`, `cloud_density_many`/`surface_gust_many`/`background_wind` — нули, `wave_info` — `[0, 0]`, `weather_json` — `"{}"`, `sun_state` — `[0;3]` и `0`.
> - `cloud_objects`, `cores`, `clouds` — на `t` атмосферы (`cores`/`clouds` — на текущем; `cloud_objects` — на заданном `t` в окне W6 v4); результат — детерминированная функция снимка и `t`.
> - `surface_gust_many`: шум порывов строится при первом вызове после `configure` (ленивый `OnceLock`), `configure` сбрасывает; вызов не блокирует главный поток дольше построения шума (~мс, один раз).
> - `sun_state`: `w` — прогрев (`AtmoDay.insolation`), 0..1; нет хода дня — 1 (как `weather_link::sun_state`).
> - `weather_version()`: `(мягкая, перестройка)` растёт только при реальной смене выведенной погоды (квант `weather_version` — слот 0,1 с хода дня; фасад по первому числу шлёт `weather_updated`, по второму `weather_changed`). Если значение выведенных величин не изменилось в пределах `1e-3` — номер не растёт (иначе игра будет слать сигнал каждые 0,1 с — `uncertain` RW-12d).
> - Переходное `field_export`/`field_version` — без изменений до RW-13.

Соответствие методов и готового кода крейта:

| метод | готовая pub-функция крейта | чего не хватает (в 12za) |
|---|---|---|
| `sample_many`, `decompose` | `terms::sum`, `terms::decompose` | подключение слагаемых (§3) |
| `cores` | `Terms::thermal_cores(center, radius, t, out)` (`terms/mod.rs:352`) | `Formula::cores` берёт `pb.terms` и текущее `t` |
| `clouds` | `terms::clouds::clouds(terms, center, radius, t, out)` (`clouds/mod.rs:227`) | то же |
| `cloud_density_many` | `clouds::cloud_density_many(terms, pts, out)` (`:306`) | то же |
| `cloud_raster` | `clouds::cloud_raster(terms) -> Option<Arc<Raster>>` (`:320`) | то же |
| `cloud_objects` | `objects::cloud_objects_into` (`objects/mod.rs:187`) | метод трейта, перенос `ObjRecord` в корень |
| `wave_crests` | `waves::wave_crests(terms, place, …)` (`waves/mod.rs:133`) | то же |
| `wave_info` | нет; есть `WaveExtra::field(terms, place) -> Option<(Arc<WaveField>, WaveCfg)>` (`waves/mod.rs:50`) и `WaveField::wavelength()` (`field.rs:171`) | новая `waves::wave_info(terms, place) -> [f32; 2]`; сверить `wavelength` с формулой W6 `2π·max(u_ref,1)/max(N,1e-4)` |
| `surface_gust_many` | `surface_gust::surface_gust_many(terms, xz, t, out)` (`surface_gust/mod.rs:94`) | метод трейта; нули без места/не `Ready` (признак места — у `Published`, не у `Terms`: `uncertain` RW-8s) |
| `weather_json`, `weather_version`, `sun_state` | `Terms::weather_json/weather_version/sun_state(t)` (`weather_link.rs:272–290`) | подключить `Terms::set_place`; порог изменения |
| `background_wind` | `WindModel::vec2_at(agl)` / `speed_at_pos(agl, msl)` + `dir()` (`frame.rs:185,262,288`) | нужен `ground_ref` (как `_ground_ref` в GD, `atmosphere.gd:2206`); сейчас в `Terms` его нет — взять `PlaceLink.ctx.mean_msl_m` или считать при `set_place`; сверить с GD |
| `cloudbase_msl` | нет pub; значение — `ThermalSlot::setup().cloudbase_msl` (`terms/thermal`) | `Terms::cloudbase_msl()`; до готовности термиков — 0 |
| `debug_raster*` | нет | остаются пустыми (решение — §5, строка RW-7b) |

## 3. Что подключает Rust-часть (RW-12za): `Formula` → `Terms`

Все вызовы — в местах, где уже публикуется снимок (`publish_terms`, `formula.rs:694`); горячий путь опросов не меняется (чтение `Arc<Terms>`).

1. **Место.** В `load_place`: `terms.set_place(Some(&place))` (погода по часу, `PlaceLink::of`), `terms.set_thermal_place(place, hour)` (`hour` — `SourceHour` из хода дня `Terms::day()` на `t`; нет хода дня — `None`), `terms.wind.ref_msl` — из `Conditions.wind_ref.ref_msl` (прогноз) или из эталона-пресета; в `unload_place` — `set_place(None)` (уже в `weather_unload_place`).
2. **Поле.** После каждой подачи поля (`note_feed`/`reset_published`, где меняется набор уровней): `terms.set_air_field(&levels, u10)`; режим `off` (`set_field_enabled(false)`) — `set_air_field(&[], None)`. Источники термиков пересоберутся на ближайшем `advance`/`start_at`.
3. **Облака.** `terms.set_cloud_inputs(Arc<dyn CloudInputs>)`: входы из `Field` + `AirThermals` (шаг RW-10f/RW-11d: сейчас собраны только в тесте `tests/terms_thermal_cloud.rs` `AirInputs`); без поля — `AnalyticInputs` (по умолчанию).
4. **Слоты.** Слот `Analytic` (RW-9) — установка в `Terms::configure`, как `turb` (RW-8); `ExtraSet` (гроза, волны, облака) и `ThermalSlot` уже в `Slots::new`. `air_mode off` на синтетике/реальном рельефе: `Formula` сама включает упрощённый профиль `wind_profile_simple` (`uncertain` RW-11b).
5. **Ключ места.** Кеши по указателю (`WaveExtra::field`, `analytic/ground.rs:PlaceSig::of`) заменить ключом = `sh.epoch` на `load_place` (поколение уже есть в `Formula`): исключает ложное попадание в кеш по освобождённому адресу.
6. **Фон и бюджет `advance_to` (0,5 мс, W3).** Измеренные шаги: термики 2 мс (RW-10b), поле облаков 0,43 мс + клон 0,5 МБ, разгон облаков 56 мс, подготовка 4 мс (RW-11d). `Terms.thermal_async` уже есть для термиков; для облаков — тот же приём: шаг поля и пересборка входов — в одной фоновой задаче (single-flight, подмена `Arc<Terms>`), `advance_to` лишь ставит срок. Если не укладывается — `<ID> contract:` с предложением (бюджет с 0,5 до N мс или фон только для разгона).
7. **Методы трейта** — замена заглушек по таблице §2.3; `weather_version` с порогом; `Calm` — без изменений (умолчания).
8. **Кеш в `Terms`:** `wind.speed_at(300)` (σ-адвекция) и `cloudbase` для конвективной σ — считать при `configure`/`set_conditions`, а не на каждом опросе (`uncertain` RW-8).

Размер: ≈ 3–4 дня исполнителя (оценка), риск — п. 6 и п. 3.

## 4. Разбиение RW-12z на четыре задачи

Скоупы не пересекаются по файлам. Порядок: **12za → 12zb → 12zc → 12zd**; 12zc и 12zd после слияния «шага 1 12zc» (обёртки фасада) идут параллельно.

### RW-12za. Rust: трейт и подключение слагаемых
- **Скоуп:** `rust/dp-air/src/{lib,formula}.rs`, `terms/{mod,waves,clouds}/…` (только добавление `wave_info`, `cloudbase_msl`, кеши §3), новые `tests/formula_facade.rs`, `benches/formula.rs`; контракты W4 v6 — читает, не правит.
- **Шаг 1 (сливается раньше остального):** трейт W4 v6 (три метода с умолчаниями, `ObjRecord` в корне, `API_VERSION = 4`) — чтобы 12zb мог собираться.
- **Красные тесты первым шагом:** (а) `Formula` на `tests/fixtures/wind/places/synthetic` + эталон `ongudai_*`: `cores/clouds/cloud_raster/cloud_density_many/cloud_objects` против `terms::*` напрямую (равенство побитно) и непустые там, где пусты заглушки; (б) `sample_many(FULL)` с подключённым местом и полем = `decompose().total` ± 1e-4 и против эталона RW-2b в допуске W8 по слагаемым `thermal`, `cloud`, `storm`, `wave` на `ongudai_*`; (в) `weather_json/weather_version/sun_state` на `ongudai_day_*`: версия растёт ≤ 1 раза за квант, нет роста при неизменной погоде; (г) `surface_gust_many` против дампа `tests/data/RW-8s`; нет места → нули; (д) `unload_place` → `load_place` другого места не берёт кеш прошлого (ключ места); (е) `set_field_enabled(false)` не оставляет источников термиков из старого поля; (ж) `advance_to` на главном потоке ≤ 0,5 мс на `ongudai_*` (бенч, замок cpu).
- **Проверка:** `cargo test -p dp-air`, `clippy -D warnings`, `fmt`; бенч W8 (с волной и без) — одним прогоном; `cargo tree -p dp-air -e normal` без `godot`. Godot и T1 — не здесь.
- **Размер:** 3–4 дня. **Зависит от:** RW-9 (слот `Analytic`), RW-10e/10f/11d/12d влиты (есть). RW-9 в доработке — если срок поджимает, 12za делает всё кроме п. 3.4 и режима `off`, а он добавляется отдельной правкой 12za после слияния RW-9.

### RW-12zb. dp-gd: W3 v5
- **Скоуп:** `rust/dp-gd/src/{lib,bridge}.rs`, `rust/dp-gd/tests/`, `tests/contracts/test_dp_air_ext.gd`.
- **Красные тесты:** `cargo test -p dp-gd` — разбор массивов (`cloud_objects` — длина `22·N`, `radius < 0`, пусто без места; `surface_gust_many` — `min` длин, нечисловой вход → 0); `test_dp_air_ext.gd`: `api_version() == 4`, три метода есть и дают нули на пустом объекте. Проверка версии против заголовков `rust-wind.md`.
- **Размер:** 1 день. **Зависит от:** шаг 1 12za.

### RW-12zc. GDScript: фасад `atmosphere.gd` на `DpAir`
- **Скоуп:** `scripts/atmosphere/atmosphere.gd`, `scripts/game/calm_air.gd`, `tests/contracts/test_rust_wind_contracts.gd` (новые методы, `start_at`), `tests/contracts/test_rust_wind_consumers.gd`.
- **Шаг 1 (сливается раньше шага 2 для 12zd):** обёртки `cloud_objects`, `wave_info`, `surface_gust_many`, константы `OBJ_*`/`WAVE_INFO_*`, `CalmAir` с теми же.
- **Шаг 2:** `sample_many/sample/cloud_density_many/cloudbase_msl/background_wind/weather/sun_state/cores/clouds/cloud_raster(+version)/wave_crests/decompose/debug_raster*` → `DpAir`; `mean_wind_at`, `thermals_near` (по §2.1); `weather()` — разбор `weather_json` по `weather_version` (кэш `Dictionary`); сигналы `weather_*` — по версиям; из горячего пути убираются `air_velocity_at` (GD-ветка), `step`, `_f_build`, `_f_apply_*`, `set_ground/set_day/set_wind/set_weather`. Удаление файлов слагаемых — не здесь (RW-13). Подача `field_export` в `air_field` — только для отладки и превью (`_dp_feed` остаётся; ветка включается по запросу `air_field` потребителя).
- **Красные тесты:** T5/T6 на фасаде против заглушек (`test_rust_wind_contracts.gd` уже есть — должен пройти на `DpAir` без правок, кроме формулировки `start_at` по W2 v4: облачные величины — детерминизм, не равенство прогону с 0); `thermals_near` — состав ключей §2.1; `pump` пуст; headless `auto` → поле выключено (`uncertain` RW-7b).
- **Проверка:** набор игровых тестов фасада (T7) — один целевой прогон Godot (`--filter=rust_wind`), полный T7/T9 — итоговый.
- **Размер:** 2–3 дня. **Зависит от:** 12zb.

### RW-12zd. GDScript: потребители и храповик чистоты
- **Скоуп:** `scripts/atmosphere/{cloud_layer,gust_dust,gust_dust_model}.gd`, `scripts/atmosphere/atmosphere_preview.gd`, `thermal_signs.gd`, `bird_flock.gd` — только если после 12zc остались обращения; `tests/contracts/{rust_wind_purity_baseline.txt,test_rust_wind_purity.gd}`, `tests/{game/test_forecast_game.gd,atmosphere/test_ridge_starts.gd,atmosphere/test_start_air_gpu.gd,atmosphere/test_gust_dust.gd}`.
- **Работа:** (1) `cloud_layer.gd`: `atmo.field.thermals`/`cloud_phys.model` → `cloud_objects` + выбор/слияние в Godot (`select*`, `merge_winners` остаются, W6 v4), `atmo.storm` → поля `storm_t0/storm_k` записи, `atmo.wave` → `wave_info` + `wave_crests`, `atmo.cloud_phys.field/poll` → `cloud_raster(_version)`; (2) `gust_dust.gd`/`gust_dust_model.gd`: `GustDustModel.event` делится на «кандидаты клетки → пачка `surface_gust_many` → событие» (по клетке сейчас по одному `gust_ms`), убирается `wind`-источник из `setup` (и TODO `atmosphere.gd:2584`), отладочный `force_wind`/`--gust-dust-wind` удаляется (решение координатора 2026-10-29, W6 v4); (3) тесты: `air.wind.ref_msl` → `weather()`/`sample`, `air.ground.sample` → `sample_many(MEAN)` или тестовый вход места; (4) база храповика → пустая, тест = W10 целиком.
- **Красные тесты:** храповик чистоты (все 15 обращений `cloud_layer.gd` и прочие обращаются в нуль — тест красный, пока база не пустая и не равен 0); `test_cloud_fade`, `test_cloud_layer_history`, `test_cloud_select_chunked` на записях; сравнение пыли: события клеток (число и позиции) на кадре `ongudai` до и после — равны при том же ветре.
- **Размер:** 3 дня. **Зависит от:** шаг 1 12zc (обёртки) и 12zb.
- **Замечание о RW-11e.** Карточка RW-11e («`cloud_layer.gd` на W6 v4», зависит от 11c, 11d) в прежнем виде невыполнима: `cloud_objects` в GDScript появляется только с 12zb/12zc (W6 v4: «вводятся в RW-12z»). Предложение: **RW-11e целиком — в 12zd** (скоуп `cloud_layer.gd`/`cloud_model.gd` совпадает, ~300 строк GD в оценке 11e), отдельную 11e не запускать. Если координатор уже запустил 11e — 12zd берёт остаток, а не дублирует.

### Что общее для всех четырёх
- Тяжёлое (полный T1, `acceptance_release`, `tests_vs_base`, T9, прогоны Godot вне целевого фильтра) — в итоговый прогон (решение 2026-10-29), не в accept задач. В каждой задаче: `cargo test`/`clippy`/`fmt` и, для GDScript, `gdlint`/`gdformat` и целевой фильтр тестов.
- Файлы не пересекаются: `formula.rs`/`terms/` — только 12za; `dp-gd/` — только 12zb; `atmosphere.gd`/`calm_air.gd` — только 12zc; `cloud_layer.gd`/`gust_dust*.gd`/храповик — только 12zd. Тесты-контракты `test_rust_wind_contracts.gd` — 12zc, `test_dp_air_ext.gd` — 12zb.
- Критический путь: 12za (шаг 1: 0,5 дня; полностью 3–4) → 12zb (1) → 12zc шаг 1 (0,5) → 12zc шаг 2 ∥ 12zd (по 3) ≈ 8–9 календарных дней при последовательном шаге 1.

## 5. Сомнения из `uncertain.md` с пометкой RW-12z (и связанные) — кому какое

| источник | сомнение (кратко) | задача | действие |
|---|---|---|---|
| RW-7b (`cli-tests.md`, `debug.md`) | описан удалённый `--air-field` | RW-13 | документация; не здесь |
| RW-7b (`debug_raster` «карта фаз») | крейт карту фаз не отдаёт | 12zc | `debug_raster_names()` без `phase`; оверлей фаз в `wind_field_debug.gd` — вне горячего пути, решает пользователь (отладочный инструмент); по умолчанию — не переносить |
| RW-7b (`atmosphere.gd`) | поле только для прогноза, пресет без поля — строже W2 | 12zc | тест пресета с `on`; итоговый T7 |
| RW-12c (`weather/`) | нет эталонов `cases/<имя>.weather.json` | 12za (тест), итоговый прогон (дамп `weather_dump.sh`/`day_dump.sh`) | `ongudai_day_*` в тесте (в) |
| RW-10b (`Terms::advance`) | построение термиков 2 мс при бюджете 0,5 | 12za п. 6 | фон (`thermal_async`), бенч |
| RW-10c (`SourceHour::at`) | часовой множитель не сверен с `AtmoDay.source_fn` | 12za п. 3.1 | сверка в тесте (в) на потоке часов |
| RW-11b (`WaveExtra::flow`) | `Mutex` на каждый вызов | 12za | бенч с волной; уходит под ключ места (п. 5) |
| RW-11b, RW-9 (кеш места по указателю) | ложное попадание | 12za п. 5 | ключ — `sh.epoch`; тест (д) |
| RW-11b (`terms_of`) | `air_mode off` включает профиль вручную | 12za п. 4 | `Formula` включает сама |
| RW-12d (`PlaceLink::of`, `ref_msl`) | `start_msl_m`, `ref_msl` = NaN | 12za п. 3.1 | `ref_msl` — из `Conditions.wind_ref`; пресет без `ref_msl` — берётся из эталона W5; нужна ли новая запись — `contract:` координатору |
| RW-12d (`advance_weather`) | `true` каждые 0,1 с | 12za п. 7 | порог изменения (§2.3) |
| RW-10e (`tests/data/RW-10e`) | 4,96 МиБ у края 5 МБ | итог | не расти; в 12za новых данных > 1 МБ не добавлять |
| RW-11d (`set_inputs`, разгон) | шаг 0,43 мс + клон, разгон 56 мс синхронно | 12za п. 6 | фон + бенч W3 |
| RW-11d (`Terms.clouds` не в `Slots`) | слот облаков вне `Slots` | 12za | оставить: `Slots` — `Arc<dyn Trait>` без состояния шага; запись в комментарии |
| RW-10f (`synced_with_clouds`, T6 `start_at ≠ прогон с 0`) | формулировка `start_at` | W2 v4 (§2.1) + 12zc | тест T6 по новой формулировке |
| RW-10f (`AirInputs` в тесте) | входы облаков из `Field`+`AirThermals` | 12za п. 3.3 | `CloudInputs` в `Formula` |
| RW-8 (`sigma advect`, `ground_ref`) | `speed_at(300)` на каждом опросе; cloudbase для σ из погоды, в GD — из поля | 12za п. 8 | кеш в `Terms`; сверка σ на `ongudai_*` |
| RW-8 (`state`) | 18 точек ≤ 50 мкс не замерено | 12za | бенч W8 |
| RW-9 (`terms_analytic.rs`, `ref_msl`) | пресет без `ref_msl` — ветер вдвое | 12za | вместе с RW-12d |
| RW-8s (`surface_gust`) | нет признака места; свой `GustUnit` | 12za | нули без места/не `Ready`; общий `GustUnit` с Turb — только если сверка σ покажет расхождение |
| RW-8s (`tests/data/RW-8s`) | не полный прогон `Atmosphere` | итог | вместе с T7 |
| RW-7a (`field_export` мьютекс, `set_field_enabled`) | zstd под замком; отказ после включения → `Failed` | итог (T7) | тест «включение поля в полёте» — в целевой набор 12zc |
| RW-7b (`air_place_data.gd`, слои конфигов) | `utc_offset_h = NaN`; пилотский слой | итог (T7) | вне 12z |
| RW-2c (`off` на Онгудае) | нет покрытия | 12za (после RW-9) | случай `off` на реальном рельефе в тест (а) |

## 6. Открытые вопросы к координатору

1. **Порог бюджета `advance_to`** (п. 3.6): если фон для облаков усложняет детерминизм (`air.deterministic = true` — всё в `advance`), оставить синхронный путь для детерминированного режима и бенч только для фонового — предлагаю так.
2. **RW-11e целиком в 12zd** (§4).
3. **Режим `off`** целиком зависит от RW-9; до его слияния 12za уходит без него (§4).
4. **`ground_ref` для `background_wind`**: взять `PlaceLink.ctx.mean_msl_m` или считать как GD `WeatherModel.ground_context`; проверка — точка `ongudai_*` в тесте (в). Если значения не сходятся — `contract:` на добавление поля в `Place`.
5. Для T9 (боты, сравнение с `main`) нужна сборка ветки после 12zd; это итоговый прогон, не часть 12z.
