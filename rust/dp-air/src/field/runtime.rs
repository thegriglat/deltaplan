//! Оркестровка поля Пикара в крейте (RW-6j): перенос оркестровки — загрузка,
//! грубый старт 1200 → 400 м, пара решений mech → heat, пересчёт на
//! сроке, тёплые состояния, откат прохода и таймаут. Без движка, без состояния: одна функция
//! [`run_job`] делает одно «поле» (загрузку или пересчёт) и возвращает уровни и состояния;
//! подмену, фон, отмену и опросы ведёт `Formula` (`formula.rs`).
//!
//! ## Цепочка прохода ([`solve_pass`])
//! `field_weather` (6c) → `build_domain_input` (6b) → `build_case` (6d, с нагревом и
//! `without_heat`) → `prepare` → `build_solver_case` (6e) → [грубый Пикар 1200 м: mech → heat,
//! `prolong_state` (6f)] → `picard_rs::api::solve` mech, затем heat (каждое со своим стартом) →
//! `Field::from_mac` (6i). Старт решений: прошлое поле пары (пересчёт в полёте), иначе грубый старт (`air_model.picard_start = coarse`), иначе фон. Отказ грубого
//! шага — старт с фона без ошибки.
//!
//! ## Один проход ([`run_job`])
//! Загрузка и пересчёт в полёте — один проход [`solve_pass`]: ветер условий — всегда набегающий
//! поток на границах области (приток `k = 1`, WF-К1), подбора по ветру над стартом нет. Загрузка
//! стартует с грубого шага или фона, пересчёт — с прошлого поля пары.
//!
//! ## Фазы (RW-6t, `_after_phases`/`_start_picard`)
//! После сборки уровня на каждом проходе — [`assemble`] (фазы 1–3): маски и поля заморозки колонн
//! (`freeze` для решения с нагревом, `freeze_mech` для без нагрева), `nonconv` в запасных правилах
//! обоих решений. Старт решений — как в эталоне: прошлое поле пары, грубый шаг, иначе фон; `warm` фаз
//! в эталоне Пикару стартом не служит (только внутри `nonconv`) и здесь не используется. Карта ω
//! (`omega.use_map`, в эталоне выключена) не подаётся. Все колонны заморожены в обоих вариантах —
//! грубый шаг пропускается (`all_mech`), Пикар возвращает поле заморозки без итераций. Отказ фаз —
//! заметка и Пикар без них.
//!
//! ## Кеш полей (RW-6t, `load_field`)
//! Только загрузка (`loading`): кеш (`set_cache_dir`) → расчёт; запись в кеш — после готового поля,
//! в пуле, после подачи. Нужен `header.model_hash` места (пусто — без кеша). Попадание — уровни из
//! файла кеша, `Ready` без Пикара; промах — причина в `JobReport.notes`.
//!
//! ## Отмена (W11 v6, W1 «≤ 1 с»)
//! Флаг отмены проверяется между стадиями подготовки ([`build_level`]: погода, вход области, случай,
//! `prepare`, случай решателя), после фаз, перед каждым решением и внутри `picard_rs` (сборка
//! уровней многосетки, V-циклы старта, каждая итерация, финальная проекция). Не прерываются:
//! сборка фаз (до ~0,15 с на release, ~0,7 с на `-O0`) и сами шаги стадий; `Formula` ждёт задачу
//! не дольше `JOIN_LIMIT` (0,5 с) и отпускает её сменой поколения места.
//!
//! ## Границы модели
//! - Окна 100/50 м (RW-6o, `field::clipmap`): после области прохода считаются окна
//!   `window_levels_m` с центром на старте (первый фокус; нет фокуса — нет окон), пересчёт в
//!   полёте — на прежних местах с тёплого старта. Ошибка окон не отказ прохода: поле — только область, причина в
//!   `JobReport.windows_error`. Сдвиг окон за фокусом — отдельная задача (`clipmap::run_shift`).
//! - Область — квадрат вокруг (0, 0), `domain_l_m` (по умолчанию 38,4 км); место меньше —
//!   область сжимается до помещающейся (кратно `dx·coarse_factor`), меньше 12 клеток — отказ.
//! - Климат места — из секция `weather_model` (`typical_max_c`, `diurnal.range_k`), как GD без
//!   сеток ERA5: `Loc.climate` (W5 v3) в заголовке пока не разбирается (`place.rs`).
//! - Время решения не ограничено (W5 v7): остановка — только отмена и ошибки.
use super::case_build::{SolverCfg, build_solver_case};
use super::case_prepare::{AirCaseRs, CaseOpts, PreparedPlanes, build_case};
use super::clipmap::{ClipMap, ParentArea, Plan, WinReport, ZiArea, solve_windows};
use super::field_cache::{FieldCache, Miss};
use super::field_set::FieldSet;
use super::phase::assembly::{PhaseResult, assemble};
use super::phase::config::PhaseCfg;
use super::phase::prepare::PhaseCase;
use super::place_input::{ZiCfg, build_domain_input};
use super::solved::SolvedField;
use super::weather_core::{
    Climate, ClimateCell, Domain, FieldWeather, WeatherConfigs, WeatherInputs, field_weather,
    monthly,
};
use super::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use super::window::tcode;
use crate::level::{Level, prolong_state};
use crate::weather::Weather;
use crate::{Conditions, Configs, Error, Place, Raster};
use picard_rs::api::{Fallback, Freeze, NonConv, SolveOpts, Solved, StopReason, solve};
use picard_rs::case::Case;
use picard_rs::state::State;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Instant;

pub use picard_rs::api::StopReason as Stop;

// ---------------------------------------------------------------- константы эталона

/// Шаг области, м (`DX`).
pub const DX: f64 = 400.0;
/// Порог заданного ветра профиля (`WindProfile.U10_MIN`).
pub const U10_MIN: f64 = 0.5;
/// Допуски пересчёта: ветер, направление, температура (`WIND_TOL_MS`, `DIR_TOL_DEG`, `TMAX_TOL_C`).
pub const WIND_TOL_MS: f64 = 0.05;
pub const DIR_TOL_DEG: f64 = 1.0;
pub const TMAX_TOL_C: f64 = 0.25;
/// Предел итераций решения (`AirPicardJob.max_outer`).
pub const MAX_OUTER: usize = 3000;
/// Меньше клеток по стороне (с учётом грубого шага) область не собирается.
pub const MIN_CELLS: usize = 12;
/// Пауза после отказа окон до новой попытки, с времени атмосферы (`AirClipmap._retry_at`: 10 с).
pub const SHIFT_RETRY_S: f64 = 10.0;

// ---------------------------------------------------------------- конфиг

/// Климат без сеток ERA5 (`has_hh1 = has_hh5 = false`): запасные таблицы секция `weather_model`.
#[derive(Clone, Debug, PartialEq)]
pub struct TableClimate {
    tx_c: Vec<f64>,
    dtr_k: Vec<f64>,
}

impl Climate for TableClimate {
    fn cell(&self, _lat: f64, _lon: f64, month: i64, day: i64) -> ClimateCell {
        ClimateCell {
            tx_c: monthly(&self.tx_c, month.clamp(1, 12), day),
            dtr_k: monthly(&self.dtr_k, month.clamp(1, 12), day),
            z_cell_m: 0.0,
            has_hh1: false,
            has_hh5: false,
        }
    }
}

/// Климат места: ячейка сеток климата [`Weather`] (W5 v10; `ClimateGrid.at` на дату и центр
/// места), где есть сетка HH5 / HH1; иначе запасные таблицы (`ClimateGrid.place`: без HH5
/// `tx_c`/`dtr_k` - из секция `weather_model`). Нет `Weather` - таблицы целиком. Для воды (W5 v7)
/// дату сдвигает вызывающий (`water_mean_air_c`), ячейка берётся тем же правилом.
pub struct PlaceClimate<'a> {
    pub table: &'a TableClimate,
    pub weather: Option<&'a Weather>,
}

impl<'a> PlaceClimate<'a> {
    pub fn of(table: &'a TableClimate, weather: Option<&'a Weather>) -> Self {
        PlaceClimate { table, weather }
    }
}

impl Climate for PlaceClimate<'_> {
    fn cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> ClimateCell {
        match self.weather {
            Some(w) => w.cell(lat, lon, month, day),
            None => self.table.cell(lat, lon, month, day),
        }
    }
}

/// Подставные отказы для тестов (T4a).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Faults {
    /// Грубый шаг не удался: старт с фона.
    pub coarse: bool,
    /// Решение прохода с этим номером (с 1; проход один) не удаётся.
    pub fail_pass: Option<usize>,
    /// Фазы не считаются: Пикар без заморозки и `nonconv` (сравнение итераций в тестах).
    pub no_phase: bool,
    /// Окна клипмапа не считаются при непустых `window_levels_m` (только область).
    pub no_windows: bool,
}

/// Всё, что оркестровке нужно из конфигов.
#[derive(Clone, Debug)]
pub struct RtCfg {
    /// Потоков в пуле и в каждом `solve` (≥ 1).
    pub threads: usize,
    pub deterministic: bool,
    pub tol_scale: f64,
    pub domain_l_m: f64,
    /// Множитель клетки грубого старта (1 — без него).
    pub coarse_factor: usize,
    /// `window_levels_m` не пуст: эталон подстраивает приток по старту.
    pub windows_wanted: bool,
    pub step_min: f64,
    pub blend_s: f64,
    pub edge_blend_cells: f64,
    pub limits: Limits,
    pub max_iters: usize,
    pub omega_after: usize,
    pub omega: f32,
    pub late_from: usize,
    pub zi: ZiCfg,
    pub wc: WeatherConfigs,
    pub climate: TableClimate,
    pub faults: Faults,
    /// Блок `air_phase` (фазы поля).
    pub phase: PhaseCfg,
    /// Шаги окон `window_levels_m` (ключ решённого поля и список окон клипмапа), м, от грубого
    /// к мелкому.
    pub window_dx: Vec<f64>,
    /// Сдвиг окна, когда фокус ушёл от его центра дальше этой доли стороны
    /// (`air_model.window_shift_frac`).
    pub shift_frac: f64,
    /// После отказа окон новая попытка не раньше чем через столько секунд времени атмосферы.
    pub shift_retry_s: f64,
    /// Предел кеша, байт (`air_cache.max_mb`; 0 — кеш выключен).
    pub cache_max_bytes: u64,
    /// Хеш текстов конфигов (ключ кеша).
    pub configs_hash: String,
}

fn json(c: &Configs, name: &str) -> Result<Value, Error> {
    match c.get(name) {
        None => Ok(Value::Null),
        Some(t) => {
            serde_json::from_str(t).map_err(|e| Error::bad_input(format!("config '{name}': {e}")))
        }
    }
}

fn num(v: &Value, ptr: &str, d: f64) -> f64 {
    v.pointer(ptr).and_then(Value::as_f64).unwrap_or(d)
}

fn nums(v: &Value, ptr: &str) -> Vec<f64> {
    v.pointer(ptr)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_f64).collect())
        .unwrap_or_default()
}

/// Хеш всех конфигов: имена и тексты (16 hex sha256).
fn configs_hash(c: &Configs) -> String {
    let mut h = Sha256::new();
    for (n, t) in &c.files {
        h.update((n.len() as u64).to_le_bytes());
        h.update(n.as_bytes());
        h.update((t.len() as u64).to_le_bytes());
        h.update(t.as_bytes());
    }
    hex16(h)
}

fn hex16(h: Sha256) -> String {
    h.finalize()
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Число потоков: `0` — все ядра минус одно, не меньше одного.
pub fn resolve_threads(n: usize) -> usize {
    if n > 0 {
        return n;
    }
    std::thread::available_parallelism()
        .map_or(1, |p| p.get())
        .saturating_sub(1)
        .max(1)
}

impl RtCfg {
    /// Из конфигов: `atmosphere` (`air`, `air_model`, `air_phase`), `weather_model`, `surface_heat`.
    /// Нет `weather_model` или `surface_heat` — `BadInput`.
    pub fn from_configs(c: &Configs) -> Result<Self, Error> {
        let atm = json(c, "atmosphere")?;
        let wm = json(c, "weather_model")?;
        let wc = WeatherConfigs::from_configs(c)?;
        let am = |k: &str, d: f64| num(&atm, &format!("/air_model/{k}"), d);
        let coarse = atm
            .pointer("/air_model/picard_start")
            .and_then(Value::as_str)
            .unwrap_or("cold")
            == "coarse";
        let factor = am("picard_coarse_factor", 1.0).round().max(1.0) as usize;
        let windows = atm
            .pointer("/air_model/window_levels_m")
            .and_then(Value::as_array)
            .is_none_or(|a| !a.is_empty());
        let mut tx = nums(&wm, "/typical_max_c");
        if tx.is_empty() {
            tx = vec![20.0];
        }
        let mut dtr = nums(&wm, "/diurnal/range_k");
        if dtr.is_empty() {
            dtr = vec![10.0];
        }
        Ok(RtCfg {
            threads: resolve_threads(num(&atm, "/air/threads", 0.0).max(0.0) as usize),
            deterministic: atm
                .pointer("/air/deterministic")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            tol_scale: num(&atm, "/air/tol_scale", 5.0),
            domain_l_m: num(&atm, "/air/domain_l_m", super::weather_core::DOMAIN_L),
            coarse_factor: if coarse { factor } else { 1 },
            windows_wanted: windows,
            step_min: am("recompute_game_min", 15.0),
            blend_s: am("blend_s", 60.0),
            edge_blend_cells: am("edge_blend_cells", 5.0),
            limits: Limits {
                max_speed: am("max_speed_ms", 40.0),
                max_w: am("max_w_ms", 10.0),
            },
            max_iters: MAX_OUTER,
            omega_after: num(&atm, "/air_phase/omega/fallback_iters", 300.0).max(0.0) as usize,
            omega: num(&atm, "/air_phase/omega/fallback_omega", 0.5) as f32,
            late_from: num(&atm, "/air_phase/nonconv/late_from", 500.0).max(0.0) as usize,
            zi: ZiCfg::from_configs(c)?,
            wc,
            climate: TableClimate {
                tx_c: tx,
                dtr_k: dtr,
            },
            faults: Faults::default(),
            phase: PhaseCfg::from_configs(c)?,
            window_dx: nums(&atm, "/air_model/window_levels_m"),
            shift_frac: am("window_shift_frac", 0.25),
            shift_retry_s: SHIFT_RETRY_S,
            cache_max_bytes: (num(&atm, "/air_cache/max_mb", 200.0).max(0.0) * 1048576.0) as u64,
            configs_hash: configs_hash(c),
        })
    }

    /// Параметры решателя случая с заданным ветром `u10` (`AirCase.p`, `AirPicardJob`).
    pub fn solver(&self, u10: f64) -> SolverCfg {
        SolverCfg::new(u10)
    }
}

// ---------------------------------------------------------------- условия и срок

/// Условия, по которым посчитано (или будет считаться) поле (`_req`/`_cur` эталона).
#[derive(Clone, Debug, PartialEq)]
pub struct CondRec {
    /// Час места: при загрузке — как есть, в полёте — начало срока.
    pub hour: f64,
    pub u10: f64,
    pub wdir: f64,
    pub t_max: Option<f64>,
    pub sky: String,
}

impl CondRec {
    pub fn new(inputs: &WeatherInputs, hour: f64) -> Self {
        CondRec {
            hour,
            u10: inputs.u10,
            wdir: inputs.wdir,
            t_max: inputs.t_max,
            sky: inputs.sky.clone(),
        }
    }
}

/// Номер срока пересчёта для часа (`slot`).
pub fn slot(hour: f64, step_min: f64) -> i64 {
    (hour * 60.0 / step_min.max(1.0) + 1.0e-6).floor() as i64
}

/// Час начала срока (`slot_hour`).
pub fn slot_hour(hour: f64, step_min: f64) -> f64 {
    slot(hour, step_min) as f64 * step_min.max(1.0) / 60.0
}

/// Разность углов в `[−π, π]` (`angle_difference`).
fn angle_difference(a: f64, b: f64) -> f64 {
    let d = (b - a).rem_euclid(std::f64::consts::TAU);
    if d > std::f64::consts::PI {
        d - std::f64::consts::TAU
    } else {
        d
    }
}

/// Причина пересчёта (`needs_recompute`): `None` — не нужен. Нет прошлых условий — «нет поля».
pub fn needs_recompute(
    have: Option<&CondRec>,
    want: &CondRec,
    step_min: f64,
) -> Option<&'static str> {
    let Some(have) = have else {
        return Some("нет поля");
    };
    if (have.u10 - want.u10).abs() > WIND_TOL_MS {
        return Some("смена ветра");
    }
    if angle_difference(have.wdir.to_radians(), want.wdir.to_radians()).abs()
        > DIR_TOL_DEG.to_radians()
    {
        return Some("смена ветра");
    }
    let t_changed = match (have.t_max, want.t_max) {
        (None, None) => false,
        (Some(a), Some(b)) => (a - b).abs() > TMAX_TOL_C,
        _ => true,
    };
    if have.sky != want.sky || t_changed {
        return Some("смена погоды");
    }
    if slot(want.hour, step_min) != slot(have.hour, step_min) {
        return Some("срок");
    }
    None
}

// ---------------------------------------------------------------- место

/// Высота рельефа места в (x, z) мира, м: билинейно по узлам, вне — по краю (W5).
pub fn ground_height(place: &Place, x: f32, z: f32) -> f32 {
    let g = &place.header().grid;
    let (w, h) = (g.width as usize, g.height as usize);
    if w < 2 || h < 2 {
        return place.heights().first().copied().unwrap_or(0.0);
    }
    let inv = 1.0 / g.spacing;
    let fx = ((x as f64 - g.origin_x) * inv).clamp(0.0, w as f64 - 1.0);
    let fz = ((z as f64 - g.origin_z) * inv).clamp(0.0, h as f64 - 1.0);
    let (i, j) = ((fx as usize).min(w - 2), (fz as usize).min(h - 2));
    let (tx, tz) = ((fx - i as f64) as f32, (fz - j as f64) as f32);
    let hs = place.heights();
    let k = j * w + i;
    let a = hs[k] + (hs[k + 1] - hs[k]) * tx;
    let b = hs[k + w] + (hs[k + w + 1] - hs[k + w]) * tx;
    a + (b - a) * tz
}

/// Область вокруг (0, 0): `domain_l_m`, но не больше помещающейся в растр места; сторона — число
/// клеток кратно `coarse_factor` (грубая сетка делит тонкую нацело).
pub fn domain_for(place: &Place, cfg: &RtCfg) -> Result<Domain, Error> {
    let g = &place.header().grid;
    let (x_hi, z_hi) = (
        g.origin_x + (g.width as f64 - 1.0) * g.spacing,
        g.origin_z + (g.height as f64 - 1.0) * g.spacing,
    );
    // область: x ∈ [−H, H], y = −z ∈ [−H, H]; полшага узла на край
    let fit = (-g.origin_x).min(x_hi).min(-g.origin_z).min(z_hi) - 2.0 * g.spacing;
    let half = fit.min(cfg.domain_l_m / 2.0);
    let f = cfg.coarse_factor.max(1);
    let cell = DX * f as f64;
    let n = if half.is_finite() && half > 0.0 {
        (2.0 * half / cell).floor() as usize * f
    } else {
        0
    };
    if n < MIN_CELLS.max(4 * f) {
        return Err(Error::bad_input(format!(
            "field: place raster is too small for the domain ({n} cells of {DX} m, need {})",
            MIN_CELLS.max(4 * f)
        )));
    }
    let side = n as f64 * DX;
    Ok(Domain {
        x0: -side / 2.0,
        y0: -side / 2.0,
        nx: n,
        ny: n,
        dx: DX,
    })
}

/// Грубая область: те же начало и размер, клетка `dx·factor`.
pub fn coarse_domain(fine: &Domain, factor: usize) -> Domain {
    Domain {
        dx: fine.dx * factor as f64,
        nx: fine.nx / factor,
        ny: fine.ny / factor,
        ..*fine
    }
}

// ---------------------------------------------------------------- решённые поля

/// Запись для кеша: делается в пуле после подачи поля.
#[derive(Debug)]
pub struct CachePut {
    pub cache: FieldCache,
    pub key: Value,
    pub model_hash: String,
    pub field: SolvedField,
    pub extra: Map<String, Value>,
}

impl CachePut {
    /// Записывает; ошибка диска — не ошибка поля, текст возвращается.
    pub fn run(self) -> Option<String> {
        self.cache
            .put(&self.key, &self.model_hash, &self.field, &self.extra)
            .err()
            .map(|e| e.msg)
    }
}

/// Откуда поле.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Computed,
    Cache,
}

/// Ключ кеша: всё, от чего зависит посчитанное поле и что видно крейту (место целиком по хешу,
/// конфиги по хешу, условия, точка старта, срок). Ключ словаря в `json!` — по алфавиту.
fn cache_key(job: &JobIn) -> Value {
    let h = job.place.header();
    let hash = job.place_hash.get_or_init(|| place_hash(&job.place));
    let rec = &job.rec;
    json!({
        "kind": "formula-field",
        "format": 2,
        "location": h.loc.id,
        "center": [h.loc.center_lat, h.loc.center_lon],
        "month": h.loc.month,
        "day": h.loc.day,
        "utc": h.loc.utc_offset_h,
        "place": hash,
        "configs": job.cfg.configs_hash,
        "domain_dx": DX,
        "step_min": job.cfg.step_min,
        "start": job.focus.map(|f| [f[0], f[1]]),
        "hour": rec.hour,
        "u10": rec.u10,
        "wdir": rec.wdir,
        "t_max": rec.t_max,
        "sky": rec.sky,
    })
}

/// Хеш содержимого места: заголовок и растры (16 hex sha256).
pub fn place_hash(p: &Place) -> String {
    let h = p.header();
    let mut d = Sha256::new();
    d.update(
        serde_json::to_string(&json!({
            "loc": [h.loc.id, h.loc.center_lat, h.loc.center_lon, h.loc.utc_offset_h, h.loc.month, h.loc.day],
            "grid": [h.grid.origin_x, h.grid.origin_z, h.grid.spacing, h.grid.width, h.grid.height],
            "classes": h.surface_classes.iter().collect::<Vec<_>>(),
        }))
        .unwrap_or_default(),
    );
    feed_f32(&mut d, p.heights());
    d.update(p.water());
    d.update(p.cls());
    feed_f32(&mut d, p.moist());
    hex16(d)
}

/// Числа в хеш кусками через небольшой буфер (без копии всего растра).
fn feed_f32(d: &mut Sha256, v: &[f32]) {
    let mut buf = [0u8; 16384];
    for ch in v.chunks(4096) {
        for (o, x) in buf.chunks_exact_mut(4).zip(ch) {
            o.copy_from_slice(&x.to_le_bytes());
        }
        d.update(&buf[..ch.len() * 4]);
    }
}

// ---------------------------------------------------------------- проход

/// Пара состояний для тёплого старта следующего решения.
#[derive(Clone, Debug)]
pub struct Pair {
    pub mech: State,
    pub heat: State,
}

/// Откуда стартовали решения.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    Cold,
    Coarse,
    Warm,
}

/// Итог одного прохода.
#[derive(Clone, Debug)]
pub struct PassReport {
    /// Итерации решений `[mech, heat]`.
    pub iters: [usize; 2],
    /// Итерации грубых решений `[mech, heat]`, если грубый шаг был.
    pub coarse_iters: Option<[usize; 2]>,
    pub start: Start,
    /// Заметки: отказ грубого шага и т. п.
    pub notes: Vec<String>,
    pub stop: [Stop; 2],
    /// `div_rms` невязки решений `[mech, heat]` (диагностика RW-6z).
    pub div_rms: [f64; 2],
    pub omega_fallback: bool,
    pub nonconv_fallback: bool,
    /// Секунды: подготовка (вход, случаи), грубый шаг, решения, сборка поля.
    pub secs: [f64; 4],
    /// Фазы поля посчитаны (иначе — Пикар без фаз).
    pub phases: bool,
    /// Растр главной фазы клетки (`debug_raster("phase_main")`, F4); `None` - без фаз.
    pub phase_main: Option<Arc<Raster>>,
    /// Секунды сборки фаз.
    pub phase_s: f64,
    /// Доля замороженных колонн `[heat, mech]`.
    pub frozen_frac: [f64; 2],
    /// Колонны запасного пути переданы решениям.
    pub nonconv_cols: bool,
    /// Окна клипмапа этого прохода (от грубого к мелкому); пусто — без окон или отказ.
    pub windows: Vec<WinReport>,
    /// Окна не посчитались: причина (поле — только область).
    pub win_error: Option<String>,
    /// Секунды окон (вход, решения, поля).
    pub win_s: f64,
}

struct PassOut {
    /// Уровни от мелкого к грубому: окна и область (или одна область).
    levels: Vec<Arc<Field>>,
    clip: Option<Arc<ClipMap>>,
    pair: Arc<Pair>,
    report: PassReport,
}

/// Ошибка задачи.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobErr {
    Cancelled,
    Failed(String),
}

impl From<Error> for JobErr {
    fn from(e: Error) -> Self {
        JobErr::Failed(e.msg)
    }
}

/// Вход задачи (одно поле).
pub struct JobIn {
    pub cfg: Arc<RtCfg>,
    pub configs: Arc<Configs>,
    pub place: Arc<Place>,
    pub cond: Conditions,
    pub rec: CondRec,
    /// Загрузка (час как есть) или пересчёт (час — начало срока).
    pub loading: bool,
    /// Точка старта (x, z мира): первый фокус.
    pub focus: Option<[f32; 2]>,
    /// Прошлое поле пары (пересчёт в полёте).
    pub warm: Option<Arc<Pair>>,
    pub cancel: Arc<AtomicBool>,
    /// Доля готовности 0..1 (биты `f32`).
    pub progress: Arc<AtomicU32>,
    /// Этап и его итерации (`Status::stage/iters`).
    pub stage: Arc<StageCounter>,
    /// Кеш полей (`set_cache_dir`); `None` — выключен.
    pub cache: Option<FieldCache>,
    /// Хеш места — считается при первой надобности и живёт с местом.
    pub place_hash: Arc<OnceLock<String>>,
    /// Окна прошлого поля (пересчёт в полёте: те же места и тёплый старт); `None` — окна с
    /// центром в `focus`.
    pub clip: Option<Arc<ClipMap>>,
    /// Подставные отказы окон (тесты): сколько ближайших расчётов окон должны не удаться.
    pub win_fail: Arc<AtomicUsize>,
    /// Погода с сетками климата (`set_weather`); нет - климат по запасным таблицам.
    pub weather: Option<Arc<Weather>>,
}

/// Итог задачи.
#[derive(Debug)]
pub struct JobOut {
    /// Уровни от мелкого к грубому (сейчас один).
    pub levels: Vec<Arc<Field>>,
    pub rec: CondRec,
    /// Состояния для тёплого старта следующего пересчёта (`None` — поле из файла или кеша).
    pub pair: Option<Arc<Pair>>,
    /// Окна клипмапа и область-родитель (`None` — окон нет: выключены, нет фокуса, поле из файла).
    /// Окна не посчитались — `ClipMap` без окон (`ready() == false`): область и места для новой
    /// попытки.
    pub clip: Option<Arc<ClipMap>>,
    pub report: JobReport,
    /// Запись в кеш после подачи (забирает вызывающий).
    pub cache_put: Option<CachePut>,
}

/// Журнал задачи.
#[derive(Clone, Debug)]
pub struct JobReport {
    pub passes: Vec<PassReport>,
    pub wall_s: f64,
    /// Откуда поле.
    pub source: Source,
    /// Заметки: почему решённое и кеш не взяты, ошибки записи кеша.
    pub notes: Vec<String>,
    /// Окна поданного поля (последний проход / сдвиг), от грубого к мелкому.
    pub windows: Vec<WinReport>,
    /// Окна не посчитались — подана только область: причина (в `Status.reason`).
    pub windows_error: Option<String>,
}

/// Этапы задачи поля (идентификаторы `Status::stage`), в порядке работы.
pub const STAGES: [&str; 7] = [
    "lookup",
    "prepare",
    "phases",
    "coarse",
    "solve_mech",
    "solve_heat",
    "windows",
];

/// Текущий этап задачи и итерации решателя в нём (W4 v4): читается из любого потока без
/// блокировок. Итерации идущего решения приходят от решателя (`SolveOpts.progress`, W11 v10),
/// законченных решений этапа — копятся в `base`.
#[derive(Debug, Default)]
pub struct StageCounter {
    /// 0 — нет этапа, иначе индекс в [`STAGES`] + 1.
    idx: AtomicU32,
    /// Итерации законченных решений этапа.
    base: AtomicU32,
    /// Итерации идущего решения (пишет решатель).
    cur: Arc<AtomicU32>,
    /// Нечётное — перенос `cur` в `base` идёт: читатель повторяет.
    gen_: AtomicU32,
    /// Номер прогона (вход в этап с итерациями решателя) в задаче; 0 — ещё не было.
    run: AtomicU32,
    /// Прогонов по текущему плану задачи (растёт, когда нужен следующий проход).
    runs: AtomicU32,
}

/// Этапы с итерациями решателя: каждый вход в них — новый прогон (счёт итераций с нуля).
const ITER_STAGES: [&str; 3] = ["coarse", "solve_mech", "solve_heat"];

impl StageCounter {
    /// Начало этапа `name` (из [`STAGES`]): итерации с нуля.
    pub fn enter(&self, name: &str) {
        let i = STAGES.iter().position(|s| *s == name).map_or(0, |i| i + 1);
        self.transfer(|| {
            if name.is_empty() || name == "lookup" {
                self.run.store(0, Ordering::SeqCst);
                self.runs.store(0, Ordering::SeqCst);
            } else if ITER_STAGES.contains(&name) {
                let r = self.run.load(Ordering::SeqCst) + 1;
                self.runs.fetch_max(r, Ordering::SeqCst);
                self.run.store(r, Ordering::SeqCst);
            }
            self.base.store(0, Ordering::Relaxed);
            self.cur.store(0, Ordering::Relaxed);
            self.idx.store(i as u32, Ordering::Relaxed);
        });
    }
    fn transfer(&self, f: impl FnOnce()) {
        self.gen_.fetch_add(1, Ordering::SeqCst);
        f();
        self.gen_.fetch_add(1, Ordering::SeqCst);
    }
    /// Счётчик для `SolveOpts.progress` следующего решения.
    pub fn solve_counter(&self) -> Arc<AtomicU32> {
        self.cur.clone()
    }
    /// Решение закончено, сделало `n` итераций: в копилку этапа.
    pub fn end_solve(&self, n: usize) {
        let n = u32::try_from(n).unwrap_or(u32::MAX);
        self.transfer(|| {
            let v = self.base.load(Ordering::Relaxed).saturating_add(n);
            self.base.store(v, Ordering::Relaxed);
            self.cur.store(0, Ordering::Relaxed);
        });
    }
    /// План: в проходе ещё `this_pass` прогонов (в т.ч. текущий, если он ещё не начат) и
    /// `later_passes` проходов по два прогона (mech, heat) после него.
    pub fn plan(&self, this_pass: u32, later_passes: usize) {
        let later = u32::try_from(later_passes).unwrap_or(u32::MAX / 4);
        let n = self
            .run
            .load(Ordering::SeqCst)
            .saturating_add(this_pass)
            .saturating_add(later.saturating_mul(2));
        self.transfer(|| {
            self.runs.fetch_max(n, Ordering::SeqCst);
        });
    }
    /// Согласованный снимок `(этап, run, runs, итерации)` для `Status`: одно чтение под
    /// счётчиком поколений — смена этапа не даёт смеси старого и нового.
    pub fn snapshot(&self) -> (&'static str, u32, u32, u32) {
        loop {
            let g = self.gen_.load(Ordering::SeqCst);
            let stage = self.stage();
            let run = self.run.load(Ordering::SeqCst);
            let runs = self.runs.load(Ordering::SeqCst);
            let iters = self
                .base
                .load(Ordering::Relaxed)
                .saturating_add(self.cur.load(Ordering::Relaxed));
            if g.is_multiple_of(2) && self.gen_.load(Ordering::SeqCst) == g {
                let (run, runs) = if ITER_STAGES.contains(&stage) {
                    (run, runs.max(run))
                } else {
                    (0, 0)
                };
                return (stage, run, runs, iters);
            }
            std::hint::spin_loop();
        }
    }
    pub fn clear(&self) {
        self.enter("");
    }
    /// Идентификатор этапа (`""` — нет).
    pub fn stage(&self) -> &'static str {
        match self.idx.load(Ordering::Relaxed) {
            0 => "",
            i => STAGES.get(i as usize - 1).copied().unwrap_or(""),
        }
    }
    pub fn iters(&self) -> u32 {
        loop {
            let g = self.gen_.load(Ordering::SeqCst);
            let v = self
                .base
                .load(Ordering::Relaxed)
                .saturating_add(self.cur.load(Ordering::Relaxed));
            if g.is_multiple_of(2) && self.gen_.load(Ordering::SeqCst) == g {
                return v;
            }
            std::hint::spin_loop();
        }
    }
}

fn set_progress(job: &JobIn, x: f32) {
    job.progress
        .store(x.clamp(0.0, 0.999).to_bits(), Ordering::Relaxed);
}

pub(crate) fn check_cancel(job: &JobIn) -> Result<(), JobErr> {
    cancelled(&job.cancel)
}

pub(crate) fn cancelled(cancel: &AtomicBool) -> Result<(), JobErr> {
    if cancel.load(Ordering::Relaxed) {
        Err(JobErr::Cancelled)
    } else {
        Ok(())
    }
}

/// Погода поля для области `dom` и часа задачи (`field_weather`): общая у области и окон.
pub(crate) fn weather_for(job: &JobIn, dom: &Domain) -> Result<FieldWeather, Error> {
    let climate = PlaceClimate::of(&job.cfg.climate, job.weather.as_deref());
    field_weather(
        &job.cond,
        &job.place,
        &job.cfg.wc,
        &job.configs,
        &climate,
        job.rec.hour,
        dom,
    )
}

/// Уровень решения: два случая (mech и heat), плоскости не нужны после сборки случая.
struct LevelCase {
    heat: AirCaseRs,
    planes_h: PreparedPlanes,
    case_h: Case,
    case_m: Case,
}

fn build_level(job: &JobIn, dom: &Domain) -> Result<LevelCase, JobErr> {
    let cfg = &job.cfg;
    check_cancel(job)?;
    let fw = weather_for(job, dom)?;
    check_cancel(job)?;
    let inp = build_domain_input(&job.place, &cfg.wc.sh, &cfg.zi, dom, &fw.day)?;
    check_cancel(job)?;
    let heat = build_case(&inp, &fw, &CaseOpts { heat: true })?;
    check_cancel(job)?;
    let mech = heat.without_heat();
    let (ph, pm) = rayon::join(|| heat.prepare(), || mech.prepare());
    let (ph, pm) = (ph?, pm?);
    check_cancel(job)?;
    let sc = cfg.solver(heat.u10);
    let (ch, cm) = rayon::join(
        || build_solver_case(&ph, &heat.p, &sc),
        || build_solver_case(&pm, &mech.p, &sc),
    );
    Ok(LevelCase {
        heat,
        planes_h: ph,
        case_h: ch?,
        case_m: cm?,
    })
}

/// Случаи решателя `[mech, heat]` тонкой области (для тестов и стенда: то, что решает
/// проход, без решения).
pub fn level_cases(job: &JobIn) -> Result<[Case; 2], JobErr> {
    let dom = domain_for(&job.place, &job.cfg)?;
    let lc = build_level(job, &dom)?;
    Ok([lc.case_m, lc.case_h])
}

/// Фазы поля тонкой области (для тестов и стенда).
pub fn phase_result(job: &JobIn) -> Result<PhaseResult, JobErr> {
    let dom = domain_for(&job.place, &job.cfg)?;
    let lc = build_level(job, &dom)?;
    phases_of(&job.cfg.phase, &lc).map_err(JobErr::Failed)
}

/// Фазы поля (`AirPhase.result`): вход из случая с нагревом и его плоскостей.
fn phases_of(cfg: &PhaseCfg, lc: &LevelCase) -> Result<PhaseResult, String> {
    let (h, pl) = (&lc.heat, &lc.planes_h);
    let (nx, n) = (h.dom.nx, h.dom.nx * h.dom.ny);
    let inner = |plane: &[f32]| -> Vec<f64> {
        (0..n)
            .map(|c| f64::from(plane[(c / nx + 1) * pl.nx_h + c % nx + 1]))
            .collect()
    };
    let (h_bl, wst) = (inner(pl.col_plane(2)), inner(pl.col_plane(3)));
    let zic: Vec<f64> = h.z_i_col.iter().map(|&v| f64::from(v)).collect();
    assemble(
        &PhaseCase {
            nx,
            ny: h.dom.ny,
            nz: h.nz,
            dx: h.dom.dx,
            dz: h.dz,
            z_bot: h.z_bot,
            ex: pl.ex,
            ey: pl.ey,
            u_a: pl.u_a,
            z_sat: f64::from(pl.prm[12]),
            alpha: pl.alpha,
            z0: pl.z0,
            ustar: pl.ustar,
            tau_cool: h.p.tau_cool,
            u10: h.u10,
            z_i: h.z_i,
            hc: &h.hc,
            hc_type: &h.hc_type,
            gam: &h.gam,
            heat: &h.heat,
            heat_used: &pl.heat_used,
            h_bl: &h_bl,
            wst: &wst,
            z_i_col: &zic,
            g: None,
        },
        cfg,
    )
}

pub(crate) fn level_of(p: &PreparedPlanes, dom: &Domain) -> Level {
    Level {
        nx: p.nx_h,
        ny: p.ny_h,
        nz: p.nz_h,
        x0: dom.x0,
        y0: dom.y0,
        dx: dom.dx,
        dz: p.dz,
        z_bot: p.z_bot,
        halo: 1,
    }
}

fn blank_state(l: &Level) -> State {
    let n = l.len();
    State {
        case: String::new(),
        input: String::new(),
        it: 0,
        dims: [l.nx, l.ny, l.nz],
        halo: 1,
        n: [l.nx - 2, l.ny - 2, l.nz - 2],
        u: vec![0.0; n],
        v: vec![0.0; n],
        w: vec![0.0; n],
        th: vec![0.0; n],
        thd: vec![0.0; n],
        p: vec![0.0; n],
        nu: None,
        nuh: None,
        residuals: None,
    }
}

/// Решение грубого уровня на тонкий (`prolong`, 6f).
fn prolong_to(coarse: &Level, src: &State, fine: &Level) -> Result<State, JobErr> {
    let mut dst = blank_state(fine);
    prolong_state(
        coarse,
        [&src.u, &src.v, &src.w, &src.th, &src.thd, &src.p],
        fine,
        [
            &mut dst.u,
            &mut dst.v,
            &mut dst.w,
            &mut dst.th,
            &mut dst.thd,
            &mut dst.p,
        ],
    )?;
    Ok(dst)
}

/// Что решению сверх случая и старта: запасные правила, заморозка колонн, `nonconv`, число
/// V-циклов старта (окно от родителя — 30).
#[derive(Default)]
pub(crate) struct Spec {
    pub(crate) fallback: bool,
    pub(crate) freeze: Option<Freeze>,
    pub(crate) nonconv: Option<NonConv>,
    pub(crate) init_cycles: Option<u32>,
}

fn solve_one(job: &JobIn, case: &Case, init: Option<State>, spec: Spec) -> Result<Solved, JobErr> {
    solve_with(&job.cfg, &job.cancel, Some(&job.stage), case, init, spec)
}

/// Одно решение `picard_rs` с отменой и разбором причины остановки (без предела по времени).
pub(crate) fn solve_with(
    cfg: &RtCfg,
    cancel: &Arc<AtomicBool>,
    stage: Option<&StageCounter>,
    case: &Case,
    init: Option<State>,
    spec: Spec,
) -> Result<Solved, JobErr> {
    cancelled(cancel)?;
    let opts = SolveOpts {
        threads: cfg.threads,
        max_iters: cfg.max_iters,
        tol_scale: cfg.tol_scale,
        init,
        freeze: spec.freeze,
        init_cycles: spec.init_cycles,
        progress: stage.map(StageCounter::solve_counter),
        cancel: Some(cancel.clone()),
        fallback: spec.fallback.then_some(Fallback {
            omega_after: cfg.omega_after,
            omega: cfg.omega,
            late_from: cfg.late_from,
            nonconv: spec.nonconv,
        }),
        ..SolveOpts::default()
    };
    let s = solve(case, &opts).map_err(|e| JobErr::Failed(format!("solver: {e:#}")))?;
    if let Some(st) = stage {
        st.end_solve(s.iters);
    }
    match s.stop {
        StopReason::Cancelled => Err(JobErr::Cancelled),
        StopReason::Diverged => Err(JobErr::Failed(format!(
            "solver diverged at iteration {}",
            s.iters
        ))),
        _ => Ok(s),
    }
}

/// Грубый шаг: пара mech → heat на 1200 м без запасных правил, перенос на тонкий уровень.
fn coarse_start(
    job: &JobIn,
    lc: &LevelCase,
    coarse: &LevelCase,
    fine_dom: &Domain,
    coarse_dom: &Domain,
) -> Result<(Pair, [usize; 2]), JobErr> {
    let sm = solve_one(job, &coarse.case_m, None, Spec::default())?;
    let sh = solve_one(job, &coarse.case_h, None, Spec::default())?;
    let (cl, fl) = (
        level_of(&coarse.planes_h, coarse_dom),
        level_of(&lc.planes_h, fine_dom),
    );
    let pair = Pair {
        mech: prolong_to(&cl, &sm.state, &fl)?,
        heat: prolong_to(&cl, &sh.state, &fl)?,
    };
    Ok((pair, [sm.iters, sh.iters]))
}

fn solve_pass(
    job: &JobIn,
    prev: Option<&Pair>,
    prev_clip: Option<&Arc<ClipMap>>,
) -> Result<PassOut, JobErr> {
    let cfg = &job.cfg;
    let t0 = Instant::now();
    check_cancel(job)?;
    set_progress(job, 0.0);
    job.stage.enter("prepare");
    let fine_dom = domain_for(&job.place, cfg)?;
    let want_coarse = prev.is_none() && cfg.coarse_factor > 1;
    let coarse_dom = coarse_domain(&fine_dom, cfg.coarse_factor);
    let mut notes = Vec::new();
    let (fine, coarse) = if want_coarse {
        let (a, b) = rayon::join(
            || build_level(job, &fine_dom),
            || build_level(job, &coarse_dom),
        );
        let b = match b {
            Ok(c) => Some(c),
            Err(JobErr::Cancelled) => return Err(JobErr::Cancelled),
            Err(JobErr::Failed(m)) => {
                notes.push(format!("coarse case: {m}"));
                None
            }
        };
        (a?, b)
    } else {
        (build_level(job, &fine_dom)?, None)
    };
    let t_prep = t0.elapsed().as_secs_f64();
    set_progress(job, 0.15);
    check_cancel(job)?;
    job.stage.enter("phases");
    let t_ph = Instant::now();
    let phase = if cfg.faults.no_phase {
        None
    } else {
        match phases_of(&cfg.phase, &fine) {
            Ok(r) => Some(r),
            Err(m) => {
                notes.push(format!("phases failed ({m}): Picard without them"));
                None
            }
        }
    };
    let phase_s = t_ph.elapsed().as_secs_f64();
    check_cancel(job)?;
    // все колонны обоих вариантов — механизмам: грубый шаг не нужен (`all_mech`)
    let all_mech = phase.as_ref().is_some_and(|r| {
        [&r.freeze.mask, &r.freeze_mech.mask]
            .iter()
            .all(|m| !m.is_empty() && m.iter().all(|&x| x != 0))
    });
    let (frozen_frac, nonconv_cols) = phase.as_ref().map_or(([0.0; 2], false), |r| {
        (
            [r.stats.frozen_frac, r.stats.frozen_frac_mech],
            r.nonconv.is_some(),
        )
    });
    let fr_some = phase.is_some();
    let phase_main = phase
        .as_ref()
        .and_then(|r| crate::debug_rasters::phase_main(&fine_dom, &r.maps.heat.weights))
        .map(Arc::new);
    let (fr_h, fr_m, nonconv) = match phase {
        Some(r) => (Some(r.freeze), Some(r.freeze_mech), r.nonconv),
        None => (None, None, None),
    };
    let fine_n = [fine.case_h.nxh, fine.case_h.nyh, fine.case_h.nzh];
    let (mut init_m, mut init_h) = (None, None);
    let mut start = Start::Cold;
    let mut coarse_iters = None;
    if let Some(p) = prev {
        if p.mech.dims == fine_n && p.heat.dims == fine_n {
            init_m = Some(p.mech.clone());
            init_h = Some(p.heat.clone());
            start = Start::Warm;
        } else {
            notes.push("warm state of another grid: cold start".into());
        }
    }
    let t1 = Instant::now();
    let do_coarse = start == Start::Cold && !all_mech && coarse.is_some() && !cfg.faults.coarse;
    job.stage.plan(2 + u32::from(do_coarse), 0);
    if start == Start::Cold
        && !all_mech
        && let Some(c) = &coarse
    {
        if cfg.faults.coarse {
            notes.push("coarse step failed (injected): start from the background".into());
        } else {
            job.stage.enter("coarse");
            match coarse_start(job, &fine, c, &fine_dom, &coarse_dom) {
                Ok((pair, it)) => {
                    init_m = Some(pair.mech);
                    init_h = Some(pair.heat);
                    start = Start::Coarse;
                    coarse_iters = Some(it);
                }
                Err(JobErr::Cancelled) => return Err(JobErr::Cancelled),
                Err(JobErr::Failed(m)) => {
                    notes.push(format!(
                        "coarse step failed ({m}): start from the background"
                    ));
                }
            }
        }
    }
    drop(coarse);
    let t_coarse = t1.elapsed().as_secs_f64();
    set_progress(job, 0.3);
    let t2 = Instant::now();
    if cfg.faults.fail_pass == Some(1) {
        return Err(JobErr::Failed("pass 1 failed (injected)".into()));
    }
    let spec = |freeze, nonconv| Spec {
        fallback: true,
        freeze,
        nonconv,
        init_cycles: None,
    };
    job.stage.enter("solve_mech");
    let sm = solve_one(job, &fine.case_m, init_m, spec(fr_m, nonconv.clone()))?;
    set_progress(job, 0.6);
    job.stage.enter("solve_heat");
    let sh = solve_one(job, &fine.case_h, init_h, spec(fr_h, nonconv))?;
    set_progress(job, 0.9);
    let t_solve = t2.elapsed().as_secs_f64();
    let t3 = Instant::now();
    let field = build_field(
        &fine.heat,
        &fine.planes_h,
        &fine.case_h,
        &sh.state,
        &sm.state,
        cfg,
    )?;
    let area_field = FieldSet::prepare(vec![field], cfg.limits, cfg.edge_blend_cells)
        .pop()
        .ok_or_else(|| JobErr::Failed("empty field set".into()))?;
    let t_build = t3.elapsed().as_secs_f64();
    let pair = Arc::new(Pair {
        mech: sm.state,
        heat: sh.state,
    });
    // окна клипмапа: от области этого прохода
    let t4 = Instant::now();
    let want_win = cfg.windows_wanted && !cfg.faults.no_windows;
    let (levels, clip, windows, win_error) = match prev_clip.filter(|c| c.ready()).cloned() {
        _ if !want_win => (vec![area_field.clone()], None, Vec::new(), None),
        Some(old) => {
            let plan = Plan {
                corners: old.corners.clone(),
                keep: Vec::new(),
                prev: old.wins.clone(),
            };
            windows_of(job, &fine, &fine_dom, &pair, &area_field, plan)?
        }
        None => match job.focus {
            Some(f) => {
                let plan = Plan::fresh(&cfg.window_dx, [f[0] as f64, -(f[1] as f64)]);
                windows_of(job, &fine, &fine_dom, &pair, &area_field, plan)?
            }
            None => (vec![area_field.clone()], None, Vec::new(), None),
        },
    };
    let win_s = t4.elapsed().as_secs_f64();
    let report = PassReport {
        iters: [sm.iters, sh.iters],
        coarse_iters,
        start,
        notes,
        stop: [sm.stop, sh.stop],
        div_rms: [sm.residuals.div_rms, sh.residuals.div_rms],
        omega_fallback: sm.omega_fallback_used || sh.omega_fallback_used,
        nonconv_fallback: sm.nonconv_fallback || sh.nonconv_fallback,
        secs: [t_prep, t_coarse, t_solve, t_build],
        phases: fr_some,
        phase_main,
        phase_s,
        frozen_frac,
        nonconv_cols,
        windows,
        win_error,
        win_s,
    };
    set_progress(job, 1.0);
    Ok(PassOut {
        levels,
        clip,
        pair,
        report,
    })
}

/// Окна по `plan` от области прохода: набор уровней, `ClipMap`, итоги и причина отказа. Отказ окон
/// не отказ прохода (`_on_windows_failed`): поле — только область, `ClipMap` без окон помнит
/// область и места для новой попытки. Отмена — наружу.
#[allow(clippy::type_complexity, clippy::too_many_arguments)]
fn windows_of(
    job: &JobIn,
    fine: &LevelCase,
    fine_dom: &Domain,
    pair: &Arc<Pair>,
    area_field: &Arc<Field>,
    plan: Plan,
) -> Result<
    (
        Vec<Arc<Field>>,
        Option<Arc<ClipMap>>,
        Vec<WinReport>,
        Option<String>,
    ),
    JobErr,
> {
    check_cancel(job)?;
    let cfg = &job.cfg;
    let area = Arc::new(ParentArea {
        level: level_of(&fine.planes_h, fine_dom),
        tc: tcode(&fine.planes_h),
        pair: pair.clone(),
        zi: ZiArea {
            nx: fine_dom.nx,
            ny: fine_dom.ny,
            dx: fine_dom.dx,
            x0: fine_dom.x0,
            y0: fine_dom.y0,
            z_i: fine.heat.z_i,
            z_i_col: fine.heat.z_i_col.clone(),
            alpha_on: cfg.zi.alpha > 0.0,
        },
    });
    let corners = plan.corners.clone();
    job.stage.enter("windows");
    let progress = |x: f32| set_progress(job, 0.9 + 0.1 * x);
    match solve_windows(job, &area, area_field, plan, &progress) {
        Ok(w) => Ok((w.clip.levels(), Some(w.clip), w.reports, None)),
        Err(JobErr::Cancelled) => Err(JobErr::Cancelled),
        Err(JobErr::Failed(m)) => {
            let clip = ClipMap::unplaced(
                &cfg.window_dx,
                corners,
                area,
                area_field.clone(),
                job.cond.clone(),
                job.rec.clone(),
            );
            Ok((
                vec![area_field.clone()],
                Some(Arc::new(clip)),
                Vec::new(),
                Some(m),
            ))
        }
    }
}

/// Поле Пикара из пары решений (`Field::from_mac`): сетка и метаданные из случая.
pub(crate) fn build_field(
    c: &AirCaseRs,
    planes_h: &PreparedPlanes,
    case_h: &Case,
    sh: &State,
    sm: &State,
    cfg: &RtCfg,
) -> Result<Field, JobErr> {
    let nz = c.nz;
    let grid = FieldGrid {
        dx: c.dom.dx,
        dz: c.dz,
        x0: c.dom.x0,
        y0: c.dom.y0,
        z_bot: c.z_bot,
        nx: c.dom.nx,
        ny: c.dom.ny,
        nz,
    };
    let meta = FieldMeta {
        // z0 — как его хранит файл поля (f32): поле из кеша побитно равно посчитанному
        z0: if c.z0_map.is_empty() {
            Z0::Uniform(f64::from(c.p.z0 as f32))
        } else {
            Z0::Map(c.z0_map.iter().map(|&z| f64::from(z as f32)).collect())
        },
        gam: c.gam[1..=nz].iter().map(|&g| g as f32).collect(),
        heat: planes_h.heat_used.iter().map(|&h| h as f32).collect(),
        z_i: c.z_i,
        z_i_col: c.z_i_col.clone(),
    };
    let hc32: Vec<f32> = c.hc.iter().map(|&h| h as f32).collect();
    let cell = case_h
        .arrays
        .get("cell")
        .ok_or_else(|| JobErr::Failed("case has no 'cell' array".into()))?;
    let mut field = Field::from_mac(sh, sm, &grid, cell, &hc32, meta, cfg.limits)?;
    field.edge_cells = cfg.edge_blend_cells;
    Ok(field)
}

/// Поле из файла (решённое или кеш): Ready без Пикара.
fn from_file(
    job: JobIn,
    b: SolvedField,
    source: Source,
    t0: Instant,
    notes: Vec<String>,
) -> JobOut {
    job.progress.store(1.0f32.to_bits(), Ordering::Relaxed);
    JobOut {
        levels: FieldSet::prepare(b.levels, job.cfg.limits, job.cfg.edge_blend_cells),
        rec: job.rec,
        pair: None,
        clip: None,
        report: JobReport {
            passes: Vec::new(),
            wall_s: t0.elapsed().as_secs_f64(),
            source,
            notes,
            windows: Vec::new(),
            windows_error: None,
        },
        cache_put: None,
    }
}

/// Одно поле: загрузка (решённое → кеш → проход) или пересчёт (один проход, тёплый старт).
pub fn run_job(job: JobIn) -> Result<JobOut, JobErr> {
    let t0 = Instant::now();
    let mut notes = Vec::new();
    let mut ckey = None;
    job.stage.enter("lookup");
    if job.loading {
        check_cancel(&job)?;
        let mh = job.place.header().model_hash.clone();
        if let Some(cache) = job.cache.clone().filter(|c| c.enabled() && !mh.is_empty()) {
            let key = cache_key(&job);
            check_cancel(&job)?;
            match cache.get(&key, &mh) {
                Ok(b) => return Ok(from_file(job, b, Source::Cache, t0, notes)),
                Err(Miss::Absent) => {}
                Err(Miss::Rejected(w)) => notes.push(format!("cache: {w}")),
            }
            ckey = Some(key);
        }
        check_cancel(&job)?;
    }
    let out = solve_pass(&job, job.warm.as_deref(), job.clip.as_ref())?;
    let report = JobReport {
        passes: vec![out.report.clone()],
        wall_s: 0.0,
        source: Source::Computed,
        notes,
        windows: Vec::new(),
        windows_error: None,
    };
    Ok(finish(job, out, report, t0, ckey))
}

fn finish(
    job: JobIn,
    p: PassOut,
    mut report: JobReport,
    t0: Instant,
    ckey: Option<Value>,
) -> JobOut {
    report.wall_s = t0.elapsed().as_secs_f64();
    job.progress.store(1.0f32.to_bits(), Ordering::Relaxed);
    let levels = p.levels;
    report.windows = p.report.windows.clone();
    report.windows_error = p.report.win_error.clone();
    // поле без окон из-за отказа в кеш не кладётся: следующая загрузка посчитает окна заново
    let cache_put = match (
        ckey,
        job.cache.clone().filter(|_| report.windows_error.is_none()),
    ) {
        (Some(key), Some(cache)) => {
            let mut extra = Map::new();
            extra.insert("status".into(), json!("ok"));
            extra.insert("wall_s".into(), json!(report.wall_s));
            Some(CachePut {
                cache: FieldCache {
                    max_bytes: job.cfg.cache_max_bytes,
                    ..cache
                },
                key,
                model_hash: job.place.header().model_hash.clone(),
                field: SolvedField {
                    location: job.place.header().loc.id.clone(),
                    site: String::new(),
                    model_hash: job.place.header().model_hash.clone(),
                    key: Value::Null,
                    levels: levels.iter().map(|l| (**l).clone()).collect(),
                    names: Vec::new(),
                    level_meta: vec![Map::new()],
                },
                extra,
            })
        }
        _ => None,
    };
    JobOut {
        levels,
        rec: job.rec,
        pair: Some(p.pair),
        clip: p.clip,
        report,
        cache_put,
    }
}
