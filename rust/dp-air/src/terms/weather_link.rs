//! Погода в `Terms` (RW-12d): условия → выведенная погода, ход дня и мягкая смена, версии, рамка ветра.
//!
//! Связка `dp_air::weather` (RW-12b/c) с `Terms`: `set_conditions` строит погоду так же, как
//! `Atmosphere._f_resolve` / `_f_build` / `_f_apply_soft` (прогноз → `derive` по часу, `AtmoDay`; эталон
//! пресета — без дня), `advance(t)` ведёт ход дня на сетке `state_update_interval_s` и мягкую смену
//! (`WeatherState::advance_to`), при смене погоды обновляет `Terms::weather` (`WeatherView`) и условия
//! профиля ветра (`wind_conditions`: высота солнца часа, облачность). Номера версий — `WeatherState`.
//!
//! Место нужно только прогнозу (климат ячейки, дата, координаты, высоты долины и средняя): его кладёт
//! `Terms::set_place` (RW-12z вызывает после `load_place`). Нет места, `weather_model` или прогнозу не
//! хватает климата — прогноз без вывода (словарь из полей прогноза и переопределений, как до RW-12d).
//!
//! Для RW-12z: `weather_json`, `weather_version`, `sun_state`, `coefficients`, `set_place`.
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Map, Value};

use super::{Terms, WeatherView, named_json, thermal_src};
use crate::field::weather_core::{Ctx, WeatherModelCfg, context};
use crate::place::Place;
use crate::weather::{
    AtmoDay, ClimatePlace, Coefficients, PlaceCtx, Weather, WeatherMap, WeatherState, WorldTime,
    climate_place,
};
use crate::{Conditions, Source};

/// Место для погоды: контекст `derive` (дата, координаты, пояс, долина и средняя высота). Климат
/// ячейки берётся у [`Weather`] (W5 v10); `Weather` нет — запасные значения `weather_model.json`.
#[derive(Clone, Debug, PartialEq)]
pub struct PlaceLink {
    pub ctx: PlaceCtx,
}

impl PlaceLink {
    /// Из места (`AirPlace.context`). `start_msl_m` не задан (NaN), как в
    /// `Atmosphere._f_weather_ctx`: ветер прогноза на высоте старта задаёт `wind_ref` условий, а
    /// `derive` климат без высоты старта не использует.
    pub fn of(place: &Place) -> Self {
        let c = context(place);
        PlaceLink {
            ctx: PlaceCtx {
                month: c.month,
                day: c.day,
                lat: c.lat,
                lon: c.lon,
                utc_offset_h: c.utc_offset_h,
                valley_msl_m: c.valley_msl_m,
                mean_msl_m: c.mean_msl_m,
                start_msl_m: f64::NAN,
            },
        }
    }
}

/// Контекст без места: дата по умолчанию, остальное не задано (запасной климат).
const NO_PLACE: PlaceCtx = PlaceCtx {
    month: 7,
    day: 15,
    lat: f64::NAN,
    lon: f64::NAN,
    utc_offset_h: f64::NAN,
    valley_msl_m: f64::NAN,
    mean_msl_m: f64::NAN,
    start_msl_m: f64::NAN,
};

/// Погода `Terms`: состояние, конфиги, место, время.
#[derive(Clone, Default)]
pub(super) struct WeatherLink {
    state: Option<WeatherState>,
    place: Option<PlaceLink>,
    /// Погода и климат (`set_weather`); нет — климат по `climate.fallback`.
    weather: Option<Arc<Weather>>,
    /// `weather_model.json` (с ростом ветра из `atmosphere.json`); нет — вывода по часу нет.
    wm: Option<Arc<WeatherModelCfg>>,
    /// `atmosphere.json`; нет — условия профиля ветра остаются прежними.
    atm: Option<Arc<Value>>,
    world: WorldTime,
    /// Время атмосферы, до которого продвинута погода.
    time: f64,
    /// Номера версий до пересоздания состояния (`configure`): растут монотонно.
    carry: (u64, u64),
}

/// Погода из условий: словарь, ход дня (прогноз) и ветер для рамки.
struct Resolved {
    weather: WeatherMap,
    day: Option<AtmoDay>,
}

impl Terms {
    /// Конфиги погоды после `configure`: состояние пересоздаётся при следующих условиях.
    pub(super) fn weather_configure(&mut self) {
        let c = &self.configs;
        let atm = named_json(c, "atmosphere");
        let wm = named_json(c, "weather_model").map(|v| {
            let mut m = WeatherModelCfg::from_value(&v);
            m.altitude_gain_per_km = atm
                .as_ref()
                .and_then(|a| a.pointer("/wind/altitude_gain_per_km"))
                .and_then(Value::as_f64)
                .unwrap_or(0.6);
            Arc::new(m)
        });
        let world =
            named_json(c, "world").map_or_else(WorldTime::default, |w| WorldTime::from_world(&w));
        let l = &mut self.link;
        if let Some(s) = &l.state {
            l.carry = s.versions();
        }
        l.state = None;
        l.wm = wm;
        l.atm = atm.map(Arc::new);
        l.world = world;
    }

    /// Место для прогноза (вызывает фасад после `load_place`); `None` — снять. Условия, если уже
    /// заданы, применяются заново как перестройка.
    pub fn set_place(&mut self, place: Option<&Place>) {
        self.link.place = place.map(PlaceLink::of);
        if let Some(c) = self.cond.take() {
            self.apply_conditions(&c, true);
        }
    }

    /// Погода с сетками климата (W4 v10): до `load_place`; уже заданные условия применяются заново.
    pub fn set_weather(&mut self, w: Arc<Weather>) {
        self.link.weather = Some(w);
        if let Some(c) = self.cond.take() {
            self.apply_conditions(&c, true);
        }
    }

    /// Климат места на дату: у `Weather`, иначе запасные значения (ячейка без сеток).
    fn place_climate(&self, ctx: &PlaceCtx, wm: &WeatherModelCfg) -> ClimatePlace {
        match &self.link.weather {
            Some(w) => w.climate_place(ctx),
            None => climate_place(&Value::Null, ctx, wm),
        }
    }

    pub(super) fn weather_unload_place(&mut self) {
        self.link.place = None;
    }

    /// Применить условия (см. модуль). `force_rebuild` — перестройка, как `rebuild` условий или новое
    /// место.
    pub(super) fn apply_conditions(&mut self, c: &Conditions, force_rebuild: bool) {
        let r = self.resolve_conditions(c);
        let t = self.link.time;
        let rebuild = force_rebuild || c.rebuild || self.link.state.is_none();
        let atm = self.link.atm.clone();
        let blend = c.blend_s.unwrap_or_else(|| self.default_blend_s(c.speed));
        let mut st = self.link.state.take();
        match (&mut st, rebuild) {
            (Some(s), true) => {
                s.clear_day();
                s.rebuild(r.weather.clone());
            }
            (None, _) => {
                let a = atm.as_deref().cloned().unwrap_or(Value::Null);
                let mut s = WeatherState::new(&a, r.weather.clone());
                s.version += self.link.carry.0;
                s.rebuild_version += self.link.carry.1;
                s.advance_to(t);
                st = Some(s);
            }
            (Some(s), false) => {
                if r.day.is_none() {
                    s.clear_day();
                    s.update_weather(&r.weather, blend);
                }
            }
        }
        if let (Some(s), Some(d)) = (&mut st, r.day) {
            s.set_day(d);
        }
        self.link.state = st;
        // ветер и опорная высота: как `Atmosphere.set_wind(speed, from, ref_msl, gain)`
        let wv = WeatherView::new(r.weather);
        self.wind.set_from_weather(&wv);
        match &c.source {
            Source::Forecast {
                wind_ref: Some(w), ..
            } => {
                self.wind.ref_msl = w.ref_msl;
                // нет gain_per_km - из климата места на высоте старта (W5 v10); нет места или
                // `Weather` - запасной климат (`climate.fallback`: рост ветра конфига). Прежний
                // рост от прошлых условий не остаётся.
                let gain = w.gain_per_km.or_else(|| {
                    let wm = self.link.wm.as_ref()?;
                    let base = self.link.place.as_ref().map_or(NO_PLACE, |p| p.ctx);
                    let ctx = PlaceCtx {
                        start_msl_m: w.ref_msl,
                        ..base
                    };
                    Some(self.place_climate(&ctx, wm).gain_per_km)
                });
                if let Some(g) = gain {
                    self.wind.set_altitude_gain(g);
                }
            }
            _ => self.wind.ref_msl = f64::NAN,
        }
        self.sync_weather();
        self.cond = Some(c.clone());
    }

    /// Блендинг по умолчанию: `diurnal.blend_s / max(speed, 1)` (`Atmosphere._f_apply_soft`).
    fn default_blend_s(&self, speed: f64) -> f64 {
        let b = self
            .link
            .wm
            .as_ref()
            .and_then(|w| w.raw.pointer("/diurnal/blend_s").and_then(Value::as_f64))
            .unwrap_or(300.0);
        b / speed.max(1.0)
    }

    /// Условия → погода и ход дня (`Atmosphere._f_resolve`).
    fn resolve_conditions(&self, c: &Conditions) -> Resolved {
        let mut r = match &c.source {
            Source::Preset(p) => Resolved {
                weather: match p {
                    Value::String(n) => {
                        let n = n.strip_prefix("weather/").unwrap_or(n);
                        match named_json(&self.configs, &format!("weather/{n}")) {
                            Some(Value::Object(m)) => m,
                            _ => Map::new(),
                        }
                    }
                    Value::Object(m) => m.clone(),
                    _ => Map::new(),
                },
                day: None,
            },
            Source::Forecast {
                forecast,
                quantum_h,
                overrides,
                ..
            } => match (&self.link.place, &self.link.wm) {
                (Some(pl), Some(wm)) => {
                    let climate: ClimatePlace = self.place_climate(&pl.ctx, wm);
                    let day = AtmoDay::from_forecast(
                        forecast.clone(),
                        pl.ctx,
                        climate,
                        (**wm).clone(),
                        overrides.clone(),
                        c.start_hour,
                        self.link.time,
                        c.speed,
                        *quantum_h,
                        self.link.world,
                    );
                    Resolved {
                        weather: day.weather_for_hour(c.start_hour),
                        day: Some(day),
                    }
                }
                _ => {
                    let mut map = Map::new();
                    map.insert("temperature_c".into(), forecast.temperature_c.into());
                    map.insert("wind_speed_kmh".into(), forecast.wind_speed_kmh.into());
                    map.insert("wind_from_deg".into(), forecast.wind_from_deg.into());
                    map.insert("sky".into(), forecast.sky.clone().into());
                    for (k, v) in overrides {
                        map.insert(k.clone(), v.clone());
                    }
                    Resolved {
                        weather: map,
                        day: None,
                    }
                }
            },
        };
        r.weather.remove("static_thermals");
        r
    }

    /// Выведенная погода и условия профиля ветра из состояния в `Terms::weather` и `wind`.
    fn sync_weather(&mut self) {
        let Some(s) = &self.link.state else { return };
        self.weather = WeatherView::new(s.map.clone());
        if let (Some(_), Some(wm)) = (&self.link.atm, &self.link.wm) {
            let (sun, cover) = s.wind_conditions(wm);
            self.wind.set_conditions(sun, cover);
        }
    }

    /// Ход времени погоды: `true` — изменилось то, что читают слагаемые (словарь погоды, версии,
    /// коэффициенты суммы), снимок нужно публиковать заново.
    pub(super) fn advance_weather(&mut self, t: f64) -> bool {
        self.link.time = t;
        let Some(s) = self.link.state.as_mut() else {
            return false;
        };
        let before = (s.versions(), s.coeffs.clone());
        s.advance_to(t);
        let changed = before.0 != s.versions() || before.1 != s.coeffs;
        if before.0.0 != s.version {
            self.sync_weather();
        }
        changed
    }

    /// Выведенная погода json-строкой (`weather_json`, W2). Нет условий — `{}`.
    pub fn weather_json(&self) -> String {
        self.link
            .state
            .as_ref()
            .map_or_else(|| "{}".into(), WeatherState::weather_json)
    }

    /// `(мягкая, перестройка)` (`weather_version`, W4): растёт при каждой смене погоды / только при
    /// перестройке; смены нет — стоит.
    pub fn weather_version(&self) -> (u64, u64) {
        self.link
            .state
            .as_ref()
            .map_or(self.link.carry, WeatherState::versions)
    }

    /// `[на солнце x, y, z; прогрев 0..1]` на момент `t` (`sun_state`, W2): направление — заданное
    /// `Terms::sun`, иначе из хода дня, иначе `clouds.sun_*`; прогрев — `Atmosphere.get_insolation`.
    pub fn sun_state(&self, t: f64) -> [f32; 4] {
        match &self.link.state {
            Some(s) => s.sun_state_with(t, self.sun),
            None => {
                let v = self.sun.unwrap_or([0.0; 3]);
                [v[0], v[1], v[2], 1.0]
            }
        }
    }

    /// Коэффициенты суммы на текущий момент (плавные — по ходу дня / мягкой смене); нет условий — `None`.
    pub fn coefficients(&self) -> Option<&Coefficients> {
        self.link.state.as_ref().map(|s| &s.coeffs)
    }

    /// Время атмосферы, с которого идёт погода (после `load_place` - 0): прогноз при `set_place`
    /// строит ход дня от этого момента.
    pub fn set_origin(&mut self, t: f64) {
        self.link.time = t;
    }

    /// Часовая часть силы источников термиков как функция времени атмосферы (`AtmoDay.source_fn`):
    /// направления солнца по классам и застройка ночью из `SurfaceHeating` места и даты, час - по
    /// ходу дня. Воды нет (`water: None`): температуры воды и воздуха для источника - по клетке,
    /// растровый путь их не знает. Нет хода дня, места или `weather_model` - `None` (источники -
    /// статичное солнце мира). Ответ кешируется по минуте часа места.
    pub fn source_hours(&self) -> Option<Arc<super::HourFn>> {
        let (day, pl, wm) = (
            self.day()?,
            self.link.place.as_ref()?,
            self.link.wm.as_ref()?,
        );
        let c = pl.ctx;
        let heating = wm.surface_heating(&Ctx {
            month: c.month,
            day: c.day,
            lat: c.lat,
            lon: c.lon,
            utc_offset_h: c.utc_offset_h,
            valley_msl_m: c.valley_msl_m,
            mean_msl_m: c.mean_msl_m,
        });
        let day = day.clone();
        let min_light = day.time.min_light_elevation_deg;
        let memo: Mutex<Option<(i64, thermal_src::SourceHour)>> = Mutex::new(None);
        Some(Arc::new(move |t| {
            let hour = day.hour_at(t);
            let key = (hour * 60.0).floor() as i64;
            let mut g = memo.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some((k, h)) = *g
                && k == key
            {
                return h;
            }
            let to_sun = thermal_src::atmo_sun(&heating, hour, min_light);
            let h = thermal_src::SourceHour::at(&heating, hour, to_sun, None);
            *g = Some((key, h));
            h
        }))
    }

    /// Подпись хода дня `(start_hour, t0, speed)`: сменилась - часовая часть источников устарела.
    pub fn day_sig(&self) -> Option<[f64; 3]> {
        self.day().map(|d| [d.start_hour, d.t0, d.speed])
    }

    /// Ход дня (часы места, `AtmoDay`); прогноз без вывода и эталон — `None`.
    pub fn day(&self) -> Option<&AtmoDay> {
        self.link.state.as_ref().and_then(WeatherState::day)
    }
}
