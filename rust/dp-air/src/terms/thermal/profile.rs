//! Профиль подъёма одного термика (`ThermalField.sample`): по радиусу — Гедеон
//! `(1 − x²)·exp(−x²)` с кольцом опускания, радиус растёт с высотой по Аллену
//! `ξ^⅓(1 − 0,25ξ)/0,75`, по высоте — разгон у земли (`ground_ramp_m`), спад у верха
//! (`top_taper_m`), подсос под основанием облака, оторвавшийся низ на распаде, σ края.
use super::cfg::ThermalCfg;
use super::life::{AtmoThermal, Phase, smoothstep};

/// Плавность границы оторвавшегося низа термика, м (форма, не параметр погоды).
pub const CUT_BLEND_M: f64 = 60.0;
const THIRD: f64 = 1.0 / 3.0;
/// Allen: при ξ = 1 множитель 0,75 — нормируем, чтобы у верха был радиус `R`.
const ALLEN_NORM: f64 = 1.0 / 0.75;

/// Вклад одного термика в точке.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Contribution {
    /// Вертикальная скорость, м/с.
    pub w: f64,
    /// Маска ядра 0..1.
    pub mask: f64,
    /// Квадрат вклада в σ края.
    pub edge2: f64,
}

/// Параметры края (σ): `edge_factor · thermal_edge_k`, `edge_width`.
#[derive(Clone, Copy, Debug)]
pub struct Edge {
    pub k: f64,
    pub w: f64,
}

/// Вклад термика `th` в точке `pos` в состоянии `ph`; `suck = (усиление у основания, высота
/// потока в облаке)` — крючок облаков (RW-11), без облака `(th.suck, 0)`. `None` — не действует.
pub fn contribution(
    th: &AtmoThermal,
    ph: &Phase,
    cfg: &ThermalCfg,
    edge: Edge,
    pos: [f32; 3],
    suck: [f64; 2],
) -> Option<Contribution> {
    let (px, py, pz) = (f64::from(pos[0]), f64::from(pos[1]), f64::from(pos[2]));
    let src_y = f64::from(th.src[1]);
    let dh = py - src_y;
    let top = th.top;
    let in_h = suck[1];
    if dh <= 0.0 || py >= top + in_h || ph.env <= 0.0 {
        return None;
    }
    let cut2 = cfg.profile_cutoff_radii * cfg.profile_cutoff_radii;
    // быстрый отсев по максимальному радиусу (у верха)
    let cx = f64::from(th.src[0]) + f64::from(ph.drift[0]) + f64::from(th.lean[0]) * dh - px;
    let cz = f64::from(th.src[2]) + f64::from(ph.drift[1]) + f64::from(th.lean[1]) * dh - pz;
    let d2 = cx * cx + cz * cz;
    let r0 = th.radius;
    if d2 > r0 * r0 * cut2 {
        return None;
    }
    // оторвавшийся низ на распаде: плавная граница
    let mut cutk = 1.0;
    if py < ph.cut_h + CUT_BLEND_M {
        cutk = (py - ph.cut_h) / CUT_BLEND_M;
        if cutk <= 0.0 {
            return None;
        }
    }
    let xi = (dh / (top - src_y).max(1.0)).min(1.0);
    let rf = cfg
        .radius_min_factor
        .max(xi.powf(THIRD) * (1.0 - 0.25 * xi) * ALLEN_NORM);
    let r = r0 * rf;
    let x2 = d2 / (r * r);
    if x2 > cut2 {
        return None;
    }
    let mut vert = 1.0f64.min((dh / cfg.ground_ramp_m).powf(THIRD));
    let top_d = top - py;
    let s = suck[0];
    if top_d < 0.0 {
        // в облаке упорядоченного потока почти нет; к верхушке гаснет
        vert *= cfg.in_cloud_mean_frac * (1.0 + s) * (1.0 - smoothstep(0.5, 1.0, -top_d / in_h));
    } else if s > 0.0 {
        // облачный подсос: в последних suck_depth м под основанием подъём растёт
        vert *= 1.0 + s * (1.0 - smoothstep(0.0, cfg.suck_depth_m, top_d));
    } else if top_d < cfg.top_taper_m {
        vert *= smoothstep(0.0, cfg.top_taper_m, top_d);
    }
    let a = th.strength * ph.env * vert * cutk;
    let ex = (-x2).exp();
    let mut g = ex * (1.0 - x2);
    if g < 0.0 {
        g *= if th.ring >= 0.0 {
            th.ring
        } else {
            cfg.ring_sink_factor
        };
    }
    let e = (x2.sqrt() - 1.0) / edge.w;
    let ea = edge.k * a * (-e * e).exp();
    Some(Contribution {
        w: a * g,
        mask: ph.env * vert * cutk * ex,
        edge2: ea * ea,
    })
}
