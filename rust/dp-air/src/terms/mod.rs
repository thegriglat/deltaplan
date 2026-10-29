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
//! - **`frame`** — `WindModel` (профиль, `speed_at`, `altitude_factor`, `vec2_at`, `dir`) и
//!   `WeatherView` (словарь выведенной погоды, ключи как у GD; заполняет
//!   RW-12b; пока — из условий: пресет или прогноз).
pub mod analytic;
pub mod clouds;
mod decompose;
mod frame;
pub mod objects;
mod slots;
pub mod storm;
mod sum;
pub mod surface_gust;
pub mod thermal;
pub mod thermal_air;
pub mod thermal_src;
pub mod turb;
pub mod waves;
mod weather_link;

use crate::field::field_set::FieldSet;
use crate::field::wind_field::Field;
use crate::place::Place;
use crate::{Conditions, Configs, Focus, SampleMode};
pub use decompose::{
    NAMES, Rec, T_ANALYTIC, T_CLOUD, T_FIELD, T_GUST, T_RIDGE, T_STORM, T_THERMAL, T_TURB, T_WAVE,
    empty as empty_decomposition,
};
pub use frame::{AIR_CASE_Z0, WeatherView, WindCfg, WindModel};
use serde_json::Value;
pub use slots::{
    Analytic, AnalyticMean, AnalyticTurb, Extra, ExtraOut, ExtraSet, NoAnalytic, NoExtra,
    NoThermal, NoTurb, Thermal, ThermalOut, Turb, TurbMean, TurbOut,
};
use std::sync::{Arc, OnceLock};
pub use sum::{Mid, sum};
pub use weather_link::PlaceLink;

/// Коэффициенты суммы из секция `atmosphere` (запасные значения — как в эталоне).
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

/// Секция конфигов (`atmosphere`, `weather/medium`, …) как json.
pub fn named_json(c: &Configs, name: &str) -> Option<Value> {
    c.value(name)
}

/// Часовая часть силы источников термиков по времени атмосферы (ход дня).
pub type HourFn = dyn Fn(f64) -> thermal_src::SourceHour + Send + Sync;

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
            analytic: Arc::new(analytic::AnalyticSlot::unconfigured()), // RW-9
            thermal: Arc::new(thermal::ThermalSlot::empty()),           // RW-10b
            extra: Arc::new(ExtraSet::new(vec![
                Arc::new(storm::StormExtra::new()),  // RW-11c
                Arc::new(waves::WaveExtra::new()),   // RW-11b
                Arc::new(clouds::CloudExtra::new()), // RW-11d
            ])),
            turb: Arc::new(NoTurb), // RW-8
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
    /// Самый грубый уровень поля воздуха: по нему собираются источники термиков
    /// (`set_air_field`); нет — термики только по клеткам.
    pub air: Option<Arc<Field>>,
    /// Ветер прогноза на 10 м для источников из поля, м/с (`None` — `wind_speed_kmh` погоды).
    pub air_u10: Option<f64>,
    /// Термики пересобираются в фоне (`advance` не ждёт): `true` при `air.deterministic = false`.
    pub thermal_async: bool,
    /// Поле облаков шагает в фоне (`advance` не ждёт). Ставит `Formula` (`air.deterministic = false`);
    /// по умолчанию - синхронно.
    pub clouds_async: bool,
    /// Ключ места (поколение `load_place`): кеши слагаемых (`WaveExtra`) не принимают чужое место
    /// по совпавшему адресу освобождённого растра. `0` — не задан (кеши идут по адресу).
    pub place_key: u64,
    pub slots: Slots,
    /// Направление ветра, по которому построена линия тени рельефа (единичный `(x, z)`, f32 как в
    /// GD). Меняется при повороте ветра больше `ground.wind_dir_tolerance_deg` (RW-9).
    pub ground_dir: [f32; 2],
    /// `ground.wind_dir_tolerance_deg`.
    pub ground_tol_deg: f64,
    /// Облака (RW-11d): снимок физики облаков, обновляет `advance`/`start_at`.
    pub clouds: Arc<clouds::CloudSlot>,
    /// Шум и константы поверхностного порыва (RW-8s): строится при первом вызове, `configure` сбрасывает.
    surface_gust: Arc<OnceLock<surface_gust::SurfaceGust>>,
    /// Погода во времени (RW-12d, `weather_link.rs`): состояние, место, версии.
    link: weather_link::WeatherLink,
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
            air: None,
            air_u10: None,
            thermal_async: false,
            clouds_async: false,
            place_key: 0,
            slots: Slots::new(),
            ground_dir: [0.0, 1.0],
            ground_tol_deg: 5.0,
            clouds: Arc::new(clouds::CloudSlot::analytic()),
            surface_gust: Default::default(),
            link: Default::default(),
        }
    }
}

impl Terms {
    pub fn configure(&mut self, configs: &Arc<Configs>, seed: u64) {
        self.configs = configs.clone();
        self.seed = seed;
        self.cfg = SumCfg::from_configs(configs);
        self.surface_gust = Default::default();
        // детерминированный режим (`air.deterministic`): фона нет, всё считается в `advance`
        let det = named_json(configs, "atmosphere")
            .and_then(|a| a.pointer("/air/deterministic").and_then(Value::as_bool))
            .unwrap_or(false);
        self.thermal_async = !det;
        self.weather_configure();
        // RW-8: слот Turb зависит от конфигов и сида (шум, таблицы), поэтому ставится здесь
        self.slots.turb = turb::FieldTurb::slot(configs, seed);
        let ref_msl = self.wind.ref_msl;
        self.wind = WindModel::new(WindCfg::from_configs(configs));
        self.wind.ref_msl = ref_msl;
        self.ground_tol_deg = named_json(configs, "atmosphere")
            .and_then(|v| {
                v.pointer("/ground/wind_dir_tolerance_deg")
                    .and_then(Value::as_f64)
            })
            .unwrap_or(5.0);
        self.ground_dir = norm_dir(self.wind.dir());
        if let Some(a) = self.slots.analytic.configured(configs, seed) {
            self.slots.analytic = a;
        }
        let cond = self.cond.take();
        if let Some(c) = cond {
            self.set_conditions(&c);
        }
    }

    /// Шум порывов у земли для пыли (`surface_gust::surface_gust_many`): по конфигам и сиду.
    pub fn surface_gust(&self) -> &surface_gust::SurfaceGust {
        self.surface_gust
            .get_or_init(|| surface_gust::SurfaceGust::new(&self.configs, self.seed))
    }

    /// Погода и ветер из условий (`weather_link.rs`): эталон-пресет или прогноз; прогноз с местом
    /// (`set_place`) выводит погоду по часу (`derive`, ход дня), первый вызов и `rebuild` — перестройка,
    /// иначе мягкая смена (`blend_s`).
    pub fn set_conditions(&mut self, c: &Conditions) {
        let (old_from, first) = (self.wind.from_deg, self.cond.is_none());
        self.apply_conditions(c, false);
        // Линия тени рельефа следует за ветром с отставанием: поворот не больше допуска её не
        // перестраивает (`Atmosphere.set_wind`, RW-9); первые условия — как `configure`.
        if first || angle_diff_deg(old_from, self.wind.from_deg).abs() > self.ground_tol_deg {
            self.ground_dir = norm_dir(self.wind.dir());
        }
    }

    /// Хук времени (`advance_to`): обновить слагаемые, которым нужен шаг (термики раз в 1 с
    /// атмосферы, облака 0,1 с) и погоду (ход дня на сетке 0,1 с, мягкая смена). `true` — снимок
    /// изменился, нужна публикация. Термики (RW-10b): новый набор при смене ячейки
    /// `floor(t / refresh_interval_s)`, условий, ветра, статичных.
    pub fn advance(&mut self, t: f64) -> bool {
        let w = self.advance_weather(t);
        let th = match self.slots.thermal.advanced(self, t, false) {
            Some(n) => {
                self.slots.thermal = n;
                true
            }
            None => false,
        };
        let cl = self.advance_clouds(t, false);
        // подсос видит облака этого шага (в GD `update_time` пишет параметры термиков по текущим
        // облакам), порождение термиков - прежние (`refresh_now`: термики раньше облаков)
        let sy = match self.slots.thermal.synced_with_clouds(self) {
            Some(n) => {
                self.slots.thermal = n;
                true
            }
            None => false,
        };
        w || th || cl || sy
    }

    /// Обновить облака; `true` - публикация нужна: поле шагнуло или есть Cb-объекты (их центры
    /// движутся). Пустое обновление объектов (облаков-объектов нет) снимок не публикует.
    fn advance_clouds(&mut self, t: f64, force: bool) -> bool {
        let next = if self.clouds_async && !force {
            self.clouds.advanced_bg(self, t)
        } else {
            self.clouds.advanced(self, t, force)
        };
        match next {
            Some(n) => {
                let (a, b) = (self.clouds.physics(), n.physics());
                let publish =
                    force || a.version != b.version || a.objects.count > 0 || b.objects.count > 0;
                self.clouds = n;
                publish
            }
            None => false,
        }
    }

    /// Поставщик входов поля облаков (`Field` + `AirThermals` - RW-10e/RW-12z).
    pub fn set_cloud_inputs(&mut self, inputs: Arc<dyn clouds::CloudInputs>) {
        self.clouds = Arc::new(self.clouds.with_inputs(inputs));
    }

    /// Снимок физики облаков (крючки `CloudHooks` для термиков).
    pub fn cloud_physics(&self) -> &Arc<clouds::CloudPhysics> {
        self.clouds.physics()
    }

    /// Хук `start_at`: состояние слагаемых на `t` как после прогона с 0 (W2). Погода — ход дня на `t`
    /// (чистая функция времени); термики — чистая функция (клетка, цикл), набор строится на `t` сразу.
    pub fn start_at(&mut self, t: f64) -> bool {
        let w = self.advance_weather(t);
        let th = match self.slots.thermal.advanced(self, t, true) {
            Some(n) => {
                self.slots.thermal = n;
                true
            }
            None => false,
        };
        let cl = self.advance_clouds(t, true);
        w || th || cl
    }

    /// Земля для термиков (высота, вода, сила источника): `thermal::PlaceGround` или своя.
    /// Набор термиков строится при следующем `advance`/`start_at`.
    pub fn set_thermal_ground(&mut self, g: Arc<dyn thermal::GroundSource>) {
        self.slots.thermal = Arc::new(thermal::ThermalSlot::new(g));
    }

    /// Поле воздуха для источников термиков: берётся самый грубый (последний) уровень.
    /// `u10` — ветер прогноза на 10 м (нет — из погоды). Источники пересоберутся при следующем
    /// `advance`/`start_at`.
    pub fn set_air_field(&mut self, levels: &[Arc<Field>], u10: Option<f64>) {
        self.air = levels.last().cloned();
        self.air_u10 = u10;
    }

    /// Ветер прогноза на 10 м, м/с: заданный или `wind_speed_kmh` погоды.
    pub fn air_u10(&self) -> f64 {
        self.air_u10
            .unwrap_or_else(|| self.weather.f64_or("wind_speed_kmh", 0.0) / 3.6)
    }

    /// Земля термиков из места W5: высота по растру, вода, сила источника по растрам
    /// (`thermal_src`) на час `hour` (нет — статичное солнце секция `world → sun`, без воды и ночи, как у случаев
    /// W8 без `AtmoDay`). Конфиги — те, что в `configure`.
    pub fn set_thermal_place(
        &mut self,
        place: Arc<crate::place::Place>,
        hour: Option<thermal_src::SourceHour>,
    ) -> Result<(), crate::Error> {
        // без часа — статичное солнце мира (секция `world → sun`, `Terrain.refresh_sun`)
        let hr = hour.unwrap_or_else(|| self.static_source_hour());
        self.set_thermal_place_hours(place, Arc::new(move |_| hr))
    }

    /// Как [`set_thermal_place`](Self::set_thermal_place), но часовая часть - функция времени
    /// атмосферы (`source_hours`: ход дня).
    pub fn set_thermal_place_hours(
        &mut self,
        place: Arc<crate::place::Place>,
        hours: Arc<HourFn>,
    ) -> Result<(), crate::Error> {
        let cfg = thermal_src::SourceCfg::from_configs(&self.configs)?;
        let p2 = place.clone();
        let src: Arc<thermal::SourceFn> = Arc::new(move |x, z, t| {
            f64::from(thermal_src::source_strength(&p2, &cfg, &hours(t), x, z))
        });
        self.set_thermal_ground(Arc::new(thermal::PlaceGround::new(place, src)));
        Ok(())
    }

    /// Статичное солнце мира (секция `world → sun`) для всех классов.
    pub fn static_source_hour(&self) -> thermal_src::SourceHour {
        let w = named_json(&self.configs, "world").unwrap_or(Value::Null);
        let g = |k: &str, d: f64| w.pointer(k).and_then(Value::as_f64).unwrap_or(d);
        thermal_src::SourceHour::uniform(crate::field::sun::sun_direction(
            g("/sun/azimuth_deg", 180.0),
            g("/sun/elevation_deg", 45.0),
        ))
    }

    /// Ядра подъёма W6 (`AirModel::cores` подключит RW-12z): на момент `t`.
    /// Поле `storm` ядра Cb - интенсивность грозы (`StormField.intensity`, RW-11f).
    pub fn thermal_cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<crate::Core>) {
        match self.slots.thermal.as_slot().and_then(|s| s.state()) {
            Some(st) => {
                let f = storm::field_of(self, storm::StormCfg::from_configs(&self.configs));
                thermal::cores::cores_with(st, center, radius, t, out, &|th, t| f.intensity(th, t));
            }
            None => self.slots.thermal.cores(center, radius, t, out),
        }
    }

    /// Кромка облаков, м MSL (`Atmosphere.cloudbase_msl`): средняя высота земли + `cloudbase_agl_m`
    /// погоды; пока термики не собраны - `0`.
    pub fn cloudbase_msl(&self) -> f32 {
        self.slots
            .thermal
            .as_slot()
            .and_then(|s| s.setup())
            .map_or(0.0, |s| s.cloudbase_msl as f32)
    }

    /// Средняя высота земли вокруг (0, 0), м (`Atmosphere._ground_ref`); слот термиков без земли
    /// места - `None`.
    pub fn ground_ref(&self) -> Option<f64> {
        let s = self.slots.thermal.as_slot()?;
        Some(s.ground_ref(&thermal::ThermalCfg::from_configs(&self.configs)))
    }

    /// Фоновый (синоптический) ветер на высотах MSL без рельефа и термиков (`background_wind`, W2):
    /// `out[i] = dir · speed_at_pos(max(h − ground_ref, 0), h)`; не конечная высота - `[0, 0]`;
    /// земли нет - нули.
    pub fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]) {
        let gr = self.ground_ref();
        let dir = self.wind.dir();
        let (dx, dz) = (f64::from(dir[0] as f32), f64::from(dir[1] as f32));
        for (o, &h) in out.iter_mut().zip(heights) {
            *o = [0.0; 2];
            if let (Some(gr), true) = (gr, h.is_finite()) {
                let u = self
                    .wind
                    .speed_at_pos((f64::from(h) - gr).max(0.0), f64::from(h));
                *o = [(dx * u) as f32, (dz * u) as f32];
            }
        }
    }

    /// Выгрузка места: условия и конфиги остаются, фокусы и статические термики — нет.
    pub fn unload_place(&mut self) {
        self.focuses.clear();
        self.statics.clear();
        self.air = None;
        self.slots.thermal = Arc::new(thermal::ThermalSlot::empty());
        self.weather_unload_place();
    }
}

/// Единичное направление `(x, z)` в f32 (`Vector2.normalized()`); нулевое — прежнее по умолчанию.
fn norm_dir(d: [f64; 2]) -> [f32; 2] {
    let (x, z) = (d[0] as f32, d[1] as f32);
    let l = (x * x + z * z).sqrt();
    if l > 0.0 { [x / l, z / l] } else { [0.0, 1.0] }
}

/// `angle_difference` эталона для углов в градусах: разность `b − a` в (−180, 180].
fn angle_diff_deg(a: f64, b: f64) -> f64 {
    let d = (b - a).rem_euclid(360.0);
    if d > 180.0 { d - 360.0 } else { d }
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
