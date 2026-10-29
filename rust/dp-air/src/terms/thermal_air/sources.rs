//! Параметры источников (`_src_band` GD) и `fill`: термик источника — точка, потолок, сила, кольцо,
//! радиус, редкий «очень сильный».
use super::{CORE_FLUX, K_ALLEN, Shape, ZI_MIN, allen_r2, gclamp, gmax, gmin, wstar};
use crate::compat::rng::Pcg32;
use crate::field::wind_field::Field;
use std::collections::HashMap;

pub(super) struct SrcIn<'a> {
    pub f: &'a Field,
    pub shape: &'a Shape,
    pub chosen: &'a [usize],
    pub picked: &'a HashMap<usize, [f32; 2]>,
    pub hcs: &'a [f32],
    pub k1s: &'a [u32],
    pub s_top: &'a [f32],
    pub c_zl: &'a [f32],
    pub cb: f64,
    pub s_zi: &'a [f32],
    pub hsum: &'a [f64],
    pub m_i: &'a [f64],
    pub o_i: &'a [f64],
    pub a_i: &'a [f64],
    pub ring_int: f64,
    pub height_fn: Option<&'a (dyn Fn(f64, f64) -> f64 + Sync)>,
}

pub(super) struct SrcOut {
    pub pos: Vec<[f32; 3]>,
    pub top: Vec<f32>,
    pub depth: Vec<f32>,
    pub wstar: Vec<f32>,
    pub flux: Vec<f32>,
    pub area: Vec<f32>,
    pub radius: Vec<f32>,
    pub w0: Vec<f32>,
    pub carried: Vec<f32>,
    pub net: Vec<f32>,
    pub ring: Vec<f32>,
    pub drift: Vec<[f32; 2]>,
}

/// Источники `[lo, hi)`.
pub(super) fn src_band(c: &SrcIn, lo: usize, hi: usize) -> SrcOut {
    let g = *c.f.grid();
    let (nx, nz) = (g.nx, g.nz);
    let nxy = nx * g.ny;
    let (u, v) = (c.f.raw_u(), c.f.raw_v());
    let mut o = SrcOut {
        pos: Vec::with_capacity(hi - lo),
        top: Vec::with_capacity(hi - lo),
        depth: Vec::with_capacity(hi - lo),
        wstar: Vec::with_capacity(hi - lo),
        flux: Vec::with_capacity(hi - lo),
        area: Vec::with_capacity(hi - lo),
        radius: Vec::with_capacity(hi - lo),
        w0: Vec::with_capacity(hi - lo),
        carried: Vec::with_capacity(hi - lo),
        net: Vec::with_capacity(hi - lo),
        ring: Vec::with_capacity(hi - lo),
        drift: Vec::with_capacity(hi - lo),
    };
    for s in lo..hi {
        let col = c.chosen[s];
        let (i, j) = (col % nx, col / nx);
        let hc = c.hcs[col] as f64;
        let mut p = [
            (g.x0 + (i as f64 + 0.5) * g.dx) as f32,
            (-(g.y0 + (j as f64 + 0.5) * g.dx)) as f32,
        ];
        if let Some(q) = c.picked.get(&col) {
            p = *q;
        }
        let y = match c.height_fn {
            Some(h) => h(p[0] as f64, p[1] as f64),
            None => hc,
        };
        o.pos.push([p[0], y as f32, p[1]]);
        o.top.push(c.s_top[col]);
        let d_top = gmax(gmin(c.s_top[col] as f64, c.cb) - hc, ZI_MIN);
        o.depth.push(d_top as f32);
        let ws = wstar(c.hsum[s] / gmax(c.a_i[s], 1.0), c.s_zi[col] as f64, hc) as f32;
        o.wstar.push(ws);
        o.flux.push(c.m_i[s] as f32);
        o.area.push(c.a_i[s] as f32);
        let radius = allen_r2(1.0, c.c_zl[col] as f64) as f32;
        o.radius.push(radius);
        // d_top в расчёте kbar — не округлённый (локальная переменная GD)
        let kbar = CORE_FLUX
            * std::f64::consts::PI
            * radius as f64
            * radius as f64
            * c.shape.mean(d_top)
            * c.shape.life_mean;
        let w0 = (K_ALLEN * ws as f64) as f32;
        o.w0.push(w0);
        let carried = (w0 as f64 * kbar) as f32;
        o.carried.push(carried);
        // Чистый поток пузыря — организованная доля того, что несут ядра; подсеточная доля
        // возвращается кольцом у самого пузыря: ρ = (1 − O/M)·e⁻¹/|кольцо|.
        let org = gclamp(c.o_i[s] / gmax(c.m_i[s], 1.0e-9), 0.0, 1.0);
        o.net.push((carried as f64 * org) as f32);
        o.ring.push(((1.0 - org) * CORE_FLUX / c.ring_int) as f32);
        // снос: средний ветер столба источника от земли до потолка
        let k1 = c.k1s[col] as usize;
        let (mut su, mut sv, mut n) = (0.0f64, 0.0f64, 0usize);
        for k in k1..nz {
            let zk = g.z_bot + (k as f64 + 0.5) * g.dz;
            if zk > hc + d_top {
                break;
            }
            su += u[k * nxy + col] as f64;
            sv += v[k * nxy + col] as f64;
            n += 1;
        }
        o.drift.push(if n > 0 {
            [(su / n as f64) as f32, (-sv / n as f64) as f32]
        } else {
            [0.0, 0.0]
        });
    }
    o
}

/// Погода для `fill` (`thermal_radius_m[1]`, `thermal_extreme_chance`, `thermal_extreme_ms`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FillWeather {
    /// Верхняя граница радиуса термика пресета `thermal_radius_m[1]`, м.
    pub radius_max: f64,
    /// Доля «очень сильных» термиков.
    pub extreme_chance: f64,
    /// Диапазон силы «очень сильного», м/с (`None` — нет, как `ext.size() != 2`).
    pub extreme_ms: Option<[f64; 2]>,
}

/// Результат `fill`: поля `AtmoThermal`, которые задаёт источник.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fill {
    /// −1 — столб ниже `ZI_MIN` (термика нет), 0 — обычный, 1 — очень сильный.
    pub kind: i32,
    pub src: [f32; 3],
    /// Потолок `min(частица, кромка)`, м над морем.
    pub top: f64,
    pub strength: f64,
    pub ring: f64,
    pub radius: f64,
}

impl super::AirThermals {
    /// Термик источника `s`: точка, потолок `min(top, cb)`, сила `w0`, кольцо, радиус (Аллен по толщине
    /// слоя); редкий очень сильный — как у клетки (радиус не меньше пресета). Порядок вызовов
    /// `rng` — буквально как `fill` GD: `randf` всегда (после проверки столба), потом
    /// `randf_range` силы только у очень сильного.
    pub fn fill(&self, s: usize, rng: &mut Pcg32, w: &FillWeather, cb: f64) -> Fill {
        let src = self.pos[s];
        let top = gmin(self.top[s] as f64, cb);
        let mut out = Fill {
            kind: 0,
            src,
            top,
            strength: 0.0,
            ring: 0.0,
            radius: 0.0,
        };
        if top - (src[1] as f64) < ZI_MIN {
            out.kind = -1;
            return out;
        }
        out.strength = self.w0[s] as f64;
        out.ring = self.ring[s] as f64;
        out.radius = self.radius[s] as f64;
        // `rng.randf() < chance and ext.size() == 2`: randf вызывается всегда
        let r = rng.randf() as f64;
        if r < w.extreme_chance
            && let Some(ext) = w.extreme_ms
        {
            out.strength = rng.randf_range(ext[0] as f32, ext[1] as f32) as f64;
            out.radius = gmax(out.radius, w.radius_max);
            out.kind = 1;
        }
        out
    }
}
