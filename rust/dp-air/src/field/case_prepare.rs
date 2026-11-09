//! Случай области Пикара и его плоскости (RW-6d): перенос `AirPlace.domain_case` (сборка
//! `AirCase`) и `AirCase.prepare` (`kf`, число неизвестных, фон, губки, `closure`, плоскости
//! `col` 14 / `lev` 5 / `prm` 32). Формулы и порядок операций — как в эталоне,
//! поэтому на тех же входах плоскости совпадают побитно (f64 внутри, f32 в плоскостях).
//!
//! ## Внутренний интерфейс для RW-6e (`K_SETUP` → `picard_rs::Case`)
//! ```text
//! let inp  = place_input::build_domain_input(place, &sh, &zi, &dom, &fw.day)?; // RW-6b
//! let fw   = weather_core::field_weather(cond, place, &wc, configs, climate, hour, &dom)?; // RW-6c
//! let heat = build_case(&inp, &fw, &CaseOpts { heat: true })?;  // AirCaseRs
//! let mech = heat.without_heat();                                               // w_mech
//! let planes: PreparedPlanes = heat.prepare()?;
//! ```
//! [`PreparedPlanes`] — всё, что нужно ядру до первой итерации: размеры с ореолом
//! (`nx_h = nx + 2`, …), плоскости SoA в одном `Vec<f32>` ([`PreparedPlanes::col_plane`],
//! [`PreparedPlanes::lev_plane`]), `prm`, `kf`, счёт неизвестных и скаляры замыкания. Раскладка
//! решателя: индекс `(k·ny_h + j)·nx_h + i`; `i` — восток, `j` — север, `k` — вверх; центр
//! клетки — `x0 + (i − ½)·dx`, `z_bot + (k − ½)·dz`. Плоскости `col` — `ny_h·nx_h` (индекс
//! `j·nx_h + i`), порядок: 0 `hp` (рельеф), 1 `kf`, 2 `h_bl`, 3 `w*`, 4 `1/L`, 5 неустойчиво,
//! 6 губка бока, 7 губка по ветру, 8 `Q` (нагрев, К·м/с), 9 `k0`, 10 `k1`, 11 `λ`, 12 `C_d`,
//! 13 `u*`. Плоскости `lev` — `nz_h`: 0 `z_c`, 1 `γ`, 2 связь θ, 3 губка верха (центр), 4 губка
//! верха (грань).
//!
//! Стиль: плоские массивы SoA, обход подряд, `rayon` по строкам/столбцам, без промежуточных `Vec`
//! в горячем пути (по столбцам — только записываемые плоскости). Сумма баланса потоков
//! `fixed_scale` — последовательная (порядок слагаемых как в эталоне: побитно).
//!
//! Границы модели: случай — область одной сетки (окна клипмапа — RW-6n); ветер условий — всегда
//! набегающий поток (приток `k = 1`, WF-К1); нагрев — `FieldWeather::heat` (RW-6c)
//! или внешний массив; профиль притока степенной с насыщением (`max_profile`), фон — ветер у
//! границ `fixed_scale`-балансом площадей, без поправки на устойчивость по высоте.
use super::cut_input::CutFrac;
use super::place_input::DomainInput;
use super::weather_core::{Domain, FieldWeather, log_mean};
use super::wind_profile::{self, CaseProfile, F_COR, KAPPA, NEUTRAL_BL_K, WindProfileCfg};
use crate::Error;
use rayon::prelude::*;
use std::f64::consts::PI;
use std::sync::Arc;

pub const G: f64 = 9.81;
pub const THETA0: f64 = 300.0;
pub const RHO_CP: f64 = 1.2 * 1005.0;
/// λ/h — доля толщины слоя в асимптотической длине перемешивания (`AirCase.LAM_FRAC`).
pub const LAM_FRAC: f64 = 0.0158;
pub const NCOL: usize = 14;
pub const NLEV: usize = 5;
pub const NPRM: usize = 32;
pub const COL_CD: usize = 12;
pub const COL_UST: usize = 13;
/// Слоты `prm`: окно клипмапа (0 у области), 1/Pr_t.
pub const P_NEST: usize = 19;
pub const P_IPRT: usize = 20;

/// Параметры модели (`AirCase.p`), только те, что влияют на плоскости.
#[derive(Clone, Debug, PartialEq)]
pub struct CaseParams {
    pub tau_cool: f64,
    pub pr_t: f64,
    /// Эффективный z0 области, м (лог-среднее карты; без карты — этот).
    pub z0: f64,
    pub alpha: f64,
    /// `NaN` — по правилу `z_sat` при `prepare` (класс D).
    pub max_profile: f64,
    pub f_cor: f64,
    pub k_fa: f64,
    pub k_smooth_m: f64,
    pub zi_min: f64,
    pub heat_cbl: bool,
    /// `NaN` — `dtau_per_m·Δx`.
    pub dtau_u: f64,
    pub dtau_per_m: f64,
    pub dtau_th: f64,
    pub couple: f64,
    pub sponge_top_m: f64,
    pub sponge_side_m: f64,
    pub sponge_rate: f64,
    pub heat_taper_m: f64,
    pub lam: f64,
    pub lam_frac: f64,
    pub k_relax: f64,
    pub cs_h: f64,
}

impl Default for CaseParams {
    fn default() -> Self {
        CaseParams {
            tau_cool: 7200.0,
            pr_t: 0.85,
            z0: 0.1,
            alpha: 0.24,
            max_profile: f64::NAN,
            f_cor: F_COR,
            k_fa: 1.0,
            k_smooth_m: 1500.0,
            zi_min: 300.0,
            heat_cbl: true,
            dtau_u: f64::NAN,
            dtau_per_m: 0.3,
            dtau_th: 1200.0,
            couple: 1.0,
            sponge_top_m: 1000.0,
            sponge_side_m: 2000.0,
            sponge_rate: 1.0 / 300.0,
            heat_taper_m: 2000.0,
            lam: 40.0,
            lam_frac: LAM_FRAC,
            k_relax: 0.1,
            cs_h: 0.25,
        }
    }
}

/// Случай области (`AirCase` до `prepare`): сетка, рельеф, фон, нагрев, ветер.
#[derive(Clone, Debug, PartialEq)]
pub struct AirCaseRs {
    pub dom: Domain,
    pub nz: usize,
    pub dz: f64,
    pub z_bot: f64,
    pub hc: Vec<f64>,
    /// Граница воздуха столбца (PT7 v1): низ первой клетки с долей объёма ≥ `VF_MIN`; `kf` — от неё.
    /// `hc` — настоящая земля (фон, AGL, `z_i`, источники).
    pub hc_type: Vec<f64>,
    /// Доли срезанных клеток (общие для случаев с нагревом и без); `None` — путь без долей, только
    /// для тестов-дампов GDScript/GPU (вход `hc_type = hc`).
    pub cut: Option<Arc<CutFrac>>,
    /// `nz + 2` значений dθ̄/dz в центрах уровней, К/м.
    pub gam: Vec<f64>,
    pub z_i: f64,
    /// Пусто — везде `z_i`.
    pub z_i_col: Vec<f32>,
    /// Пусто — везде `p.z0`.
    pub z0_map: Vec<f64>,
    /// Поток тепла, Вт/м² (пусто — 0).
    pub heat: Vec<f64>,
    pub p: CaseParams,
    /// Ветер условий на 10 м над открытой местностью — набегающий поток.
    pub u10: f64,
    pub wdir: f64,
    /// Гасить нагрев у края области.
    pub taper: bool,
}

/// Что собирать: с нагревом или без.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaseOpts {
    pub heat: bool,
}

/// Сборка случая (`AirPlace.domain_case`) из входа области и погоды поля.
pub fn build_case(
    inp: &DomainInput,
    fw: &FieldWeather,
    opts: &CaseOpts,
) -> Result<AirCaseRs, Error> {
    build_case_with(
        inp,
        &fw.wind,
        fw.inputs.u10,
        fw.inputs.wdir,
        opts.heat.then_some(fw.heat.as_slice()),
    )
}

/// То же с явным заданным ветром `u10_menu` (м/с), `wdir`, профилем притока `wind`
/// (`WindProfile.apply_to_case`) и потоком тепла `heat`.
pub fn build_case_with(
    inp: &DomainInput,
    wind: &CaseProfile,
    u10_menu: f64,
    wdir: f64,
    heat: Option<&[f64]>,
) -> Result<AirCaseRs, Error> {
    let n = inp.dom.nx * inp.dom.ny;
    let bad = |m: &str| Error::bad_input(format!("case: {m}"));
    if inp.hc.len() != n || inp.hc_type.len() != n || inp.gam.len() != inp.nz + 2 {
        return Err(bad("input sizes"));
    }
    if heat.is_some_and(|h| h.len() != n) {
        return Err(bad("heat size"));
    }
    if !inp.z0_map.is_empty() && inp.z0_map.len() != n {
        return Err(bad("z0 map size"));
    }
    let mut p = CaseParams::default();
    if !inp.z0_map.is_empty() {
        p.z0 = log_mean(&inp.z0_map);
    }
    p.alpha = wind.alpha;
    p.max_profile = wind.max_profile;
    Ok(AirCaseRs {
        dom: inp.dom,
        nz: inp.nz,
        dz: inp.dz,
        z_bot: inp.z_bot,
        hc: inp.hc.clone(),
        hc_type: inp.hc_type.clone(),
        cut: inp.cut.clone(),
        gam: inp.gam.clone(),
        z_i: inp.z_i,
        z_i_col: inp.z_i_col.clone(),
        z0_map: inp.z0_map.clone(),
        heat: heat.map(<[f64]>::to_vec).unwrap_or_default(),
        p,
        u10: u10_menu,
        wdir,
        taper: true,
    })
}

/// Результат `prepare`: плоскости и скаляры для решателя.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedPlanes {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub nx_h: usize,
    pub ny_h: usize,
    pub nz_h: usize,
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
    pub dz: f64,
    pub z_bot: f64,
    /// `NCOL` плоскостей по `ny_h·nx_h`, подряд.
    pub col: Vec<f32>,
    /// `NLEV` плоскостей по `nz_h`, подряд.
    pub lev: Vec<f32>,
    pub prm: [f32; NPRM],
    /// Первая клетка воздуха столбца, `ny_h·nx_h`.
    pub kf: Vec<i32>,
    /// Доли срезанных клеток (те же `Arc`, что в случае); `None` — без долей.
    pub cut: Option<Arc<CutFrac>>,
    /// Неизвестные: грани u, v, w типа 1 и клетки воздуха.
    pub n_unk: [u64; 4],
    pub n_fluid: u64,
    pub cd: f64,
    pub fixed_scale: f64,
    pub ustar: f64,
    pub u_a: f64,
    pub ex: f64,
    pub ey: f64,
    pub z_sat: f64,
    pub z0: f64,
    pub alpha: f64,
    pub h_mech: f64,
    pub wstar_max: f64,
    pub h_max: f64,
    /// Поток тепла как его берёт решение (с гашением у края), `ny·nx`, Вт/м².
    pub heat_used: Vec<f64>,
}

impl PreparedPlanes {
    /// Плоскость `col` номер `p` (`ny_h·nx_h`).
    pub fn col_plane(&self, p: usize) -> &[f32] {
        let n = self.nx_h * self.ny_h;
        &self.col[p * n..(p + 1) * n]
    }

    /// Плоскость `lev` номер `p` (`nz_h`).
    pub fn lev_plane(&self, p: usize) -> &[f32] {
        &self.lev[p * self.nz_h..(p + 1) * self.nz_h]
    }

    /// Центр клетки `k` (с ореолом), м над морем.
    pub fn zc(&self, k: usize) -> f64 {
        self.z_bot + (k as f64 - 0.5) * self.dz
    }

    /// Тип клетки `(k, j, i)` по `air_picard.glsl:cellt`: 0 земля, 2 внешняя (ореол, верх), 1 воздух.
    pub fn cell_type(&self, k: usize, j: usize, i: usize) -> u8 {
        let kf = self.col_plane(1)[j * self.nx_h + i];
        cell_code(kf, k, j, i, (self.nx_h, self.ny_h, self.nz_h))
    }

    /// Тип грани по типам двух клеток (`air_picard.glsl:ftype`): 0 стенка, 1 неизвестная, 2 жёсткая.
    fn face_type(a: u8, b: u8) -> u8 {
        face_type(a, b)
    }

    /// Значение жёсткой грани: приток — фон, выход — фон × баланс площадей.
    fn fixed_face(&self, ub: f64, s: f64) -> f64 {
        if self.prm[17] == 0.0 {
            return 0.0;
        }
        let nn = s * ub;
        if nn > 0.0 {
            ub * self.fixed_scale
        } else if nn < 0.0 {
            ub
        } else {
            0.0
        }
    }

    /// Фон на грани u клетки `(k, j, i)` (между `i − 1` и `i`), как `K_SETUP`: у стенки 0, на гранях
    /// типа 2 — приток или выход с множителем баланса.
    pub fn bg_u(&self, k: usize, j: usize, i: usize) -> f64 {
        let c = self.cell_type(k, j, i);
        let tu = if i == 0 {
            3
        } else {
            Self::face_type(self.cell_type(k, j, i - 1), c)
        };
        if tu == 0 {
            return 0.0;
        }
        let hp = self.col_plane(0);
        let q = j * self.nx_h + i;
        let hu = if i > 0 {
            0.5 * (hp[q] as f64 + hp[q - 1] as f64)
        } else {
            hp[q] as f64
        };
        let ub = self.u_a * self.ex * self.prof(self.zc(k) - hu);
        if tu == 2 {
            self.fixed_face(ub, if c == 1 { -1.0 } else { 1.0 })
        } else {
            ub
        }
    }

    /// Фон на грани v клетки `(k, j, i)` (между `j − 1` и `j`).
    pub fn bg_v(&self, k: usize, j: usize, i: usize) -> f64 {
        let c = self.cell_type(k, j, i);
        let tv = if j == 0 {
            3
        } else {
            Self::face_type(self.cell_type(k, j - 1, i), c)
        };
        if tv == 0 {
            return 0.0;
        }
        let hp = self.col_plane(0);
        let q = j * self.nx_h + i;
        let hv = if j > 0 {
            0.5 * (hp[q] as f64 + hp[q - self.nx_h] as f64)
        } else {
            hp[q] as f64
        };
        let vb = self.u_a * self.ey * self.prof(self.zc(k) - hv);
        if tv == 2 {
            self.fixed_face(vb, if c == 1 { -1.0 } else { 1.0 })
        } else {
            vb
        }
    }

    /// Профиль притока `min((max(agl, z0)/z_sat)^α, 1)`.
    pub fn prof(&self, agl: f64) -> f64 {
        prof(agl, self.z0, self.z_sat, self.alpha)
    }
}

/// Тип клетки по `kf` её столбца (`cellt`): 0 земля, 2 внешняя (ореол, верх), 1 воздух.
#[inline]
pub(crate) fn cell_code(kf: f32, k: usize, j: usize, i: usize, (nx_h, ny_h, nz_h): (usize, usize, usize)) -> u8 {
    if k == 0 || (k as f32) < kf {
        return 0;
    }
    if i == 0 || i == nx_h - 1 || j == 0 || j == ny_h - 1 || k == nz_h - 1 {
        return 2;
    }
    1
}

/// Тип грани по типам двух клеток (`ftype`): 0 стенка, 1 неизвестная, 2 жёсткая, 3 ореол–ореол.
#[inline]
pub(crate) fn face_type(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        0
    } else if a == 1 && b == 1 {
        1
    } else if (a == 1 && b == 2) || (a == 2 && b == 1) {
        2
    } else {
        3
    }
}

/// `kf` (ореольный индекс первой клетки воздуха) по границе воздуха `hc_type`: низ клетки `k` —
/// `z_bot + (k − 1)·dz`, поэтому `k = round((hc_type − z_bot)/dz) + 1` (не `ceil` по равенству f64).
/// Массив с ореолом `ny_h·nx_h`, ореол — копия ближайшего внутреннего столбца.
pub(crate) fn kf_of_type(hc_type: &[f64], dom: (usize, usize), z_bot: f64, dz: f64, nz_h: usize) -> Vec<i32> {
    let (nx, ny) = dom;
    let nx_h = nx + 2;
    let mut kf = vec![0i32; nx_h * (ny + 2)];
    kf.par_chunks_mut(nx_h).enumerate().for_each(|(j, row)| {
        let jj = j.saturating_sub(1).min(ny - 1);
        for (i, o) in row.iter_mut().enumerate() {
            let h = hc_type[jj * nx + i.saturating_sub(1).min(nx - 1)];
            let k = (((h - z_bot) / dz).round() as i64 + 1).clamp(1, nz_h as i64);
            *o = k as i32;
        }
    });
    kf
}

/// Типы клеток и граней `cell, tu, tv, tw` (раскладка `(k·ny_h + j)·nx_h + i`) по `kf` столбцов с
/// ореолом — тот же код, что `PreparedPlanes::cell_type`/`face_type` (вход `finish` долей).
pub(crate) fn types_of_kf(kf: &[i32], dims: (usize, usize, usize)) -> [Vec<u8>; 4] {
    let (nx_h, ny_h, nz_h) = dims;
    let nyx = nx_h * ny_h;
    let n = nyx * nz_h;
    let (mut cell, mut tu, mut tv, mut tw) = (vec![0u8; n], vec![0u8; n], vec![0u8; n], vec![0u8; n]);
    let ct = |k: usize, j: usize, i: usize| cell_code(kf[j * nx_h + i] as f32, k, j, i, dims);
    cell.par_chunks_mut(nyx)
        .zip(tu.par_chunks_mut(nyx))
        .zip(tv.par_chunks_mut(nyx))
        .zip(tw.par_chunks_mut(nyx))
        .enumerate()
        .for_each(|(k, (((pc, pu), pv), pw))| {
            for j in 0..ny_h {
                for i in 0..nx_h {
                    let c = ct(k, j, i);
                    let q = j * nx_h + i;
                    pc[q] = c;
                    pu[q] = if i == 0 { 3 } else { face_type(ct(k, j, i - 1), c) };
                    pv[q] = if j == 0 { 3 } else { face_type(ct(k, j - 1, i), c) };
                    pw[q] = if k == 0 { 0 } else { face_type(ct(k - 1, j, i), c) };
                }
            }
        });
    [cell, tu, tv, tw]
}

fn prof(agl: f64, z0: f64, z_sat: f64, alpha: f64) -> f64 {
    (agl.max(z0) / z_sat).powf(alpha).min(1.0)
}

fn ramp(d: f64, side_len: f64, rate: f64) -> f64 {
    let r = (1.0 - d / side_len).clamp(0.0, 1.0);
    r * r * rate
}

/// Строка за строкой: плоскость `ny_h × nx_h`, значение — функция `(j, i)`.
fn fill_plane(plane: &mut [f32], nx_h: usize, f: impl Fn(usize, usize) -> f32 + Sync) {
    plane.par_chunks_mut(nx_h).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            *o = f(j, i);
        }
    });
}

impl AirCaseRs {
    /// Тот же случай без нагрева (`AirCase.without_heat`).
    pub fn without_heat(&self) -> AirCaseRs {
        AirCaseRs {
            heat: Vec::new(),
            ..self.clone()
        }
    }

    /// Центр клетки `k` (с ореолом), м над морем.
    pub fn zc(&self, k: usize) -> f64 {
        self.z_bot + (k as f64 - 0.5) * self.dz
    }

    /// `z_i` над столбцом `c`: столбец `z_i_col`, иначе скаляр.
    fn z_i_of(&self, c: usize) -> f64 {
        if self.z_i_col.len() == self.hc.len() && !self.hc.is_empty() {
            self.z_i_col[c] as f64
        } else {
            self.z_i
        }
    }

    fn dtau_u(&self) -> f64 {
        if self.p.dtau_u.is_nan() {
            self.p.dtau_per_m * self.dom.dx
        } else {
            self.p.dtau_u
        }
    }

    /// Предел профиля притока: `p.max_profile`, иначе по правилу `z_sat` (класс D).
    pub fn max_profile_used(&self) -> f64 {
        if self.p.max_profile.is_nan() {
            wind_profile::max_profile(
                &WindProfileCfg::default(),
                self.p.alpha,
                self.u10,
                self.p.z0,
                self.p.f_cor,
                wind_profile::D,
            )
        } else {
            self.p.max_profile
        }
    }

    /// Всё по столбцам и уровням (`AirCase.prepare`).
    pub fn prepare(&self) -> Result<PreparedPlanes, Error> {
        let (nx, ny, nz) = (self.dom.nx, self.dom.ny, self.nz);
        let (nx_h, ny_h, nz_h) = (nx + 2, ny + 2, nz + 2);
        let dx = self.dom.dx;
        let dz = self.dz;
        let p = &self.p;
        let bad = |m: &str| Error::bad_input(format!("AirCase: {m}"));
        if nx < 4 || ny < 4 || nz < 2 || self.hc.len() != nx * ny || self.hc_type.len() != nx * ny || self.gam.len() != nz_h {
            return Err(bad("input sizes"));
        }
        if !self.heat.is_empty() && self.heat.len() != nx * ny {
            return Err(bad("heat size"));
        }
        if !self.z0_map.is_empty() && self.z0_map.len() != nx * ny {
            return Err(bad("z0 map size"));
        }
        let nyx = nx_h * ny_h;
        let ncell = nx * ny;
        let zc = |k: usize| self.zc(k);

        // рельеф с ореолом и первая клетка воздуха столбца
        let mut hp = vec![0.0f64; nyx];
        hp.par_chunks_mut(nx_h).enumerate().for_each(|(j, row)| {
            let jj = j.saturating_sub(1).min(ny - 1);
            for (i, o) in row.iter_mut().enumerate() {
                *o = self.hc[jj * nx + i.saturating_sub(1).min(nx - 1)];
            }
        });
        let kf = if self.cut.is_some() {
            kf_of_type(&self.hc_type, (nx, ny), self.z_bot, dz, nz_h)
        } else {
            // путь без долей (тесты-дампы): наименьшее `k ≥ 1`, у которого `zc(k) ≥ hc_type`
            let mut kf = vec![0i32; nyx];
            kf.par_chunks_mut(nx_h).enumerate().for_each(|(j, row)| {
                let jj = j.saturating_sub(1).min(ny - 1);
                for (i, o) in row.iter_mut().enumerate() {
                    let h = self.hc_type[jj * nx + i.saturating_sub(1).min(nx - 1)];
                    let c = ((h - self.z_bot) / dz + 0.5).ceil();
                    let mut k = (c.max(1.0).min(nz_h as f64)) as usize;
                    while k > 1 && zc(k - 1) >= h {
                        k -= 1;
                    }
                    while k < nz_h && zc(k) < h {
                        k += 1;
                    }
                    *o = k as i32;
                }
            });
            kf
        };
        let (n_unk, n_fluid) = count_unknowns(&kf, nx_h, ny_h, nz_h);

        // фон: ветер
        let windy = self.u10 > 0.0;
        let mp = self.max_profile_used();
        let u_a = self.u10 * mp;
        let ang = self.wdir * (PI / 180.0);
        let (ex, ey) = if windy {
            (-ang.sin(), -ang.cos())
        } else {
            (0.0, 0.0)
        };
        let z_sat = 10.0 * mp.powf(1.0 / p.alpha);

        // губки
        let ztop = self.z_bot + nz as f64 * dz;
        let rate = p.sponge_rate;
        let mut col = vec![0.0f32; NCOL * nyx];
        let mut planes: Vec<&mut [f32]> = col.chunks_mut(nyx).collect();
        if windy {
            let side_len = p.sponge_side_m;
            let lx = nx as f64 * dx;
            let ly = ny as f64 * dx;
            let (pa, pb) = planes.split_at_mut(7);
            let (side, scs) = (&mut *pa[6], &mut *pb[0]);
            side.par_chunks_mut(nx_h)
                .zip(scs.par_chunks_mut(nx_h))
                .enumerate()
                .for_each(|(j, (srow, crow))| {
                    let yj = (j as f64 - 0.5) * dx;
                    let ry0 = ramp(yj, side_len, rate);
                    let ry1 = ramp(ly - yj, side_len, rate);
                    for i in 0..nx_h {
                        let xi = (i as f64 - 0.5) * dx;
                        let rx0 = ramp(xi, side_len, rate);
                        let rx1 = ramp(lx - xi, side_len, rate);
                        srow[i] = rx0.max(rx1).max(ry0.max(ry1)) as f32;
                        let mut s = 0.0f64;
                        if ex > 1e-9 {
                            s = s.max(rx0);
                        }
                        if ex < -1e-9 {
                            s = s.max(rx1);
                        }
                        if ey > 1e-9 {
                            s = s.max(ry0);
                        }
                        if ey < -1e-9 {
                            s = s.max(ry1);
                        }
                        crow[i] = s as f32;
                    }
                });
        }
        let mut lev = vec![0.0f32; NLEV * nz_h];
        let s_th = p.dtau_th;
        for k in 0..nz_h {
            let z = zc(k);
            lev[k] = z as f32;
            lev[nz_h + k] = self.gam[k] as f32;
            let gw = if k > 0 {
                0.5 * (self.gam[k] + self.gam[k - 1])
            } else {
                0.0
            };
            lev[2 * nz_h + k] = (p.couple * G / THETA0 * gw.max(0.0) * s_th) as f32;
            lev[3 * nz_h + k] = ramp(ztop - z, p.sponge_top_m, rate) as f32;
            lev[4 * nz_h + k] = ramp(ztop - (z - 0.5 * dz), p.sponge_top_m, rate) as f32;
        }

        // нагрев (Вт/м² → К·м/с), у края области гасится
        let mut hk = vec![0.0f64; ncell];
        let (mut any_heat, mut any_pos) = (false, false);
        if !self.heat.is_empty() {
            let lx2 = nx as f64 * dx;
            let ly2 = ny as f64 * dx;
            let tm = p.heat_taper_m;
            hk.par_chunks_mut(nx)
                .zip(self.heat.par_chunks(nx))
                .enumerate()
                .for_each(|(j, (out, src))| {
                    let ye = (j as f64 + 0.5) * dx;
                    let eyy = (ye.min(ly2 - ye) / tm).clamp(0.0, 1.0);
                    for (i, (o, &h)) in out.iter_mut().zip(src).enumerate() {
                        let mut v = h;
                        if self.taper {
                            let xe = (i as f64 + 0.5) * dx;
                            let exx = (xe.min(lx2 - xe) / tm).clamp(0.0, 1.0);
                            let f = (0.5 * PI * eyy).sin() * (0.5 * PI * exx).sin();
                            v *= f * f;
                        }
                        *o = v / RHO_CP;
                    }
                });
            any_heat = hk.iter().any(|&v| v != 0.0);
            any_pos = hk.iter().any(|&v| v > 0.0);
        }
        let heat_used: Vec<f64> = hk.par_iter().map(|&v| v * RHO_CP).collect();

        // замыкание по столбцам
        let ustar = if self.u10 > 0.0 {
            KAPPA * self.u10 / (10.0 / p.z0).ln()
        } else {
            0.0
        };
        let lr = (0.5 * dz / p.z0).ln();
        let sig = p.k_smooth_m / dx;
        let hs_heat = if any_heat {
            super::place_input::gauss2d(&hk, nx, ny, sig)
        } else {
            vec![0.0; ncell]
        };
        let hs = super::place_input::gauss2d(&self.hc, nx, ny, sig);
        let mut cl = Closure::new(ncell);
        cl.cd
            .par_iter_mut()
            .zip(cl.ust.par_iter_mut())
            .zip(cl.h_bl.par_iter_mut())
            .zip(cl.wst.par_iter_mut())
            .zip(cl.invl.par_iter_mut())
            .zip(cl.unst.par_iter_mut())
            .enumerate()
            .for_each(|(c, (((((cd, ust), h_bl), wst), invl), unst))| {
                let z0c = if self.z0_map.is_empty() {
                    p.z0
                } else {
                    self.z0_map[c]
                };
                let lc = (0.5 * dz / z0c).ln();
                *cd = (KAPPA / lc).powf(2.0);
                let us = if z0c != p.z0 { ustar * lr / lc } else { ustar };
                *ust = us;
                let h_mech = NEUTRAL_BL_K * us / p.f_cor;
                let hsv = hs_heat[c];
                let u = hsv > 1e-6;
                let zic = self.z_i_of(c);
                let h_c = if zic.is_nan() {
                    p.zi_min
                } else {
                    (zic - hs[c]).max(p.zi_min)
                };
                let h_u = h_c.max(h_mech);
                let ws = if u {
                    (G / THETA0 * hsv.max(0.0) * h_u).powf(1.0 / 3.0)
                } else {
                    0.0
                };
                let mut lmo = f64::INFINITY;
                if hsv < -1e-6 {
                    lmo = -us * us * us * THETA0 / (KAPPA * G * hsv);
                }
                let mut h_s = h_mech;
                if lmo.is_finite() {
                    h_s = h_mech.min(0.4 * (us * lmo / p.f_cor).sqrt());
                }
                *h_bl = (if u { h_u } else { h_s }).max(1.0);
                *wst = ws;
                *invl = if lmo.is_finite() && lmo != 0.0 {
                    1.0 / lmo
                } else if lmo.is_finite() {
                    f64::INFINITY
                } else {
                    0.0
                };
                *unst = u;
            });
        let (wmax, hmax) = cl
            .wst
            .iter()
            .zip(&cl.h_bl)
            .fold((0.0f64, 0.0f64), |(a, b), (&w, &h)| (a.max(w), b.max(h)));
        let h_mech_s = NEUTRAL_BL_K * ustar / p.f_cor;

        // столбцы (с ореолом: копия ближайшего внутреннего)
        let lam = p.lam;
        let lam_frac = p.lam_frac;
        let cbl = p.heat_cbl && any_pos;
        let at = |j: usize, i: usize| {
            j.saturating_sub(1).min(ny - 1) * nx + i.saturating_sub(1).min(nx - 1)
        };
        fill_plane(&mut *planes[0], nx_h, |j, i| hp[j * nx_h + i] as f32);
        fill_plane(&mut *planes[1], nx_h, |j, i| kf[j * nx_h + i] as f32);
        fill_plane(&mut *planes[2], nx_h, |j, i| cl.h_bl[at(j, i)] as f32);
        fill_plane(&mut *planes[3], nx_h, |j, i| cl.wst[at(j, i)] as f32);
        fill_plane(&mut *planes[4], nx_h, |j, i| cl.invl[at(j, i)] as f32);
        fill_plane(&mut *planes[5], nx_h, |j, i| f32::from(cl.unst[at(j, i)]));
        fill_plane(&mut *planes[11], nx_h, |j, i| {
            lam.max(lam_frac * cl.h_bl[at(j, i)]) as f32
        });
        fill_plane(&mut *planes[COL_CD], nx_h, |j, i| cl.cd[at(j, i)] as f32);
        fill_plane(&mut *planes[COL_UST], nx_h, |j, i| cl.ust[at(j, i)] as f32);
        // нагрев: Q = значение на уровнях [k0, k1] столбца (ореол — нет)
        {
            let (_, rest) = planes.split_at_mut(8);
            let (q8, rest) = rest.split_at_mut(1);
            let (q9, rest) = rest.split_at_mut(1);
            let q10 = &mut rest[0];
            q8[0]
                .par_chunks_mut(nx_h)
                .zip(q9[0].par_chunks_mut(nx_h))
                .zip(q10.par_chunks_mut(nx_h))
                .enumerate()
                .for_each(|(j, ((rq, r0), r1))| {
                    for i in 0..nx_h {
                        let mut qv = 0.0f64;
                        let mut k0 = 1.0f64;
                        let mut k1 = 0.0f64;
                        if i > 0 && i < nx_h - 1 && j > 0 && j < ny_h - 1 {
                            let q = j * nx_h + i;
                            let c = (j - 1) * nx + (i - 1);
                            let mut kb = kf[q].max(1) as usize;
                            if kb > nz_h - 2 {
                                kb = 0; // столбец целиком в земле
                            }
                            let h0 = hk[c];
                            if cbl && h0 > 0.0 {
                                // нелокальный перенос: равномерно по слою перемешивания
                                let mut n_in = 0usize;
                                let mut ks = usize::MAX;
                                for k in (kf[q].max(1) as usize)..nz_h - 1 {
                                    let za = zc(k) - self.hc[c];
                                    if za < cl.h_bl[c] && za > -dz {
                                        if ks == usize::MAX {
                                            ks = k;
                                        }
                                        n_in += 1;
                                    }
                                }
                                if n_in > 0 {
                                    qv = h0 / (n_in as f64 * dz);
                                    k0 = ks as f64;
                                    k1 = (ks + n_in - 1) as f64;
                                }
                            } else {
                                qv = h0 / dz;
                                k0 = kb as f64;
                                k1 = kb as f64;
                            }
                        }
                        rq[i] = qv as f32;
                        r0[i] = k0 as f32;
                        r1[i] = k1 as f32;
                    }
                });
        }

        // «жёсткие» границы: множитель выхода (баланс потоков по граням типа 2)
        let mut fixed_scale = 1.0;
        if windy {
            let (mut fin, mut fout) = (0.0f64, 0.0f64);
            for side_i in [1, nx_h - 1] {
                let s = if side_i == 1 { -1.0 } else { 1.0 };
                for j in 1..ny_h - 1 {
                    let q = j * nx_h + side_i;
                    let hu = 0.5 * (hp[q] + hp[q - 1]);
                    let k0 = kf[j * nx_h + if side_i == 1 { 1 } else { nx_h - 2 }].max(1) as usize;
                    for k in k0..nz_h - 1 {
                        let nn = s * u_a * ex * prof(zc(k) - hu, p.z0, z_sat, p.alpha);
                        fin -= nn.min(0.0);
                        fout += nn.max(0.0);
                    }
                }
            }
            for side_j in [1, ny_h - 1] {
                let s = if side_j == 1 { -1.0 } else { 1.0 };
                for i in 1..nx_h - 1 {
                    let q = side_j * nx_h + i;
                    let hv = 0.5 * (hp[q] + hp[q - nx_h]);
                    let row = if side_j == 1 { 1 } else { ny_h - 2 };
                    let k0 = kf[row * nx_h + i].max(1) as usize;
                    for k in k0..nz_h - 1 {
                        let nn = s * u_a * ey * prof(zc(k) - hv, p.z0, z_sat, p.alpha);
                        fin -= nn.min(0.0);
                        fout += nn.max(0.0);
                    }
                }
            }
            fixed_scale = if fout > 0.0 { fin / fout } else { 1.0 };
        }
        let cd = (KAPPA / (0.5 * dz / p.z0).ln()).powf(2.0);
        let dtu = self.dtau_u();
        let mut prm = [0.0f32; NPRM];
        let vals = [
            dx,
            dz,
            1.0 / dtu,
            cd,
            self.z_bot,
            p.k_relax,
            (p.cs_h * dx).powf(2.0),
            1.0 / p.dtau_th,
            1.0 / p.tau_cool,
            u_a * ex,
            u_a * ey,
            p.z0,
            z_sat,
            p.alpha,
            ustar,
            p.k_fa,
            fixed_scale,
            if windy { 1.0 } else { 0.0 },
            KAPPA,
        ];
        for (o, v) in prm.iter_mut().zip(vals) {
            *o = v as f32;
        }
        prm[P_IPRT] = (1.0 / p.pr_t) as f32;
        drop(planes);
        Ok(PreparedPlanes {
            nx,
            ny,
            nz,
            nx_h,
            ny_h,
            nz_h,
            x0: self.dom.x0,
            y0: self.dom.y0,
            dx,
            dz,
            z_bot: self.z_bot,
            col,
            lev,
            prm,
            kf,
            cut: self.cut.clone(),
            n_unk,
            n_fluid,
            cd,
            fixed_scale,
            ustar,
            u_a,
            ex,
            ey,
            z_sat,
            z0: p.z0,
            alpha: p.alpha,
            h_mech: h_mech_s,
            wstar_max: wmax,
            h_max: hmax,
            heat_used,
        })
    }
}

/// Замыкание по внутренним столбцам: `C_d`, `u*`, толщина слоя, `w*`, `1/L`, неустойчивость.
struct Closure {
    cd: Vec<f64>,
    ust: Vec<f64>,
    h_bl: Vec<f64>,
    wst: Vec<f64>,
    invl: Vec<f64>,
    unst: Vec<bool>,
}

impl Closure {
    fn new(n: usize) -> Self {
        Closure {
            cd: vec![0.0; n],
            ust: vec![0.0; n],
            h_bl: vec![0.0; n],
            wst: vec![0.0; n],
            invl: vec![0.0; n],
            unst: vec![false; n],
        }
    }
}

/// Число неизвестных (`AirCase._count_unknowns`): грани u, v, w типа 1 и клетки воздуха.
fn count_unknowns(kf: &[i32], nx_h: usize, ny_h: usize, nz_h: usize) -> ([u64; 4], u64) {
    let top = nz_h as i64 - 2;
    let cnt = |a: i32| (top - a.max(1) as i64 + 1).max(0);
    let (mut nf, mut nw, mut nu, mut nv) = (0i64, 0i64, 0i64, 0i64);
    for j in 1..ny_h - 1 {
        for i in 1..nx_h - 1 {
            let c = cnt(kf[j * nx_h + i]);
            nf += c;
            nw += (c - 1).max(0);
        }
    }
    for j in 1..ny_h - 1 {
        for i in 2..nx_h - 1 {
            nu += cnt(kf[j * nx_h + i].max(kf[j * nx_h + i - 1]));
        }
    }
    for j in 2..ny_h - 1 {
        for i in 1..nx_h - 1 {
            nv += cnt(kf[j * nx_h + i].max(kf[(j - 1) * nx_h + i]));
        }
    }
    ([nu as u64, nv as u64, nw as u64, nf as u64], nf as u64)
}
