//! Погода и солнце для поля воздуха: то, что `AirPlace.domain_case` берёт из погоды игры, но
//! из условий W5 v2, конфигов (текст json) и растров места — без колбэков и без Godot.
//!
//! Перенесено из GDScript (совпадение проверяет `tests/weather_core.rs` против дампа GD):
//! `WeatherModel.{diurnal_state, sky_params, typical_max_c, diurnal_range_k, ground_context,
//! monthly}`, `AirPlace.{context, day, theta, gamma, block_mean, cell_surface, cell_z0,
//! surface_flux}`, температура воды (`SurfaceHeat.water_temp_c`), `WindProfile.apply_to_case`.
//! Не здесь (RW-12): `WeatherModel.derive`, `td_day`, `haze_k_rh`, `AtmoDay`.
//!
//! ## Внутренний интерфейс для RW-6d
//! [`field_weather`] — `(Conditions, Place, WeatherConfigs, Climate, hour, Domain)` →
//! [`FieldWeather`]: контекст места (долина, средняя высота), день [`Day`] (профиль θ̄ —
//! [`Day::theta`], [`Day::gamma`], `z_i`), блочное среднее рельефа `hc`, шероховатость клеток
//! `z0` и эффективная `z0_eff`, поток тепла `heat` (Вт/м², `ny·nx`, строка `j` на север), α,
//! класс устойчивости, `z_sat`, `max_profile`. Растры — плоские массивы, индекс `j·nx + i`.
//!
//! Климат ERA5 (`ClimateGrid.at`: сетки `data/climate/*.bin` под brotli) в крейт не входит:
//! значения ячейки на дату даёт вызывающий через [`Climate`]; поправки на высоту долины
//! (`ClimateGrid.place`) делаются здесь.
//!
//! Допущения: сетка рельефа и снимка поверхности места — шаг 25 м, начало кратно 25 м, область
//! (`Domain`) лежит на этой решётке (`dx`, `x0`, `y0` кратны 25 м) и целиком внутри места.
use super::sun::{day_of_year, days_in_month, lerp, solar_position};
use super::surface_heat::{
    CLASS_COUNT, NONE, Sky, SurfaceHeatCfg, SurfaceHeating, WATER, WaterIn, mix_flux, num,
};
use super::wind_profile::{CaseProfile, F_COR, WindProfileCfg, apply_to_case};
use crate::{Conditions, Configs, Error, Place, Source};
use rayon::prelude::*;
use serde_json::Value;

/// Сторона области, м (38,4 км = 96·400 = 192·200).
pub const DOMAIN_L: f64 = 38400.0;
/// Шаг решётки мира, м.
pub const NODE_STEP: f64 = 25.0;
/// Сухоадиабатический градиент, К/км.
pub const GAMMA_D: f64 = 9.8;

// ---------------------------------------------------------------- конфиги

/// Климат ячейки ERA5 на дату без поправки на высоту (`ClimateGrid.at`): то, что нужно полю.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClimateCell {
    /// Дневной максимум HH5 (или запас из `typical_max_c`, если сетки нет), °C.
    pub tx_c: f64,
    /// Суточная амплитуда HH5 (или запас из `diurnal.range_k`), К.
    pub dtr_k: f64,
    /// Средняя высота ячейки HH1, м (0 — сетки HH1 нет).
    pub z_cell_m: f64,
    pub has_hh1: bool,
    pub has_hh5: bool,
}

/// Источник климата: ячейка на (широта, долгота, месяц, день).
pub trait Climate: Sync {
    fn cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> ClimateCell;
}

impl<F: Fn(f64, f64, i64, i64) -> ClimateCell + Sync> Climate for F {
    fn cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> ClimateCell {
        self(lat, lon, month, day)
    }
}

/// Параметры `weather_model.json`, нужные полю.
#[derive(Clone, Debug, PartialEq)]
pub struct WeatherModelCfg {
    pub ui_temperature_c: [f64; 2],
    pub peak_after_noon_h: f64,
    pub sunset_fraction: f64,
    pub night_tau_h: f64,
    /// `diurnal.residual_cooling_k` в `diurnal_state` (запасное 1,0) и в `day` (запасное 2,0).
    pub residual_cooling_state_k: f64,
    pub residual_cooling_day_k: f64,
    pub break_window_k: f64,
    pub inversion_depth_m: f64,
    pub heat_lag_h: f64,
    pub sharp_min: f64,
    pub evening_calm_h: f64,
    pub evening_mech_k: f64,
    pub parcel_excess_k: f64,
    pub upper_temp_c: Vec<f64>,
    pub upper_z_msl_m: f64,
    pub upper_lapse_k_per_km: f64,
    sky: Value,
    heating: Value,
    tx_gradient: Option<Value>,
    dtr_gradient: Option<Value>,
}

fn arr(v: &Value, path: &[&str], def: &[f64]) -> Vec<f64> {
    let mut cur = v;
    for k in path {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return def.to_vec(),
        }
    }
    match cur.as_array() {
        Some(a) => a.iter().map(|x| x.as_f64().unwrap_or(0.0)).collect(),
        None => def.to_vec(),
    }
}

impl WeatherModelCfg {
    pub fn from_value(v: &Value) -> Self {
        let ui = arr(v, &["ui", "temperature_c"], &[-50.0, 60.0, 1.0]);
        let d = |k: &str, def: f64| num(v, &["diurnal", k], def);
        WeatherModelCfg {
            ui_temperature_c: [ui[0], ui[1]],
            peak_after_noon_h: d("peak_after_noon_h", 2.5),
            sunset_fraction: d("sunset_fraction", 0.65),
            night_tau_h: d("night_tau_h", 2.0),
            residual_cooling_state_k: d("residual_cooling_k", 1.0),
            residual_cooling_day_k: d("residual_cooling_k", 2.0),
            break_window_k: d("break_window_k", 3.0),
            inversion_depth_m: d("inversion_depth_m", 500.0),
            heat_lag_h: d("heat_lag_h", 0.3),
            sharp_min: num(v, &["diurnal", "soft", "sharp_min"], 0.5),
            evening_calm_h: d("evening_calm_h", 2.0),
            evening_mech_k: d("evening_mech_k", 0.6),
            parcel_excess_k: num(v, &["parcel_excess_k"], 1.0),
            upper_temp_c: arr(v, &["upper_air", "temp_c"], &[0.0]),
            upper_z_msl_m: num(v, &["upper_air", "z_msl_m"], 3000.0),
            upper_lapse_k_per_km: num(v, &["upper_air", "lapse_k_per_km"], 4.0),
            sky: v.get("sky").cloned().unwrap_or(Value::Null),
            heating: v.get("heating").cloned().unwrap_or(Value::Null),
            tx_gradient: v.pointer("/climate/tx_gradient_k_per_km").cloned(),
            dtr_gradient: v.pointer("/climate/dtr_gradient_k_per_km").cloned(),
        }
    }

    /// Инерция прогрева поверхности на дату и место `ctx` (`SurfaceHeating.setup`).
    pub fn surface_heating(&self, ctx: &Ctx) -> SurfaceHeating {
        SurfaceHeating::new(
            ctx.lat,
            ctx.lon,
            ctx.month,
            ctx.day,
            ctx.utc_offset_h,
            &self.heating,
        )
    }

    /// Поправки облачности: `(cover, heat)`; неизвестная облачность — как "clear".
    pub fn sky_params(&self, sky: &str) -> (f64, f64) {
        let p = self.sky.get(sky).or_else(|| self.sky.get("clear"));
        let g = |k: &str, def: f64| {
            p.and_then(|p| p.get(k))
                .and_then(Value::as_f64)
                .unwrap_or(def)
        };
        (g("cover", 0.0), g("heat", 1.0))
    }
}

/// Все конфиги поля: `weather_model`, `surface_heat`, `atmosphere` (секция `wind`).
#[derive(Clone, Debug, PartialEq)]
pub struct WeatherConfigs {
    pub wm: WeatherModelCfg,
    pub sh: SurfaceHeatCfg,
    pub wind: WindProfileCfg,
}

fn find<'a>(c: &'a Configs, name: &str) -> Option<&'a str> {
    c.files
        .iter()
        .find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))
        .map(|(_, t)| t.as_str())
}

fn parse_named(c: &Configs, name: &str) -> Result<Value, Error> {
    let t = find(c, name).ok_or_else(|| Error::bad_input(format!("config '{name}' missing")))?;
    serde_json::from_str(t).map_err(|e| Error::bad_input(format!("config '{name}': {e}")))
}

impl WeatherConfigs {
    /// Из пар (имя, текст): `atmosphere` (необязателен), `weather_model`, `surface_heat`.
    pub fn from_configs(c: &Configs) -> Result<Self, Error> {
        let atm = match find(c, "atmosphere") {
            Some(_) => parse_named(c, "atmosphere")?,
            None => Value::Null,
        };
        Ok(WeatherConfigs {
            wm: WeatherModelCfg::from_value(&parse_named(c, "weather_model")?),
            sh: SurfaceHeatCfg::from_value(&parse_named(c, "surface_heat")?)?,
            wind: WindProfileCfg {
                alpha_n: num(&atm, &["wind", "shear_exponent_neutral"], 0.24),
                z_sat_frac: num(&atm, &["wind", "z_sat_frac"], 0.3),
            },
        })
    }
}

// ---------------------------------------------------------------- условия

/// Входы погоды поля из условий W5 v2.
#[derive(Clone, Debug, PartialEq)]
pub struct WeatherInputs {
    /// Дневной максимум, °C; `None` — обычный для даты места.
    pub t_max: Option<f64>,
    pub sky: String,
    /// Ветер меню на 10 м, м/с.
    pub u10: f64,
    pub wdir: f64,
}

impl WeatherInputs {
    /// Прогноз: `temperature_c`, `sky`, `wind_speed_kmh / 3,6`, `wind_from_deg`. Эталон — ключи
    /// пресета (`temperature_c`, `sky` необязательны; имя пресета ищется как `weather/<имя>`).
    pub fn from_conditions(cond: &Conditions, cfgs: &Configs) -> Result<Self, Error> {
        match &cond.source {
            Source::Forecast { forecast, .. } => Ok(WeatherInputs {
                t_max: Some(forecast.temperature_c),
                sky: forecast.sky.clone(),
                u10: forecast.wind_speed_kmh.max(0.0) / 3.6,
                wdir: forecast.wind_from_deg,
            }),
            Source::Preset(p) => {
                let obj = match p {
                    Value::String(name) => {
                        let n = name.strip_prefix("weather/").unwrap_or(name);
                        parse_named(cfgs, &format!("weather/{n}"))?
                    }
                    other => other.clone(),
                };
                Ok(WeatherInputs {
                    t_max: obj.get("temperature_c").and_then(Value::as_f64),
                    sky: obj
                        .get("sky")
                        .and_then(Value::as_str)
                        .unwrap_or("clear")
                        .to_string(),
                    u10: num(&obj, &["wind_speed_kmh"], 0.0).max(0.0) / 3.6,
                    wdir: num(&obj, &["wind_from_deg"], 270.0),
                })
            }
        }
    }
}

/// Час суток (часы места) в момент `t_s` с начала полёта: `start_hour + t·speed/3600`.
pub fn hour_at(cond: &Conditions, t_s: f64) -> f64 {
    cond.start_hour + t_s * cond.speed / 3600.0
}

// ---------------------------------------------------------------- место и контекст

/// Контекст места для погоды: дата, широта, долгота, пояс, высота долины и средняя, м.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ctx {
    pub month: i64,
    pub day: i64,
    pub lat: f64,
    pub lon: f64,
    pub utc_offset_h: f64,
    pub valley_msl_m: f64,
    pub mean_msl_m: f64,
}

/// Высота рельефа в (x, z) мира: билинейно по узлам места, вне — по краю (`HeightLayer.sample`).
fn sample_height(place: &Place, x: f64, z: f64) -> f64 {
    let g = &place.header().grid;
    let (w, h) = (g.width as usize, g.height as usize);
    let inv = 1.0 / g.spacing;
    let fx = ((x - g.origin_x) * inv).clamp(0.0, w as f64 - 1.0);
    let fz = ((z - g.origin_z) * inv).clamp(0.0, h as f64 - 1.0);
    let i = (fx as usize).min(w - 2);
    let j = (fz as usize).min(h - 2);
    let (tx, tz) = (fx - i as f64, fz - j as f64);
    let hs = place.heights();
    let k = j * w + i;
    let (a, b, c, d) = (
        hs[k] as f64,
        hs[k + 1] as f64,
        hs[k + w] as f64,
        hs[k + w + 1] as f64,
    );
    lerp(lerp(a, b, tx), lerp(c, d, tx), tz)
}

/// Долина (нижняя доля `low_percentile`) и средняя высота в круге `radius_m` вокруг (0, 0) по
/// сетке `samples²` (`WeatherModel.ground_context`; отсчёты хранятся как f32).
pub fn ground_context(
    place: &Place,
    radius_m: f64,
    samples: usize,
    low_percentile: f64,
) -> (f64, f64) {
    let n = samples.max(2);
    let mut hs: Vec<f32> = Vec::with_capacity(n * n);
    for j in 0..n {
        for i in 0..n {
            let u = i as f64 / (n - 1) as f64 * 2.0 - 1.0;
            let v = j as f64 / (n - 1) as f64 * 2.0 - 1.0;
            if u * u + v * v > 1.0 {
                continue;
            }
            hs.push(sample_height(place, u * radius_m, v * radius_m) as f32);
        }
    }
    if hs.is_empty() {
        return (0.0, 0.0);
    }
    let sum: f64 = hs.iter().map(|&h| h as f64).sum();
    hs.sort_by(|a, b| a.total_cmp(b));
    let k = ((low_percentile * (hs.len() - 1) as f64).floor() as i64).clamp(0, hs.len() as i64 - 1);
    (hs[k as usize] as f64, sum / hs.len() as f64)
}

/// Контекст места (`AirPlace.context`): дата и положение из заголовка места, высоты из растра.
pub fn context(place: &Place) -> Ctx {
    let loc = &place.header().loc;
    let (valley, mean) = ground_context(place, 10000.0, 15, 0.1);
    Ctx {
        month: loc.month as i64,
        day: loc.day as i64,
        lat: loc.center_lat,
        lon: loc.center_lon,
        utc_offset_h: loc.utc_offset_h,
        valley_msl_m: valley,
        mean_msl_m: mean,
    }
}

// ---------------------------------------------------------------- климат и суточный ход

/// Значение из таблицы по месяцам (12 чисел, середина месяца — 15-е), линейно между месяцами.
pub fn monthly(arr: &[f64], month: i64, day: i64) -> f64 {
    if arr.is_empty() {
        return 0.0;
    }
    if arr.len() < 12 {
        return arr[0];
    }
    let m = month.clamp(1, 12) - 1;
    let dim = days_in_month(m + 1) as f64;
    let f = (day as f64 - 15.0) / dim;
    let j = (m + if f >= 0.0 { 1 } else { -1 }).rem_euclid(12);
    lerp(arr[m as usize], arr[j as usize], f.abs())
}

/// Физический сезон 0..3 = ДЯФ, МАМ, ИИА, СОН; в южном полушарии месяц сдвинут на 6.
pub fn season_index(month: i64, lat: f64) -> usize {
    let mut m = month.clamp(1, 12);
    if lat < 0.0 {
        m = (m + 5) % 12 + 1;
    }
    ((m % 12) as f64 / 3.0).floor() as usize
}

/// Градиент по поясам: `mid` (30–60°) по сезону, `tropics` (|φ| ≤ 20°), `other`; нет — `def`.
fn belt_gradient(lat: f64, season: usize, g: Option<&Value>, def: f64) -> f64 {
    let Some(g) = g else {
        return def; // секции нет: пустой словарь — всё по умолчанию
    };
    let Value::Object(_) = g else {
        return g.as_f64().unwrap_or(def);
    };
    let a = lat.abs();
    if (30.0..=60.0).contains(&a) {
        let t = arr(g, &["mid"], &[def]);
        return t[season.min(t.len() - 1)];
    }
    if a <= 20.0 {
        return num(g, &["tropics"], def);
    }
    num(g, &["other"], def)
}

impl WeatherModelCfg {
    /// Дневной максимум и амплитуда места на дату с поправкой на высоту долины
    /// (`ClimateGrid.place`: tx_c, dtr_k).
    fn place_climate(&self, cell: &ClimateCell, lat: f64, month: i64, valley: f64) -> (f64, f64) {
        let valley = if !cell.has_hh1 || valley.is_nan() {
            cell.z_cell_m
        } else {
            valley
        };
        let dz_km = (valley - cell.z_cell_m) / 1000.0;
        let season = season_index(month.clamp(1, 12), lat);
        let (mut tx, mut dtr) = (cell.tx_c, cell.dtr_k);
        if cell.has_hh5 {
            tx += belt_gradient(lat, season, self.tx_gradient.as_ref(), -6.31) * dz_km;
            dtr = (dtr + belt_gradient(lat, season, self.dtr_gradient.as_ref(), -0.48) * dz_km)
                .max(0.0);
        }
        (tx, dtr)
    }

    /// Обычный дневной максимум места на дату `ctx`, °C (зажат в диапазон меню).
    pub fn typical_max_c(&self, ctx: &Ctx, climate: &dyn Climate) -> f64 {
        let cell = climate.cell(ctx.lat, ctx.lon, ctx.month, ctx.day);
        let (tx, _) = self.place_climate(&cell, ctx.lat, ctx.month, ctx.valley_msl_m);
        tx.clamp(self.ui_temperature_c[0], self.ui_temperature_c[1])
    }

    /// Суточная амплитуда места на дату `ctx`, К.
    pub fn diurnal_range_k(&self, ctx: &Ctx, climate: &dyn Climate) -> f64 {
        let cell = climate.cell(ctx.lat, ctx.lon, ctx.month, ctx.day);
        self.place_climate(&cell, ctx.lat, ctx.month, ctx.valley_msl_m)
            .1
    }

    /// Суточный ход при заданной амплитуде (`WeatherModel.diurnal_state`).
    pub fn diurnal_state_amp(&self, t_max: f64, hour: f64, ctx: &Ctx, amp: f64) -> DiurnalState {
        let doy = day_of_year(ctx.month.clamp(1, 12), ctx.day);
        let utc = ctx.utc_offset_h;
        let noon = if utc.is_nan() {
            12.0
        } else {
            12.0 - (4.0 * ctx.lon - 60.0 * utc) / 60.0
        };
        let decl =
            23.44f64.to_radians() * (std::f64::consts::TAU * (284.0 + doy as f64) / 365.0).sin();
        let cos_h0 = (-ctx.lat.to_radians().tan() * decl.tan()).clamp(-1.0, 1.0);
        let half = cos_h0.acos().to_degrees() / 15.0;
        let sunrise = noon - half;
        let sunset = noon + half;
        let peak = (noon + self.peak_after_noon_h).min(sunset - 0.5);
        let fs = self.sunset_fraction;
        let pi = std::f64::consts::PI;
        let f = if hour <= sunrise {
            0.0
        } else if hour <= peak {
            (pi * 0.5 * (hour - sunrise) / (peak - sunrise).max(0.1)).sin()
        } else if hour <= sunset {
            fs + (1.0 - fs) * (pi * 0.5 * (hour - peak) / (sunset - peak).max(0.1)).cos()
        } else {
            fs * (-(hour - sunset) / self.night_tau_h).exp()
        };
        let t = t_max - amp * (1.0 - f);
        let excess = self.parcel_excess_k;
        let t_res = t_max - self.residual_cooling_state_k;
        let t_min = t_max - amp;
        let window = self.break_window_k;
        let mut cap = f64::INFINITY;
        let mut brk = 1.0;
        if hour < peak && t + excess < t_res {
            let t_full = t_res - window;
            cap = self.inversion_depth_m
                * ((t + excess - t_min) / (t_full - t_min).max(0.5)).clamp(0.0, 1.0);
            brk = ((t + excess - t_full) / window.max(0.1)).clamp(0.0, 1.0);
        }
        let el = solar_position(ctx.lat, ctx.lon, doy, hour - self.heat_lag_h, utc).1;
        let el_noon = solar_position(ctx.lat, ctx.lon, doy, noon, utc).1;
        let mut heat = el.to_radians().sin().max(0.0) / el_noon.to_radians().sin().max(0.05);
        heat = heat.clamp(0.0, 1.0);
        if solar_position(ctx.lat, ctx.lon, doy, hour, utc).1 <= 0.0 {
            heat = 0.0;
        }
        let soft = ((1.0 - heat) / (1.0 - self.sharp_min).max(0.01)).clamp(0.0, 1.0);
        let calm_h = self.evening_calm_h;
        let calm = ((hour - (sunset - calm_h)) / calm_h.max(0.01)).clamp(0.0, 1.0);
        DiurnalState {
            temperature_c: t,
            cap_agl_m: cap,
            brk,
            heat,
            soft,
            mech_k: lerp(1.0, self.evening_mech_k, calm),
            sunrise_h: sunrise,
            sunset_h: sunset,
            peak_h: peak,
        }
    }

    /// Суточный ход: амплитуда места из климата.
    pub fn diurnal_state(
        &self,
        t_max: f64,
        hour: f64,
        ctx: &Ctx,
        climate: &dyn Climate,
    ) -> DiurnalState {
        self.diurnal_state_amp(t_max, hour, ctx, self.diurnal_range_k(ctx, climate))
    }
}

/// Суточный ход (`WeatherModel.diurnal_state`): температура, верх утреннего слоя над долиной
/// (`INFINITY` — инверсия пробита), доля пробоя, поток тепла к полуденному, мягкость, механика.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiurnalState {
    pub temperature_c: f64,
    pub cap_agl_m: f64,
    pub brk: f64,
    pub heat: f64,
    pub soft: f64,
    pub mech_k: f64,
    pub sunrise_h: f64,
    pub sunset_h: f64,
    pub peak_h: f64,
}

// ---------------------------------------------------------------- день и профиль θ̄

/// Погода дня в час для поля (`AirPlace.day`): температура, профиль θ̄ и верх слоя перемешивания.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Day {
    pub hour: f64,
    pub t: f64,
    pub cap: f64,
    /// Высота долины, км.
    pub h_v: f64,
    pub t_u: f64,
    /// Высота верхнего уровня, км.
    pub z_u: f64,
    pub gam: f64,
    pub t_min: f64,
    pub t_res: f64,
    pub t_full: f64,
    /// Толщина утренней инверсии, км.
    pub dep: f64,
    pub sky_heat: f64,
    pub cover: f64,
    pub heat: f64,
    pub theta_s: f64,
    /// Верх слоя перемешивания, м над морем.
    pub z_i: f64,
}

impl Day {
    fn theta_upper(&self, zk: f64) -> f64 {
        let fa = self.t_u + self.gam * (self.z_u - zk) + GAMMA_D * zk;
        if self.cap.is_infinite() {
            return fa;
        }
        let th_min = self.t_min + GAMMA_D * self.h_v;
        let th_res = self.t_res + GAMMA_D * self.h_v;
        let slope = (self.t_full - self.t_min) / self.dep;
        let night = (th_min + slope * (zk - self.h_v).max(0.0)).min(th_res);
        night.max(fa)
    }

    /// θ̄(z) над морем (м), К.
    pub fn theta(&self, z_m: f64) -> f64 {
        self.theta_upper(z_m / 1000.0).max(self.theta_s)
    }

    /// dθ̄/dz, К/м (разностью ±5 м, как эталон).
    pub fn gamma(&self, z_m: f64) -> f64 {
        (self.theta(z_m + 5.0) - self.theta(z_m - 5.0)) / 10.0
    }
}

/// Погода дня (`AirPlace.day`): `z_i` — где профиль над слоем впервые теплее частицы.
pub fn day(
    cfg: &WeatherModelCfg,
    climate: &dyn Climate,
    ctx: &Ctx,
    hour: f64,
    t_max: f64,
    sky: &str,
) -> Day {
    let st = cfg.diurnal_state(t_max, hour, ctx, climate);
    let amp = cfg.diurnal_range_k(ctx, climate);
    let t_res = t_max - cfg.residual_cooling_day_k;
    let (cover, sky_heat) = cfg.sky_params(sky);
    let mut d = Day {
        hour,
        t: st.temperature_c,
        cap: st.cap_agl_m,
        h_v: ctx.valley_msl_m / 1000.0,
        t_u: monthly(&cfg.upper_temp_c, ctx.month.clamp(1, 12), ctx.day),
        z_u: cfg.upper_z_msl_m / 1000.0,
        gam: cfg.upper_lapse_k_per_km,
        t_min: t_max - amp,
        t_res,
        t_full: t_res - cfg.break_window_k,
        dep: cfg.inversion_depth_m / 1000.0,
        sky_heat,
        cover,
        heat: st.heat * sky_heat,
        theta_s: 0.0,
        z_i: 0.0,
    };
    d.theta_s = d.t + cfg.parcel_excess_k + GAMMA_D * d.h_v;
    let nstep = 23000;
    let step = (12.0 - d.h_v) / nstep as f64;
    let mut zi = 12.0;
    for k in 0..=nstep {
        let z = if k < nstep {
            d.h_v + k as f64 * step
        } else {
            12.0
        };
        if d.theta_upper(z) > d.theta_s {
            zi = z;
            break;
        }
    }
    d.z_i = zi * 1000.0;
    d
}

// ---------------------------------------------------------------- вода

fn lapse(z_m: f64, ctx: &Ctx, sh: &SurfaceHeatCfg) -> f64 {
    sh.water.lapse_k_per_km * (z_m - ctx.valley_msl_m) / 1000.0
}

/// Среднесуточная температура воздуха T̄ на дату «сейчас − `lag_days`» на высоте долины, °C
/// (24 часовых отсчёта `diurnal_state` при `typical_max_c` сдвинутой даты). Температура воды
/// на высоте `z` — `max(0, T̄ − lapse(z))` ([`water_temp_c`]).
pub fn water_mean_air_c(cfg: &WeatherConfigs, ctx: &Ctx, climate: &dyn Climate) -> f64 {
    let mut doy = day_of_year(ctx.month, ctx.day) - cfg.sh.water.lag_days.round() as i64;
    if doy < 1 {
        doy += 365;
    }
    let (mut month, mut d) = (12, 31);
    let mut left = doy;
    for m in 1..=12 {
        let dim = days_in_month(m);
        if left <= dim {
            month = m;
            d = left;
            break;
        }
        left -= dim;
    }
    let c2 = Ctx {
        month,
        day: d,
        ..*ctx
    };
    let t_max = cfg.wm.typical_max_c(&c2, climate);
    let amp = cfg.wm.diurnal_range_k(&c2, climate);
    let sum: f64 = (0..24)
        .map(|i| {
            cfg.wm
                .diurnal_state_amp(t_max, i as f64 + 0.5, &c2, amp)
                .temperature_c
        })
        .sum();
    sum / 24.0
}

/// Температура воды на высоте `z_m` по среднему воздуху, °C.
pub fn water_temp_c(t_mean_air_c: f64, z_m: f64, ctx: &Ctx, sh: &SurfaceHeatCfg) -> f64 {
    (t_mean_air_c - lapse(z_m, ctx, sh)).max(0.0)
}

// ---------------------------------------------------------------- область, рельеф, поверхность

/// Область решателя: квадрат клеток `dx` с юго-западным углом (`x0`, `y0`) (y — на север).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Domain {
    pub x0: f64,
    pub y0: f64,
    pub nx: usize,
    pub ny: usize,
    pub dx: f64,
}

impl Domain {
    /// Область места по умолчанию: квадрат `DOMAIN_L` вокруг (0, 0).
    pub fn standard(dx: f64) -> Domain {
        let n = (DOMAIN_L / dx).round() as usize;
        Domain {
            x0: -DOMAIN_L / 2.0,
            y0: -DOMAIN_L / 2.0,
            nx: n,
            ny: n,
            dx,
        }
    }

    fn cells(&self) -> usize {
        self.nx * self.ny
    }

    /// Узлов решётки 25 м на клетку по стороне.
    fn f(&self) -> usize {
        (self.dx / NODE_STEP).round() as usize
    }

    fn check(&self, place: &Place) -> Result<(), Error> {
        let bad = |m: String| Err(Error::bad_input(format!("domain: {m}")));
        for v in [self.x0, self.y0, self.dx] {
            if (v / NODE_STEP - (v / NODE_STEP).round()).abs() > 1e-9 {
                return bad("dx, x0, y0 must be multiples of 25 m".into());
            }
        }
        if self.nx == 0 || self.ny == 0 || self.f() == 0 {
            return bad("empty".into());
        }
        let g = &place.header().grid;
        if (g.spacing - NODE_STEP).abs() > 1e-9
            || (g.origin_x / NODE_STEP - (g.origin_x / NODE_STEP).round()).abs() > 1e-9
            || (g.origin_z / NODE_STEP - (g.origin_z / NODE_STEP).round()).abs() > 1e-9
        {
            return bad("place grid must be 25 m with origin multiple of 25 m".into());
        }
        if g.width < 2 || g.height < 2 {
            return bad("place grid too small".into());
        }
        Ok(())
    }
}

/// Дробный индекс узлов решётки 25 м вдоль оси: `(i0, t)`; узел вне слоя — `None`.
fn axis_nodes(
    a0: f64,
    cnt: usize,
    sign: f64,
    o: f64,
    s: f64,
    n_layer: usize,
) -> Option<(Vec<u32>, Vec<f64>)> {
    let hi = (n_layer - 1) as f64;
    let mut i0 = Vec::with_capacity(cnt);
    let mut t = Vec::with_capacity(cnt);
    for m in 0..cnt {
        let v = (sign * (a0 + NODE_STEP * m as f64) - o) / s;
        if v < -1e-9 || v > hi + 1e-9 {
            return None;
        }
        let v = v.clamp(0.0, hi);
        let i = (v as usize).min(n_layer - 2);
        i0.push(i as u32);
        t.push(v - i as f64);
    }
    Some((i0, t))
}

/// Высота клетки — среднее билинейных высот в узлах решётки 25 м (`AirPlace.block_mean`),
/// `ny·nx`, строка `j` на север.
pub fn block_mean(place: &Place, dom: &Domain) -> Result<Vec<f64>, Error> {
    dom.check(place)?;
    let g = &place.header().grid;
    let f = dom.f();
    let (w, hgt) = (g.width as usize, g.height as usize);
    let ax = axis_nodes(dom.x0, f * dom.nx, 1.0, g.origin_x, g.spacing, w);
    let ay = axis_nodes(dom.y0, f * dom.ny, -1.0, g.origin_z, g.spacing, hgt);
    let (Some((xi, xt)), Some((yi, yt))) = (ax, ay) else {
        return Err(Error::bad_input("domain: outside the place raster"));
    };
    let hs = place.heights();
    let inv_n = 1.0 / (f * f) as f64;
    let mut out = vec![0.0; dom.cells()];
    out.par_chunks_mut(dom.nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let mut acc = 0.0;
            for my in 0..f {
                let (r, tz) = (yi[j * f + my] as usize, yt[j * f + my]);
                for mx in 0..f {
                    let (c, tx) = (xi[i * f + mx] as usize, xt[i * f + mx]);
                    let k = r * w + c;
                    let top = (1.0 - tx) * hs[k] as f64 + tx * hs[k + 1] as f64;
                    let bot = (1.0 - tx) * hs[k + w] as f64 + tx * hs[k + w + 1] as f64;
                    acc += (1.0 - tz) * top + tz * bot;
                }
            }
            *o = acc * inv_n;
        }
    });
    Ok(out)
}

/// Доли классов (`ny·nx·CLASS_COUNT`, подряд по клетке) и влажность клеток (`ny·nx`).
#[derive(Clone, Debug, PartialEq)]
pub struct Cells {
    pub fr: Vec<f32>,
    pub m: Vec<f32>,
}

/// Доли классов и влажность клеток по узлам решётки 25 м (`AirPlace.cell_surface`) из снимка
/// поверхности места (`cls`, `moist`); узлы вне снимка — NONE и `m_norm`.
pub fn cell_surface(place: &Place, dom: &Domain, sh: &SurfaceHeatCfg) -> Result<Cells, Error> {
    dom.check(place)?;
    let g = &place.header().grid;
    let (sw, shh) = (g.width as i64, g.height as i64);
    let f = dom.f() as i64;
    let i0 = ((dom.x0 - g.origin_x) / NODE_STEP).round() as i64;
    let r0 = ((-dom.y0 - g.origin_z) / NODE_STEP).round() as i64;
    let inv = 1.0 / (f * f) as f64;
    let m_norm = sh.m_norm_cells;
    let (cls, mo) = (place.cls(), place.moist());
    let nx = dom.nx;
    let mut fr = vec![0.0f32; dom.cells() * CLASS_COUNT];
    let mut m = vec![0.0f32; dom.cells()];
    fr.par_chunks_mut(nx * CLASS_COUNT)
        .zip(m.par_chunks_mut(nx))
        .enumerate()
        .for_each(|(j, (frow, mrow))| {
            for i in 0..nx {
                let mut cnt = [0u32; CLASS_COUNT];
                let mut msum = 0.0f64;
                let c0 = i0 + i as i64 * f;
                for mm in 0..f {
                    let row = r0 - (j as i64 * f + mm);
                    for qq in 0..f {
                        let col = c0 + qq;
                        if row < 0 || row >= shh || col < 0 || col >= sw {
                            cnt[NONE] += 1;
                            msum += m_norm;
                        } else {
                            let k = (row * sw + col) as usize;
                            cnt[(cls[k] as usize).min(CLASS_COUNT - 1)] += 1;
                            msum += mo[k] as f64;
                        }
                    }
                }
                for c in 0..CLASS_COUNT {
                    frow[i * CLASS_COUNT + c] = (cnt[c] as f64 * inv) as f32;
                }
                mrow[i] = (msum * inv) as f32;
            }
        });
    Ok(Cells { fr, m })
}

/// Шероховатость клеток, м: лог-среднее по площади z0 классов клетки (`AirPlace.cell_z0`).
pub fn cell_z0(cells: &Cells, sh: &SurfaceHeatCfg) -> Vec<f64> {
    let lz: Vec<f64> = sh.classes.iter().map(|c| c.z0_m.ln()).collect();
    cells
        .fr
        .par_chunks(CLASS_COUNT)
        .map(|fr| {
            let (mut s, mut w) = (0.0, 0.0);
            for k in 0..CLASS_COUNT {
                let f = fr[k] as f64;
                s += f * lz[k];
                w += f;
            }
            if w > 0.0 {
                (s / w).exp()
            } else {
                lz[NONE].exp()
            }
        })
        .collect()
}

/// exp(среднее ln a) — эффективный z0 смеси; все равны — само значение (`AirCase.log_mean`).
pub fn log_mean(a: &[f64]) -> f64 {
    let s: f64 = a.iter().map(|v| v.ln()).sum();
    if a.iter().all(|&v| v == a[0]) {
        a[0]
    } else {
        (s / a.len() as f64).exp()
    }
}

// ---------------------------------------------------------------- поток тепла

/// Поток тепла клеток, Вт/м² на горизонтальную площадь (`AirPlace.surface_flux`): `SurfaceHeat.
/// mix_flux` по долям классов, влажности, нормали сетки (−∂h/∂x, 1, ∂h/∂y; центральные разности,
/// на краях односторонние), солнцу классов, небу дня; вода — по температурам даты места и
/// высоты клетки.
#[allow(clippy::too_many_arguments)]
pub fn surface_flux(
    hc: &[f64],
    dom: &Domain,
    day: &Day,
    ctx: &Ctx,
    cfg: &WeatherConfigs,
    climate: &dyn Climate,
    cells: &Cells,
    u10: f64,
) -> Vec<f64> {
    let (nx, ny, dx) = (dom.nx, dom.ny, dom.dx);
    let sh = &cfg.sh;
    let heating = cfg.wm.surface_heating(ctx);
    let hour = day.hour;
    let sun = heating
        .directions(hour)
        .unwrap_or([heating.sun_at(hour); CLASS_COUNT]);
    let sky = Sky {
        cover: day.cover,
        sky_heat: day.sky_heat,
        night: heating.built_night(hour),
    };
    let t_mean = water_mean_air_c(cfg, ctx, climate);
    let ta_v = day.t; // воздух на высоте долины (lapse = 0): температура часа
    let mut out = vec![0.0; dom.cells()];
    out.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let q = j * nx + i;
            let gx = if i == 0 {
                (hc[q + 1] - hc[q]) / dx
            } else if i == nx - 1 {
                (hc[q] - hc[q - 1]) / dx
            } else {
                (hc[q + 1] - hc[q - 1]) / (2.0 * dx)
            };
            let gy = if j == 0 {
                (hc[q + nx] - hc[q]) / dx
            } else if j == ny - 1 {
                (hc[q] - hc[q - nx]) / dx
            } else {
                (hc[q + nx] - hc[q - nx]) / (2.0 * dx)
            };
            let fr = &cells.fr[q * CLASS_COUNT..(q + 1) * CLASS_COUNT];
            let water = (fr[WATER] > 0.0).then(|| {
                let z = hc[q];
                let lap = lapse(z, ctx, sh);
                WaterIn {
                    t_water_c: water_temp_c(t_mean, z, ctx, sh),
                    t_air_c: ta_v - lap,
                    u_ms: u10,
                    z_m: z,
                }
            });
            *o = mix_flux(
                fr,
                [-gx, 1.0, gy],
                &sun,
                cells.m[q] as f64,
                &sky,
                water.as_ref(),
                sh,
            );
        }
    });
    out
}

// ---------------------------------------------------------------- итог

/// Погода и солнце для поля на час `hour`.
#[derive(Clone, Debug, PartialEq)]
pub struct FieldWeather {
    pub ctx: Ctx,
    pub inputs: WeatherInputs,
    pub hour: f64,
    pub domain: Domain,
    /// Дневной максимум, использованный в расчёте, °C.
    pub t_max: f64,
    pub diurnal: DiurnalState,
    pub day: Day,
    /// Азимут и высота солнца в `hour`, градусы.
    pub sun: (f64, f64),
    /// Среднесуточный воздух даты воды, °C (вода на высоте долины — `max(0, ·)`).
    pub water_mean_air_c: f64,
    pub hc: Vec<f64>,
    pub z0: Vec<f64>,
    /// Эффективный z0 области (лог-среднее).
    pub z0_eff: f64,
    pub heat: Vec<f64>,
    pub wind: CaseProfile,
}

/// Погода и солнце для поля (`AirPlace.domain_case` без сетки по высоте и без `gam`): `heat` —
/// поток тепла, `wind` — α, класс, `z_sat`, `max_profile`. `hour` — час места (см. [`hour_at`]).
pub fn field_weather(
    cond: &Conditions,
    place: &Place,
    cfg: &WeatherConfigs,
    configs: &Configs,
    climate: &dyn Climate,
    hour: f64,
    dom: &Domain,
) -> Result<FieldWeather, Error> {
    let inputs = WeatherInputs::from_conditions(cond, configs)?;
    let hc = block_mean(place, dom)?;
    let ctx = context(place);
    let t_max = inputs
        .t_max
        .unwrap_or_else(|| cfg.wm.typical_max_c(&ctx, climate));
    let d = day(&cfg.wm, climate, &ctx, hour, t_max, &inputs.sky);
    let cells = cell_surface(place, dom, &cfg.sh)?;
    let z0 = cell_z0(&cells, &cfg.sh);
    let z0_eff = log_mean(&z0);
    let doy = day_of_year(ctx.month, ctx.day);
    let sun = solar_position(ctx.lat, ctx.lon, doy, hour, ctx.utc_offset_h);
    let wind = apply_to_case(&cfg.wind, inputs.u10, z0_eff, F_COR, sun.1, d.cover);
    let heat = surface_flux(&hc, dom, &d, &ctx, cfg, climate, &cells, inputs.u10);
    Ok(FieldWeather {
        ctx,
        hour,
        domain: *dom,
        t_max,
        diurnal: cfg.wm.diurnal_state(t_max, hour, &ctx, climate),
        day: d,
        sun,
        water_mean_air_c: water_mean_air_c(cfg, &ctx, climate),
        hc,
        z0,
        z0_eff,
        heat,
        wind,
        inputs,
    })
}
