---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-16a: аудит чистоты dp-air по решению 2026-10-30 — 458 нарушений по пяти категориям, файл:строка, куда деть, влияние на W3/W4/W5."
---

# RW-16a: аудит чистоты dp-air

Решение пользователя 2026-10-30: `dp-air` — чистая библиотека ветра и погоды, про игру не знает. Критерии: (а) нет Godot (мост только `dp-gd`); (б) нет путей и раскладки игры (`res://`, `data/locations`, имена `configs/*.json`); (в) нет понятий игры; (г) compat — решить после RW-13. Код этой задачей не правился.

## Проверка

`bash tools/dp_air_purity.sh [-v] [категория]` — grep по `rust/dp-air/src` и `Cargo.toml`, печатает «нарушений: N». Критерий приёмки модуля — 0 (или список исключений, согласованный с пользователем). Строка, подходящая под две категории, считается в обеих. Комментарии `//` считаются отдельно от кода: ссылка на GDScript в доке — тоже знание об игре, но чинится правкой текста. Регэкспы грубые: возможны ложные срабатывания (проверено вручную, слова `bot`, `gd` как градиент, `Variant` исключены), пропуски — для слов вне списка.

| Категория | код | комментарии |
|---|---|---|
| godot | 5 | 144 |
| paths | 11 | 63 |
| cfgnames | 28 | 43 |
| game | 66 | 81 |
| compat | 16 | 1 |
| **всего** | 126 | 332 |

Критерий (а): `Cargo.toml` без `godot`/`gdext`; зависимости — serde, serde_json, rayon, zstd, half, sha2, picard_rs. Выполнен. `rust/dp-air/tests` и `benches` вне границ скрипта (читают фикстуры игры) — проверять отдельно при RW-16.

## Что делать, по категориям

### godot: Godot / GDScript в тексте и именах

**Куда деть:** Комментарии переформулировать («эталонная реализация», без ссылок на `.gd`); `gd_num` (`field/baked.rs`) уходит вместе с baked (см. game). Зависимости от Godot в `Cargo.toml` нет — критерий (а) выполнен.

**Влияние на контракты:** нет: W3/W4/W5 не называют эти идентификаторы; правка только текста `//!`

### paths: Пути и раскладка игры, суффикс `.json` в именах конфигов

**Куда деть:** `BAKED_ROOT = res://data/locations` и `baked_path` — удалить с baked (запечённые поля убраны решением RP11). Поиск «name | name.json» в 6 копиях (`find`/`named_json`/`json`) свести в один `Configs::get(name)`; пути в `fixtures.rs` (`places/<имя>.json`, `desc.json`) — вынести в `tests/` или dev-feature, не в публичный src.

**Влияние на контракты:** W5 v9: `Configs.files` — пары (имя, текст). Либо оставить имя как есть без обработки `.json`, либо секции (см. cfgnames): правка W5

### cfgnames: Имена конфигов игры (atmosphere, weather_model, surface_heat, world, air_phase)

**Куда деть:** Конфиги приходят данными, но крейт знает имена файлов игры. Предложение: типизированные секции вместо имён файлов — `Configs { atmosphere, weather, surface_heat, world: Value }` (или перечисление `Section`), а сопоставление «файл игры -> секция» делает `dp-gd`/GDScript. Слова `atmosphere.json` в `dp-air` не остаётся.

**Влияние на контракты:** W5 v10 (структура `Configs`: из пар имя/текст в секции), W3 `set_configs` принимает словарь секций (меняется место сопоставления), W4 `configure` — сигнатура. Затрагивает ~25 мест чтения

### game: Игровые понятия: пилот, запечённое поле, AirRuntime

**Куда деть:** `pilot` (клипмап, `formula.rs`) — положение наблюдателя: переименовать в `observer`/`focus` (W3/W4 говорят «фокус»). Весь `baked` (`field/baked.rs`, `BakedEntry`, `pick_baked`, `Source::Baked`, `add_baked_field` в трейте) — мёртвый код после RP11: удалить (~600 строк baked.rs + ветки в `runtime.rs`, `formula.rs`, `field_cache.rs`). Формат кеша на диске (`field_cache`) — понятие библиотеки; его тип `BakedField` переименовать в `SolvedField`. `AirRuntime` встречается в комментариях-ссылках на GD-код — убрать.

**Влияние на контракты:** W4: `add_baked_field`, `Source::Baked` убрать из трейта (контракт уже пишет «удалены» — расхождение с кодом). W3: убрать `add_baked_field` в `dp-gd`. Версия: решает координатор (W4 v10 вместе с секциями)

### compat: Слой compat (Godot FastNoiseLite / PCG32 / hash)

**Куда деть:** Решение пользователя: после RW-13 выбрать — оставить как обычный шум/ГСЧ без «Godot» либо заменить своим. Рекомендация: оставить и переименовать `compat::{noise,rng,hash}` -> `noise`/`rand`/`hash` (самодостаточный код: OpenSimplex2S — Jordan Peck, MIT; PCG32 — стандарт); числа без причины не менять. Тест `tests/godot_compat.rs` и `tools/wind_fixtures/compat_dump.sh` — удалить или оставить регрессом по файлу дампа.

**Влияние на контракты:** W3/W4/W5 не затрагиваются: слой внутренний, публичных типов compat в контракте нет

## Сводка по контрактам

- W5 (вход): главное влияние — имена конфигов (`cfgnames`, `paths`); предлагается v10 вместе с правкой W3 `set_configs` и W4 `configure`.
- W4: убрать `add_baked_field` / `Source::Baked` (код расходится с контрактом после RP11).
- W3: убрать `add_baked_field` в `dp-gd`; остальное без изменений.
- Порядок: сначала удалить baked (самое крупное, контракт уже «убрано»), затем секции конфигов (одна правка W5), затем переименования pilot/compat и правка комментариев.

## Нарушения по файлам

Код — построчно, комментарии — номера строк. Те же строки покажет `tools/dp_air_purity.sh -v`.

### godot

Код:

- `src/field/baked.rs:351`: `pub fn gd_num(x: f64) -> String {`
- `src/field/baked.rs:410`: `format!("{path}: {} ≠ {}", gd_num(x), gd_num(y))`
- `src/field/baked.rs:559`: `gd_num(c.t_max),`
- `src/field/baked.rs:560`: `gd_num(t_max)`
- `src/field/phase/assembly.rs:246`: `let (l, d) = (g.gl[c], g.gd[c]);`

Комментарии (файл: строки):

- `src/lib.rs`: 3
- `src/level.rs`: 4
- `src/compat/noise.rs`: 1, 2, 28, 66, 356
- `src/compat/rng.rs`: 1, 13, 38
- `src/compat/hash.rs`: 1, 3
- `src/compat/mod.rs`: 1, 2, 3
- `src/field/place_input.rs`: 1, 13, 37
- `src/field/field_set.rs`: 1, 2
- `src/field/runtime.rs`: 1, 3, 86, 366, 643
- `src/field/case_prepare.rs`: 3, 26
- `src/field/window.rs`: 2, 3
- `src/field/clipmap.rs`: 1, 2
- `src/field/weather_core.rs`: 2, 4
- `src/field/baked.rs`: 4, 18, 20, 344, 349, 380, 513, 578
- `src/field/phase/linear.rs`: 7, 226
- `src/field/phase/bubble.rs`: 11
- `src/field/phase/prepare.rs`: 6, 10, 44, 205
- `src/field/phase/calm.rs`: 14
- `src/field/phase/drainage.rs`: 310
- `src/field/phase/mech.rs`: 30
- `src/field/phase/layers.rs`: 7, 18, 31
- `src/field/field_cache.rs`: 1, 2, 8
- `src/field/wind_field.rs`: 1, 2, 13, 74
- `src/terms/waves/field.rs`: 1, 112, 125, 311
- `src/terms/clouds/sources.rs`: 1, 4, 68
- `src/terms/clouds/physics.rs`: 1, 5
- `src/terms/clouds/field.rs`: 1, 7
- `src/terms/thermal/statics.rs`: 20
- `src/terms/thermal/cells.rs`: 1, 4, 27, 199
- `src/terms/thermal/cores.rs`: 3
- `src/terms/thermal/life.rs`: 1, 8, 17, 288
- `src/terms/thermal/mod.rs`: 4
- `src/terms/storm/cloud_model.rs`: 1, 3, 11, 77
- `src/terms/storm/field.rs`: 1, 9, 106
- `src/terms/storm/mod.rs`: 6, 9, 11, 87
- `src/terms/sum.rs`: 1
- `src/terms/objects/mod.rs`: 1, 5, 9
- `src/terms/thermal_air/expected.rs`: 8
- `src/terms/thermal_air/mod.rs`: 1, 2, 12, 20, 23, 92, 93, 113
- `src/terms/surface_gust/mod.rs`: 2
- `src/terms/thermal_src/mod.rs`: 2
- `src/terms/frame.rs`: 1, 158, 271
- `src/terms/turb/spectrum.rs`: 1, 5, 6
- `src/terms/turb/gust.rs`: 1, 2, 6, 7, 69
- `src/terms/turb/sep.rs`: 1, 2, 17
- `src/terms/turb/sigma.rs`: 1, 145, 318
- `src/terms/turb/mod.rs`: 12
- `src/terms/analytic/ground.rs`: 1
- `src/terms/analytic/noise.rs`: 1, 2, 5
- `src/terms/analytic/ridge.rs`: 1
- `src/terms/analytic/strip.rs`: 1
- `src/terms/analytic/lee.rs`: 1, 63
- `src/terms/analytic/mod.rs`: 2, 4
- `src/terms/mod.rs`: 468
- `src/weather/day.rs`: 72
- `src/weather/noise.rs`: 12
- `src/weather/coeffs.rs`: 2
- `src/weather/mod.rs`: 1, 3
- `src/debug_rasters.rs`: 3

### paths

Код:

- `src/fixtures.rs:24`: `let stem = s.strip_suffix(".json").unwrap_or(&s);`
- `src/fixtures.rs:260`: `root.join("places").join(format!("{}.json", self.place))`
- `src/fixtures.rs:449`: `let p = sibling(case_path, "desc.json");`
- `src/field/place_input.rs:42`: `.find(|(n, _)| n.strip_suffix(".json").unwrap_or(n) == "atmosphere")`
- `src/field/runtime.rs:237`: `.find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))`
- `src/field/weather_core.rs:189`: `.find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))`
- `src/field/baked.rs:42`: `pub const BAKED_ROOT: &str = "res://data/locations";`
- `src/field/baked.rs:574`: `format!("{BAKED_ROOT}/{location}/air/{site}.json")`
- `src/field/phase/config.rs:172`: `.find(|(n, _)| n.strip_suffix(".json").unwrap_or(n) == "atmosphere")`
- `src/terms/frame.rs:98`: `.find(|(n, _)| n == "atmosphere" || n == "atmosphere.json")`
- `src/terms/mod.rs:115`: `.find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))`

Комментарии (файл: строки):

- `src/fixtures.rs`: 4, 6, 21, 78, 87, 121, 254, 264, 404
- `src/field/place_input.rs`: 37
- `src/field/runtime.rs`: 54, 116, 136
- `src/field/wind_profile.rs`: 44
- `src/field/weather_core.rs`: 79, 103, 105
- `src/field/baked.rs`: 494
- `src/field/phase/config.rs`: 1, 167, 178
- `src/field/field_cache.rs`: 26
- `src/field/surface_heat.rs`: 55, 324
- `src/terms/waves/field.rs`: 27
- `src/terms/weather_link.rs`: 28, 67, 69
- `src/terms/clouds/cfg.rs`: 1, 2
- `src/terms/thermal/air.rs`: 82
- `src/terms/thermal/cfg.rs`: 1, 2
- `src/terms/storm/cloud_model.rs`: 11
- `src/terms/storm/field.rs`: 9
- `src/terms/thermal_air/mod.rs`: 143, 166, 197
- `src/terms/surface_gust/mod.rs`: 7, 21
- `src/terms/thermal_src/mod.rs`: 65
- `src/terms/frame.rs`: 13, 60
- `src/terms/turb/gust.rs`: 11, 36
- `src/terms/turb/sigma.rs`: 23
- `src/terms/analytic/noise.rs`: 13
- `src/terms/analytic/mod.rs`: 40
- `src/terms/mod.rs`: 73, 111, 366, 373, 394
- `src/weather/day.rs`: 4, 30, 50
- `src/weather/climate.rs`: 115
- `src/weather/coeffs.rs`: 1, 73, 195
- `src/weather/tables.rs`: 1
- `src/place.rs`: 27, 37

### cfgnames

Код:

- `src/field/place_input.rs:42`: `.find(|(n, _)| n.strip_suffix(".json").unwrap_or(n) == "atmosphere")`
- `src/field/runtime.rs:296`: `let atm = json(c, "atmosphere")?;`
- `src/field/runtime.rs:297`: `let wm = json(c, "weather_model")?;`
- `src/field/weather_core.rs:201`: `let atm = match find(c, "atmosphere") {`
- `src/field/weather_core.rs:202`: `Some(_) => parse_named(c, "atmosphere")?,`
- `src/field/weather_core.rs:205`: `let mut wm = WeatherModelCfg::from_value(&parse_named(c, "weather_model")?);`
- `src/field/weather_core.rs:209`: `sh: SurfaceHeatCfg::from_value(&parse_named(c, "surface_heat")?)?,`
- `src/field/phase/config.rs:172`: `.find(|(n, _)| n.strip_suffix(".json").unwrap_or(n) == "atmosphere")`
- `src/field/phase/config.rs:183`: `.get("air_phase")`
- `src/terms/waves/field.rs:78`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/weather_link.rs:88`: `let atm = named_json(c, "atmosphere");`
- `src/terms/weather_link.rs:89`: `let wm = named_json(c, "weather_model").map(|v| {`
- `src/terms/clouds/cfg.rs:73`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/clouds/cfg.rs:159`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/thermal/cfg.rs:112`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/thermal/mod.rs:320`: `thermal: crate::terms::named_json(&terms.configs, "atmosphere")`
- `src/terms/storm/cloud_model.rs:45`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/storm/field.rs:66`: `let atm = named_json(c, "atmosphere").unwrap_or(serde_json::Value::Null);`
- `src/terms/surface_gust/mod.rs:44`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/thermal_src/mod.rs:101`: `Self::from_values(&get("surface_heat")?, &get("world")?)`
- `src/terms/frame.rs:98`: `.find(|(n, _)| n == "atmosphere" || n == "atmosphere.json")`
- `src/terms/turb/gust.rs:38`: `let atm = crate::terms::named_json(c, "atmosphere").unwrap_or(serde_json::Value::Null);`
- `src/terms/turb/sigma.rs:106`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/analytic/mod.rs:58`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/mod.rs:99`: `let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);`
- `src/terms/mod.rs:229`: `let det = named_json(configs, "atmosphere")`
- `src/terms/mod.rs:239`: `self.ground_tol_deg = named_json(configs, "atmosphere")`
- `src/formula.rs:1257`: `self.fade_out_s = terms::named_json(&self.configs, "atmosphere")`

Комментарии (файл: строки):

- `src/field/runtime.rs`: 54, 116, 136
- `src/field/wind_profile.rs`: 44
- `src/field/weather_core.rs`: 79, 103, 105
- `src/field/phase/config.rs`: 1, 178
- `src/field/field_cache.rs`: 26
- `src/field/surface_heat.rs`: 55, 324
- `src/terms/waves/field.rs`: 27
- `src/terms/weather_link.rs`: 28, 67, 69
- `src/terms/clouds/cfg.rs`: 1, 2
- `src/terms/thermal/air.rs`: 82
- `src/terms/thermal/cfg.rs`: 1, 2
- `src/terms/storm/cloud_model.rs`: 11
- `src/terms/storm/field.rs`: 9
- `src/terms/thermal_air/mod.rs`: 143, 166, 197
- `src/terms/surface_gust/mod.rs`: 7, 21
- `src/terms/thermal_src/mod.rs`: 65
- `src/terms/frame.rs`: 60
- `src/terms/turb/gust.rs`: 11, 36
- `src/terms/turb/sigma.rs`: 23
- `src/terms/analytic/noise.rs`: 13
- `src/terms/analytic/mod.rs`: 40
- `src/terms/mod.rs`: 73
- `src/weather/climate.rs`: 115
- `src/weather/coeffs.rs`: 1, 73, 195
- `src/weather/tables.rs`: 1
- `src/place.rs`: 27, 37

### game

Код:

- `src/field/runtime.rs:57`: `use super::baked::{BakedField, BakedQuery, Cond, FORMAT, VERSION, baked_lookup, parse_baked};`
- `src/field/runtime.rs:566`: `pub struct BakedEntry {`
- `src/field/runtime.rs:575`: `impl BakedEntry {`
- `src/field/runtime.rs:578`: `let bad = |m: String| Error::bad_input(format!("baked field: {m}"));`
- `src/field/runtime.rs:583`: `return Err(bad("not a dp-air-baked v1 header".into()));`
- `src/field/runtime.rs:594`: `Ok(BakedEntry {`
- `src/field/runtime.rs:617`: `pub field: BakedField,`
- `src/field/runtime.rs:635`: `Baked,`
- `src/field/runtime.rs:644`: `fn pick_baked(job: &JobIn) -> Result<BakedField, String> {`
- `src/field/runtime.rs:646`: `if job.baked.is_empty() {`
- `src/field/runtime.rs:664`: `let cands: Vec<&BakedEntry> = job`
- `src/field/runtime.rs:665`: `.baked`
- `src/field/runtime.rs:670`: `return Err(format!("нет файла запечённого поля места {}", h.loc.id));`
- `src/field/runtime.rs:681`: `let q = BakedQuery {`
- `src/field/runtime.rs:702`: `let stub = BakedField {`
- `src/field/runtime.rs:880`: `pub baked: Arc<Vec<BakedEntry>>,`
- `src/field/runtime.rs:1674`: `fn from_file(job: JobIn, b: BakedField, source: Source, t0: Instant, notes: Vec<String>) -> JobOut {`
- `src/field/runtime.rs:1707`: `Ok(b) => return Ok(from_file(job, b, Source::Baked, t0, notes)),`
- `src/field/runtime.rs:1708`: `Err(m) if !m.is_empty() => notes.push(format!("baked: {m}")),`
- `src/field/runtime.rs:1854`: `field: BakedField {`
- `src/field/clipmap.rs:188`: `pub fn shift_level(corners: &[[f64; 2]], dxs: &[f64], pilot: [f64; 2], frac: f64) -> Option<usize> {`
- `src/field/clipmap.rs:192`: `(pilot[0] - m[0]).abs().max((pilot[1] - m[1]).abs()) > frac * side`
- `src/field/clipmap.rs:197`: `pub fn shifted_corner(c: [f64; 2], dx: f64, pilot: [f64; 2]) -> [f64; 2] {`
- `src/field/clipmap.rs:200`: `c[0] + ((pilot[0] - m[0]) / dx).round() * dx,`
- `src/field/clipmap.rs:201`: `c[1] + ((pilot[1] - m[1]) / dx).round() * dx,`
- `src/field/clipmap.rs:247`: `pub fn shift_target(&self, pilot: [f64; 2], frac: f64) -> Option<usize> {`
- `src/field/clipmap.rs:248`: `shift_level(&self.corners, &self.dxs, pilot, frac)`
- `src/field/clipmap.rs:253`: `pub fn plan_shift(&self, q: usize, pilot: [f64; 2]) -> Plan {`
- `src/field/clipmap.rs:255`: `return Plan::fresh(&self.dxs, pilot);`
- `src/field/clipmap.rs:263`: `shifted_corner(self.corners[i], self.dxs[i], pilot)`
- `src/field/clipmap.rs:552`: `pub fn run_shift(job: JobIn, q: usize, pilot: [f64; 2]) -> Result<JobOut, JobErr> {`
- `src/field/clipmap.rs:557`: `let plan = clip.plan_shift(q, pilot);`
- `src/field/baked.rs:28`: `pub const FORMAT: &str = "dp-air-baked";`
- `src/field/baked.rs:48`: `pub struct BakedField {`
- `src/field/baked.rs:90`: `Error::bad_input(format!("baked: {}", msg.into()))`
- `src/field/baked.rs:102`: `pub fn parse_baked(header_json: &str, data: &[u8]) -> Result<BakedField, Error> {`
- `src/field/baked.rs:135`: `Ok(BakedField {`
- `src/field/baked.rs:266`: `b: &BakedField,`
- `src/field/baked.rs:468`: `pub struct BakedQuery<'a> {`
- `src/field/baked.rs:499`: `pub fn make_key(q: &BakedQuery) -> Value {`
- `src/field/baked.rs:580`: `fields: &'a [BakedField],`
- `src/field/baked.rs:581`: `q: &BakedQuery,`
- `src/field/baked.rs:582`: `) -> Result<&'a BakedField, Reject> {`
- `src/field/field_cache.rs:14`: `use super::baked::{BakedField, encode_baked, key_diff, parse_baked};`
- `src/field/field_cache.rs:79`: `pub fn get(&self, key: &Value, model_hash: &str) -> Result<BakedField, Miss> {`
- `src/field/field_cache.rs:106`: `field: &BakedField,`
- `src/field/field_cache.rs:177`: `fn decode(raw: &[u8], key: &Value, model_hash: &str) -> Result<BakedField, String> {`
- `src/field/mod.rs:2`: `pub mod baked;`
- `src/formula.rs:46`: `use crate::field::baked::{BakedField, encode_baked};`
- `src/formula.rs:51`: `BakedEntry, CondRec, Faults, JobErr, JobIn, JobOut, JobReport, Pair, RtCfg, Source,`
- `src/formula.rs:264`: `let b = BakedField {`
- `src/formula.rs:434`: `Some((q, pilot)) => run_shift(job, q, pilot),`
- `src/formula.rs:516`: `baked: Arc<Vec<BakedEntry>>,`
- `src/formula.rs:612`: `baked: Arc::new(Vec::new()),`
- `src/formula.rs:1018`: `baked: self.baked.clone(),`
- `src/formula.rs:1124`: `let pilot = [f64::from(f.pos[0]), -f64::from(f.pos[2])];`
- `src/formula.rs:1126`: `if !self.pilot_left_baked(cfg, pilot) {`
- `src/formula.rs:1141`: `let q = clip.shift_target(pilot, cfg.shift_frac)?;`
- `src/formula.rs:1143`: `self.shift_req = Some((q, pilot));`
- `src/formula.rs:1151`: `fn pilot_left_baked(&self, cfg: &RtCfg, pilot: [f64; 2]) -> bool {`
- `src/formula.rs:1161`: `(pilot[0] - cx).abs().max((pilot[1] - cy).abs()) > cfg.shift_frac * side`
- `src/formula.rs:1279`: `self.baked = Arc::new(Vec::new());`
- `src/formula.rs:1323`: `self.baked = Arc::new(Vec::new());`
- `src/formula.rs:1452`: `let e = BakedEntry::new(header_json, data)?;`
- `src/formula.rs:1461`: `let mut list: Vec<BakedEntry> = self.baked.as_ref().clone();`
- `src/formula.rs:1464`: `self.baked = Arc::new(list);`

Комментарии (файл: строки):

- `src/lib.rs`: 130
- `src/level.rs`: 204
- `src/types.rs`: 172
- `src/field/field_set.rs`: 7, 168
- `src/field/runtime.rs`: 1, 25, 26, 27, 32, 88, 97, 220, 358, 452, 561, 643, 925, 1601, 1618, 1629, 1631, 1673, 1698
- `src/field/case_prepare.rs`: 173
- `src/field/wind_profile.rs`: 129
- `src/field/window.rs`: 45, 181, 347, 385
- `src/field/clipmap.rs`: 2, 35, 36, 186, 196, 245, 251, 252, 549
- `src/field/weather_core.rs`: 1, 226, 419
- `src/field/baked.rs`: 4, 11, 13, 16, 30, 454, 466, 489, 494, 520, 572, 577
- `src/field/case_build.rs`: 1, 20, 74, 90
- `src/field/phase/assembly.rs`: 4, 35, 145
- `src/field/phase/prepare.rs`: 91
- `src/field/phase/config.rs`: 15
- `src/field/phase/drainage.rs`: 5, 150
- `src/field/wind_field.rs`: 22, 24, 175
- `src/terms/clouds/sources.rs`: 29
- `src/terms/clouds/physics.rs`: 43
- `src/terms/thermal_src/mod.rs`: 4, 19, 233
- `src/terms/turb/sigma.rs`: 248
- `src/formula.rs`: 18, 524, 1045, 1148
- `src/place.rs`: 69, 70
- `src/debug_rasters.rs`: 3

### compat

Код:

- `src/lib.rs:6`: `pub mod compat;`
- `src/terms/clouds/field.rs:11`: `use crate::compat::hash::hash_v2i;`
- `src/terms/thermal/statics.rs:6`: `use crate::compat::hash::hash_v2i;`
- `src/terms/thermal/air.rs:9`: `use crate::compat::rng::Pcg32;`
- `src/terms/thermal/cells.rs:12`: `use crate::compat::rng::Pcg32;`
- `src/terms/thermal/life.rs:5`: `use crate::compat::rng::Pcg32;`
- `src/terms/thermal_air/pick.rs:3`: `use crate::compat::hash::hash_v3i;`
- `src/terms/thermal_air/pick.rs:4`: `use crate::compat::rng::Pcg32;`
- `src/terms/thermal_air/sources.rs:4`: `use crate::compat::rng::Pcg32;`
- `src/terms/turb/spectrum.rs:7`: `use crate::compat::noise::{FastNoise, Fractal};`
- `src/terms/turb/spectrum.rs:8`: `use crate::compat::rng::Pcg32;`
- `src/terms/turb/gust.rs:8`: `use crate::compat::noise::{FastNoise, Fractal};`
- `src/terms/turb/gust.rs:9`: `use crate::compat::rng::Pcg32;`
- `src/terms/turb/sep.rs:6`: `use crate::compat::rng::Pcg32;`
- `src/terms/analytic/noise.rs:10`: `use crate::compat::noise::{FastNoise, Fractal};`
- `src/terms/analytic/noise.rs:11`: `use crate::compat::rng::Pcg32;`

Комментарии (файл: строки):

- `src/terms/turb/mod.rs`: 5

