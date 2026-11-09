//! Подготовка фаз по столбцам (`AirPhase.prepare` без мод линейной теории и стока G): числа случая
//! (N, Fr, `U_sat/N`, `H_c`, слои D), огибающая срыва `h_eff`, эффективный рельеф `T`, уклоны,
//! ось фазы C, случайные веса P15, карта ω, ядро сглаживания весов.
//!
//! ## Интерфейс для RW-6l/6m
//! [`prepare`]`(`[`PhaseCase`]`, `[`PhaseCfg`]`) -> `[`Prepared`]. Вход — срезы того, что в эталоне
//! лежит в `AirCase` после `prepare()` (u*, `U_sat`, h_bl, w*, нагрев) и в погоде дня; их даёт
//! `case_prepare.rs` (RW-6d) и `weather_core`. Выход:
//! - `Prepared.cols` — плоскости 2D-входа ядер (`CI_*`) в SoA, `[j·nx + i]`, f64;
//! - `Prepared.prm` — скаляры ядер, округлённые до f32 как слоты `prm` эталона (`P_*`): механизмы
//!   A/B/D/H (RW-6l) и F/G/сборка (RW-6m) читают их же, чтобы совпасть побитно с `AirPhaseCpu`;
//! - `Prepared.lev`, `.zl` (слои Лапласа), `.hcd`, `.gk` — высоты линейной теории, слои D, `H_c`,
//!   ядро сглаживания весов.
//!
//! Не здесь: моды линейной теории `modes` (RW-6l: из `cols.t` и `prm`) и сток G
//! (`drainage`, RW-6m): веса G классификатор берёт готовой плоскостью [`GInput`] (`None` — G нет,
//! `P_GACT = 0`); 6m пишет в [`GInput`] остальные плоскости `CI_G*`.
use super::config::{DStrongAxis, PhaseCfg};
use rayon::prelude::*;
use std::f64::consts::PI;

/// Число фаз: A, B, C, D, F, G, H.
pub const K: usize = 7;
/// Индексы фаз в `weights[k·n² + c]`.
pub const PH_A: usize = 0;
pub const PH_B: usize = 1;
pub const PH_C: usize = 2;
pub const PH_D: usize = 3;
pub const PH_F: usize = 4;
pub const PH_G: usize = 5;
pub const PH_H: usize = 6;
/// Названия фаз по индексам.
pub const PHASES: [&str; K] = ["A", "B", "C", "D", "F", "G", "H"];

/// `AirCase.G`, `THETA0`, `KAPPA`, `RHO_CP` (константы решателя).
pub const GRAV: f64 = 9.81;
pub const THETA0: f64 = 300.0;
pub const KAPPA: f64 = 0.4;
pub const RHO_CP: f64 = 1.2 * 1005.0;
/// Наибольшее число слоёв Лапласа (`AirPhase.ZL_MAX`), ядро сглаживания (`GK_MAX`).
pub const ZL_MAX: usize = 16;
pub const GK_MAX: usize = 17;

/// Округление до f32 и обратно: как чтение слота `prm` (массив f32) в эталоне.
#[inline]
pub(crate) fn r32(x: f64) -> f64 {
    x as f32 as f64
}

/// Вес G от вечернего стока (результат `drainage`, RW-6m).
#[derive(Clone, Copy, Debug)]
pub struct GInput<'a> {
    /// Медианное Δθ склонов (`g.dth_c`), К.
    pub dth_c: f64,
    /// Вес G по столбцам (`CI_GW`), `ny·nx`.
    pub weight: &'a [f64],
}

/// Вход фаз: то, что `AirCase` и погода дня дают `AirPhase.prepare`. Массивы по столбцам —
/// `ny·nx`, `[j·nx + i]`, `j` растёт на север (как `hc`).
#[derive(Clone, Copy, Debug)]
pub struct PhaseCase<'a> {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub dx: f64,
    pub dz: f64,
    /// Низ сетки (центр клетки `k`: `z_bot + (k − ½)·dz`), м.
    pub z_bot: f64,
    /// Единичный вектор «куда дует» (`AirCase.ex/ey`; штиль — 0).
    pub ex: f64,
    pub ey: f64,
    /// Скорость на `z_sat` (`AirCase.u_a`), м/с.
    pub u_a: f64,
    /// `z_sat` (`AirCase.prm[12]`, f32), м.
    pub z_sat: f64,
    pub alpha: f64,
    /// Эффективная шероховатость области, м.
    pub z0: f64,
    /// u* замыкания, м/с.
    pub ustar: f64,
    /// `AirCase.p.tau_cool`, с.
    pub tau_cool: f64,
    /// Приток на 10 м, м/с (`AirCase.u10`).
    pub u10: f64,
    /// Скалярный `z_i` (м над морем; `NaN` — нет конвекции).
    pub z_i: f64,
    pub hc: &'a [f64],
    /// Граница воздуха (PT7 v1, `AirCaseRs::hc_type`; без долей — `hc`). Только плумбинг: логику
    /// фаз («воздух» = по ней) меняет PT-10.
    pub hc_type: &'a [f64],
    /// dθ̄/dz в центрах `nz + 2` уровней.
    pub gam: &'a [f64],
    /// Поток тепла эталона, Вт/м² (пусто — нет нагрева).
    pub heat: &'a [f64],
    /// Поток тепла, как его берёт решение (`AirCase.heat_used`), Вт/м².
    pub heat_used: &'a [f64],
    /// Высота слоя перемешивания (`AirCase.h_bl`), м.
    pub h_bl: &'a [f64],
    /// w* столбцов (`AirCase._wst`), м/с.
    pub wst: &'a [f64],
    /// `z_i` по столбцам (`AirCase.z_i_of`; пусто — везде `z_i`), м над морем.
    pub z_i_col: &'a [f64],
    /// Сток G (`None` — не включён).
    pub g: Option<GInput<'a>>,
}

/// Плоскости 2D-входа ядер (`CI_*`), `[j·nx + i]`. `gw` пуст, если G нет.
#[derive(Clone, Debug, Default)]
pub struct Columns {
    pub hc: Vec<f64>,
    /// Граница воздуха (PT7 v1) столбцов.
    pub hc_type: Vec<f64>,
    /// Огибающая срыва `h_eff`.
    pub heff: Vec<f64>,
    /// Эффективный рельеф `T = max(h_eff, H_c)` (при слоях D) для линейной теории.
    pub t: Vec<f64>,
    /// Уклон `|∇h|`.
    pub s: Vec<f64>,
    pub gx: Vec<f64>,
    pub gy: Vec<f64>,
    /// Поток тепла (0, если нагрева нет), Вт/м².
    pub heat: Vec<f64>,
    /// Кинематический поток `heat_used/ρc_p`, К·м/с (0, если нагрева нет).
    pub hk: Vec<f64>,
    pub hbl: Vec<f64>,
    pub wst: Vec<f64>,
    /// Уклон вдоль ветра `|e·∇h_s|` (ось фазы C).
    pub sal: Vec<f64>,
    /// `z_i` столбца, м над морем.
    pub zi: Vec<f64>,
    pub gw: Vec<f64>,
}

/// Слоты параметров ядер, округлённые до f32 (как `AirPhase.params`).
#[derive(Clone, Debug, Default)]
pub struct Prm {
    pub dx: f64,
    pub dz: f64,
    pub z_bot: f64,
    pub ex: f64,
    pub ey: f64,
    pub usat: f64,
    pub zsat: f64,
    pub alpha: f64,
    pub z0: f64,
    pub fr: f64,
    pub n_eff: f64,
    pub hcd: f64,
    pub nl: usize,
    pub ustar: f64,
    pub heated: bool,
    pub zi: f64,
    pub gamw: f64,
    pub gact: bool,
    pub gdthc: f64,
    pub tau: f64,
    pub wh: f64,
    pub wds: f64,
    pub wd: f64,
    pub full: bool,
    pub d_local: bool,
    pub d_ramp: f64,
    pub c_wms: f64,
    pub c_wdec: f64,
    pub lee_depth: f64,
    pub lee_hlo: f64,
    pub lee_hhi: f64,
    pub lee_steep: f64,
    pub lee_hsk: f64,
    pub zil_c: f64,
    pub w_ef: f64,
    pub fr_inf: f64,
    pub frz_w: f64,
    pub ws_over_u: f64,
    pub cap: f64,
    pub bub_r: f64,
    pub slope_len: f64,
    pub ana_dmin: f64,
    pub ana_dfrac: f64,
    pub uml_n: usize,
    pub uml_min: f64,
    pub sor_omega: f64,
    pub g_topl: f64,
    pub g_memb: f64,
    pub grav: f64,
    pub theta0: f64,
    pub kappa: f64,
    pub uref_min: f64,
    /// Радиус ядра сглаживания весов (`P_GK_R`).
    pub gk_r: usize,
}

/// Результат подготовки: числа случая, плоскости, слоты ядер.
#[derive(Clone, Debug)]
pub struct Prepared {
    pub cfg: PhaseCfg,
    pub nx: usize,
    pub ny: usize,
    pub n2: usize,
    /// Ореол: `NX = nx + 2` и т. д., `N = NX·NY·NZ`.
    pub big_n: usize,
    pub windy: bool,
    pub usat: f64,
    pub u10: f64,
    pub ex: f64,
    pub ey: f64,
    pub dx: f64,
    pub z0: f64,
    /// Показатель профиля притока без округления до f32 (`p.alpha` эталона; `u_prof`).
    pub alpha: f64,
    pub hmin: f64,
    pub relief: f64,
    /// N над слоем перемешивания (S2), 1/с.
    pub n_bv: f64,
    pub fr: f64,
    /// N для линейной теории (AP-17 `n_effective`).
    pub n_eff: f64,
    /// Опорный `z_i`.
    pub zi: f64,
    /// Градиент θ выше `z_i` (θ0·N²/g), К/м.
    pub gamw: f64,
    /// `z_i` над низом рельефа, м (−1 — нет).
    pub zi_agl: f64,
    /// 5-й процентиль рельефа («равнина»).
    pub base: f64,
    /// Разделяющая линия тока `H_c`.
    pub hcd: f64,
    /// Высоты слоёв Лапласа, м над морем.
    pub zl: Vec<f64>,
    /// Высоты линейной теории над рельефом, м.
    pub lev: Vec<f64>,
    pub b_fr: f64,
    pub b_u: f64,
    /// ω карты фаз (однородна по области).
    pub omega: f64,
    pub w_h: f64,
    pub w_ds: f64,
    pub w_d: f64,
    pub u_over_n: f64,
    /// Вся область — механизм (H + сильное D ≥ `freeze_w`).
    pub full: bool,
    pub heated: bool,
    pub shadow_frac: f64,
    pub cols: Columns,
    /// Ядро сглаживания весов (σ = `smooth_cells`).
    pub gk: Vec<f64>,
    pub prm: Prm,
}

impl Prepared {
    /// Карта ω (`ny·nx`, f32 как `AirPhase.result.omega`): однородна.
    pub fn omega_map(&self) -> Vec<f32> {
        vec![self.omega as f32; self.n2]
    }
}

/// σ((lg x − lg x_c)/w) — граница фазы (`AirPhase.sig_log`).
#[inline]
pub fn sig_log(x: f64, xc: f64, w: f64) -> f64 {
    let lx = x.max(1e-12).ln() / 10f64.ln();
    1.0 / (1.0 + (-(lx - xc.ln() / 10f64.ln()) / w).exp())
}

/// Принадлежность полосе `[lo, hi]` по lg x (`AirPhase.band`).
#[inline]
pub fn band(x: f64, lo: f64, hi: f64, w: f64) -> f64 {
    sig_log(x, lo, w) * (1.0 - sig_log(x, hi, w))
}

#[inline]
pub fn smooth01(e0: f64, e1: f64, x: f64) -> f64 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Ядро гаусса σ (клетки), радиус `int(truncate·σ + ½)`; σ ≤ `min_sigma` — `[1]`.
pub fn gauss_kernel(sigma: f64, truncate: f64, min_sigma: f64) -> Vec<f64> {
    if sigma <= min_sigma {
        return vec![1.0];
    }
    let r = (truncate * sigma + 0.5) as i64;
    let mut w = vec![0.0; (2 * r + 1) as usize];
    let mut s = 0.0;
    for q in -r..=r {
        let e = (-0.5 * (q as f64 / sigma).powf(2.0)).exp();
        w[(q + r) as usize] = e;
        s += e;
    }
    for x in &mut w {
        *x /= s;
    }
    w
}

/// Отражение «через полуклетку» (scipy `reflect`: d c b a | a b c d).
#[inline]
pub fn refl(i: i64, n: usize) -> usize {
    let n = n as i64;
    let period = 2 * n;
    let m = i.rem_euclid(period);
    (if m < n { m } else { period - 1 - m }) as usize
}

/// Гаусс 2D (раздельно, отражение), `a` — `ny·nx`.
pub fn gauss2(a: &[f64], nx: usize, ny: usize, ker: &[f64]) -> Vec<f64> {
    let r = (ker.len() / 2) as i64;
    if r == 0 {
        return a.to_vec();
    }
    let mut t = vec![0.0; a.len()];
    t.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let mut s = 0.0;
            for q in -r..=r {
                s += ker[(q + r) as usize] * a[j * nx + refl(i as i64 + q, nx)];
            }
            *o = s;
        }
    });
    let mut o = vec![0.0; a.len()];
    o.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, v) in row.iter_mut().enumerate() {
            let mut s = 0.0;
            for q in -r..=r {
                s += ker[(q + r) as usize] * t[refl(j as i64 + q, ny) * nx + i];
            }
            *v = s;
        }
    });
    o
}

/// Градиент как `numpy.gradient(a, dx)`: центральные разности, на краях односторонние.
pub fn grad(a: &[f64], nx: usize, ny: usize, dx: f64) -> (Vec<f64>, Vec<f64>) {
    let mut gx = vec![0.0; a.len()];
    let mut gy = vec![0.0; a.len()];
    gx.par_chunks_mut(nx)
        .zip(gy.par_chunks_mut(nx))
        .enumerate()
        .for_each(|(j, (rx, ry))| {
            for i in 0..nx {
                let q = j * nx + i;
                rx[i] = if i == 0 {
                    (a[q + 1] - a[q]) / dx
                } else if i == nx - 1 {
                    (a[q] - a[q - 1]) / dx
                } else {
                    (a[q + 1] - a[q - 1]) / (2.0 * dx)
                };
                ry[i] = if j == 0 {
                    (a[q + nx] - a[q]) / dx
                } else if j == ny - 1 {
                    (a[q] - a[q - nx]) / dx
                } else {
                    (a[q + nx] - a[q - nx]) / (2.0 * dx)
                };
            }
        });
    (gx, gy)
}

/// Процентиль (numpy, линейная интерполяция).
pub fn percentile(a: &[f64], pct: f64) -> f64 {
    let mut s = a.to_vec();
    s.sort_by(f64::total_cmp);
    let pos = pct / 100.0 * (s.len() - 1) as f64;
    let i0 = pos.floor() as usize;
    let i1 = (i0 + 1).min(s.len() - 1);
    s[i0] + (pos - i0 as f64) * (s[i1] - s[i0])
}

/// Огибающая срыва `h_eff = max(h, линия тени)` (AP-10, AP-17 `envelope`): проходы Гаусса–Зейделя
/// по ветру до неподвижной точки.
fn envelope(c: &PhaseCase, cfg: &PhaseCfg, windy: bool) -> Vec<f64> {
    let hc = c.hc;
    let mut he = hc.to_vec();
    let ang = cfg.classifier.b_env_angle_deg;
    if !windy || ang <= 0.0 {
        return he;
    }
    let (nx, ny) = (c.nx, c.ny);
    let drop = c.dx * (ang * PI / 180.0).tan();
    let key: Vec<f64> = (0..nx * ny)
        .map(|q| (q % nx) as f64 * c.ex + (q / nx) as f64 * c.ey)
        .collect();
    let mut order: Vec<usize> = (0..nx * ny).collect();
    order.sort_by(|&a, &b| key[a].total_cmp(&key[b]).then(a.cmp(&b)));
    for _ in 0..cfg.classifier.env_max_sweeps {
        let mut changed = false;
        for &q in &order {
            let (i, j) = (q % nx, q / nx);
            let fi = i as f64 - c.ex;
            let fj = j as f64 - c.ey;
            if fi < 0.0 || fi > (nx - 1) as f64 || fj < 0.0 || fj > (ny - 1) as f64 {
                continue;
            }
            let i0 = (fi.floor() as i64).clamp(0, nx as i64 - 2) as usize;
            let j0 = (fj.floor() as i64).clamp(0, ny as i64 - 2) as usize;
            let a = fi - i0 as f64;
            let b = fj - j0 as f64;
            let v = (1.0 - b) * ((1.0 - a) * he[j0 * nx + i0] + a * he[j0 * nx + i0 + 1])
                + b * ((1.0 - a) * he[(j0 + 1) * nx + i0] + a * he[(j0 + 1) * nx + i0 + 1]);
            let nv = hc[q].max(v - drop);
            if nv != he[q] {
                he[q] = nv;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    he
}

/// Числа случая и сборка плоскостей. Ошибка — размеры входа не сходятся.
pub fn prepare(c: &PhaseCase, cfg: &PhaseCfg) -> Result<Prepared, String> {
    let (nx, ny) = (c.nx, c.ny);
    let n2 = nx * ny;
    if nx < 4 || ny < 4 || c.nz < 2 {
        return Err("AirPhase: размеры области (nx, ny ≥ 4, nz ≥ 2)".into());
    }
    let col_ok = |a: &[f64]| a.len() == n2;
    if !col_ok(c.hc)
        || !col_ok(c.hc_type)
        || c.gam.len() != c.nz + 2
        || !col_ok(c.heat_used)
        || !col_ok(c.h_bl)
        || !col_ok(c.wst)
        || !(c.heat.is_empty() || col_ok(c.heat))
        || !(c.z_i_col.is_empty() || col_ok(c.z_i_col))
        || c.g.is_some_and(|g| !col_ok(g.weight))
    {
        return Err("AirPhase: длины входов не сходятся с nx·ny / nz + 2".into());
    }
    let cl = &cfg.classifier;
    let windy = c.u10 > 0.0;
    let hc = c.hc;
    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for &v in hc {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    let relief = hi - lo;
    // ---- N над слоем перемешивания (derive S2)
    let zref = if c.z_i.is_finite() { c.z_i } else { lo };
    let (mut ns, mut cnt) = (0.0, 0usize);
    for k in 1..=c.nz {
        let z = c.z_bot + (k as f64 - 0.5) * c.dz;
        if z >= zref && z <= zref + cl.n_layer_m {
            ns += (GRAV / THETA0 * c.gam[k].max(0.0)).sqrt();
            cnt += 1;
        }
    }
    let n_bv = if cnt > 0 { ns / cnt as f64 } else { 0.0 };
    let fr = if n_bv > 0.0 {
        c.u_a / (n_bv * relief.max(1.0))
    } else {
        cl.fr_inf
    };
    let zi_agl = if c.z_i.is_finite() { c.z_i - lo } else { -1.0 };
    let mut n_eff = n_bv;
    if zi_agl > relief && zi_agl > 0.0 {
        n_eff = n_bv * (relief / zi_agl).min(1.0);
    }
    let zi = if c.z_i.is_finite() {
        c.z_i
    } else {
        c.z_bot - c.dz
    };
    let gamw = THETA0 * n_bv * n_bv / GRAV;
    // ---- D: разделяющая линия тока и слои Лапласа
    let base = percentile(hc, cfg.d.base_pct);
    let mut hcd = base;
    if fr < 1.0 {
        hcd = base + (hi - base) * (1.0 - fr);
    }
    let mut zl = Vec::new();
    if hcd > base + 1.0 {
        let nl = cfg
            .d
            .max_layers
            .min(ZL_MAX)
            .min((((hcd - base) / cfg.d.dz_layer_m).ceil() as usize).max(1));
        for q in 0..nl {
            zl.push(base + (q as f64 + 0.5) * (hcd - base) / nl as f64);
        }
    }
    // ---- ω по карте фаз (AP-18)
    let u10 = c.u10;
    let b_fr = band(fr, cl.omega_fr_lo, cl.omega_fr_hi, cl.omega_w_dec);
    let b_u = band(u10, cl.omega_u10_lo, cl.omega_u10_hi, cl.omega_w_dec);
    let mut omega = 1.0 - (1.0 - cl.omega_band) * b_fr.max(b_u);
    if omega > 1.0 - cl.omega_snap {
        omega = 1.0;
    }
    // ---- случайные веса P15
    let xh = if cl.h_axis_u10 { u10 } else { fr };
    let w_h = 1.0 - sig_log(xh, cl.h_c, cl.h_w_dec);
    let nb = n_bv.max(1e-6);
    let u_over_n = c.u_a / nb;
    let ss = match cl.d_strong_axis {
        DStrongAxis::None => 0.0,
        ax => {
            let xs = match ax {
                DStrongAxis::NcLaw => {
                    cl.d_strong_nc0 * (c.u_a.max(1e-3) / 3.0).powf(cl.d_strong_p) / nb
                }
                DStrongAxis::Fr => fr,
                _ => u_over_n,
            };
            1.0 - sig_log(xs, cl.d_strong_c, cl.d_strong_w_dec)
        }
    };
    let w_ds = (1.0 - w_h) * ss;
    let w_d = (1.0 - w_h) * (1.0 - sig_log(fr, cl.d_fr_c, cl.d_w_dec));
    let full = w_h + w_ds >= cl.freeze_w;
    // ---- нагрев и плоскости
    let heated = c.heat.iter().any(|&v| v != 0.0);
    let (gx, gy) = grad(hc, nx, ny, c.dx);
    let s: Vec<f64> = gx
        .iter()
        .zip(&gy)
        .map(|(&a, &b)| (a * a + b * b).sqrt())
        .collect();
    let heat: Vec<f64> = if heated {
        c.heat.to_vec()
    } else {
        vec![0.0; n2]
    };
    let hk: Vec<f64> = if heated {
        c.heat_used.iter().map(|&v| v / RHO_CP).collect()
    } else {
        vec![0.0; n2]
    };
    let zi_col: Vec<f64> = (0..n2)
        .map(|q| {
            let z = if c.z_i_col.is_empty() {
                c.z_i
            } else {
                c.z_i_col[q]
            };
            if z.is_finite() { z } else { zi }
        })
        .collect();
    let heff = envelope(c, cfg, windy);
    let t: Vec<f64> = heff
        .iter()
        .map(|&h| if zl.is_empty() { h } else { h.max(hcd) })
        .collect();
    // ---- ось фазы C: уклон вдоль ветра сглаженного рельефа
    let ker = gauss_kernel(
        (u_over_n / c.dx).clamp(1.0, cl.c_sigma_max_cells),
        cl.smooth_truncate,
        cl.smooth_min_cells,
    );
    let hs = gauss2(hc, nx, ny, &ker);
    let (sgx, sgy) = grad(&hs, nx, ny, c.dx);
    let sal: Vec<f64> = sgx
        .iter()
        .zip(&sgy)
        .map(|(&a, &b)| (a * c.ex + b * c.ey).abs())
        .collect();
    let mut shadow_frac = 0.0;
    for q in 0..n2 {
        shadow_frac += (if heff[q] > hc[q] + 1.0 { 1.0 } else { 0.0 }) / n2 as f64;
    }
    let mut gk = gauss_kernel(cl.smooth_cells, cl.smooth_truncate, cl.smooth_min_cells);
    if gk.len() > GK_MAX {
        let m = gk.len() / 2;
        gk = gk[m - GK_MAX / 2..=m + GK_MAX / 2].to_vec();
    }
    let lev = cfg.agl_levels_m.clone();
    let m = &cfg.mech;
    let prm = Prm {
        dx: r32(c.dx),
        dz: r32(c.dz),
        z_bot: r32(c.z_bot),
        ex: r32(c.ex),
        ey: r32(c.ey),
        usat: r32(c.u_a),
        zsat: r32(c.z_sat),
        alpha: r32(c.alpha),
        z0: r32(c.z0),
        fr: r32(fr),
        n_eff: r32(n_eff),
        hcd: r32(hcd),
        nl: zl.len(),
        ustar: r32(c.ustar),
        heated,
        zi: r32(zi),
        gamw: r32(gamw),
        gact: c.g.is_some(),
        gdthc: r32(c.g.map_or(0.0, |g| g.dth_c)),
        tau: r32(c.tau_cool),
        wh: r32(w_h),
        wds: r32(w_ds),
        wd: r32(w_d),
        full,
        d_local: cl.d_local,
        d_ramp: r32(cl.d_local_ramp_m),
        c_wms: r32(cl.c_w_ms),
        c_wdec: r32(cl.c_w_dec),
        lee_depth: r32(cl.b_depth_m),
        lee_hlo: r32(cl.b_heat_lo),
        lee_hhi: r32(cl.b_heat_hi),
        lee_steep: r32(cl.b_steep),
        lee_hsk: r32(cl.b_heat_steep_k),
        zil_c: r32(cl.f_zil_c),
        w_ef: r32(cl.f_w_dec),
        fr_inf: r32(cl.fr_inf),
        frz_w: r32(cl.freeze_w),
        ws_over_u: r32(cl.f_wstar_over_usat),
        cap: r32(cfg.a.cap_frac),
        bub_r: r32(m.bubble_reverse),
        slope_len: r32(m.slope_len_m),
        ana_dmin: r32(m.ana_delta_min_m),
        ana_dfrac: r32(m.ana_delta_frac),
        uml_n: m.uml_levels.min(lev.len()),
        uml_min: r32(m.uml_min_ms),
        sor_omega: r32(cfg.d.sor_omega),
        g_topl: r32(m.g_top_l),
        g_memb: r32(m.g_member_frac),
        grav: r32(GRAV),
        theta0: r32(THETA0),
        kappa: r32(KAPPA),
        uref_min: r32(cfg.a.uref_min),
        gk_r: gk.len() / 2,
    };
    let cols = Columns {
        hc: hc.to_vec(),
        hc_type: c.hc_type.to_vec(),
        heff,
        t,
        s,
        gx,
        gy,
        heat,
        hk,
        hbl: c.h_bl.to_vec(),
        wst: c.wst.to_vec(),
        sal,
        zi: zi_col,
        gw: c.g.map_or_else(Vec::new, |g| g.weight.to_vec()),
    };
    Ok(Prepared {
        cfg: cfg.clone(),
        nx,
        ny,
        n2,
        big_n: (nx + 2) * (ny + 2) * (c.nz + 2),
        windy,
        usat: c.u_a,
        u10,
        ex: c.ex,
        ey: c.ey,
        dx: c.dx,
        z0: c.z0,
        alpha: c.alpha,
        hmin: lo,
        relief,
        n_bv,
        fr,
        n_eff,
        zi,
        gamw,
        zi_agl,
        base,
        hcd,
        zl,
        lev,
        b_fr,
        b_u,
        omega,
        w_h,
        w_ds,
        w_d,
        u_over_n,
        full,
        heated,
        shadow_frac,
        cols,
        gk,
        prm,
    })
}
