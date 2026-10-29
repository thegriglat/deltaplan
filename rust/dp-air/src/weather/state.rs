//! Состояние погоды (RW-12c): словарь погоды, коэффициенты суммы, ход дня, мягкая смена и номера версий
//! (`Atmosphere._configure_legacy` / `_update_weather` / `_blend` / `_apply_day`, без поля и термиков).
//!
//! Версии (`weather_version() -> (мягкая, перестройка)`, W4): `version` растёт при **каждой** смене
//! погоды (GD `weather_updated` и `weather_changed`), `rebuild_version` — только при полной перестройке
//! (GD `weather_changed`: [`WeatherState::rebuild`]); смены нет — версии стоят.
use std::sync::Arc;

use serde_json::Value;

use super::coeffs::{Coefficients, wind_conditions};
use super::day::{AtmoDay, WeatherMap, get_or, normalized_f32};
use super::derive::sun_block_cover;
use crate::field::sun::lerp;
use crate::field::weather_core::WeatherModelCfg;

/// Ключи, которые смена погоды (ход дня, мягкая) оставляет прежними: ветер, сетка источников и
/// статичные термики задаёт игра, а не погода часа.
const KEEP_KEYS: [&str; 4] = [
    "wind_speed_kmh",
    "wind_from_deg",
    "thermal_spacing_m",
    "static_thermals",
];

/// К чему мягко ведём коэффициенты.
#[derive(Clone, Copy, Debug)]
struct Target {
    bg_sink: f64,
    conv_amp: f64,
    cloudbase_agl: f64,
    insolation: f64,
    edge: f64,
    mech: f64,
}

/// Погода места: словарь, коэффициенты, версии.
pub struct WeatherState {
    /// Выведенная погода (ключи пресета и `_derived`) — то, что отдаёт `weather()`.
    pub map: WeatherMap,
    /// Мягкая смена (любая смена погоды): растёт на 1 при каждой.
    pub version: u64,
    /// Полная перестройка (новое место, `rebuild`).
    pub rebuild_version: u64,
    pub coeffs: Coefficients,
    atm: Value,
    day: Option<AtmoDay>,
    day_w: Option<Arc<WeatherMap>>,
    target: Option<Target>,
    blend_tau: f64,
    state_interval: f64,
    state_slot: i64,
    time_s: f64,
    /// Направление на солнце, заданное снаружи (`set_sun_direction`); `None` — из дня или конфига.
    sun_set: Option<[f32; 3]>,
    /// Солнце по умолчанию (`clouds.sun_elevation_deg/sun_azimuth_deg`; не нормализовано, как в GD).
    sun_default: [f32; 3],
}

impl WeatherState {
    /// Полная настройка (`_configure_legacy`): это первая перестройка, `version` и `rebuild_version` = 1.
    pub fn new(atm: &Value, weather: WeatherMap) -> Self {
        let g = |k: &str, def: f64| super::tables::num(atm, &["clouds", k], def);
        let (el, az) = (
            g("sun_elevation_deg", 0.0).to_radians(),
            g("sun_azimuth_deg", 0.0).to_radians(),
        );
        let sun_default = [
            (az.sin() * el.cos()) as f32,
            el.sin() as f32,
            (-az.cos() * el.cos()) as f32,
        ];
        let mut s = WeatherState {
            coeffs: Coefficients::new(atm, &weather),
            map: weather,
            version: 0,
            rebuild_version: 0,
            atm: atm.clone(),
            day: None,
            day_w: None,
            target: None,
            blend_tau: 0.0,
            state_interval: super::tables::num(atm, &["thermal", "state_update_interval_s"], 0.1),
            state_slot: -(1 << 62),
            time_s: 0.0,
            sun_set: None,
            sun_default,
        };
        s.rebuild_counters();
        s
    }

    fn rebuild_counters(&mut self) {
        self.version += 1;
        self.rebuild_version += 1;
    }

    /// Полная перестройка с новой погодой (`set_weather` без мягкой смены): коэффициенты заново,
    /// мягкая цель сброшена, ход дня (если задан) применяется на текущий момент.
    pub fn rebuild(&mut self, weather: WeatherMap) {
        self.coeffs = Coefficients::new(&self.atm, &weather);
        self.map = weather;
        self.target = None;
        self.day_w = None;
        let before = self.version;
        if self.day_active() {
            self.apply_day(self.time_s);
        }
        self.version = before;
        self.rebuild_counters();
    }

    fn day_active(&self) -> bool {
        self.day.as_ref().is_some_and(AtmoDay::has_weather)
    }

    /// Задать ход дня (`set_day`): погода и плавные величины — по нему на текущее время.
    pub fn set_day(&mut self, day: AtmoDay) {
        let active = day.has_weather();
        self.day = Some(day);
        self.day_w = None;
        if active {
            self.apply_day(self.time_s);
        }
    }

    /// Убрать ход дня (мягкая смена к пресету без дня).
    pub fn clear_day(&mut self) {
        self.day = None;
        self.day_w = None;
    }

    pub fn day(&self) -> Option<&AtmoDay> {
        self.day.as_ref()
    }

    pub fn day_mut(&mut self) -> Option<&mut AtmoDay> {
        self.day.as_mut()
    }

    /// Время атмосферы, на которое состояние продвинуто.
    pub fn time(&self) -> f64 {
        self.time_s
    }

    /// Продвинуть время до `t` (`Atmosphere.step`): без дня — шаг мягкой смены на `1 − exp(−dt/τ)`
    /// (`τ = blend_s/3`; шаги складываются точно), с днём — `apply_day` на начало интервала состояния,
    /// когда сменился слот. Время назад — только слот.
    pub fn advance_to(&mut self, t: f64) {
        let dt = t - self.time_s;
        self.time_s = t;
        if !self.day_active() && self.target.is_some() {
            let k = if self.blend_tau > 0.0 {
                1.0 - (-dt / self.blend_tau).exp()
            } else {
                1.0
            };
            self.blend(k);
        }
        if self.day_active() {
            let slot = (t / self.state_interval).floor() as i64;
            if slot != self.state_slot {
                self.state_slot = slot;
                self.apply_day(slot as f64 * self.state_interval);
            }
        }
    }

    /// Мягкая смена к новой погоде (`_update_weather`): живое остаётся, кромка, фон, болтанка и прогрев
    /// идут к новым значениям за `~blend_s`; ветер, сетка источников и статичные термики не меняются.
    pub fn update_weather(&mut self, w: &WeatherMap, blend_s: f64) {
        let mut nw = w.clone();
        for k in KEEP_KEYS {
            if let Some(v) = self.map.get(k) {
                nw.insert(k.into(), v.clone());
            }
        }
        self.map = nw;
        let c = &self.coeffs;
        self.target = Some(Target {
            bg_sink: get_or(&self.map, "background_sink_ms", 0.0),
            conv_amp: get_or(&self.map, "convective_turbulence_ms", 0.0),
            cloudbase_agl: get_or(&self.map, "cloudbase_agl_m", 0.0),
            insolation: 1.0 - sun_block_cover(&self.map) * c.sun_block,
            edge: c.edge_factor_base * get_or(&self.map, "thermal_edge_k", 1.0),
            mech: c.mech_k_base * get_or(&self.map, "mech_turbulence_k", 1.0),
        });
        self.blend_tau = blend_s.max(0.0) / 3.0;
        if self.blend_tau <= 0.0 {
            self.blend(1.0);
        }
        self.version += 1;
    }

    /// Идёт ли мягкая смена (цель не достигнута).
    pub fn blending(&self) -> bool {
        self.target.is_some()
    }

    /// Сдвинуть коэффициенты к цели (доля `k` 0..1), `_blend`.
    fn blend(&mut self, k: f64) {
        let Some(t) = self.target else { return };
        let c = &mut self.coeffs;
        c.bg_sink = lerp(c.bg_sink, t.bg_sink, k);
        c.conv_amp = lerp(c.conv_amp, t.conv_amp, k);
        c.insolation = lerp(c.insolation, t.insolation, k);
        c.mech_k = lerp(c.mech_k, t.mech, k);
        c.edge_factor = lerp(c.edge_factor, t.edge, k);
        c.cloudbase_agl = lerp(c.cloudbase_agl, t.cloudbase_agl, k);
        if (k >= 1.0 || (c.cloudbase_agl - t.cloudbase_agl).abs() < 0.5)
            && (c.bg_sink - t.bg_sink).abs() < 1.0e-3
        {
            self.target = None;
        }
    }

    /// Ход дня на момент `t` (`_apply_day`): погода шага — в `map` (с сохранёнными ключами), плавные
    /// величины — линейно между шагами.
    fn apply_day(&mut self, t: f64) {
        let Some(day) = self.day.as_mut() else { return };
        let (w0, w1, f) = day.bracket(t);
        let changed = !self.day_w.as_ref().is_some_and(|d| Arc::ptr_eq(d, &w0));
        if changed {
            self.day_w = Some(w0.clone());
            let mut nw = (*w0).clone();
            for k in KEEP_KEYS {
                if let Some(v) = self.map.get(k) {
                    nw.insert(k.into(), v.clone());
                }
            }
            self.map = nw;
            self.version += 1;
        }
        let lk = |key: &str, def: f64| lerp(get_or(&w0, key, def), get_or(&w1, key, def), f);
        let c = &mut self.coeffs;
        c.bg_sink = lk("background_sink_ms", c.bg_sink);
        c.conv_amp = lk("convective_turbulence_ms", c.conv_amp);
        c.mech_k = c.mech_k_base * lk("mech_turbulence_k", 1.0);
        c.edge_factor = c.edge_factor_base * lk("thermal_edge_k", 1.0);
        c.insolation = 1.0 - lerp(sun_block_cover(&w0), sun_block_cover(&w1), f) * c.sun_block;
        c.cloudbase_agl = lk("cloudbase_agl_m", c.cloudbase_agl);
    }

    /// Выведенная погода json-строкой (`weather()` → `weather_json()`).
    pub fn weather_json(&self) -> String {
        serde_json::to_string(&self.map).unwrap_or_else(|_| "{}".into())
    }

    /// `(мягкая, перестройка)`.
    pub fn versions(&self) -> (u64, u64) {
        (self.version, self.rebuild_version)
    }

    /// Прогрев 0..1 на текущий момент (`get_insolation` с зажимом `sun_state`).
    pub fn insolation(&self) -> f64 {
        self.coeffs.insolation.clamp(0.0, 1.0)
    }

    /// Задать направление на солнце снаружи (`set_sun_direction`); `None` — снять. Нулевой или
    /// нечисловой вектор игнорируется, остальное нормализуется (как GD).
    pub fn set_sun_direction(&mut self, to_sun: Option<[f32; 3]>) {
        match to_sun {
            None => self.sun_set = None,
            Some(v) => {
                let l2: f32 = v.iter().map(|x| x * x).sum();
                if v.iter().all(|x| x.is_finite()) && l2 >= 1.0e-12 {
                    self.sun_set = Some(normalized_f32(v));
                }
            }
        }
    }

    /// `(на солнце x, y, z; прогрев 0..1)` на момент `t` (W2 `sun_state`). Направление: заданное снаружи,
    /// иначе из хода дня (если у него есть солнце), иначе `clouds.sun_*` из конфига.
    pub fn sun_state(&self, t: f64) -> [f32; 4] {
        let s = self.sun_set.unwrap_or_else(|| {
            let d = self.day.as_ref().map_or([0.0; 3], |d| d.sun_at(t));
            if d == [0.0; 3] { self.sun_default } else { d }
        });
        [s[0], s[1], s[2], self.insolation() as f32]
    }

    /// Условия профиля ветра (RW-9): (высота солнца часа, °; облачность 0..1).
    pub fn wind_conditions(&self, wm: &WeatherModelCfg) -> (f64, f64) {
        wind_conditions(&self.atm, &self.map, wm)
    }
}
