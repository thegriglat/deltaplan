//! Сборка случая решателя в памяти (RW-6e): перенос того, что эталонный GPU делает до первой
//! итерации Пикара, — ядра `air_picard.glsl:K_SETUP` и подготовки `AirPicardJob` из плоскостей
//! `AirCase.prepare` (RW-6d). Из [`PreparedPlanes`] получается [`picard_rs::case::Case`] без
//! эталона (R6 v3: `solution`, `history`, `sol_*` нет — решение даёт `dev = None`).
//!
//! ## Внутренний интерфейс для RW-6j
//! ```text
//! let planes = heat_case.prepare()?;                         // RW-6d
//! let case = build_solver_case(&planes, &heat_case.p, &SolverCfg::new(heat_case.u10))?;
//! let solved = picard_rs::api::solve(&case, &opts)?;         // тот же Case годится и для mech
//! ```
//!
//! ## Что в `Case`
//! Массивы R1 (раскладка `(k·ny_h + j)·nx_h + i`, типы — `f32`): `cell`, `tu`, `tv`, `tw` из
//! `tcode = cell + 4·tu + 16·tv + 64·tw`; `ubg`, `vbg` — фон на гранях до жёсткой границы;
//! `sp_u`, `sp_w`, `spc` — губки; `nu_bg` — K_b (Троен–Март / Холтслаг–Бовилль по столбцу); `Q`;
//! `Kx`, `Ky`, `Kz` — проводимости проекции SIMPLEC; `fixed_u/v` и `b_u/v` — значения и индексы
//! граней типа 2; `gam`, `cplz` — уровни; `lam` — плоскость λ; `hc` — рельеф без ореола.
//! Арифметика — `f32` в порядке GLSL (`powf` вместо GPU-`pow`, без явного fma): на тех же входах
//! совпадает с буферами эталона до последнего знака там, где нет `pow`/`sqrt`, иначе — единицы ulp
//! (достигнутое — `tests/case_build.rs`).
//!
//! ## Границы модели
//! - `C_d` стенки решатель берёт по столбцу (W11 v4): `Case.cd_col` — плоскость 12 `PreparedPlanes`
//!   с ореолом, как `air_picard.glsl:393`; `Case.cd` (одно на область) остаётся для файлов без карты.
//!   `u*` по столбцу (плоскость 13) входит в `nu_bg`.
//! - Индексы граней `b_u/b_v` хранятся как `f32` (R1): область ≤ 2^24 клеток с ореолом.
//! - Грани `w` типа 2 и фон `w` (`ubw`, `thb`, `thbd`) в `Case` не входят: у области они нулевые.
//! - Окно клипмапа (`P_NEST = 1`: фон и граница от родителя) не собирается — RW-6n.
//!
//! Стиль: плоские массивы SoA, обход подряд, `rayon` по плоскостям `k`, без промежуточных `Vec`
//! в горячем пути (кроме выходных массивов и `u8`-кода типов).
use super::case_prepare::{COL_CD, CaseParams, NCOL, NLEV, NPRM, P_NEST, PreparedPlanes};
use crate::Error;
use picard_rs::case::{Case, CaseParams as RsCaseParams, CaseParts, Criterion, Params};
use rayon::prelude::*;
use std::collections::HashMap;

// Слоты `prm` (air_picard.glsl).
const P_IDTU: usize = 2;
const P_UAX: usize = 9;
const P_UAY: usize = 10;
const P_Z0: usize = 11;
const P_ZSAT: usize = 12;
const P_ALPHA: usize = 13;
const P_KFA: usize = 15;
const P_FSC: usize = 16;
const P_WINDY: usize = 17;
const P_KAPPA: usize = 18;
// Плоскости `col`.
const C_HP: usize = 0;
const C_KF: usize = 1;
const C_HBL: usize = 2;
const C_WST: usize = 3;
const C_INVL: usize = 4;
const C_UNST: usize = 5;
const C_SIDE: usize = 6;
const C_SCS: usize = 7;
const C_QV: usize = 8;
const C_QK0: usize = 9;
const C_QK1: usize = 10;
const C_LAM: usize = 11;
const C_UST: usize = 13;
// Плоскости `lev`.
const L_ZC: usize = 0;
const L_GAM: usize = 1;
const L_CPL: usize = 2;
const L_SPZ: usize = 3;
const L_SPZW: usize = 4;

/// Предел индексов граней, точных в `f32` (R1).
const MAX_CELLS_F32: usize = 1 << 24;

/// Что решатель берёт не из плоскостей: заданный ветер, критерий остановки, числа проходов.
#[derive(Clone, Debug, PartialEq)]
pub struct SolverCfg {
    /// Приток на 10 м, м/с (`AirCaseRs::u10`); `> 0` — решатель держит жёсткую границу.
    pub u10: f64,
    pub mom_sweeps: usize,
    pub heat_sweeps: usize,
    pub vcycles: usize,
    pub local_k: bool,
    pub tol_mom_rms: f64,
    pub tol_th_rms: f64,
    pub tol_div_rms: f64,
    pub check_every: usize,
}

impl SolverCfg {
    /// Как у эталона (`AirCase.p`, `AirPicardJob`): 2/4/1 проход, местное K, допуски 2e-5/5e-7/1e-6
    /// раз в 10 итераций.
    pub fn new(u10: f64) -> Self {
        SolverCfg {
            u10,
            mom_sweeps: 2,
            heat_sweeps: 4,
            vcycles: 1,
            local_k: true,
            tol_mom_rms: 2e-5,
            tol_th_rms: 5e-7,
            tol_div_rms: 1e-6,
            check_every: 10,
        }
    }
}

/// Константы ядра: срезы плоскостей и размеры одной области.
struct Ctx<'a> {
    col: &'a [f32],
    lev: &'a [f32],
    prm: &'a [f32; NPRM],
    nx: usize,
    ny: usize,
    nz: usize,
    nyx: usize,
}

impl Ctx<'_> {
    #[inline]
    fn c(&self, plane: usize, j: usize, i: usize) -> f32 {
        self.col[plane * self.nyx + j * self.nx + i]
    }

    #[inline]
    fn lev(&self, plane: usize, k: usize) -> f32 {
        self.lev[plane * self.nz + k]
    }

    /// `cellt`: 0 земля, 2 ореол/верх, 1 воздух.
    #[inline]
    fn cellt(&self, k: usize, j: usize, i: usize) -> u8 {
        if k == 0 || (k as f32) < self.c(C_KF, j, i) {
            return 0;
        }
        if i == 0 || i + 1 == self.nx || j == 0 || j + 1 == self.ny || k + 1 == self.nz {
            return 2;
        }
        1
    }

    /// `ftype`: 0 стенка, 1 неизвестная, 2 воздух–ореол, 3 ореол–ореол.
    #[inline]
    fn ftype(a: u8, b: u8) -> u8 {
        if a == 0 || b == 0 {
            0
        } else if a == 1 && b == 1 {
            1
        } else if a == 1 && b == 2 || a == 2 && b == 1 {
            2
        } else {
            3
        }
    }

    /// Степенной профиль фона над землёй.
    #[inline]
    fn prof(&self, agl: f32) -> f32 {
        let z = agl.max(self.prm[P_Z0]) / self.prm[P_ZSAT];
        z.powf(self.prm[P_ALPHA]).min(1.0)
    }

    /// Значение жёсткой грани: приток — фон, выход — фон × баланс площадей.
    #[inline]
    fn fixed_face(&self, ub: f32, s: f32) -> f32 {
        if self.prm[P_WINDY] == 0.0 {
            return 0.0;
        }
        let nn = s * ub;
        if nn > 0.0 {
            ub * self.prm[P_FSC]
        } else if nn < 0.0 {
            ub
        } else {
            0.0
        }
    }

    #[inline]
    fn kc_cell(&self, k: usize, j: usize, i: usize) -> f32 {
        1.0 / (self.prm[P_IDTU] + self.lev(L_SPZ, k).max(self.c(C_SIDE, j, i)))
    }
}

#[inline]
fn tu_of(t: u8) -> u8 {
    (t >> 2) & 3
}
#[inline]
fn tv_of(t: u8) -> u8 {
    (t >> 4) & 3
}
#[inline]
fn tw_of(t: u8) -> u8 {
    (t >> 6) & 3
}

/// Собирает `picard_rs::Case` без эталона из плоскостей `prepare` (`K_SETUP` и загрузка
/// `AirPicardJob` до первой итерации). `p` — параметры того же случая (`AirCaseRs::p`): из
/// них — `τ_cool`, `Pr_t`, `Δτ_u`, `Δτ_θ`, `k_relax`, `c_s`; плоскости несут их же в `f32`, но
/// решатель читает `Params` в `f64`, как файл R1. Один `Case` годится для решения с нагревом и
/// без (`mech` — другие плоскости `prepare` у `without_heat`).
pub fn build_solver_case(
    planes: &PreparedPlanes,
    p: &CaseParams,
    cfg: &SolverCfg,
) -> Result<Case, Error> {
    let bad = |m: &str| Error::bad_input(format!("case_build: {m}"));
    let (nx, ny, nz) = (planes.nx_h, planes.ny_h, planes.nz_h);
    if nx != planes.nx + 2 || ny != planes.ny + 2 || nz != planes.nz + 2 {
        return Err(bad("dims without halo 1"));
    }
    let (nyx, n3) = (nx * ny, nx * ny * nz);
    if planes.col.len() != NCOL * nyx || planes.lev.len() != NLEV * nz {
        return Err(bad("plane sizes"));
    }
    if n3 >= MAX_CELLS_F32 {
        return Err(bad(
            "more than 2^24 cells: face indices are not exact in f32",
        ));
    }
    if planes.prm[P_NEST] != 0.0 {
        return Err(bad("window case (P_NEST) is not assembled here"));
    }
    let x = Ctx {
        col: &planes.col,
        lev: &planes.lev,
        prm: &planes.prm,
        nx,
        ny,
        nz,
        nyx,
    };

    // код типов: cell + 4·tu + 16·tv + 64·tw
    let mut tc = vec![0u8; n3];
    tc.par_chunks_mut(nyx).enumerate().for_each(|(k, pl)| {
        for j in 0..ny {
            for i in 0..nx {
                let c = x.cellt(k, j, i);
                let tu = if i == 0 {
                    3
                } else {
                    Ctx::ftype(x.cellt(k, j, i - 1), c)
                };
                let tv = if j == 0 {
                    3
                } else {
                    Ctx::ftype(x.cellt(k, j - 1, i), c)
                };
                let tw = if k == 0 {
                    0
                } else {
                    Ctx::ftype(x.cellt(k - 1, j, i), c)
                };
                pl[j * nx + i] = c + 4 * tu + 16 * tv + 64 * tw;
            }
        }
    });

    let unpack = |f: fn(u8) -> u8| -> Vec<f32> {
        let mut v = vec![0.0f32; n3];
        v.par_chunks_mut(nyx)
            .zip(tc.par_chunks(nyx))
            .for_each(|(o, t)| {
                for (o, &t) in o.iter_mut().zip(t) {
                    *o = f32::from(f(t));
                }
            });
        v
    };
    let cell = unpack(|t| t & 3);
    let tu = unpack(tu_of);
    let tv = unpack(tv_of);
    let tw = unpack(tw_of);

    // фон на гранях (профиль над средней высотой двух столбцов грани)
    let (mut ubg, mut vbg) = (vec![0.0f32; n3], vec![0.0f32; n3]);
    ubg.par_chunks_mut(nyx)
        .zip(vbg.par_chunks_mut(nyx))
        .zip(tc.par_chunks(nyx))
        .enumerate()
        .for_each(|(k, ((ou, ov), t))| {
            let zc = x.lev(L_ZC, k);
            for j in 0..ny {
                for i in 0..nx {
                    let q = j * nx + i;
                    let hu = if i > 0 {
                        0.5 * (x.c(C_HP, j, i) + x.c(C_HP, j, i - 1))
                    } else {
                        x.c(C_HP, j, 0)
                    };
                    let hv = if j > 0 {
                        0.5 * (x.c(C_HP, j, i) + x.c(C_HP, j - 1, i))
                    } else {
                        x.c(C_HP, 0, i)
                    };
                    ou[q] = if tu_of(t[q]) != 0 {
                        planes.prm[P_UAX] * x.prof(zc - hu)
                    } else {
                        0.0
                    };
                    ov[q] = if tv_of(t[q]) != 0 {
                        planes.prm[P_UAY] * x.prof(zc - hv)
                    } else {
                        0.0
                    };
                }
            }
        });

    // губки
    let (mut sp_u, mut sp_w, mut spc) = (vec![0.0f32; n3], vec![0.0f32; n3], vec![0.0f32; n3]);
    sp_u.par_chunks_mut(nyx)
        .zip(sp_w.par_chunks_mut(nyx))
        .zip(spc.par_chunks_mut(nyx))
        .enumerate()
        .for_each(|(k, ((su, sw), sc))| {
            let (spz, spzw) = (x.lev(L_SPZ, k), x.lev(L_SPZW, k));
            for j in 0..ny {
                for i in 0..nx {
                    let q = j * nx + i;
                    let side = x.c(C_SIDE, j, i);
                    su[q] = spz.max(side);
                    sw[q] = spzw.max(side);
                    sc[q] = spz.max(x.c(C_SCS, j, i));
                }
            }
        });

    // K_b и нагрев
    let (mut nu_bg, mut q_src) = (vec![0.0f32; n3], vec![0.0f32; n3]);
    let (kap, kfa) = (planes.prm[P_KAPPA], planes.prm[P_KFA]);
    nu_bg
        .par_chunks_mut(nyx)
        .zip(q_src.par_chunks_mut(nyx))
        .enumerate()
        .for_each(|(k, (kb, qs))| {
            let zc = x.lev(L_ZC, k);
            for j in 0..ny {
                for i in 0..nx {
                    let q = j * nx + i;
                    let (jj, ii) = (j.clamp(1, ny - 2), i.clamp(1, nx - 2));
                    let h = x.c(C_HBL, jj, ii);
                    let z = (zc - x.c(C_HP, jj, ii)).max(0.0);
                    let ust = x.c(C_UST, jj, ii);
                    let wm = if x.c(C_UNST, jj, ii) != 0.0 {
                        let zs = z.min(0.1 * h);
                        let ws = x.c(C_WST, jj, ii);
                        let a = ust * ust * ust + 7.0 * kap * (zs / h) * ws * ws * ws;
                        if a > 0.0 { a.powf(1.0 / 3.0) } else { 0.0 }
                    } else if ust > 0.0 {
                        ust / (1.0 + 5.0 * z * x.c(C_INVL, jj, ii))
                    } else {
                        0.0
                    };
                    let r1 = (1.0 - z / h).clamp(0.0, 1.0);
                    let kbl = kap * wm * z * r1 * r1;
                    kb[q] = kfa.max(if z < h { kbl } else { 0.0 });
                    let inner = i > 0 && i + 1 < nx && j > 0 && j + 1 < ny;
                    qs[q] = if inner
                        && (k as f32) >= x.c(C_QK0, j, i)
                        && (k as f32) <= x.c(C_QK1, j, i)
                    {
                        x.c(C_QV, j, i)
                    } else {
                        0.0
                    };
                }
            }
        });

    // проводимости проекции (SIMPLEC): K = 1/(1/Δτ + s) на гранях-неизвестных
    let (mut kx, mut ky, mut kz) = (vec![0.0f32; n3], vec![0.0f32; n3], vec![0.0f32; n3]);
    kx.par_chunks_mut(nyx)
        .zip(ky.par_chunks_mut(nyx))
        .zip(kz.par_chunks_mut(nyx))
        .zip(tc.par_chunks(nyx))
        .enumerate()
        .for_each(|(k, (((ox, oy), oz), t))| {
            let (spzw, cpl) = (x.lev(L_SPZW, k), x.lev(L_CPL, k));
            for j in 0..ny {
                for i in 0..nx {
                    let q = j * nx + i;
                    if tu_of(t[q]) == 1 {
                        ox[q] = 0.5 * (x.kc_cell(k, j, i) + x.kc_cell(k, j, i - 1));
                    }
                    if tv_of(t[q]) == 1 {
                        oy[q] = 0.5 * (x.kc_cell(k, j, i) + x.kc_cell(k, j - 1, i));
                    }
                    if tw_of(t[q]) == 1 {
                        let side = x.c(C_SIDE, j, i);
                        oz[q] = 1.0 / (planes.prm[P_IDTU] + spzw.max(side) + cpl);
                    }
                }
            }
        });

    // грани типа 2: индексы по возрастанию и жёсткие значения
    let faces = |t: fn(u8) -> u8, bg: &[f32]| -> (Vec<f32>, Vec<f32>) {
        let idx: Vec<u32> = (0..n3)
            .into_par_iter()
            .filter(|&q| t(tc[q]) == 2)
            .map(|q| q as u32)
            .collect();
        let val: Vec<f32> = idx
            .par_iter()
            .map(|&q| {
                let q = q as usize;
                let s = if tc[q] & 3 == 1 { -1.0 } else { 1.0 };
                x.fixed_face(bg[q], s)
            })
            .collect();
        (idx.iter().map(|&q| q as f32).collect(), val)
    };
    let (b_u, fixed_u) = faces(tu_of, &ubg);
    let (b_v, fixed_v) = faces(tv_of, &vbg);

    // hc без ореола — из плоскости рельефа (ореол в ней — край, `clamp`)
    let (nxi, nyi) = (planes.nx, planes.ny);
    let mut hc = vec![0.0f32; nxi * nyi];
    hc.par_chunks_mut(nxi).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            *o = x.c(C_HP, j + 1, i + 1);
        }
    });

    let mut arrays: HashMap<String, Vec<f32>> = HashMap::with_capacity(24);
    let mut put = |k: &str, v: Vec<f32>| {
        arrays.insert(k.to_string(), v);
    };
    put("hc", hc);
    put("cell", cell);
    put("tu", tu);
    put("tv", tv);
    put("tw", tw);
    put("nu_bg", nu_bg);
    put("Q", q_src);
    put("gam", planes.lev_plane(L_GAM).to_vec());
    put("cplz", planes.lev_plane(L_CPL).to_vec());
    put("sp_u", sp_u);
    put("sp_w", sp_w);
    put("spc", spc);
    put("ubg", ubg);
    put("vbg", vbg);
    put("lam", planes.col_plane(C_LAM).to_vec());
    put("Kx", kx);
    put("Ky", ky);
    put("Kz", kz);
    put("fixed_u", fixed_u);
    put("fixed_v", fixed_v);
    put("b_u", b_u);
    put("b_v", b_v);

    let params = Params {
        tau_cool: p.tau_cool,
        z0: planes.z0,
        pr_t: p.pr_t,
        dtau_u: (!p.dtau_u.is_nan()).then_some(p.dtau_u),
        dtau_per_m: p.dtau_per_m,
        dtau_th: p.dtau_th,
        couple: p.couple,
        mom_sweeps: cfg.mom_sweeps,
        heat_sweeps: cfg.heat_sweeps,
        vcycles: cfg.vcycles,
        local_k: cfg.local_k,
        k_relax: p.k_relax,
        cs_h: p.cs_h,
    };
    Case::from_parts(CaseParts {
        name: "game".to_string(),
        path: String::new(),
        dims: [nx, ny, nz],
        nx: planes.nx,
        ny: planes.ny,
        nz: planes.nz,
        dx: planes.dx,
        dz: planes.dz,
        z_bot: planes.z_bot,
        params,
        case_params: RsCaseParams {
            u10: cfg.u10,
            u_aloft: planes.u_a,
        },
        criterion: Criterion {
            tol_mom_rms: cfg.tol_mom_rms,
            tol_th_rms: cfg.tol_th_rms,
            tol_div_rms: cfg.tol_div_rms,
            check_every: cfg.check_every,
            pre_steps: 0,
        },
        solution: None,
        history: None,
        crop: None,
        cd: Some(planes.cd as f32),
        cd_col: Some(planes.col_plane(COL_CD).to_vec()),
        arrays,
    })
    .map_err(|e| bad(&e.to_string()))
}
