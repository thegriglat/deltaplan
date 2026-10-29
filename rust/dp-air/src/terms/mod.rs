//! Слагаемые ветра: снимок `Terms`, слоты, сумма и разложение (этап 3 переноса, RW-8b).
//!
//! `Formula` (`formula.rs`) после RW-8b не знает про отдельные слагаемые: она кладёт в `Terms`
//! всё, что слагаемым нужно от неё (конфиги, сид, условия, выведенную погоду, фокусы, статические
//! термики, солнце, время), и опрашивает `sum`. Задачи RW-8…11 заменяют заглушки слотов и
//! добавляют свои файлы в `terms/<своё>/`; `formula.rs` не правят (кроме итогового шага RW-12z).
//!
//! ## Стык слагаемых
//! - **`Terms`** — снимок слагаемых; лежит в `Published` за `Arc` (подмена указателя, как у поля;
//!   читатели держат прежний). Команды меняют копию в `Formula` и публикуют (`Formula::publish_terms`).
//!   Состояние слагаемых во времени (термики раз в 1 с атмосферы, облака 0,1 с) — внутри их
//!   слотов (`Arc<dyn …>`), обновляет `Terms::advance(t)` (сейчас пусто; вернула `true` —
//!   снимок изменился и публикуется заново). Время опроса — `Ctx::t` (текущее время атмосферы).
//! - **`Ctx`** — точка опроса: позиция, высота земли `ground` (`ground_height` места), `agl`,
//!   доля поля `a` и вклад поля `fw` (уже со своими весами), ветер профиля в точке `u`
//!   (`wind.speed_at_pos`), время `t`, режим, ссылки на `Terms` (рамка ветра, `weather`, `cfg`,
//!   `seed`, `focuses`, `statics`, `sun`, `configs`), `FieldSet` (повторные опросы поля: `U_H`,
//!   `turb_at`, `sample_dx`) и место.
//! - **Слоты** (`slots.rs`): `Analytic` (RW-9: среднее `h`, склон, подветренная зона, σ и шум
//!   аналитики), `Thermal` (RW-10: `w`, маска, σ края), `Extra` (RW-11: гроза, волна, облако,
//!   бурление), `Turb` (RW-8: среднее поправки поля, σ и шум поля). Метод без вклада возвращает
//!   `None` — `sum` его пропускает. Вклады приходят уже со своими весами (полоса края `a < 1`:
//!   веса `(1 − a)` у аналитики). Регистрация — одна строка в `Slots::new` ниже.
//! - **`sum`** — порядок `air_velocity_at` буквально: (1) `fw`, `u`; (2) `Analytic::mean`;
//!   (3) `Turb::mean` при `a > 0`; (4) `Thermal::sample`, `fade = min(agl/ground_fade_m, 1)`,
//!   `w += fade·(bg_sink·(1 − маска) + w_терм)`; (5) `Extra::flow` (гроза, волна, облако);
//!   (6) σ: `ex2 = σ_терм² + σ_гроза² + σ_ротор²`; поле — `Turb::sigma`, `σ = min(√(σ² + ex2),
//!   max(turb_max, min(σ_sep, rotor_max)))` (σ_w — `ex2·vertical_ratio²`); аналитика — `amp =
//!   min(√(var + ex2), max(turb_max, min(rot, rotor_max)))`; (7) шум вдоль/поперёк среднего
//!   ветра в точке (после `Extra`), полоса края `tv = (a·tv_поля + (1 − a)·tv_ан)·k`,
//!   `k = 1/√(a² + (1 − a)²)`, `σ = √(a·σ_u² + (1 − a)·amp²)`; (8) бурление в облаке
//!   `chaos`: `v += шум·chaos`, `σ = √(σ² + chaos²)`. Шум только в `Full`; в `Mean` σ та же.
//! - **`decompose`** — `sum` с записью `Rec`: имена W7 (`field, analytic, ridge, thermal, storm,
//!   wave, cloud, turb, gust`), запись не меняет счёта: `total` = `sample(Full)` побитно,
//!   `Σ vel = total.xyz`. Слот, пишущий вклад, добавляет его в `Rec` в `sum` (не в слоте).
//! - **`frame`** — `WindModel` (профиль, `speed_at`, `altitude_factor`, `vec2_at`, `dir`,
//!   `simple_profile`) и `WeatherView` (словарь выведенной погоды, ключи как у GD; заполняет
//!   RW-12b; пока — из условий: пресет или прогноз).
mod decompose;
mod frame;
mod slots;
mod sum;
pub mod thermal;

use crate::field::field_set::FieldSet;
use crate::place::Place;
use crate::{Conditions, Configs, Focus, SampleMode, Source};
pub use decompose::{
    NAMES, Rec, T_ANALYTIC, T_CLOUD, T_FIELD, T_GUST, T_RIDGE, T_STORM, T_THERMAL, T_TURB, T_WAVE,
    empty as empty_decomposition,
};
pub use frame::{AIR_CASE_Z0, WeatherView, WindCfg, WindModel};
use serde_json::{Map, Value};
pub use slots::{
    Analytic, AnalyticMean, AnalyticTurb, Extra, ExtraOut, NoAnalytic, NoExtra, NoThermal, NoTurb,
    Thermal, ThermalOut, Turb, TurbMean, TurbOut,
};
use std::sync::Arc;
pub use sum::{Mid, sum};

/// Коэффициенты суммы из `atmosphere.json` (запасные значения — как в GD).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SumCfg {
    /// `ground_fade_m`: у земли термики плавно гаснут.
    pub ground_fade_m: f64,
    /// `turbulence.max_amplitude_ms`: общий предел σ.
    pub turb_max_ms: f64,
    /// `lee.rotor_max_amplitude_ms`: предел σ у ротора.
    pub rotor_max_ms: f64,
    /// `turbulence.vertical_ratio`.
    pub vertical_ratio: f64,
}

impl Default for SumCfg {
    fn default() -> Self {
        SumCfg {
            ground_fade_m: 60.0,
            turb_max_ms: 4.0,
            rotor_max_ms: 7.0,
            vertical_ratio: 0.7,
        }
    }
}

impl SumCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = SumCfg::default();
        let g = |p: &str, dv: f64| atm.pointer(p).and_then(Value::as_f64).unwrap_or(dv);
        SumCfg {
            ground_fade_m: g("/ground_fade_m", d.ground_fade_m).max(1.0e-6),
            turb_max_ms: g("/turbulence/max_amplitude_ms", d.turb_max_ms),
            rotor_max_ms: g("/lee/rotor_max_amplitude_ms", d.rotor_max_ms),
            vertical_ratio: g("/turbulence/vertical_ratio", d.vertical_ratio),
        }
    }
}

/// Конфиг по имени (`weather/medium` или `weather/medium.json`) как json.
pub fn named_json(c: &Configs, name: &str) -> Option<Value> {
    c.files
        .iter()
        .find(|(n, _)| n == name || n.strip_suffix(".json") == Some(name))
        .and_then(|(_, t)| serde_json::from_str(t).ok())
}

/// Слоты слагаемых. Каждая задача заменяет свою строку в `Slots::new`.
#[derive(Clone)]
pub struct Slots {
    pub analytic: Arc<dyn Analytic>,
    pub thermal: Arc<dyn Thermal>,
    pub extra: Arc<dyn Extra>,
    pub turb: Arc<dyn Turb>,
}

impl Slots {
    pub fn new() -> Self {
        Slots {
            analytic: Arc::new(NoAnalytic),                   // RW-9
            thermal: Arc::new(thermal::ThermalSlot::empty()), // RW-10b
            extra: Arc::new(NoExtra),                         // RW-11
            turb: Arc::new(NoTurb),                           // RW-8
        }
    }
}

impl Default for Slots {
    fn default() -> Self {
        Self::new()
    }
}

/// Снимок слагаемых: всё, что `sum` берёт помимо поля и места.
#[derive(Clone)]
pub struct Terms {
    pub cfg: SumCfg,
    pub wind: WindModel,
    pub weather: WeatherView,
    pub configs: Arc<Configs>,
    pub seed: u64,
    pub cond: Option<Conditions>,
    pub focuses: Vec<Focus>,
    /// Статические термики `[x, z, радиус, сила]` и режим (`set_static_thermals`).
    pub statics: Vec<[f32; 4]>,
    pub statics_mode: u8,
    /// Направление на солнце (`set_sun_direction`).
    pub sun: Option<[f32; 3]>,
    pub slots: Slots,
}

impl Default for Terms {
    fn default() -> Self {
        Terms {
            cfg: SumCfg::default(),
            wind: WindModel::default(),
            weather: WeatherView::default(),
            configs: Arc::new(Configs::default()),
            seed: 0,
            cond: None,
            focuses: Vec::new(),
            statics: Vec::new(),
            statics_mode: 0,
            sun: None,
            slots: Slots::new(),
        }
    }
}

impl Terms {
    pub fn configure(&mut self, configs: &Arc<Configs>, seed: u64) {
        self.configs = configs.clone();
        self.seed = seed;
        self.cfg = SumCfg::from_configs(configs);
        let ref_msl = self.wind.ref_msl;
        self.wind = WindModel::new(WindCfg::from_configs(configs));
        self.wind.ref_msl = ref_msl;
        let cond = self.cond.take();
        if let Some(c) = cond {
            self.set_conditions(&c);
        }
    }

    /// Погода и ветер из условий: пресет (имя или словарь) или прогноз. Выведенная погода
    /// (`_derived`, ход дня) — RW-12b.
    pub fn set_conditions(&mut self, c: &Conditions) {
        let mut map: Map<String, Value> = Map::new();
        match &c.source {
            Source::Preset(Value::String(n)) => {
                let n = n.strip_prefix("weather/").unwrap_or(n);
                if let Some(Value::Object(m)) = named_json(&self.configs, &format!("weather/{n}")) {
                    map = m;
                }
                self.wind.ref_msl = f64::NAN;
            }
            Source::Preset(Value::Object(m)) => {
                map = m.clone();
                self.wind.ref_msl = f64::NAN;
            }
            Source::Preset(_) => {}
            Source::Forecast {
                forecast,
                wind_ref,
                overrides,
                ..
            } => {
                map.insert("temperature_c".into(), forecast.temperature_c.into());
                map.insert("wind_speed_kmh".into(), forecast.wind_speed_kmh.into());
                map.insert("wind_from_deg".into(), forecast.wind_from_deg.into());
                map.insert("sky".into(), forecast.sky.clone().into());
                for (k, v) in overrides {
                    map.insert(k.clone(), v.clone());
                }
                match wind_ref {
                    Some(w) => {
                        self.wind.ref_msl = w.ref_msl;
                        self.wind.set_altitude_gain(w.gain_per_km);
                    }
                    None => self.wind.ref_msl = f64::NAN,
                }
            }
        }
        self.weather = WeatherView::new(map);
        self.wind.set_from_weather(&self.weather);
        self.cond = Some(c.clone());
    }

    /// Хук времени (`advance_to`): обновить слагаемые, которым нужен шаг (термики раз в 1 с
    /// атмосферы, облака 0,1 с). `true` — снимок изменился, нужна публикация. Термики (RW-10b):
    /// новый набор при смене ячейки `floor(t / refresh_interval_s)`, условий, ветра, статичных.
    pub fn advance(&mut self, t: f64) -> bool {
        match self.slots.thermal.advanced(self, t, false) {
            Some(n) => {
                self.slots.thermal = n;
                true
            }
            None => false,
        }
    }

    /// Хук `start_at`: состояние слагаемых на `t` как после прогона с 0 (W2). Термики — чистая
    /// функция (клетка, цикл), набор строится на `t` сразу.
    pub fn start_at(&mut self, t: f64) -> bool {
        match self.slots.thermal.advanced(self, t, true) {
            Some(n) => {
                self.slots.thermal = n;
                true
            }
            None => false,
        }
    }

    /// Земля для термиков (высота, вода, сила источника): `thermal::PlaceGround` или своя.
    /// Набор термиков строится при следующем `advance`/`start_at`.
    pub fn set_thermal_ground(&mut self, g: Arc<dyn thermal::GroundSource>) {
        self.slots.thermal = Arc::new(thermal::ThermalSlot::new(g));
    }

    /// Ядра подъёма W6 (`AirModel::cores` подключит RW-12z): на момент `t`.
    pub fn thermal_cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<crate::Core>) {
        self.slots.thermal.cores(center, radius, t, out);
    }

    /// Выгрузка места: условия и конфиги остаются, фокусы и статические термики — нет.
    pub fn unload_place(&mut self) {
        self.focuses.clear();
        self.statics.clear();
    }
}

/// Точка опроса суммы (см. «Стык слагаемых»).
pub struct Ctx<'a> {
    pub pos: [f32; 3],
    /// Высота рельефа под точкой, м.
    pub ground: f32,
    pub agl: f64,
    /// Время атмосферы, с.
    pub t: f64,
    pub mode: SampleMode,
    /// Доля поля 0..1 и вклад поля (x, w_mech, z) со своими весами.
    pub a: f64,
    pub fw: [f64; 3],
    /// Ветер профиля в точке: `speed_at_pos(agl, y)`.
    pub u: f64,
    pub terms: &'a Terms,
    pub fs: &'a FieldSet,
    pub place: &'a Place,
}

/// Разложение W7 в точке `p`: `sum` с записью вкладов.
pub fn decompose(
    terms: &Terms,
    fs: &FieldSet,
    place: Option<&Place>,
    p: [f32; 3],
    t: f64,
) -> crate::Decomposition {
    if !p.iter().all(|v| v.is_finite()) || place.is_none() {
        return empty_decomposition();
    }
    let mut rec = Rec::default();
    let total = sum(terms, fs, place, p, SampleMode::Full, t, Some(&mut rec));
    rec.into_decomposition(total)
}
