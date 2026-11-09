//! Вход области Пикара из растров места (RW-6b) (без нагрева).
//!
//! Что строится: сетка и `nz`, `gam` (dθ̄/dz в центрах `nz + 2` уровней), `z_i_col`
//! (`AirZiTerrain`) поверх того, что даёт [`weather_core`]: рельеф клеток `hc` (`block_mean`),
//! доли классов и влажность (`cell_surface`), шероховатость (`cell_z0`), профиль и `z_i` дня
//! ([`Day`]). Одна реализация: здесь только то, чего нет в `weather_core`.
//! Тот же код на любом `dx` (400, 1200 м), кратном 25 м.
//!
//! ## Внутренний интерфейс для RW-6d
//! [`build_domain_input`]`(place, sh, zi, dom, day) -> `[`DomainInput`]: `dom` — [`Domain`]
//! (`Domain::standard(dx)` — 38,4 км), `day` — [`Day`] из `weather_core::day` (погода — его
//! параметр, не часть этого модуля), `sh` — `WeatherConfigs.sh`, `zi` — [`ZiCfg`] из конфигов.
//! Оси — как в эталоне: массивы по клеткам — `[j * nx + i]`, `j` растёт на СЕВЕР (`y = -z`
//! мира W1), узел сетки `y0 + dx * j`; в W1 это не выходит. Редукции — f64.
//!
//! Границы модели: область целиком в растре места (иначе `BAD_INPUT`); растр места — 25 м
//! с началом, кратным 25 м (снимок поверхности = растры `cls`/`moist`).
use super::cut_input::{CutFrac, cut_level};
use super::surface_heat::SurfaceHeatCfg;
use super::weather_core::{Cells, Day, Domain, NODE_STEP, block_mean, cell_surface, cell_z0};
use crate::{Configs, Error, Place};
use rayon::prelude::*;
use std::sync::Arc;

pub use super::weather_core::DOMAIN_L;
/// Высота области над самым высоким рельефом, м.
pub const TOP_ABOVE: f64 = 3000.0;

/// Числа `AirZiTerrain`: `air_model.zi_terrain_alpha`, `zi_terrain_smooth_m`, `AirCase.p.zi_min`.
#[derive(Clone, Debug, PartialEq)]
pub struct ZiCfg {
    pub alpha: f64,
    pub smooth_m: f64,
    /// Мин. толщина слоя перемешивания над рельефом, м.
    pub zi_min: f64,
}

impl ZiCfg {
    /// Из конфига `atmosphere`; нет секции — значения по умолчанию эталона.
    pub fn from_configs(cfg: &Configs) -> Result<Self, Error> {
        let text = cfg.get("atmosphere");
        let v: serde_json::Value = match text {
            Some(t) => serde_json::from_str(t)
                .map_err(|e| Error::bad_input(format!("config 'atmosphere': {e}")))?,
            None => serde_json::Value::Null,
        };
        let num = |k: &str, d: f64| {
            v.pointer(&format!("/air_model/{k}"))
                .and_then(serde_json::Value::as_f64)
                .unwrap_or(d)
        };
        Ok(ZiCfg {
            alpha: num("zi_terrain_alpha", 0.0),
            smooth_m: num("zi_terrain_smooth_m", 5000.0),
            zi_min: 300.0,
        })
    }
}

/// Вход области (без нагрева и притока).
#[derive(Clone, Debug, PartialEq)]
pub struct DomainInput {
    pub dom: Domain,
    pub nz: usize,
    pub dz: f64,
    pub z_bot: f64,
    /// Рельеф клеток, м.
    pub hc: Vec<f64>,
    /// Граница воздуха (PT7 v1): низ первой клетки с `vf ≥ VF_MIN`; `kf` случая — от неё.
    pub hc_type: Vec<f64>,
    /// Доли срезанных клеток; `None` — путь без долей (тесты-дампы).
    pub cut: Option<Arc<CutFrac>>,
    /// `nz + 2` значений, центр уровня `k`: [`DomainInput::zc`].
    pub gam: Vec<f64>,
    pub z_i: f64,
    pub z_i_col: Vec<f32>,
    pub z0_map: Vec<f64>,
    pub cells: Cells,
}

impl DomainInput {
    /// Центр клетки `k` (с ореолом), м над морем.
    pub fn zc(&self, k: usize) -> f64 {
        self.z_bot + (k as f64 - 0.5) * self.dz
    }
}

/// Доля воды по клеткам (`AirPlace.water_fraction`): узлы решётки 25 м, ближайший узел растра
/// `water` (> 0), доля узлов клетки. Путь без снимка поверхности.
pub fn water_fraction(place: &Place, dom: &Domain) -> Result<Vec<f64>, Error> {
    let g = &place.header().grid;
    let (w, h) = (g.width as usize, g.height as usize);
    let f = (dom.dx / NODE_STEP).round() as usize;
    let bad = || Error::bad_input("field input: domain outside the place raster");
    let idx = |a: f64, o: f64, n: usize| -> Result<usize, Error> {
        let v = (a - o) / g.spacing;
        if !(-0.5..(n as f64 - 0.5)).contains(&v) {
            return Err(bad());
        }
        Ok(v.round().max(0.0) as usize)
    };
    let cols = (0..f * dom.nx)
        .map(|m| idx(dom.x0 + NODE_STEP * m as f64, g.origin_x, w))
        .collect::<Result<Vec<_>, _>>()?;
    let rows = (0..f * dom.ny)
        .map(|m| idx(-(dom.y0 + NODE_STEP * m as f64), g.origin_z, h).map(|r| r * w))
        .collect::<Result<Vec<_>, _>>()?;
    let water = place.water();
    let inv = (f * f) as f64;
    let mut out = vec![0.0f64; dom.nx * dom.ny];
    out.par_chunks_mut(dom.nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let mut cnt = 0usize;
            for &rb in &rows[j * f..(j + 1) * f] {
                for &c in &cols[i * f..(i + 1) * f] {
                    cnt += usize::from(water[rb + c] > 0);
                }
            }
            *o = cnt as f64 / inv;
        }
    });
    Ok(out)
}

fn reflect(i: i64, n: i64) -> usize {
    if n == 1 {
        return 0;
    }
    let period = 2 * (n - 1);
    let m = i.rem_euclid(period);
    (if m < n { m } else { period - m }) as usize
}

/// Отводы оси: для каждого выходного индекса — (источник, вес), ядро сложено по отражению.
fn axis_taps(n: usize, ker: &[f64], r: usize) -> Vec<Vec<(usize, f64)>> {
    (0..n)
        .map(|i| {
            let mut acc = vec![0.0f64; n];
            for (q, k) in ker.iter().enumerate() {
                acc[reflect(i as i64 + q as i64 - r as i64, n as i64)] += k;
            }
            acc.iter()
                .enumerate()
                .filter(|(_, w)| **w != 0.0)
                .map(|(s, w)| (s, *w))
                .collect()
        })
        .collect()
}

/// Гауссово сглаживание (σ в клетках), края — отражение без повтора (numpy `reflect`).
pub fn gauss2d(a: &[f64], w: usize, h: usize, sigma: f64) -> Vec<f64> {
    if sigma <= 0.3 {
        return a.to_vec();
    }
    let r = (3.0 * sigma).ceil() as usize;
    let mut ker: Vec<f64> = (0..=2 * r)
        .map(|q| {
            let d = (q as f64 - r as f64) / sigma;
            (-0.5 * d * d).exp()
        })
        .collect();
    let ks: f64 = ker.iter().sum();
    ker.iter_mut().for_each(|k| *k /= ks);
    let tx = axis_taps(w, &ker, r);
    let ty = axis_taps(h, &ker, r);
    let mut tmp = vec![0.0f64; w * h];
    tmp.par_chunks_mut(w)
        .zip(a.par_chunks(w))
        .for_each(|(o, src)| {
            for (v, taps) in o.iter_mut().zip(&tx) {
                let mut s = 0.0;
                for (k, wt) in taps {
                    s += wt * src[*k];
                }
                *v = s;
            }
        });
    let mut out = vec![0.0f64; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(j, o)| {
        for (i, v) in o.iter_mut().enumerate() {
            let mut s = 0.0;
            for (k, wt) in &ty[j] {
                s += wt * tmp[k * w + i];
            }
            *v = s;
        }
    });
    out
}

/// `z_i` по столбцам (`AirZiTerrain.columns`): `z_i_ref + α·(h̃ − h_ref)`, не ниже `hc + zi_min`.
pub fn zi_columns(
    hc: &[f64],
    nx: usize,
    ny: usize,
    dx: f64,
    z_i_ref: f64,
    h_ref: f64,
    cfg: &ZiCfg,
) -> Vec<f32> {
    if z_i_ref.is_nan() || hc.len() != nx * ny || hc.is_empty() {
        return Vec::new();
    }
    if cfg.alpha == 0.0 {
        return vec![z_i_ref as f32; nx * ny];
    }
    let hs = gauss2d(hc, nx, ny, cfg.smooth_m / dx);
    let mut out = vec![0.0f32; nx * ny];
    out.par_iter_mut()
        .zip(hs.par_iter().zip(hc.par_iter()))
        .for_each(|(o, (s, h))| {
            *o = (z_i_ref + cfg.alpha * (s - h_ref)).max(h + cfg.zi_min) as f32;
        });
    out
}

/// Вход области из растров места: сетка, `gam`, `z_i`, `z_i_col` поверх `weather_core`.
pub fn build_domain_input(
    place: &Place,
    sh: &SurfaceHeatCfg,
    zi: &ZiCfg,
    dom: &Domain,
    day: &Day,
) -> Result<DomainInput, Error> {
    let hc = block_mean(place, dom)?;
    let dx = dom.dx;
    let dz = if dx >= 200.0 { 105.0 } else { dx / 2.0 };
    let lo = hc.iter().copied().fold(f64::INFINITY, f64::min);
    let hi = hc.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let z_bot = (lo / dz).floor() * dz - dz;
    let mut nz = ((hi + TOP_ABOVE - z_bot) / dz).ceil() as usize;
    nz += nz % 2;
    let z_i = day.z_i;
    let z_i_col = zi_columns(&hc, dom.nx, dom.ny, dx, z_i, day.h_v * 1000.0, zi);
    let cells = cell_surface(place, dom, sh)?;
    let z0_map = cell_z0(&cells, sh);
    let (hc_type, cut) = cut_level(place, dom, nz, dz, z_bot)?;
    let mut inp = DomainInput {
        dom: *dom,
        nz,
        dz,
        z_bot,
        hc,
        hc_type,
        cut: Some(cut),
        gam: Vec::new(),
        z_i,
        z_i_col,
        z0_map,
        cells,
    };
    inp.gam = (0..nz + 2).map(|k| day.gamma(inp.zc(k))).collect();
    Ok(inp)
}
