//! Механизм G: вечерний сток (AP-18 `drainage.py`): модель Прандтля на склонах (с замыканием по
//! потоку), накопление расхода D8 вниз по сглаженному рельефу и гидравлический слой в долинах;
//! вес G — сток против фона. Эталон — `AirPhase.{drainage, prandtl, local_relief}`.
//!
//! Выхолаживание — поток тепла игры (`AirCase.heat < 0`). Результат — плоскости `CI_G*` ([`Drainage`])
//! и числа ([`GDiag`]); [`apply`] вносит вес G и `Δθ` в [`Prepared`] (классификатор берёт их
//! оттуда же, откуда брал бы при [`super::prepare::PhaseCase::g`]).
//!
//! Проходы по столбцам независимы — rayon по строкам; накопление расхода D8 идёт по убыванию
//! высоты и зависит от порядка — последовательно (n² столбцов, `O(n² log n²)`), порядок сложений
//! фиксирован, результат не зависит от числа потоков.
use super::config::GCfg;
use super::linear::u_prof;
use super::prepare::{GRAV, Prepared, RHO_CP, THETA0, gauss_kernel, gauss2, grad, percentile, r32};
use rayon::prelude::*;
use std::f64::consts::PI;

/// Профиль Прандтля склона: `l = √(2K/(N sin α))`, `Δθ = |H| l/(ρc_p K) ≤ Δθ_max`,
/// `u_s = Δθ g/(θ0 N)` (`u_max = e^{−π/4} sin(π/4)·u_s ≤ u_max_ms`); `θ′ = −Δθ e^{−n/l} cos(n/l)`,
/// `u = u_s e^{−n/l} sin(n/l)` вниз по склону.
#[derive(Clone, Copy, Debug)]
pub struct Prandtl {
    /// Масштаб `l`, м.
    pub l: f64,
    /// Перепад `Δθ`, К.
    pub dth: f64,
    /// `u_s`, м/с.
    pub us: f64,
    /// Максимум скорости `e^{−π/4} sin(π/4)·u_s`, м/с.
    pub umax: f64,
    /// Высота максимума `πl/4`, м.
    pub nj: f64,
    /// Расход на единицу длины склона `½ u_s l`, м²/с.
    pub q: f64,
}

/// Значение `e^{−π/4}·sin(π/4)` — доля `u_s` в максимуме профиля.
#[inline]
fn peak() -> f64 {
    (-PI / 4.0).exp() * (PI / 4.0).sin()
}

/// Модель Прандтля (`AirPhase.prandtl`): `sin_a` — синус угла склона, `nbv` — N, `h_cool` ≤ 0 —
/// поток тепла выхолаживания, Вт/м².
pub fn prandtl(g: &GCfg, sin_a: f64, nbv: f64, h_cool: f64) -> Prandtl {
    let s = sin_a.max(g.sin_min);
    let l = (2.0 * g.k_m2s / (nbv * s)).sqrt();
    let mut dt = (h_cool.abs() * l / (RHO_CP * g.k_m2s)).min(g.dth_max_k);
    let pk = peak();
    let u = (dt * GRAV / (THETA0 * nbv)).min(g.u_max_ms / pk);
    dt = u * THETA0 * nbv / GRAV;
    Prandtl {
        l,
        dth: dt,
        us: u,
        umax: pk * u,
        nj: PI / 4.0 * l,
        q: 0.5 * u * l,
    }
}

/// Местный перепад `max − min` в квадрате `(2r + 1)²` (край — ближайшая клетка, scipy `nearest`).
pub fn local_relief(a: &[f64], nx: usize, ny: usize, r: usize) -> Vec<f64> {
    let r = r as i64;
    let mut mx = vec![0.0; a.len()];
    let mut mn = vec![0.0; a.len()];
    mx.par_chunks_mut(nx)
        .zip(mn.par_chunks_mut(nx))
        .enumerate()
        .for_each(|(j, (rmx, rmn))| {
            for i in 0..nx {
                let (mut hi, mut lo) = (f64::NEG_INFINITY, f64::INFINITY);
                for q in -r..=r {
                    let v = a[j * nx + (i as i64 + q).clamp(0, nx as i64 - 1) as usize];
                    hi = hi.max(v);
                    lo = lo.min(v);
                }
                rmx[i] = hi;
                rmn[i] = lo;
            }
        });
    let mut out = vec![0.0; a.len()];
    out.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let (mut hi, mut lo) = (f64::NEG_INFINITY, f64::INFINITY);
            for q in -r..=r {
                let jj = (j as i64 + q).clamp(0, ny as i64 - 1) as usize;
                hi = hi.max(mx[jj * nx + i]);
                lo = lo.min(mn[jj * nx + i]);
            }
            *o = hi - lo;
        }
    });
    out
}

/// Числа стока (`AirPhase.drainage` → diag, `stats.g`).
#[derive(Clone, Copy, Debug, Default)]
pub struct GDiag {
    /// Медианное `Δθ` склонов, К.
    pub dth_c: f64,
    /// Средний поток тепла по области, Вт/м².
    pub heat_mean: f64,
    /// Медиана максимума скорости на склонах, м/с.
    pub umax_med: f64,
    /// Медиана `l`, м.
    pub l_med: f64,
    /// Доля столбцов с гидравлическим слоем.
    pub layer_frac: f64,
    /// Медиана глубины слоя, м.
    pub d_layer_med: f64,
    /// Медиана скорости слоя, м/с.
    pub uc_layer_med: f64,
    /// Средний вес G.
    pub w_mean: f64,
    /// Доля столбцов с весом G ≥ `freeze_w`.
    pub w_ge_frac: f64,
}

/// Плоскости стока (`CI_G*`), `[j·nx + i]`.
#[derive(Clone, Debug)]
pub struct Drainage {
    /// Масштаб Прандтля `l`.
    pub gl: Vec<f64>,
    /// `Δθ` Прандтля.
    pub gdth: Vec<f64>,
    /// `u_s` на склоне (0, если склон положе `sin_min`).
    pub gus: Vec<f64>,
    /// 1 — склон (sin α ≥ `sin_min`).
    pub gon: Vec<f64>,
    /// 1 — гидравлический слой (глубина больше `top_l·l`).
    pub glay: Vec<f64>,
    /// Глубина слоя `d`, м.
    pub gd: Vec<f64>,
    /// Скорость слоя `u_c`, м/с.
    pub guc: Vec<f64>,
    /// Направление стока (единичный вектор): D8 в слое, иначе вниз по склону.
    pub gdx: Vec<f64>,
    pub gdy: Vec<f64>,
    /// Вес G.
    pub gw: Vec<f64>,
    pub diag: GDiag,
}

/// Медиана непустого списка (`AirPhase.median`).
fn median(a: &[f64]) -> f64 {
    percentile(a, 50.0)
}

/// Сток G по столбцам. `heat` — поток тепла игры (`AirCase.heat`, `ny·nx`); пусто — G нет. `None` —
/// G не включён (среднее тепло больше порога, нет выхолаживания или N ≤ `n_min`).
pub fn drainage(p: &Prepared, heat: &[f64]) -> Option<Drainage> {
    if heat.is_empty() {
        return None;
    }
    let cfg = &p.cfg;
    let gc = &cfg.g;
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let mut mh = 0.0;
    let mut any_cool = false;
    for &v in heat {
        mh += v / n2 as f64;
        any_cool = any_cool || v <= 0.0;
    }
    let nbv = p.n_bv;
    if !(mh <= gc.mean_heat_max_wm2 && nbv > gc.n_min && any_cool) {
        return None;
    }
    let cl = &cfg.classifier;
    let hs = gauss2(
        &p.cols.hc,
        nx,
        ny,
        &gauss_kernel(gc.smooth_cells, cl.smooth_truncate, cl.smooth_min_cells),
    );
    let (grx, gry) = grad(&hs, nx, ny, p.dx);
    let pk = peak();
    let mut l = vec![0.0; n2];
    let mut dth = vec![0.0; n2];
    let mut us = vec![0.0; n2];
    let mut sina = vec![0.0; n2];
    let mut qc = vec![0.0; n2];
    let mut on = vec![0.0; n2];
    let dx = p.dx;
    l.par_iter_mut()
        .zip(dth.par_iter_mut())
        .zip(us.par_iter_mut())
        .zip(sina.par_iter_mut())
        .zip(qc.par_iter_mut())
        .zip(on.par_iter_mut())
        .enumerate()
        .for_each(|(c, (((((lo, dto), uo), so), qo), oo))| {
            let gm = (grx[c] * grx[c] + gry[c] * gry[c]).sqrt();
            let sa = gm / (1.0 + gm * gm).sqrt();
            let pr = prandtl(gc, sa, nbv, heat[c].min(0.0));
            let o = sa >= gc.sin_min;
            *lo = pr.l;
            *dto = pr.dth;
            *uo = if o { pr.us } else { 0.0 };
            *so = sa;
            *oo = f64::from(u8::from(o));
            *qo = if heat[c] <= 0.0 {
                0.5 * *uo * pr.l
            } else {
                0.0
            };
        });
    let dths_on: Vec<f64> = (0..n2).filter(|&c| on[c] > 0.5).map(|c| dth[c]).collect();
    // D8: каждая клетка отдаёт накопленный расход соседу с наибольшим уклоном вниз (по убыванию высоты)
    let mut order: Vec<usize> = (0..n2).collect();
    order.sort_by(|&a, &b| {
        hs[b]
            .partial_cmp(&hs[a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.cmp(&b))
    });
    let mut big_q: Vec<f64> = qc.iter().map(|&q| q * dx).collect();
    let mut ex8 = vec![0.0; n2];
    let mut ey8 = vec![0.0; n2];
    for &c in &order {
        let (j, i) = ((c / nx) as i64, (c % nx) as i64);
        let mut best = 0.0;
        let mut bn: Option<(i64, i64)> = None;
        for dj in -1i64..=1 {
            for di in -1i64..=1 {
                if dj == 0 && di == 0 {
                    continue;
                }
                let (jj, ii) = (j + dj, i + di);
                if jj < 0 || jj >= ny as i64 || ii < 0 || ii >= nx as i64 {
                    continue;
                }
                let sl = (hs[c] - hs[jj as usize * nx + ii as usize])
                    / (dx * ((dj * dj + di * di) as f64).sqrt());
                if sl > best {
                    best = sl;
                    bn = Some((jj, ii));
                }
            }
        }
        if let Some((bj, bi)) = bn {
            big_q[bj as usize * nx + bi as usize] += big_q[c];
            let rr = (((bj - j) * (bj - j) + (bi - i) * (bi - i)) as f64).sqrt();
            ex8[c] = (bi - i) as f64 / rr;
            ey8[c] = (bj - j) as f64 / rr;
        }
    }
    let dth_c = if dths_on.is_empty() {
        gc.dth_max_k
    } else {
        median(&dths_on)
    };
    let gp = GRAV * dth_c / (2.0 * THETA0);
    let cd = gc.c_d;
    let relief = local_relief(
        &p.cols.hc,
        nx,
        ny,
        ((gc.relief_r_m / dx).round() as usize).max(1),
    );
    let (d_max, topl, w_dec, zg_min, umax) = (
        gc.d_max_m,
        cfg.mech.g_top_l,
        gc.w_dec,
        gc.zg_min_m,
        gc.u_max_ms,
    );
    let mut gd = vec![0.0; n2];
    let mut guc = vec![0.0; n2];
    let mut glay = vec![0.0; n2];
    let mut gdx = vec![0.0; n2];
    let mut gdy = vec![0.0; n2];
    let mut gw = vec![0.0; n2];
    gd.par_iter_mut()
        .zip(guc.par_iter_mut())
        .zip(glay.par_iter_mut())
        .zip(gdx.par_iter_mut())
        .zip(gdy.par_iter_mut())
        .zip(gw.par_iter_mut())
        .enumerate()
        .for_each(|(c, (((((dd, ucc), lay), xo), yo), wo))| {
            let sf = sina[c].max(gc.sin_floor);
            let mut d = (big_q[c] / dx).powf(2.0 / 3.0) * (cd / (gp * sf)).powf(1.0 / 3.0);
            let dcap = (0.5 * relief[c]).min(d_max);
            d = d.min(dcap.max(1.0));
            let mut uc = (gp * d * sf / cd).sqrt().min(big_q[c] / (d * dx).max(1e-9));
            uc = uc.min(umax);
            let layer = d > topl * l[c];
            let gm = (grx[c] * grx[c] + gry[c] * gry[c]).sqrt();
            let (dxn, dyn_) = if gm > 0.0 {
                (-grx[c] / gm.max(1e-12), -gry[c] / gm.max(1e-12))
            } else {
                (0.0, 0.0)
            };
            let ug = if layer { uc } else { pk * us[c] };
            let zg = if layer { 0.5 * d } else { PI / 4.0 * l[c] };
            let ubg = u_prof(p, zg.max(zg_min));
            let mut w = 1.0
                / (1.0 + (-(ug.max(1e-6).ln() - ubg.max(1e-6).ln()) / 10f64.ln() / w_dec).exp());
            if !(heat[c] <= 0.0 && (on[c] > 0.5 || layer)) {
                w = 0.0;
            }
            *dd = d;
            *ucc = uc;
            *lay = f64::from(u8::from(layer));
            *xo = if layer { ex8[c] } else { dxn };
            *yo = if layer { ey8[c] } else { dyn_ };
            *wo = w;
        });
    // числа стока — последовательно, порядок как в GDScript
    let (mut st_umax, mut st_l, mut st_d, mut st_uc) = (vec![], vec![], vec![], vec![]);
    let (mut nlayer, mut wsum, mut wge) = (0usize, 0.0, 0usize);
    for c in 0..n2 {
        if on[c] > 0.5 {
            st_umax.push(pk * us[c]);
            st_l.push(l[c]);
        }
        if glay[c] > 0.5 {
            nlayer += 1;
            st_d.push(gd[c]);
            st_uc.push(guc[c]);
        }
        wsum += gw[c] / n2 as f64;
        wge += usize::from(gw[c] >= cl.freeze_w);
    }
    let med = |a: &[f64]| if a.is_empty() { 0.0 } else { median(a) };
    let diag = GDiag {
        dth_c,
        heat_mean: mh,
        umax_med: med(&st_umax),
        l_med: med(&st_l),
        layer_frac: nlayer as f64 / n2 as f64,
        d_layer_med: med(&st_d),
        uc_layer_med: med(&st_uc),
        w_mean: wsum,
        w_ge_frac: wge as f64 / n2 as f64,
    };
    Some(Drainage {
        gl: l,
        gdth: dth,
        gus: us,
        gon: on,
        glay,
        gd,
        guc,
        gdx,
        gdy,
        gw,
        diag,
    })
}

/// Вносит сток в подготовку: вес G (плоскость `CI_GW`), включение `P_GACT` и `Δθ` слоя `P_GDTHC`
/// (как `PhaseCase.g = Some(GInput { dth_c, weight })` при [`super::prepare::prepare`]).
pub fn apply(p: &mut Prepared, g: &Drainage) {
    p.cols.gw.clone_from(&g.gw);
    p.prm.gact = true;
    p.prm.gdthc = r32(g.diag.dth_c);
}
