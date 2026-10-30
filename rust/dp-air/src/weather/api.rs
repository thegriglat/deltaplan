//! `Weather` (W12 v1): погода без загруженного места — климат, ход дня, температуры, небо.
//!
//! Неизменяемая структура (`Send + Sync`, делится через `Arc<Weather>`): конфиги разобраны один
//! раз, сетки климата — байты в памяти. Все методы — чистые функции. Единицы: °C, м над уровнем
//! моря, км/ч в прогнозе, час места десятичный. Во входах `NaN` в `lat`/`lon`/`valley_msl_m`/
//! `utc_offset_h` — «не задано»: без `lat`/`lon` берутся таблицы конфига (`typical_max_c`,
//! `diurnal.range_k`), солнечные расчёты используют широту 52° и долготу 0°, без `valley_msl_m`
//! поправки на высоту нет, без `utc_offset_h` — солнечное время.
use serde_json::Value;

use super::climate::{ClimatePlace, ClimateSrc, PlaceCtx, adjust_place};
use super::day::{WeatherMap, WorldTime, normalized_f32};
use super::derive::{derive as derive_map, haze_k_rh as haze_k_rh_cfg};
use super::grids::{ClimateCell, ClimateGrids};
use super::tables::{num, nums};
use crate::conditions::Forecast;
use crate::field::sun::{day_of_year, solar_position};
use crate::field::weather_core::{
    Climate, ClimateCell as FieldCell, Ctx, DiurnalState, WeatherConfigs, monthly, water_mean_air_c,
};
use crate::{Configs, Error};

/// Погода: конфиги модели и сетки климата. Собирается из секций данных (`weather_model`,
/// `surface_heat`, необязательные `atmosphere`, `world`), не из путей файлов.
#[derive(Clone, Debug)]
pub struct Weather {
    cfg: WeatherConfigs,
    grids: ClimateGrids,
    world: WorldTime,
    quantum_h: f64,
}

/// Контекст загруженного места (`DpAir.place_context`): дата, положение, пояс, высоты, м над морем.
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub struct PlaceContext {
    pub valley_msl_m: f64,
    pub mean_msl_m: f64,
    pub month: i64,
    pub day: i64,
    pub lat: f64,
    pub lon: f64,
    pub utc_offset_h: f64,
}

impl PlaceContext {
    /// Из места: дата и положение из заголовка, долина (нижние 10 %) и средняя высота по растру
    /// в круге 10 км (`ground_context`).
    pub fn of(place: &crate::Place) -> PlaceContext {
        let c = crate::field::weather_core::context(place);
        PlaceContext {
            valley_msl_m: c.valley_msl_m,
            mean_msl_m: c.mean_msl_m,
            month: c.month,
            day: c.day,
            lat: c.lat,
            lon: c.lon,
            utc_offset_h: c.utc_offset_h,
        }
    }

    /// Контекст для функций погоды.
    pub fn ctx(&self) -> PlaceCtx {
        PlaceCtx {
            month: self.month,
            day: self.day,
            lat: self.lat,
            lon: self.lon,
            utc_offset_h: self.utc_offset_h,
            valley_msl_m: self.valley_msl_m,
            mean_msl_m: self.mean_msl_m,
            start_msl_m: f64::NAN,
        }
    }
}

/// Широта/долгота по умолчанию для солнечных расчётов без места (как GD).
const DEFAULT_LAT: f64 = 52.0;
const DEFAULT_LON: f64 = 0.0;

impl Weather {
    /// Из секций конфигов и сеток климата. Ошибка — нет `weather_model`/`surface_heat` или
    /// они не json.
    pub fn new(cfgs: &Configs, grids: ClimateGrids) -> Result<Weather, Error> {
        let cfg = WeatherConfigs::from_configs(cfgs)?;
        let world = cfgs
            .value("world")
            .map_or_else(WorldTime::default, |w| WorldTime::from_world(&w));
        let quantum_h = num(&cfg.wm.raw, &["diurnal", "update_s"], 60.0) / 3600.0;
        Ok(Weather {
            cfg,
            grids,
            world,
            quantum_h,
        })
    }

    /// Разобранные конфиги погоды (для потребителей внутри крейта).
    pub fn configs(&self) -> &WeatherConfigs {
        &self.cfg
    }

    /// Шаг пересчёта погоды, часы (`diurnal.update_s / 3600`).
    pub fn quantum_h(&self) -> f64 {
        self.quantum_h
    }

    /// Часы мира (`world.time.*`): границы времени и минимальная высота света.
    /// Час суток по времени полёта `t` с зажимом `world.time` секции `world` (W12 v3).
    pub fn hour_at(&self, start_hour: f64, speed: f64, t: f64) -> f64 {
        hour_at(start_hour, speed, t, &self.world)
    }

    pub fn world_time(&self) -> WorldTime {
        self.world
    }

    /// Состояния сеток климата.
    pub fn climate_src(&self) -> ClimateSrc {
        self.grids.src()
    }

    /// Климат ячейки на дату без поправки на высоту (`ClimateGrid.at`).
    pub fn climate_at(&self, lat: f64, lon: f64, month: i64, day: i64) -> ClimateCell {
        self.grids.at(
            lat,
            lon,
            month,
            day,
            &self.cfg.wm.raw,
            self.cfg.wm.altitude_gain_per_km,
        )
    }

    /// Климат места на дату с поправками на высоту долины и ростом ветра (`ClimateGrid.place`).
    /// Нет `lat`/`lon` — 52°/0°.
    pub fn climate_place(&self, ctx: &PlaceCtx) -> ClimatePlace {
        let lat = if ctx.lat.is_nan() {
            DEFAULT_LAT
        } else {
            ctx.lat
        };
        let lon = if ctx.lon.is_nan() {
            DEFAULT_LON
        } else {
            ctx.lon
        };
        let month = ctx.month.clamp(1, 12);
        let cell = self.climate_at(lat, lon, month, ctx.day);
        let c = PlaceCtx {
            month,
            lat,
            lon,
            ..*ctx
        };
        adjust_place(cell, &c, &self.cfg.wm)
    }

    /// Обычный дневной максимум на дату, °C, зажат в `limits.temperature_c`. Есть `lat` и `lon` —
    /// климат ячейки с поправкой на `valley_msl_m` (NaN — без поправки); иначе таблица конфига.
    pub fn typical_max_c(
        &self,
        month: i64,
        day: i64,
        lat: f64,
        lon: f64,
        valley_msl_m: f64,
    ) -> f64 {
        let ctx = Ctx {
            month,
            day,
            lat,
            lon,
            utc_offset_h: f64::NAN,
            valley_msl_m,
            mean_msl_m: 0.0,
        };
        self.cfg.wm.typical_max_c(&ctx, self)
    }

    /// Суточная амплитуда (Tmax − Tmin) места на дату `ctx`, К.
    pub fn diurnal_range_k(&self, ctx: &PlaceCtx) -> f64 {
        self.cfg.wm.diurnal_range_k(&field_ctx(ctx), self)
    }

    /// Суточный ход при дневном максимуме `t_max` в час `hour` (`WeatherModel.diurnal_state`).
    pub fn diurnal_state(&self, t_max: f64, hour: f64, ctx: &PlaceCtx) -> DiurnalState {
        let amp = self.diurnal_range_k(ctx);
        self.cfg
            .wm
            .diurnal_state_amp(t_max, hour, &solar_ctx(ctx), amp)
    }

    /// Восход, часы места.
    pub fn sunrise_h(&self, t_max: f64, ctx: &PlaceCtx) -> f64 {
        self.diurnal_state(t_max, 12.0, ctx).sunrise_h
    }

    /// Закат, часы места.
    pub fn sunset_h(&self, t_max: f64, ctx: &PlaceCtx) -> f64 {
        self.diurnal_state(t_max, 12.0, ctx).sunset_h
    }

    /// Поправки облачности `(cover, sky_heat)`; неизвестная облачность — как `clear`.
    pub fn sky_params(&self, sky: &str) -> (f64, f64) {
        self.cfg.wm.sky_params(sky)
    }

    /// Прогноз в месте `ctx` в час `hour` (NaN — «разгар дня») -> словарь погоды с `_derived`.
    /// Не заданные `lat`/`lon`/`valley_msl_m`/`mean_msl_m` — 52°/0°/0/0 (как `WeatherModel.derive`).
    pub fn derive(&self, forecast: &Forecast, ctx: &PlaceCtx, hour: f64) -> WeatherMap {
        let d = |v: f64, def: f64| if v.is_nan() { def } else { v };
        let c = PlaceCtx {
            lat: d(ctx.lat, DEFAULT_LAT),
            lon: d(ctx.lon, DEFAULT_LON),
            valley_msl_m: d(ctx.valley_msl_m, 0.0),
            mean_msl_m: d(ctx.mean_msl_m, 0.0),
            start_msl_m: f64::NAN,
            ..*ctx
        };
        let cp = self.climate_place(&c);
        derive_map(forecast, &c, hour, &cp, &self.cfg.wm)
    }

    /// Дымка по температуре и точке росы (`haze_k_rh`).
    pub fn haze_k_rh(&self, t_c: f64, td_c: f64) -> f64 {
        haze_k_rh_cfg(t_c, td_c, &self.cfg.wm)
    }

    /// Температура воздуха у поверхности на высоте `z` (м над морем), °C: суточный ход долины
    /// минус `lapse_k_per_km` на разность `z − долина` (нет долины — без поправки).
    pub fn air_temp_c(&self, hour: f64, t_max: f64, z_m: f64, ctx: &PlaceCtx) -> f64 {
        let st = self.diurnal_state(t_max, hour, ctx);
        st.temperature_c - self.lapse(z_m, ctx)
    }

    /// Температура воды на высоте `z` (м) на дату `month`/`day`, °C (не ниже 0): среднесуточный
    /// воздух на дату «сегодня − `lag_days`» минус `lapse_k_per_km`.
    pub fn water_temp_c(&self, month: i64, day: i64, z_m: f64, ctx: &PlaceCtx) -> f64 {
        let c = PlaceCtx { month, day, ..*ctx };
        let mean = water_mean_air_c(&self.cfg, &field_ctx(&c), self);
        (mean - self.lapse(z_m, ctx)).max(0.0)
    }

    fn lapse(&self, z_m: f64, ctx: &PlaceCtx) -> f64 {
        let z0 = if ctx.valley_msl_m.is_nan() {
            z_m
        } else {
            ctx.valley_msl_m
        };
        self.cfg.sh.water.lapse_k_per_km * (z_m - z0) / 1000.0
    }

    /// Температура на высоте `alt_msl` (м над морем) по погоде из [`derive`](Self::derive):
    /// не теплее сухоадиабаты от `_derived.temperature_c` у долины и не холоднее профиля верхнего
    /// воздуха. Нет `_derived.temperature_c` или `_derived.valley_msl_m` — `NaN`.
    pub fn temp_at_altitude(
        &self,
        weather: &WeatherMap,
        alt_msl: f64,
        month: i64,
        day: i64,
    ) -> f64 {
        let d = weather.get("_derived");
        let get = |k: &str| d.and_then(|d| d.get(k)).and_then(Value::as_f64);
        let (Some(t), Some(valley)) = (get("temperature_c"), get("valley_msl_m")) else {
            return f64::NAN;
        };
        let c = &self.cfg.wm.raw;
        let dry = num(c, &["dry_adiabat_k_per_km"], 9.8);
        let ua = c.get("upper_air");
        let gam = num(c, &["upper_air", "lapse_k_per_km"], 4.0);
        let t_u = monthly(
            &nums(ua.and_then(|u| u.get("temp_c"))),
            month.clamp(1, 12),
            day,
        );
        let z_u = num(c, &["upper_air", "z_msl_m"], 3000.0) / 1000.0;
        let h_v = valley / 1000.0;
        let z = alt_msl / 1000.0;
        (t - dry * (z - h_v)).max(t_u + gam * (z_u - z))
    }

    /// Опорное место конфига без рельефа (`reference_context`); нет ключа — `NaN`
    /// (`month`/`day` — 7/15).
    pub fn reference_context(&self) -> PlaceCtx {
        let rc = self.cfg.wm.raw.get("reference_context");
        let g = |k: &str| {
            rc.and_then(|r| r.get(k))
                .and_then(Value::as_f64)
                .unwrap_or(f64::NAN)
        };
        let int = |k: &str, def: i64| {
            let v = g(k);
            if v.is_nan() { def } else { v as i64 }
        };
        PlaceCtx {
            month: int("month", 7),
            day: int("day", 15),
            lat: g("lat"),
            lon: g("lon"),
            utc_offset_h: g("utc_offset_h"),
            valley_msl_m: g("valley_msl_m"),
            mean_msl_m: g("mean_msl_m"),
            start_msl_m: f64::NAN,
        }
    }

    /// Направление НА солнце (единичный вектор, ось y вверх) в час `hour`; высота солнца не
    /// ниже `world.time.min_light_elevation_deg`. `utc_offset_h` NaN — солнечное время.
    pub fn sun_direction(
        &self,
        lat: f64,
        lon: f64,
        month: i64,
        day: i64,
        hour: f64,
        utc_offset_h: f64,
    ) -> [f32; 3] {
        let (az, el) = solar_position(lat, lon, day_of_year(month, day), hour, utc_offset_h);
        let (az, el) = (az as f32 as f64, el as f32 as f64);
        let el = el.max(self.world.min_light_elevation_deg).to_radians();
        let az = az.to_radians();
        normalized_f32([
            (az.sin() * el.cos()) as f32,
            el.sin() as f32,
            (-az.cos() * el.cos()) as f32,
        ])
    }
}

impl Climate for Weather {
    fn cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> FieldCell {
        let c = self.climate_at(lat, lon, month, day);
        FieldCell {
            tx_c: c.tx_c,
            dtr_k: c.dtr_k,
            z_cell_m: c.z_cell_m,
            has_hh1: c.src.hh1 != "none",
            has_hh5: c.src.hh5 != "none",
        }
    }
}

/// Час места в момент `t` атмосферы (с): `start_hour + t·speed/3600`, зажат в `world.time`
/// (`min_hour…max_hour`; после `max_hour` время стоит).
pub fn hour_at(start_hour: f64, speed: f64, t: f64, world: &WorldTime) -> f64 {
    (start_hour + t * speed / 3600.0).clamp(world.min_hour, world.max_hour)
}

/// Опорная высота для воды/воздуха: контекст поля из `PlaceCtx` (NaN сохраняются).
fn field_ctx(c: &PlaceCtx) -> Ctx {
    Ctx {
        month: c.month,
        day: c.day,
        lat: c.lat,
        lon: c.lon,
        utc_offset_h: c.utc_offset_h,
        valley_msl_m: c.valley_msl_m,
        mean_msl_m: c.mean_msl_m,
    }
}

/// Контекст для солнечных формул: нет широты/долготы — 52°/0°.
fn solar_ctx(c: &PlaceCtx) -> Ctx {
    Ctx {
        lat: if c.lat.is_nan() { DEFAULT_LAT } else { c.lat },
        lon: if c.lon.is_nan() { DEFAULT_LON } else { c.lon },
        ..field_ctx(c)
    }
}

/// Долина места по пробам высоты: значение с долей `percentile` снизу среди проб (`ground_context`).
/// Пустые пробы — 0.
pub fn valley_of(samples: &[f32], percentile: f64) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut hs = samples.to_vec();
    hs.sort_by(f32::total_cmp);
    let k = ((percentile * (hs.len() - 1) as f64).floor() as i64).clamp(0, hs.len() as i64 - 1);
    hs[k as usize] as f64
}
