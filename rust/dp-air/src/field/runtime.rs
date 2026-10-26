//! Оркестровка поля Пикара в крейте (RW-6j): перенос `AirRuntime` (`air_runtime.gd`) — загрузка,
//! грубый старт 1200 → 400 м, пара решений mech → heat, проходы подбора притока `k`, пересчёт на
//! сроке, тёплые состояния, откат прохода и таймаут. Без Godot, без состояния: одна функция
//! [`run_job`] делает одно «поле» (загрузку или пересчёт) и возвращает уровни и состояния;
//! подмену, фон, отмену и опросы ведёт `Formula` (`formula.rs`).
//!
//! ## Цепочка прохода ([`solve_pass`])
//! `field_weather` (6c) → `build_domain_input` (6b) → `build_case` (6d, с нагревом и
//! `without_heat`) → `prepare` → `build_solver_case` (6e) → [грубый Пикар 1200 м: mech → heat,
//! `prolong_state` (6f)] → `picard_rs::api::solve` mech, затем heat (каждое со своим стартом) →
//! `Field::from_mac` (6i). Старт решений: прошлое поле пары (пересчёт в полёте, проход 2
//! загрузки), иначе грубый старт (`air_model.picard_start = coarse`), иначе фон. Отказ грубого
//! шага — старт с фона без ошибки.
//!
//! ## Проходы `k` ([`run_job`], `_levels_done`/`_next_k`/`inflow_p`)
//! Загрузка с точкой старта (первый фокус), ветром ≥ `U10_MIN`, режимом `Start` и непустыми
//! `window_levels_m` — до `max_passes = 2` проходов: `U` над стартом на 10 м, `k₁ = k₀·(u10/U)^(1/p)`,
//! `p` по таблице [`INFLOW_P`], `k ∈ [0,3; 1]`. Дальше второго — только при `|U/u10 − 1| > pass_tol`.
//! Проход 1 упёрся в `MAX_OUTER` итераций или `k` не изменился — прохода 2 нет. Проход ≥ 2 не
//! удался — подаётся поле прошлого прохода. Режим `Inflow` и пересчёт в полёте — один проход.
//!
//! ## Фазы (RW-6t, `_after_phases`/`_start_picard`)
//! После сборки уровня на каждом проходе — [`assemble`] (фазы 1–3): маски и поля заморозки колонн
//! (`freeze` для решения с нагревом, `freeze_mech` для без нагрева), `nonconv` в запасных правилах
//! обоих решений. Старт решений — как в игре: прошлое поле пары, грубый шаг, иначе фон; `warm` фаз
//! в игре Пикару стартом не служит (только внутри `nonconv`) и здесь не используется. Карта ω
//! (`omega.use_map`, в игре выключена) не подаётся. Все колонны заморожены в обоих вариантах —
//! грубый шаг пропускается (`all_mech`), Пикар возвращает поле заморозки без итераций. Отказ фаз —
//! заметка и Пикар без них.
//!
//! ## Запечённые поля и кеш (RW-6t, `load_field`)
//! Только загрузка (`loading`), порядок как в игре: запечённое (`add_baked_field`) → кеш
//! (`set_cache_dir`) → расчёт; запись в кеш — после готового поля, в пуле, после подачи. Нужен
//! `header.model_hash` места (пусто — ни то ни другое). Площадка старта — из `start_sites` в
//! пределах 1 м от первого фокуса; набор погоды и хеш данных места берутся из `key` самого файла
//! (в W5 у `StartSite` нет id и погоды, хеш данных — дело фасада). Попадание — уровни из файла,
//! `Ready` без Пикара; промах — причина в `JobReport.notes`.
//!
//! ## Отмена (W11 v6, W1 «≤ 1 с»)
//! Флаг отмены проверяется между стадиями подготовки ([`build_level`]: погода, вход области, случай,
//! `prepare`, случай решателя), после фаз, перед каждым решением и внутри `picard_rs` (сборка
//! уровней многосетки, V-циклы старта, каждая итерация, финальная проекция). Не прерываются:
//! сборка фаз (до ~0,15 с на release, ~0,7 с на `-O0`) и сами шаги стадий; `Formula` ждёт задачу
//! не дольше `JOIN_LIMIT` (0,5 с) и отпускает её сменой поколения места.
//!
//! ## Границы модели
//! - Окон 100/50 м в расчёте нет (RW-6n/6o): `U` над стартом берётся с уровня 400 м (в игре — с
//!   окон); запечённое поле их несёт.
//! - Область — квадрат вокруг (0, 0), `domain_l_m` (по умолчанию 38,4 км); место меньше —
//!   область сжимается до помещающейся (кратно `dx·coarse_factor`), меньше 12 клеток — отказ.
//! - Климат места — из `weather_model.json` (`typical_max_c`, `diurnal.range_k`), как GD без
//!   сеток ERA5: `Loc.climate` (W5 v3) в заголовке пока не разбирается (`place.rs`).
//! - Время решения ограничено `timeout_s` на проход (остановка по бюджету — отказ прохода).
use super::baked::{BakedField, BakedQuery, Cond, FORMAT, VERSION, baked_lookup, parse_baked};
use super::case_build::{SolverCfg, build_solver_case};
use super::case_prepare::{AirCaseRs, CaseOpts, PreparedPlanes, build_case};
use super::field_cache::{FieldCache, Miss};
use super::field_set::FieldSet;
use super::phase::assembly::{PhaseResult, assemble};
use super::phase::config::PhaseCfg;
use super::phase::prepare::PhaseCase;
use super::place_input::{ZiCfg, build_domain_input};
use super::weather_core::{
    Climate, ClimateCell, Domain, WeatherConfigs, WeatherInputs, field_weather, monthly,
};
use super::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use crate::level::{Level, prolong_state};
use crate::{Conditions, Configs, Error, InflowMode, LocClimate, Place};
use picard_rs::api::{Fallback, Freeze, NonConv, SolveOpts, Solved, StopReason, solve};
use picard_rs::case::Case;
use picard_rs::state::State;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

pub use picard_rs::api::StopReason as Stop;

// ---------------------------------------------------------------- константы GDScript

/// Шаг области, м (`AirRuntime.DX`).
pub const DX: f64 = 400.0;
/// Пределы множителя притока `k` (`INFLOW_K_MIN`, `INFLOW_K_MAX`).
pub const INFLOW_K_MIN: f64 = 0.3;
pub const INFLOW_K_MAX: f64 = 1.0;
/// `[u10, p]`: показатель закона `U ∝ k^p`, между точками линейно, за краями — край (`INFLOW_P`).
pub const INFLOW_P: [[f64; 2]; 3] = [[3.0, 0.57], [6.0, 0.75], [10.0, 0.90]];
/// Высота замера `U` над землёй старта, м (`START_AGL_M`).
pub const START_AGL_M: f64 = 10.0;
/// Порог ветра меню, ниже которого подстройки нет (`WindProfile.U10_MIN`).
pub const U10_MIN: f64 = 0.5;
/// Допуски пересчёта: ветер, направление, температура (`WIND_TOL_MS`, `DIR_TOL_DEG`, `TMAX_TOL_C`).
pub const WIND_TOL_MS: f64 = 0.05;
pub const DIR_TOL_DEG: f64 = 1.0;
pub const TMAX_TOL_C: f64 = 0.25;
/// Проходов загрузки (`max_passes`) и остаток `|U/u10 − 1|`, при котором проходы сверх второго
/// не нужны (`pass_tol`).
pub const MAX_PASSES: usize = 2;
pub const PASS_TOL: f64 = 0.03;
/// Предел итераций решения (`AirPicardJob.max_outer`).
pub const MAX_OUTER: usize = 3000;
/// Меньше клеток по стороне (с учётом грубого шага) область не собирается.
pub const MIN_CELLS: usize = 12;

// ---------------------------------------------------------------- конфиг

/// Климат без сеток ERA5 (`has_hh1 = has_hh5 = false`): запасные таблицы `weather_model.json`.
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

/// Климат места: ячейка из заголовка (`loc.climate`, W5 v3), где есть сетка HH5 / HH1; иначе
/// запасные таблицы (`ClimateGrid.place`: без HH5 `tx_c`/`dtr_k` — из `weather_model.json`).
struct PlaceClimate<'a> {
    table: &'a TableClimate,
    loc: Option<LocClimate>,
}

impl Climate for PlaceClimate<'_> {
    fn cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> ClimateCell {
        let t = self.table.cell(lat, lon, month, day);
        match self.loc {
            None => t,
            Some(c) => ClimateCell {
                tx_c: if c.has_hh5 { c.tx_c } else { t.tx_c },
                dtr_k: if c.has_hh5 { c.dtr_k } else { t.dtr_k },
                z_cell_m: if c.has_hh1 { c.z_cell_m } else { 0.0 },
                has_hh1: c.has_hh1,
                has_hh5: c.has_hh5,
            },
        }
    }
}

/// Подставные отказы для тестов (T4a).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Faults {
    /// Грубый шаг не удался: старт с фона.
    pub coarse: bool,
    /// Решение прохода с этим номером (с 1) не удаётся (откат на прошлый проход).
    pub fail_pass: Option<usize>,
    /// Фазы не считаются: Пикар без заморозки и `nonconv` (сравнение итераций в тестах).
    pub no_phase: bool,
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
    pub max_passes: usize,
    pub pass_tol: f64,
    /// `window_levels_m` не пуст: игра подстраивает приток по старту.
    pub windows_wanted: bool,
    pub step_min: f64,
    pub blend_s: f64,
    pub edge_blend_cells: f64,
    pub limits: Limits,
    pub timeout_s: f64,
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
    /// Шаги окон `window_levels_m` (ключ запечённого поля).
    pub window_dx: Vec<f64>,
    /// Предел кеша, байт (`air_cache.max_mb`; 0 — кеш выключен).
    pub cache_max_bytes: u64,
    /// Хеш текстов конфигов (ключ кеша).
    pub configs_hash: String,
}

fn find<'a>(c: &'a Configs, name: &str) -> Option<&'a str> {
    c.files
        .iter()
        .find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))
        .map(|(_, t)| t.as_str())
}

fn json(c: &Configs, name: &str) -> Result<Value, Error> {
    match find(c, name) {
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
            max_passes: MAX_PASSES,
            pass_tol: PASS_TOL,
            windows_wanted: windows,
            step_min: am("recompute_game_min", 15.0),
            blend_s: am("blend_s", 60.0),
            edge_blend_cells: am("edge_blend_cells", 5.0),
            limits: Limits {
                max_speed: am("max_speed_ms", 40.0),
                max_w: am("max_w_ms", 10.0),
            },
            timeout_s: num(&atm, "/air/timeout_s", 180.0),
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
            cache_max_bytes: (num(&atm, "/air_cache/max_mb", 200.0).max(0.0) * 1048576.0) as u64,
            configs_hash: configs_hash(c),
        })
    }

    /// Параметры решателя случая с ветром меню `u10` (`AirCase.p`, `AirPicardJob`).
    pub fn solver(&self, u10: f64) -> SolverCfg {
        SolverCfg::new(u10)
    }
}

// ---------------------------------------------------------------- условия и срок

/// Условия, по которым посчитано (или будет считаться) поле (`_req`/`_cur` GDScript).
#[derive(Clone, Debug, PartialEq)]
pub struct CondRec {
    /// Час места: при загрузке — как есть, в полёте — начало срока.
    pub hour: f64,
    pub u10: f64,
    pub wdir: f64,
    pub t_max: Option<f64>,
    pub sky: String,
    pub inflow: InflowMode,
}

impl CondRec {
    pub fn new(inputs: &WeatherInputs, cond: &Conditions, hour: f64) -> Self {
        CondRec {
            hour,
            u10: inputs.u10,
            wdir: inputs.wdir,
            t_max: inputs.t_max,
            sky: inputs.sky.clone(),
            inflow: cond.inflow_mode,
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
    if have.inflow != want.inflow {
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

/// Ключ направления для памяти `k` (`_dir_key`).
pub fn dir_key(wdir: f64) -> i32 {
    (wdir.round() as i64).rem_euclid(360) as i32
}

// ---------------------------------------------------------------- приток k

/// Показатель закона `U ∝ k^p` для ветра меню `u10` (`inflow_p`).
pub fn inflow_p(u10: f64) -> f64 {
    let t = &INFLOW_P;
    if u10 <= t[0][0] {
        return t[0][1];
    }
    for i in 1..t.len() {
        if u10 <= t[i][0] {
            let (a, b) = (t[i - 1], t[i]);
            let f = (u10 - a[0]) / (b[0] - a[0]);
            return a[1] + (b[1] - a[1]) * f;
        }
    }
    t[t.len() - 1][1]
}

/// Запись прохода: `k` и `U` над стартом (`_pass_log`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PassLog {
    pub k: f64,
    pub u: f64,
}

/// `k` следующего прохода (`_next_k`): `k·(u10/U)^(1/p)`; дальше второго — секущая по двум
/// последним проходам; `U` не число или ≈ 0 — верхний предел.
pub fn next_k(log: &[PassLog], u10: f64) -> f64 {
    let Some(last) = log.last() else {
        return INFLOW_K_MAX;
    };
    let (k, u) = (last.k, last.u);
    if u.is_nan() || u <= 1.0e-3 {
        return INFLOW_K_MAX;
    }
    let mut k1 = k * (u10 / u).powf(1.0 / inflow_p(u10));
    if log.len() >= 2 {
        let prev = log[log.len() - 2];
        let (dk, du) = (k - prev.k, u - prev.u);
        if dk.abs() > 1.0e-4 && du / dk > 1.0e-3 {
            k1 = k + (u10 - u) * dk / du;
        }
    }
    k1.clamp(INFLOW_K_MIN, INFLOW_K_MAX)
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

// ---------------------------------------------------------------- запечённые поля

/// Запечённое поле места, принятое `add_baked_field`: данные как есть, из заголовка прочитано
/// только то, по чему выбирают файл (полный разбор — когда поле подошло).
#[derive(Clone, Debug)]
pub struct BakedEntry {
    pub location: String,
    pub site: String,
    pub model_hash: String,
    pub key: Value,
    pub header: String,
    pub data: Arc<Vec<u8>>,
}

impl BakedEntry {
    /// Заголовок TI-К3 v3 и тело `.bin`; неразборчивый заголовок, чужой формат — `BadInput`.
    pub fn new(header_json: &str, data: &[u8]) -> Result<Self, Error> {
        let bad = |m: String| Error::bad_input(format!("baked field: {m}"));
        let v: Value = serde_json::from_str(header_json).map_err(|e| bad(e.to_string()))?;
        if v.get("format").and_then(Value::as_str) != Some(FORMAT)
            || v.get("version").and_then(Value::as_f64) != Some(VERSION as f64)
        {
            return Err(bad("not a dp-air-baked v1 header".into()));
        }
        let text = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        if data.is_empty() {
            return Err(bad("empty data".into()));
        }
        Ok(BakedEntry {
            location: text("location"),
            site: text("site"),
            model_hash: text("model_hash"),
            key: v.get("key").cloned().unwrap_or(Value::Null),
            header: header_json.to_string(),
            data: Arc::new(data.to_vec()),
        })
    }

    /// Начало старта из `key.start` (x, z).
    fn start(&self) -> Option<[f64; 2]> {
        let a = self.key.get("start")?.as_array()?;
        Some([a.first()?.as_f64()?, a.get(1)?.as_f64()?])
    }
}

/// Запись для кеша: делается в пуле после подачи поля.
#[derive(Debug)]
pub struct CachePut {
    pub cache: FieldCache,
    pub key: Value,
    pub model_hash: String,
    pub field: BakedField,
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
    Baked,
    Cache,
}

fn hypot2(a: [f64; 2], b: [f64; 2]) -> f64 {
    (a[0] - b[0]).hypot(a[1] - b[1])
}

/// Выбор запечённого поля под условия (`baked_lookup` GDScript): `Ok(Some)` — подошло, `Err` — причина.
fn pick_baked(job: &JobIn) -> Result<BakedField, String> {
    let h = job.place.header();
    if job.baked.is_empty() {
        return Err(String::new());
    }
    if h.model_hash.is_empty() {
        return Err("у места нет model_hash".into());
    }
    let Some(f) = job.focus else {
        return Err("нет точки старта".into());
    };
    let f = [f[0] as f64, f[1] as f64];
    let Some(site) = h
        .start_sites
        .iter()
        .find(|s| hypot2([s.x, s.z], f) <= 1.0)
        .map(|s| [s.x, s.z])
    else {
        return Err("у точки старта нет площадки".into());
    };
    let cands: Vec<&BakedEntry> = job
        .baked
        .iter()
        .filter(|e| e.location == h.loc.id && e.start().is_some_and(|p| hypot2(p, site) <= 1.0))
        .collect();
    if cands.is_empty() {
        return Err(format!("нет файла запечённого поля места {}", h.loc.id));
    }
    let mut why = Vec::new();
    for e in cands {
        let no_weather = Value::Null;
        let weather = e.key.get("weather").unwrap_or(&no_weather);
        let rec = &job.rec;
        let wind_ref = match rec.inflow {
            InflowMode::Start => "start",
            InflowMode::Inflow => "inflow",
        };
        let q = BakedQuery {
            location: &h.loc.id,
            center_lat: h.loc.center_lat,
            center_lon: h.loc.center_lon,
            site: &e.site,
            start: site,
            weather,
            month: i64::from(h.loc.month),
            day: i64::from(h.loc.day),
            window_dx: &job.cfg.window_dx,
            data_hash: e.key.get("data_hash").and_then(Value::as_str).unwrap_or(""),
            model_hash: &h.model_hash,
            cond: Cond {
                hour: rec.hour,
                u10: rec.u10,
                wdir: rec.wdir,
                t_max: rec.t_max.unwrap_or(f64::NAN),
                sky: &rec.sky,
                wind_ref,
            },
        };
        let stub = BakedField {
            location: e.location.clone(),
            site: e.site.clone(),
            model_hash: e.model_hash.clone(),
            key: e.key.clone(),
            levels: Vec::new(),
            names: Vec::new(),
            level_meta: Vec::new(),
            inflow_k: 1.0,
        };
        match baked_lookup(std::slice::from_ref(&stub), &q) {
            Err(r) => why.push(format!("{}: {}", e.site, r.reason)),
            Ok(_) => {
                return match parse_baked(&e.header, &e.data) {
                    Ok(b) if !b.levels.is_empty() => Ok(b),
                    Ok(_) => Err(format!("{}: нет уровней", e.site)),
                    Err(er) => Err(format!("{}: {}", e.site, er.msg)),
                };
            }
        }
    }
    Err(why.join("; "))
}

/// Ключ кеша: всё, от чего зависит посчитанное поле и что видно крейту (место целиком по хешу,
/// конфиги по хешу, условия, точка старта, срок). Ключ словаря в `json!` — по алфавиту.
fn cache_key(job: &JobIn) -> Value {
    let h = job.place.header();
    let hash = job.place_hash.get_or_init(|| place_hash(&job.place));
    let rec = &job.rec;
    json!({
        "kind": "formula-field",
        "format": 1,
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
        "inflow": match rec.inflow { InflowMode::Start => "start", InflowMode::Inflow => "inflow" },
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
    pub k: f64,
    /// Итерации решений `[mech, heat]`.
    pub iters: [usize; 2],
    /// Итерации грубых решений `[mech, heat]`, если грубый шаг был.
    pub coarse_iters: Option<[usize; 2]>,
    pub start: Start,
    /// Заметки: отказ грубого шага и т. п.
    pub notes: Vec<String>,
    pub stop: [Stop; 2],
    pub omega_fallback: bool,
    pub nonconv_fallback: bool,
    /// Секунды: подготовка (вход, случаи), грубый шаг, решения, сборка поля.
    pub secs: [f64; 4],
    /// Фазы поля посчитаны (иначе — Пикар без фаз).
    pub phases: bool,
    /// Секунды сборки фаз.
    pub phase_s: f64,
    /// Доля замороженных колонн `[heat, mech]`.
    pub frozen_frac: [f64; 2],
    /// Колонны запасного пути переданы решениям.
    pub nonconv_cols: bool,
}

struct PassOut {
    field: Field,
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
    /// Загрузка (час как есть, проходы `k`) или пересчёт (один проход).
    pub loading: bool,
    /// Память `k` по румбу (загрузка) и `k` текущего поля (пересчёт).
    pub k_mem: Option<f64>,
    pub inflow_k: f64,
    /// Точка старта (x, z мира): первый фокус.
    pub focus: Option<[f32; 2]>,
    /// Прошлое поле пары (пересчёт в полёте).
    pub warm: Option<Arc<Pair>>,
    pub cancel: Arc<AtomicBool>,
    /// Доля готовности 0..1 (биты `f32`).
    pub progress: Arc<AtomicU32>,
    /// Запечённые поля места (`add_baked_field`).
    pub baked: Arc<Vec<BakedEntry>>,
    /// Кеш полей (`set_cache_dir`); `None` — выключен.
    pub cache: Option<FieldCache>,
    /// Хеш места — считается при первой надобности и живёт с местом.
    pub place_hash: Arc<OnceLock<String>>,
}

/// Итог задачи.
#[derive(Debug)]
pub struct JobOut {
    /// Уровни от мелкого к грубому (сейчас один).
    pub levels: Vec<Arc<Field>>,
    /// `k` поданного поля.
    pub k: f64,
    pub rec: CondRec,
    /// Состояния для тёплого старта следующего пересчёта (`None` — поле из файла или кеша).
    pub pair: Option<Arc<Pair>>,
    pub report: JobReport,
    /// Запись в кеш после подачи (забирает вызывающий).
    pub cache_put: Option<CachePut>,
}

/// Журнал задачи.
#[derive(Clone, Debug)]
pub struct JobReport {
    pub passes: Vec<PassReport>,
    /// Проходов, запланированных при старте (2 — подстройка `k`).
    pub planned: usize,
    pub log: Vec<PassLog>,
    /// Проход ≥ 2 не удался: подано поле прошлого прохода.
    pub pass_failed: Option<String>,
    /// Проход 1 упёрся в предел итераций: без подстройки.
    pub not_converged: bool,
    pub wall_s: f64,
    /// Откуда поле.
    pub source: Source,
    /// Заметки: почему запечённое и кеш не взяты, ошибки записи кеша.
    pub notes: Vec<String>,
}

fn set_progress(job: &JobIn, pass: usize, passes: usize, x: f32) {
    let v = ((pass - 1) as f32 + x.clamp(0.0, 1.0)) / passes.max(1) as f32;
    job.progress
        .store(v.min(0.999).to_bits(), Ordering::Relaxed);
}

fn check_cancel(job: &JobIn) -> Result<(), JobErr> {
    if job.cancel.load(Ordering::Relaxed) {
        Err(JobErr::Cancelled)
    } else {
        Ok(())
    }
}

/// Уровень решения: два случая (mech и heat), плоскости не нужны после сборки случая.
struct LevelCase {
    heat: AirCaseRs,
    planes_h: PreparedPlanes,
    case_h: Case,
    case_m: Case,
}

fn build_level(job: &JobIn, dom: &Domain, k: f64) -> Result<LevelCase, JobErr> {
    let cfg = &job.cfg;
    let climate = PlaceClimate {
        table: &cfg.climate,
        loc: job.place.header().loc.climate,
    };
    check_cancel(job)?;
    let fw = field_weather(
        &job.cond,
        &job.place,
        &cfg.wc,
        &job.configs,
        &climate,
        job.rec.hour,
        dom,
    )?;
    check_cancel(job)?;
    let inp = build_domain_input(&job.place, &cfg.wc.sh, &cfg.zi, dom, &fw.day)?;
    check_cancel(job)?;
    let heat = build_case(
        &inp,
        &fw,
        &CaseOpts {
            k,
            inflow_mode: job.rec.inflow,
            heat: true,
        },
    )?;
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

/// Случаи решателя `[mech, heat]` тонкой области для `k` (для тестов и стенда: то, что решает
/// проход, без решения).
pub fn level_cases(job: &JobIn, k: f64) -> Result<[Case; 2], JobErr> {
    let dom = domain_for(&job.place, &job.cfg)?;
    let lc = build_level(job, &dom, k)?;
    Ok([lc.case_m, lc.case_h])
}

/// Фазы поля тонкой области для `k` (для тестов и стенда).
pub fn phase_result(job: &JobIn, k: f64) -> Result<PhaseResult, JobErr> {
    let dom = domain_for(&job.place, &job.cfg)?;
    let lc = build_level(job, &dom, k)?;
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

fn level_of(p: &PreparedPlanes, dom: &Domain) -> Level {
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

/// Что решению сверх случая и старта: запасные правила, заморозка колонн, `nonconv`.
#[derive(Default)]
struct Spec {
    fallback: bool,
    freeze: Option<Freeze>,
    nonconv: Option<NonConv>,
}

fn solve_one(
    job: &JobIn,
    case: &Case,
    init: Option<State>,
    spec: Spec,
    deadline: Instant,
) -> Result<Solved, JobErr> {
    check_cancel(job)?;
    let cfg = &job.cfg;
    let left = deadline
        .saturating_duration_since(Instant::now())
        .max(Duration::from_secs(1));
    let opts = SolveOpts {
        threads: cfg.threads,
        max_iters: cfg.max_iters,
        tol_scale: cfg.tol_scale,
        time_budget: Some(left),
        init,
        freeze: spec.freeze,
        cancel: Some(job.cancel.clone()),
        fallback: spec.fallback.then(|| Fallback {
            omega_after: cfg.omega_after,
            omega: cfg.omega,
            late_from: cfg.late_from,
            nonconv: spec.nonconv,
        }),
        ..SolveOpts::default()
    };
    let s = solve(case, &opts).map_err(|e| JobErr::Failed(format!("solver: {e:#}")))?;
    match s.stop {
        StopReason::Cancelled => Err(JobErr::Cancelled),
        StopReason::TimeBudget => Err(JobErr::Failed(format!(
            "timeout: {} iterations in {:.0} s",
            s.iters, cfg.timeout_s
        ))),
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
    deadline: Instant,
) -> Result<(Pair, [usize; 2]), JobErr> {
    let sm = solve_one(job, &coarse.case_m, None, Spec::default(), deadline)?;
    let sh = solve_one(job, &coarse.case_h, None, Spec::default(), deadline)?;
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
    k: f64,
    prev: Option<&Pair>,
    pass: usize,
    passes: usize,
) -> Result<PassOut, JobErr> {
    let cfg = &job.cfg;
    let t0 = Instant::now();
    let deadline = t0 + Duration::from_secs_f64(cfg.timeout_s.max(1.0));
    check_cancel(job)?;
    set_progress(job, pass, passes, 0.0);
    let fine_dom = domain_for(&job.place, cfg)?;
    let want_coarse = prev.is_none() && cfg.coarse_factor > 1;
    let coarse_dom = coarse_domain(&fine_dom, cfg.coarse_factor);
    let mut notes = Vec::new();
    let (fine, coarse) = if want_coarse {
        let (a, b) = rayon::join(
            || build_level(job, &fine_dom, k),
            || build_level(job, &coarse_dom, k),
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
        (build_level(job, &fine_dom, k)?, None)
    };
    let t_prep = t0.elapsed().as_secs_f64();
    set_progress(job, pass, passes, 0.15);
    check_cancel(job)?;
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
    if start == Start::Cold
        && !all_mech
        && let Some(c) = &coarse
    {
        if cfg.faults.coarse {
            notes.push("coarse step failed (injected): start from the background".into());
        } else {
            match coarse_start(job, &fine, c, &fine_dom, &coarse_dom, deadline) {
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
    set_progress(job, pass, passes, 0.3);
    let t2 = Instant::now();
    if cfg.faults.fail_pass == Some(pass) {
        return Err(JobErr::Failed(format!("pass {pass} failed (injected)")));
    }
    let spec = |freeze, nonconv| Spec {
        fallback: true,
        freeze,
        nonconv,
    };
    let sm = solve_one(
        job,
        &fine.case_m,
        init_m,
        spec(fr_m, nonconv.clone()),
        deadline,
    )?;
    set_progress(job, pass, passes, 0.6);
    let sh = solve_one(job, &fine.case_h, init_h, spec(fr_h, nonconv), deadline)?;
    set_progress(job, pass, passes, 0.9);
    let t_solve = t2.elapsed().as_secs_f64();
    let t3 = Instant::now();
    let nz = fine.heat.nz;
    let grid = FieldGrid {
        dx: fine_dom.dx,
        dz: fine.heat.dz,
        x0: fine_dom.x0,
        y0: fine_dom.y0,
        z_bot: fine.heat.z_bot,
        nx: fine_dom.nx,
        ny: fine_dom.ny,
        nz,
    };
    let meta = FieldMeta {
        // z0 — как его хранит файл поля (f32): поле из кеша побитно равно посчитанному
        z0: if fine.heat.z0_map.is_empty() {
            Z0::Uniform(f64::from(fine.heat.p.z0 as f32))
        } else {
            Z0::Map(
                fine.heat
                    .z0_map
                    .iter()
                    .map(|&z| f64::from(z as f32))
                    .collect(),
            )
        },
        gam: fine.heat.gam[1..=nz].iter().map(|&g| g as f32).collect(),
        heat: fine.planes_h.heat_used.iter().map(|&h| h as f32).collect(),
        z_i: fine.heat.z_i,
        z_i_col: fine.heat.z_i_col.clone(),
    };
    let hc32: Vec<f32> = fine.heat.hc.iter().map(|&h| h as f32).collect();
    let cell = fine
        .case_h
        .arrays
        .get("cell")
        .ok_or_else(|| JobErr::Failed("case has no 'cell' array".into()))?;
    let mut field = Field::from_mac(&sh.state, &sm.state, &grid, cell, &hc32, meta, cfg.limits)?;
    field.edge_cells = cfg.edge_blend_cells;
    let report = PassReport {
        k,
        iters: [sm.iters, sh.iters],
        coarse_iters,
        start,
        notes,
        stop: [sm.stop, sh.stop],
        omega_fallback: sm.omega_fallback_used || sh.omega_fallback_used,
        nonconv_fallback: sm.nonconv_fallback || sh.nonconv_fallback,
        secs: [t_prep, t_coarse, t_solve, t3.elapsed().as_secs_f64()],
        phases: fr_some,
        phase_s,
        frozen_frac,
        nonconv_cols,
    };
    set_progress(job, pass, passes, 1.0);
    Ok(PassOut {
        field,
        pair: Arc::new(Pair {
            mech: sm.state,
            heat: sh.state,
        }),
        report,
    })
}

/// `U` над стартом на 10 м (`start_speed`): горизонталь поля на `START_AGL_M` над землёй точки
/// с весом края, непокрытая доля — ветер меню `u10` по направлению `wdir`. `NaN` — нет точки.
pub fn start_speed(f: &Field, place: &Place, p: Option<[f32; 2]>, u10: f64, wdir: f64) -> f64 {
    let Some(p) = p else {
        return f64::NAN;
    };
    let h = ground_height(place, p[0], p[1]);
    let pos = [p[0], h + START_AGL_M as f32, p[1]];
    let w = f.edge_weight(pos);
    let s = if w > 0.0 { f.sample(pos, h) } else { [0.0; 3] };
    let (vx, vz) = (s[0] as f64 * w, s[2] as f64 * w);
    let rest = u10 * (1.0 - w);
    let a = wdir.to_radians();
    (vx - a.sin() * rest).hypot(vz + a.cos() * rest)
}

/// Проход упёрся в предел итераций (`_hit_iter_limit`).
fn hit_iter_limit(r: &PassReport) -> bool {
    r.iters.iter().any(|&n| n >= MAX_OUTER)
}

/// Поле из файла (запечённое или кеш): Ready без Пикара.
fn from_file(job: JobIn, b: BakedField, source: Source, t0: Instant, notes: Vec<String>) -> JobOut {
    job.progress.store(1.0f32.to_bits(), Ordering::Relaxed);
    JobOut {
        levels: FieldSet::prepare(b.levels, job.cfg.limits, job.cfg.edge_blend_cells),
        k: b.inflow_k,
        rec: job.rec,
        pair: None,
        report: JobReport {
            passes: Vec::new(),
            planned: 0,
            log: Vec::new(),
            pass_failed: None,
            not_converged: false,
            wall_s: t0.elapsed().as_secs_f64(),
            source,
            notes,
        },
        cache_put: None,
    }
}

/// Одно поле: загрузка (запечённое → кеш → проходы `k`) или пересчёт (один проход, тёплый старт).
pub fn run_job(job: JobIn) -> Result<JobOut, JobErr> {
    let t0 = Instant::now();
    let cfg = job.cfg.clone();
    let mut notes = Vec::new();
    let mut ckey = None;
    if job.loading {
        match pick_baked(&job) {
            Ok(b) => return Ok(from_file(job, b, Source::Baked, t0, notes)),
            Err(m) if !m.is_empty() => notes.push(format!("baked: {m}")),
            Err(_) => {}
        }
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
    let inflow = job.rec.inflow == InflowMode::Inflow;
    let u10 = job.rec.u10;
    let (passes, mut k) = if job.loading {
        let two = job.focus.is_some()
            && u10 >= U10_MIN
            && cfg.max_passes >= 2
            && !inflow
            && cfg.windows_wanted;
        if two {
            (cfg.max_passes, job.k_mem.unwrap_or(1.0))
        } else {
            (1, 1.0)
        }
    } else {
        (1, if inflow { 1.0 } else { job.inflow_k })
    };
    let mut report = JobReport {
        passes: Vec::new(),
        planned: passes,
        log: Vec::new(),
        pass_failed: None,
        not_converged: false,
        wall_s: 0.0,
        source: Source::Computed,
        notes,
    };
    let mut pass = 1usize;
    let mut warm: Option<Arc<Pair>> = job.warm.clone();
    let mut prev_ok: Option<PassOut> = None;
    loop {
        let r = solve_pass(&job, k, warm.as_deref(), pass, passes.max(pass));
        let out = match r {
            Ok(o) => o,
            Err(JobErr::Cancelled) => return Err(JobErr::Cancelled),
            Err(JobErr::Failed(m)) => {
                // загрузка: проход ≥ 2 не удался — поле прошлого прохода (`_use_previous_pass`)
                if let (true, Some(p)) = (job.loading && pass > 1, prev_ok.take()) {
                    report.pass_failed = Some(format!("pass {pass}: {m}"));
                    return Ok(finish(job, p, report, t0, ckey));
                }
                return Err(JobErr::Failed(m));
            }
        };
        let u = start_speed(&out.field, &job.place, job.focus, u10, job.rec.wdir);
        report.log.push(PassLog { k, u });
        report.passes.push(out.report.clone());
        let mut more = pass < passes;
        if more && pass >= 2 {
            // сверх контрактных двух — только если остаток больше pass_tol
            more = !u.is_nan() && (u / u10 - 1.0).abs() > cfg.pass_tol;
        }
        if more && pass == 1 && hit_iter_limit(&out.report) {
            // слабый ветер: решение не сошлось — подстройка по нему бессмысленна
            more = false;
            report.not_converged = true;
        }
        let k1 = if more { next_k(&report.log, u10) } else { k };
        if more && (k1 - k).abs() < 1.0e-6 {
            // k упёрся в предел: проход 2 дал бы то же поле
            more = false;
        }
        if !more {
            return Ok(finish(job, out, report, t0, ckey));
        }
        warm = Some(out.pair.clone());
        prev_ok = Some(out);
        pass += 1;
        k = k1;
    }
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
    let k = p.report.k;
    let levels = FieldSet::prepare(vec![p.field], job.cfg.limits, job.cfg.edge_blend_cells);
    let cache_put = match (ckey, job.cache.clone()) {
        (Some(key), Some(cache)) => {
            let status = if report.pass_failed.is_some() {
                "previous_pass"
            } else if report.not_converged {
                "not_converged"
            } else {
                "ok"
            };
            let mut extra = Map::new();
            extra.insert("status".into(), json!(status));
            extra.insert("inflow_k".into(), json!(k));
            extra.insert("wall_s".into(), json!(report.wall_s));
            let mut meta = Map::new();
            meta.insert("inflow_k".into(), json!(k));
            Some(CachePut {
                cache: FieldCache {
                    max_bytes: job.cfg.cache_max_bytes,
                    ..cache
                },
                key,
                model_hash: job.place.header().model_hash.clone(),
                field: BakedField {
                    location: job.place.header().loc.id.clone(),
                    site: String::new(),
                    model_hash: job.place.header().model_hash.clone(),
                    key: Value::Null,
                    levels: levels.iter().map(|l| (**l).clone()).collect(),
                    names: Vec::new(),
                    level_meta: vec![meta],
                    inflow_k: k,
                },
                extra,
            })
        }
        _ => None,
    };
    JobOut {
        levels,
        k,
        rec: job.rec,
        pair: Some(p.pair),
        report,
        cache_put,
    }
}
