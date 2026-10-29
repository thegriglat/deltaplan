//! Слоты слагаемых: трейты и заглушки «ноль/нет». Каждая задача этапа 3 заменяет заглушку своего
//! слота одной строкой в `Slots::new` (`terms/mod.rs`).
//!
//! Правило выдачи: `None` — слагаемого в точке нет, `sum` его пропускает (не прибавляет нули:
//! `-0.0 + 0.0` меняет бит). Все вклады слотов приходят уже со своими весами (в т. ч. `(1 − a)`
//! полосы края), горизонтальный вклад аналитики — скаляр `h` вдоль ветра `wind.dir()`.
use super::sum::Mid;
use super::thermal::ThermalSlot;
use super::{Ctx, Terms};
use crate::Configs;
use crate::Core;
use crate::place::Place;
use std::sync::Arc;

/// Аналитика: среднее (RW-9). Ветка `a < 1` (в `a = 0` — вся); `h = u·(1 − a)·(1 − 0,6·lee_a)` и
/// добавки подветренной зоны вдоль ветра, `w_ridge` — склоновый подъём (`ridge`), `w_lee` —
/// остальная вертикаль аналитики (опускание в тени, рывки; `analytic`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AnalyticMean {
    pub h: f64,
    pub w_ridge: f64,
    pub w_lee: f64,
    /// Подветренная доля аналитики 0..1 (для `rot` болтанки).
    pub lee: f64,
    /// Опасность подветренной зоны 0..1.
    pub danger: f64,
    /// Превышение гребня, м (`-1` — не считали).
    pub relief: f64,
}

/// Составляющие σ аналитики: `var = mech² + conv² + rot²`, `rot` — ротор (для предела).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AnalyticTurb {
    pub var: f64,
    pub rot: f64,
}

pub trait Analytic: Send + Sync {
    fn mean(&self, _c: &Ctx) -> Option<AnalyticMean> {
        None
    }
    /// Дисперсия аналитики без вкладов термика/грозы/ротора волн (они в `sum`).
    fn turb(
        &self,
        _c: &Ctx,
        _m: Option<&AnalyticMean>,
        _th: Option<&ThermalOut>,
    ) -> Option<AnalyticTurb> {
        None
    }
    /// Шум аналитики `gust_unit·amp` (вертикаль × 0,7 × fade); только в FULL.
    fn gust(&self, _c: &Ctx, _amp: f64, _fade: f64) -> [f64; 3] {
        [0.0; 3]
    }
    /// Слот, заданный конфигами и сидом (`Terms::configure`); `None` — слот остаётся как есть
    /// (заглушки и пробники тестов).
    fn configured(&self, _configs: &Configs, _seed: u64) -> Option<Arc<dyn Analytic>> {
        None
    }
    /// Опасность подветренной зоны 0..1 в точке (болтанка поля, RW-8): `None` — слот не задан.
    fn lee_danger(&self, _c: &Ctx) -> Option<f64> {
        None
    }
    /// Превышение гребня против ветра над землёй в точке, м.
    fn relief(&self, _c: &Ctx) -> Option<f64> {
        None
    }
    /// Нижняя кромка облаков, м MSL (средняя высота земли у центра + `cloudbase_agl_m`).
    fn cloudbase_msl(&self, _t: &Terms, _place: &Place) -> Option<f64> {
        None
    }
    /// Фоновый ветер по высотам MSL (`[vx, vz]`), профиль без рельефа.
    fn background_wind(&self, _t: &Terms, _place: &Place, _heights: &[f32], out: &mut [[f32; 2]]) {
        out.iter_mut().for_each(|o| *o = [0.0; 2]);
    }
}

/// Термик в точке: `w` (с учётом фона — см. `bg_sink` в `sum`), маска 0..1, σ края.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ThermalOut {
    pub w: f64,
    pub mask: f64,
    pub sigma: f64,
}

pub trait Thermal: Send + Sync {
    fn sample(&self, _c: &Ctx) -> Option<ThermalOut> {
        None
    }
    /// Снимок на момент `t` (раз в обновление термиков, `Terms::advance`/`start_at`); `None` —
    /// прежний годится. `force` — `start_at`: строить заново.
    fn advanced(&self, _terms: &Terms, _t: f64, _force: bool) -> Option<Arc<dyn Thermal>> {
        None
    }
    /// Ядра подъёма W6 на момент `t` с осью ближе `radius` к `center` (подключение к `AirModel::cores`
    /// — RW-12z).
    fn cores(&self, _center: [f32; 3], _radius: f32, _t: f64, out: &mut Vec<Core>) {
        out.clear();
    }
    /// Слот термиков RW-10b (для доступа к набору из RW-10e/11).
    fn as_slot(&self) -> Option<&ThermalSlot> {
        None
    }
}

/// Гроза, волна, поток в облаке (`_extra_flow`): добавки к скорости (после своих ограничителей),
/// σ грозы и роторов волн, амплитуда бурления в облаке `chaos = in_cloud_turb·cin.x`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ExtraOut {
    pub storm: [f64; 3],
    pub wave: [f64; 3],
    pub cloud: [f64; 3],
    pub sigma_storm: f64,
    pub sigma_rotor: f64,
    pub chaos: f64,
}

pub trait Extra: Send + Sync {
    /// `v` — скорость до добавок (нужна ограничителям грозы).
    fn flow(&self, _c: &Ctx, _v: [f64; 3]) -> Option<ExtraOut> {
        None
    }
    /// Единичный шум бурления в облаке (`gust_unit(pos·k, 3t, advect, 0)`); только в FULL.
    fn chaos_noise(&self, _c: &Ctx) -> [f64; 3] {
        [0.0; 3]
    }
}

/// Поле: поправка среднего горизонтали (`-a·0,22·U_H·lee_f·danger·unres·…`, `dh` вдоль ветра).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TurbMean {
    pub dh: f64,
    /// Скачок скорости слоя смешения ΔU.
    pub du: f64,
    pub danger: f64,
}

/// Болтанка поля до слияния с термиком/грозой: `s_*` уже `max(σ_поля, σ_sep)`, `sep` — σ слоя
/// смешения (горизонталь, вертикаль) для предела, `n` — единичный шум спектра (в MEAN нули),
/// `w_burst` — рывки вниз слоя смешения (с нулевым средним).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TurbOut {
    pub s_u: f64,
    pub s_v: f64,
    pub s_w: f64,
    pub sep: [f64; 2],
    pub n: [f64; 3],
    pub w_burst: f64,
}

pub trait Turb: Send + Sync {
    /// Только при `a > 0`.
    fn mean(&self, _c: &Ctx, _m: Option<&AnalyticMean>) -> Option<TurbMean> {
        None
    }
    /// Только при `a > 0`; `mid` — средняя скорость после `_extra_flow`.
    fn sigma(&self, _c: &Ctx, _m: &Mid) -> Option<TurbOut> {
        None
    }
}

pub struct NoAnalytic;
impl Analytic for NoAnalytic {}
pub struct NoThermal;
impl Thermal for NoThermal {}
pub struct NoExtra;
impl Extra for NoExtra {}

/// Составной слот `Extra`: гроза (RW-11c), волна (RW-11b), облако (RW-11d) - каждая часть
/// заполняет свои поля `ExtraOut` (остальные нули), `flow` складывает выдачи частей. Новую часть
/// добавляет одна строка в `Slots::new`.
pub struct ExtraSet {
    pub parts: Vec<Arc<dyn Extra>>,
}

impl ExtraSet {
    pub fn new(parts: Vec<Arc<dyn Extra>>) -> Self {
        ExtraSet { parts }
    }
}

impl Extra for ExtraSet {
    fn flow(&self, c: &Ctx, v: [f64; 3]) -> Option<ExtraOut> {
        let mut acc: Option<ExtraOut> = None;
        for p in &self.parts {
            let Some(o) = p.flow(c, v) else { continue };
            acc = Some(match acc {
                None => o,
                Some(a) => ExtraOut {
                    storm: add3(a.storm, o.storm),
                    wave: add3(a.wave, o.wave),
                    cloud: add3(a.cloud, o.cloud),
                    sigma_storm: a.sigma_storm + o.sigma_storm,
                    sigma_rotor: a.sigma_rotor + o.sigma_rotor,
                    chaos: a.chaos + o.chaos,
                },
            });
        }
        acc
    }

    fn chaos_noise(&self, c: &Ctx) -> [f64; 3] {
        // шум бурления даёт часть, у которой есть `chaos` (облако); остальные возвращают нули
        let mut n = [0.0; 3];
        for p in &self.parts {
            n = add3(n, p.chaos_noise(c));
        }
        n
    }
}

fn add3(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
pub struct NoTurb;
impl Turb for NoTurb {}
