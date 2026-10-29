//! Сила источника термиков 0..1 из растров места (RW-10c): перенос `Terrain.thermal_source_strength_water`
//! (`scripts/terrain/terrain.gd`: класс точки, нормаль рельефа, влажность, поток тепла
//! `SurfaceHeat.mix_flux`, близость к границе классов-триггеров) и растрового пути
//! `AirPlaceData.source_at` (место без рельефа игры).
//!
//! ## Что берётся из места (W5)
//! `heights` — нормаль (`Terrain.normal_at`: центральные разности с шагом сетки, билинейная высота);
//! `cls` — класс узла (в нём уже маски леса/воды 10 м и скалы по уклону узла, `AirPlace.Surface`), `water` —
//! река/озеро (поверх `cls`), `moist` — влажность рельефа (билинейно). Конфиги: `surface_heat`
//! (`thermal.h_ref_wm2`, потоки) и `world` (`terrain_look.rock_slope_deg`, `surface.thermal.edge_*`).
//!
//! ## Границы модели (растр 25 м против слоёв GD 10 м)
//! GD берёт класс из маски 10 м (вода G ≥ 0,5, лес R ≥ 0,5) и карты 50 м, нормаль — на шаге слоя;
//! здесь класс — ближайший узел растра 25 м. Скалы по уклону проверяются заново в точке (по нормали
//! точки), но узел, ставший `bare` от крутизны, остаётся им и на пологой точке рядом. Границы классов
//! (`edge_proximity`) ищутся по классам узлов `cls` — включая `bare` от крутизны, которого в карте
//! классов GD («без учёта уклона») нет. Доля точек, где сила отличается от GD больше 0,05, измеряется
//! тестом `terms_thermal_src` на сетках мест (шаг 50 м, 161 × 161 вокруг первого старта, часы 6…21,5;
//! опорная ревизия c591b1026): по трём местам с рельефом игры 1,57 % точек (7335 из 466 578), Онгудай
//! 0,4–7,1 % по часам (класс совпал в 94,1 % точек, близость к границе — в 95,5 %), учебный остров
//! 0–1,1 %, вулканический 0–0,5 %; растровый путь `AirPlaceData.source_at` — max|Δ| 1,2e-7.
//!
//! ## Время суток
//! Часовая часть (`AtmoDay.source_at`: направления солнца по классам, застройка после заката, вода)
//! — параметр [`SourceHour`]; собирает её вызывающий (RW-12c): [`SourceHour::at`].
use super::named_json;
use crate::error::Error;
use crate::field::sun::{solar_position, sun_direction};
use crate::field::surface_heat::{
    CLASS_COUNT, CLASS_NAMES, NONE, Night, Sky, SurfaceHeatCfg, SurfaceHeating, WATER, WaterIn,
    mix_flux, num,
};
use crate::{Configs, Place};
use rayon::prelude::*;
use serde_json::Value;

/// Класс `bare` (скалы, голый грунт).
const BARE: usize = 5;
const GRASS: usize = 2;
const CROP: usize = 3;
const SHRUB: usize = 4;

/// Направление «на солнце» растрового пути без времени (`AirPlaceData.SUN_FOR_SOURCE`).
const SUN_FOR_SOURCE: [f64; 3] = [0.3, 0.8, 0.5];

/// Конфиг силы источника: `surface_heat` и `world`.
#[derive(Clone, Debug, PartialEq)]
pub struct SourceCfg {
    pub heat: SurfaceHeatCfg,
    /// `surface_heat.thermal.h_ref_wm2` (≥ 1), Вт/м²: поток, дающий силу 1.
    pub h_ref: f64,
    /// `world.surface.thermal.edge_boost`: прибавка силы у границы классов (доля).
    pub edge_boost: f64,
    /// `edge_full_m`: до этого расстояния от границы — полное усиление, м.
    pub edge_full_m: f64,
    /// `edge_max_m`: дальше усиления нет, м.
    pub edge_max_m: f64,
    /// Пары классов-триггеров, `edge_pair[a * 9 + b]`, симметрично.
    pub edge_pair: [bool; CLASS_COUNT * CLASS_COUNT],
    /// `cos(world.terrain_look.rock_slope_deg)`: нормаль круче (`n.y` меньше) — скалы.
    pub rock_cos: f64,
}

impl SourceCfg {
    /// Из json `surface_heat.json` и `world.json` (неизвестные ключи не ошибка; как `Terrain.set_surfaces`).
    pub fn from_values(surface_heat: &Value, world: &Value) -> Result<Self, Error> {
        let heat = SurfaceHeatCfg::from_value(surface_heat)?;
        let h_ref = num(surface_heat, &["thermal", "h_ref_wm2"], 362.0).max(1.0);
        let th = world.pointer("/surface/thermal").unwrap_or(&Value::Null);
        let mut edge_pair = [false; CLASS_COUNT * CLASS_COUNT];
        if let Some(pairs) = th.get("edge_pairs").and_then(Value::as_array) {
            for p in pairs {
                let idx = |i: usize| {
                    p.get(i)
                        .and_then(Value::as_str)
                        .and_then(|s| CLASS_NAMES.iter().position(|n| *n == s))
                };
                if let (Some(a), Some(b)) = (idx(0), idx(1)) {
                    edge_pair[a * CLASS_COUNT + b] = true;
                    edge_pair[b * CLASS_COUNT + a] = true;
                }
            }
        }
        let rock_deg = num(world, &["terrain_look", "rock_slope_deg"], 90.0);
        Ok(SourceCfg {
            heat,
            h_ref,
            edge_boost: num(th, &["edge_boost"], 0.0),
            edge_full_m: num(th, &["edge_full_m"], 50.0),
            edge_max_m: num(th, &["edge_max_m"], 150.0),
            edge_pair,
            rock_cos: rock_deg.to_radians().cos(),
        })
    }

    /// Из конфигов W5: `surface_heat` и `world` обязательны (нет — `BadInput`).
    pub fn from_configs(c: &Configs) -> Result<Self, Error> {
        let get = |n: &str| {
            named_json(c, n).ok_or_else(|| Error::bad_input(format!("config '{n}' missing")))
        };
        Self::from_values(&get("surface_heat")?, &get("world")?)
    }
}

/// Часовая часть силы источника по времени атмосферы (ход дня).
pub type HourFn = dyn Fn(f64) -> SourceHour + Send + Sync;

/// Часовая часть силы источника (`AtmoDay.source_fn`): солнце по классам, вода, застройка ночью.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourceHour {
    /// Направление НА солнце каждого класса (нулевой вектор — под горизонтом, классу K↓ = 0).
    pub class_sun: [[f64; 3]; CLASS_COUNT],
    /// Вода клетки (`None` — вода источником не считается, S = 0).
    pub water: Option<WaterIn>,
    /// Застройка после заката (`SurfaceHeating.built_night`).
    pub night: Option<Night>,
}

impl SourceHour {
    /// Всем классам одно солнце `to_sun`, без воды и ночи.
    pub fn uniform(to_sun: [f64; 3]) -> Self {
        SourceHour {
            class_sun: [to_sun; CLASS_COUNT],
            water: None,
            night: None,
        }
    }

    /// Как `AtmoDay.source_fn` на час `hour`: направления по классам и ночь застройки из
    /// `heating`; нет инерции прогрева (`enabled = false`) — всем классам `to_sun`
    /// (см. [`atmo_sun`]); `water` — контекст воды часа.
    pub fn at(
        heating: &SurfaceHeating,
        hour: f64,
        to_sun: [f64; 3],
        water: Option<WaterIn>,
    ) -> Self {
        SourceHour {
            class_sun: heating.directions(hour).unwrap_or([to_sun; CLASS_COUNT]),
            water,
            night: heating.built_night(hour),
        }
    }
}

/// `AtmoDay.sun_direction`: направление на солнце, высота не ниже `min_light_deg`
/// (`world.time.min_light_elevation_deg`, 2°) — для классов без своего направления.
pub fn atmo_sun(heating: &SurfaceHeating, hour: f64, min_light_deg: f64) -> [f64; 3] {
    let (az, el) = solar_position(
        heating.lat_deg,
        heating.lon_deg,
        heating.doy,
        hour,
        heating.utc_offset_h,
    );
    sun_direction(az, el.max(min_light_deg))
}

/// Доступ к растрам места по координатам мира (X к востоку, Z к югу, узел `(i, j)` — по индексу
/// `j · w + i`).
struct Grid<'a> {
    place: &'a Place,
    w: usize,
    h: usize,
    sp: f64,
    ox: f64,
    oz: f64,
}

impl<'a> Grid<'a> {
    fn new(place: &'a Place) -> Self {
        let g = &place.header().grid;
        Grid {
            place,
            w: g.width as usize,
            h: g.height as usize,
            sp: g.spacing,
            ox: g.origin_x,
            oz: g.origin_z,
        }
    }

    /// Билинейно, вне сетки — край (`HeightLayer.sample`).
    fn bilinear(&self, a: &[f32], x: f64, z: f64) -> f64 {
        let (w, h) = (self.w, self.h);
        if w < 2 || h < 2 {
            return a[0] as f64;
        }
        let fx = ((x - self.ox) / self.sp).clamp(0.0, (w - 1) as f64);
        let fz = ((z - self.oz) / self.sp).clamp(0.0, (h - 1) as f64);
        let i = (fx as usize).min(w - 2);
        let j = (fz as usize).min(h - 2);
        let (tx, tz) = (fx - i as f64, fz - j as f64);
        let k = j * w + i;
        let (p, q, r, s) = (
            a[k] as f64,
            a[k + 1] as f64,
            a[k + w] as f64,
            a[k + w + 1] as f64,
        );
        let top = p + (q - p) * tx;
        let bot = r + (s - r) * tx;
        top + (bot - top) * tz
    }

    fn height(&self, x: f64, z: f64) -> f64 {
        self.bilinear(self.place.heights(), x, z)
    }

    /// Ближайший узел (`roundi`, полцелого — от нуля), вне сетки — край.
    fn nearest(&self, x: f64, z: f64) -> usize {
        let i = (((x - self.ox) / self.sp).round().max(0.0) as usize).min(self.w - 1);
        let j = (((z - self.oz) / self.sp).round().max(0.0) as usize).min(self.h - 1);
        j * self.w + i
    }

    /// Класс узла: река/озеро поверх `cls`.
    fn node_class(&self, k: usize) -> usize {
        if self.place.water()[k] != 0 {
            WATER
        } else {
            (self.place.cls()[k] as usize).min(CLASS_COUNT - 1)
        }
    }

    /// Единичная нормаль `Terrain.normal_at`: `(−dx, 2e, −dz)`, `e` — шаг сетки.
    fn normal(&self, x: f64, z: f64) -> [f64; 3] {
        let e = self.sp;
        let dx = self.height(x + e, z) - self.height(x - e, z);
        let dz = self.height(x, z + e) - self.height(x, z - e);
        let l = (dx * dx + 4.0 * e * e + dz * dz).sqrt();
        [-dx / l, 2.0 * e / l, -dz / l]
    }
}

/// Сила источника без времени по растру (`AirPlaceData.source_at` без рельефа игры):
/// `moist · (0,35 + 0,8 · n·sun)`, нормаль `(−∂h/∂x, 1, −∂h/∂z)` с шагом сетки, влажность — ближайший узел.
pub fn raster_source(place: &Place, x: f64, z: f64) -> f32 {
    let g = Grid::new(place);
    let e = g.sp.max(1.0);
    let dx = (g.height(x + e, z) - g.height(x - e, z)) / (2.0 * e);
    let dz = (g.height(x, z + e) - g.height(x, z - e)) / (2.0 * e);
    let l = (dx * dx + 1.0 + dz * dz).sqrt();
    let s = SUN_FOR_SOURCE;
    let sl = (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]).sqrt();
    let dot = (-dx * s[0] + s[1] - dz * s[2]) / (l * sl);
    let m = place.moist()[g.nearest(x, z)] as f64;
    (m * (0.35 + 0.8 * dot)).clamp(0.0, 1.0) as f32
}

/// Класс точки как `Terrain._surface_class` по растру: класс ближайшего узла; луг, поле, кустарник
/// и «нет данных» на склоне круче `rock_slope_deg` — скалы.
fn surface_class(g: &Grid, cfg: &SourceCfg, x: f64, z: f64, n: &[f64; 3]) -> usize {
    let c = g.node_class(g.nearest(x, z));
    if n[1] < cfg.rock_cos && matches!(c, GRASS | CROP | SHRUB | NONE) {
        BARE
    } else {
        c
    }
}

/// Близость к границе классов-триггеров 0..1 (`Terrain._edge_proximity`): 8 направлений на 4
/// расстояниях от `edge_full/2` до `edge_max`; 1 — ближе `edge_full_m`, 0 — дальше `edge_max_m`.
fn edge_proximity(g: &Grid, cfg: &SourceCfg, x: f64, z: f64) -> f64 {
    if cfg.edge_boost <= 0.0 || !cfg.edge_pair.iter().any(|&b| b) {
        return 0.0;
    }
    let c0 = g.node_class(g.nearest(x, z));
    let steps = 4;
    for s in 0..steps {
        let d = cfg.edge_full_m * 0.5
            + (cfg.edge_max_m - cfg.edge_full_m * 0.5) * s as f64 / (steps - 1) as f64;
        for k in 0..8 {
            let a = std::f64::consts::TAU * k as f64 / 8.0;
            let c1 = g.node_class(g.nearest(x + a.cos() * d, z + a.sin() * d));
            if c1 != c0 && cfg.edge_pair[c0 * CLASS_COUNT + c1] {
                return ((cfg.edge_max_m - d) / (cfg.edge_max_m - cfg.edge_full_m).max(1.0))
                    .clamp(0.0, 1.0);
            }
        }
    }
    0.0
}

fn strength(g: &Grid, cfg: &SourceCfg, hr: &SourceHour, x: f64, z: f64) -> f32 {
    let n = g.normal(x, z);
    let c = surface_class(g, cfg, x, z, &n);
    let mut fr = [0.0f32; CLASS_COUNT];
    fr[c] = 1.0;
    let m = g.bilinear(g.place.moist(), x, z);
    let sky = Sky {
        cover: 0.0,
        sky_heat: 1.0,
        night: hr.night,
    };
    let h = mix_flux(&fr, n, &hr.class_sun, m, &sky, hr.water.as_ref(), &cfg.heat);
    if h <= 0.0 {
        return 0.0;
    }
    let edge = edge_proximity(g, cfg, x, z);
    (h / cfg.h_ref * (1.0 + cfg.edge_boost * edge)).clamp(0.0, 1.0) as f32
}

/// Сила источника термиков 0..1 в точке `(x, z)` (мир, м) в час `hr`
/// (`Terrain.thermal_source_strength_water`): `clamp(max(H, 0)/h_ref · (1 + edge_boost · близость), 0, 1)`,
/// `H` — `SurfaceHeat.mix_flux` для класса точки (единичная нормаль, класс-солнце, влажность рельефа,
/// ясное небо; вода — по `hr.water`, не задан — 0).
pub fn source_strength(place: &Place, cfg: &SourceCfg, hr: &SourceHour, x: f64, z: f64) -> f32 {
    strength(&Grid::new(place), cfg, hr, x, z)
}

/// Сила во всех узлах места (индекс `j · w + i`) в час `hr` — растр для сборки источников (RW-10d).
pub fn source_grid(place: &Place, cfg: &SourceCfg, hr: &SourceHour) -> Vec<f32> {
    let g = Grid::new(place);
    let mut out = vec![0.0f32; g.w * g.h];
    out.par_chunks_mut(g.w).enumerate().for_each(|(j, row)| {
        let z = g.oz + j as f64 * g.sp;
        for (i, o) in row.iter_mut().enumerate() {
            *o = strength(&g, cfg, hr, g.ox + i as f64 * g.sp, z);
        }
    });
    out
}

/// Класс точки (для тестов и описаний): `Terrain.surface_at` по растру.
pub fn class_at(place: &Place, cfg: &SourceCfg, x: f64, z: f64) -> usize {
    let g = Grid::new(place);
    let n = g.normal(x, z);
    surface_class(&g, cfg, x, z, &n)
}

/// Близость к границе классов-триггеров в точке (`Terrain._edge_proximity`).
pub fn edge_at(place: &Place, cfg: &SourceCfg, x: f64, z: f64) -> f64 {
    edge_proximity(&Grid::new(place), cfg, x, z)
}
