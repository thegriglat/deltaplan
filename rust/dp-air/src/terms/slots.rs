//! Слоты слагаемых: трейты и заглушки «ноль/нет». Каждая задача этапа 3 заменяет заглушку своего
//! слота одной строкой в `Slots::new` (`terms/mod.rs`).
//!
//! Правило выдачи: `None` — слагаемого в точке нет, `sum` его пропускает (не прибавляет нули:
//! `-0.0 + 0.0` меняет бит). Все вклады слотов приходят уже со своими весами (в т. ч. `(1 − a)`
//! полосы края), горизонтальный вклад аналитики — скаляр `h` вдоль ветра `wind.dir()`.
use super::Ctx;
use super::sum::Mid;

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
pub struct NoTurb;
impl Turb for NoTurb {}
