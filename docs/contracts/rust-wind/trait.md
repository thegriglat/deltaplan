---
type: "contract"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "W4 rust-wind: трейт AirModel крейта dp-air (без Godot) — типы, методы, порядок команд, структуры описаний, реализации Calm/Formula/Live."
related: ["docs/contracts/rust-wind.md", "docs/plan/rust-wind.md"]
contracts: [{"id": "W4", "version": 2}]
---

# W4. Трейт `AirModel` (крейт `dp-air`, без Godot) (v2)

Часть `docs/contracts/rust-wind.md` (версия — там, заголовок W4). Менять — только координатор.
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

