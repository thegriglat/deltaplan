//! Окна клипмапа 100/50 м (RW-6n): `AirWindowCase`, граница от родителя (`nest`), поправка потока
//! (`flux`/`corr`), тёплый сдвиг (`shift`). Перенос окна и его подготовки; эталон — AM-01 (`tools/research/air3d/air.py`:
//! `Air.set_nest_bc`, `init_nest`).
//!
//! ## Что здесь и чего нет
//! Есть всё, что эталон делает с окном до первой итерации Пикара:
//! 1. вход окна — сетка 64×64 (`dz = dx/2`, потолок 2000 м над рельефом окна) из места и
//!    родителя ([`window_domain`], [`build_window_input`], `z_i` по столбцам от родителя);
//! 2. случай окна ([`AirWindowCase`]): зона релаксации к родителю на 4 клетки по бокам и 1000 м
//!    у потолка, нагрев у края не гасится, фон ветра на гранях пишет не `setup`, а граница;
//! 3. граница от родителя ([`window_boundary`] → [`NestBc`]): общая операция уровней
//!    [`nest`] («грубый уровень → мелкий»), поправка потока Σ = 0 по граням типа 2
//!    ([`boundary_flux`], [`apply_flux_correction`]);
//! 4. старт: «родитель» ([`init_from_boundary`] — `K_BC` в режиме 1, дальше 30 V-циклов, p = 0) и
//!    тёплый сдвиг ([`warm_from_previous`] — то же + [`shift_warm`], дальше 4 V-цикла);
//! 5. [`window_solver_case`] — `picard_rs::Case` окна: всё от `build_solver_case`, граница по
//!    u, v, w, θ′, θ′_d — от родителя (`Case.nest`).
//!
//! Решение окна — `picard_rs::api::solve` с `Case`, который собирает [`window_solver_case`]
//! (W11 v7: `Case.nest`), и стартом: от родителя — `SolveOpts { init: Some(state),
//! init_cycles: Some(30) }`, тёплый сдвиг — `init: Some(state)` без `init_cycles` (4 V-цикла).
//!
//! ## Внутренний интерфейс (RW-6o: клипмап `clipmap.rs` зовёт [`window_pair_inputs`])
//! Пара окна целиком — [`window_pair_inputs`]: плоскости mech/heat, граница каждого решения от
//! своего родителя, старт «родитель» или тёплый, `Case` решателя. По шагам то же самое:
//! ```text
//! let dom   = window_domain(100.0, cx, cy, N_WINDOW);
//! let fw    = weather_core::field_weather(cond, place, &wc, configs, climate, hour, &dom)?;
//! let inp   = build_window_input(place, &wc.sh, &zi, &dom, &fw.day, parent_zi.as_ref())?;
//! let heat  = AirWindowCase::from_input(&inp, &fw.wind, fw.inputs.u10, fw.inputs.wdir,
//!                                       Some(&fw.heat))?;
//! let mech  = heat.without_heat();
//! let planes = heat.prepare()?;                          // PreparedPlanes (как у области)
//! let tc    = tcode(&planes);                            // типы клеток и граней, u8
//! let bc    = window_boundary(&parent_level, &parent_src, &planes, &tc)?;  // nest + flux + corr
//! let start = match old { Some(o) => warm_from_previous(&o.level, &o.state, &window_level(&planes),
//!                                                       &tc, &bc)?, None => None }
//!               .unwrap_or_else(|| init_from_boundary(&tc, &bc));
//! ```
//!
//! ## Границы модели
//! - Окно с `u10 = 0` (штиль): жёсткие грани u, v берутся из границы, а решатель включает их по
//!   `u10 > 0` — [`window_solver_case`] передаёт ему `u10 ≥ 1e-6`.
//! - `zi_alpha` родителя в крейте у случая не хранится (метаданные эталона); `z_i` по столбцам окна
//!   считается с нижней границей `hc + zi_min`, как у родителя с `α > 0`.
//! - Суммы потока — `f64` с порядком обхода по плоскостям `k` (не зависит от числа потоков), у
//!   GPU — `f32`-редукция: отличие чисел потока ≲ 1e-6 от потока через грань.
//!
//! Стиль: плоские массивы SoA, обход подряд, `rayon` по строкам и плоскостям, без промежуточных
//! `Vec` в горячем пути (кроме выходных массивов).
use super::case_build::{SolverCfg, build_solver_case};
use super::case_prepare::{AirCaseRs, CaseParams, NLEV, P_NEST, PreparedPlanes, build_case_with};
use super::cut_input::cut_level;
use super::place_input::{DomainInput, ZiCfg, zi_columns};
use super::surface_heat::SurfaceHeatCfg;
use super::weather_core::{Day, Domain, block_mean, cell_surface, cell_z0};
use super::wind_profile::CaseProfile;
use crate::Error;
use picard_rs::case::{Case, NestBc as SolverNest};
use rayon::prelude::*;

pub use crate::level::{
    Level, NestDst, NestSrc, Shift, ShiftDst, ShiftSrc, nest, shift_between, shift_warm,
};

/// Клеток окна по стороне (`AirWindowCase.N_WINDOW`).
pub const N_WINDOW: usize = 64;
/// Потолок окна над максимумом его рельефа, м (`AirWindowCase.TOP_ABOVE`).
pub const TOP_ABOVE: f64 = 2000.0;
/// Зона релаксации к родителю: клеток по бокам (`p.nest_sponge_cells`).
pub const NEST_SPONGE_CELLS: f64 = 4.0;
/// Зона релаксации у потолка, м (`p.nest_sponge_top_m`).
pub const NEST_SPONGE_TOP_M: f64 = 1000.0;
/// Шаг угла окна, м (`real.grid_window`): угол кратен шагу растра места.
const CORNER_STEP: f64 = 25.0;

// Плоскости `col` / `lev`, которые окно переписывает (`air_picard.glsl`).
const C_SIDE: usize = 6;
const C_SCS: usize = 7;
const L_SPZ: usize = 3;
const L_SPZW: usize = 4;

// ---------------------------------------------------------------------------------------------
// сетка и вход окна
// ---------------------------------------------------------------------------------------------

/// Область окна `n × n` клеток `dx` с центром `(cx, cy)` в осях решателя (x — восток, y — север):
/// угол кратен 25 м (`AirWindowCase.window_case`).
pub fn window_domain(dx: f64, cx: f64, cy: f64, n: usize) -> Domain {
    let half = 0.5 * n as f64 * dx;
    Domain {
        x0: ((cx - half) / CORNER_STEP).round() * CORNER_STEP,
        y0: ((cy - half) / CORNER_STEP).round() * CORNER_STEP,
        nx: n,
        ny: n,
        dx,
    }
}

/// Сетка по высоте: `dz = dx/2`, `z_bot = ⌊h_min/dz⌋·dz − dz`, верх — [`TOP_ABOVE`] над максимумом
/// рельефа, `nz` чётное (`AirWindowCase.window_at`). Возвращает `(dz, z_bot, nz)`.
pub fn window_vertical(hc: &[f64], dx: f64) -> (f64, f64, usize) {
    let dz = dx / 2.0;
    let lo = hc.iter().copied().fold(f64::INFINITY, f64::min);
    let hi = hc.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let z_bot = (lo / dz).floor() * dz - dz;
    let mut nz = ((hi + TOP_ABOVE - z_bot) / dz).ceil() as usize;
    nz += nz % 2;
    (dz, z_bot, nz)
}

/// Поле `z_i` родителя для столбцов окна (`AirZiTerrain.from_parent`, `WindField.z_i_at`).
#[derive(Clone, Copy, Debug)]
pub struct ParentZi<'a> {
    pub nx: usize,
    pub ny: usize,
    pub dx: f64,
    /// Западный и южный края сетки родителя (оси решателя).
    pub x0: f64,
    pub y0: f64,
    /// Скаляр `z_i` (NaN — нет); нужен, когда столбцов нет.
    pub z_i: f64,
    /// `z_i` по столбцам родителя (`ny·nx`); пусто — везде `z_i`.
    pub z_i_col: &'a [f32],
    /// `α > 0` родителя: нижняя граница `hc + zi_min` (`WindField.zi_alpha() > 0`).
    pub alpha_on: bool,
}

/// `z_i` по столбцам окна от родителя: билинейно в центре клетки окна, не ниже `hc + zi_min`
/// при `alpha_on`. Пусто — родитель не знает `z_i` (NaN и нет столбцов) или размеры не сошлись.
pub fn zi_from_parent(
    parent: &ParentZi,
    hc: &[f64],
    (nx, ny): (usize, usize),
    dx: f64,
    (x0, y0): (f64, f64),
    zi_min: f64,
) -> Vec<f32> {
    if hc.len() != nx * ny || nx * ny == 0 {
        return Vec::new();
    }
    let zic = parent.z_i_col;
    if zic.is_empty() || zic.len() != parent.nx * parent.ny || parent.nx < 2 || parent.ny < 2 {
        if parent.z_i.is_nan() {
            return Vec::new();
        }
        return vec![parent.z_i as f32; nx * ny];
    }
    let inv = 1.0 / parent.dx;
    let mut out = vec![0.0f32; nx * ny];
    out.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        let y = y0 + (j as f64 + 0.5) * dx;
        let gy = ((y - parent.y0) * inv - 0.5).clamp(0.0, parent.ny as f64 - 1.0);
        let j0 = (gy as usize).min(parent.ny - 2);
        let fy = gy - j0 as f64;
        for (i, o) in row.iter_mut().enumerate() {
            let x = x0 + (i as f64 + 0.5) * dx;
            let gx = ((x - parent.x0) * inv - 0.5).clamp(0.0, parent.nx as f64 - 1.0);
            let i0 = (gx as usize).min(parent.nx - 2);
            let fx = gx - i0 as f64;
            let c = j0 * parent.nx + i0;
            let lerp = |a: f32, b: f32, t: f64| f64::from(a) + (f64::from(b) - f64::from(a)) * t;
            let r0 = lerp(zic[c], zic[c + 1], fx);
            let r1 = lerp(zic[c + parent.nx], zic[c + parent.nx + 1], fx);
            let v = r0 + (r1 - r0) * fy;
            let h = hc[j * nx + i];
            *o = (if parent.alpha_on {
                v.max(h + zi_min)
            } else {
                v
            }) as f32;
        }
    });
    out
}

/// Вход окна из растров места: как `place_input::build_domain_input`, но сетка окна (`dz = dx/2`,
/// потолок [`TOP_ABOVE`]) и `z_i` по столбцам — от родителя (нет родителя или он не знает `z_i`
/// — от своего рельефа той же формулой, что у области: путь для тестов, в эталоне родитель есть
/// всегда).
pub fn build_window_input(
    place: &crate::Place,
    sh: &SurfaceHeatCfg,
    zi: &ZiCfg,
    dom: &Domain,
    day: &Day,
    parent: Option<&ParentZi>,
) -> Result<DomainInput, Error> {
    let hc = block_mean(place, dom)?;
    let dx = dom.dx;
    let (dz, z_bot, nz) = window_vertical(&hc, dx);
    let z_i = day.z_i;
    let mut z_i_col = parent
        .map(|p| zi_from_parent(p, &hc, (dom.nx, dom.ny), dx, (dom.x0, dom.y0), zi.zi_min))
        .unwrap_or_default();
    if z_i_col.is_empty() {
        z_i_col = zi_columns(&hc, dom.nx, dom.ny, dx, z_i, day.h_v * 1000.0, zi);
    }
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

// ---------------------------------------------------------------------------------------------
// случай окна
// ---------------------------------------------------------------------------------------------

fn ramp(d: f64, len: f64, rate: f64) -> f64 {
    let r = (1.0 - d / len).clamp(0.0, 1.0);
    r * r * rate
}

/// Случай окна (`AirWindowCase`): случай области с зоной релаксации к родителю.
#[derive(Clone, Debug, PartialEq)]
pub struct AirWindowCase {
    /// Случай решателя на сетке окна; нагрев у края не гасится (`taper = false`).
    pub case: AirCaseRs,
    /// Зона релаксации по бокам, клеток (4).
    pub sponge_cells: f64,
    /// Зона релаксации у потолка, м (1000).
    pub sponge_top_m: f64,
}

impl AirWindowCase {
    /// Окно из готового случая на сетке окна.
    pub fn new(mut case: AirCaseRs) -> Self {
        case.taper = false;
        AirWindowCase {
            case,
            sponge_cells: NEST_SPONGE_CELLS,
            sponge_top_m: NEST_SPONGE_TOP_M,
        }
    }

    /// Окно из входа ([`build_window_input`]), профиля притока и потока тепла (`build_case_with`).
    pub fn from_input(
        inp: &DomainInput,
        wind: &CaseProfile,
        u10_menu: f64,
        wdir: f64,
        heat: Option<&[f64]>,
    ) -> Result<Self, Error> {
        Ok(Self::new(build_case_with(inp, wind, u10_menu, wdir, heat)?))
    }

    /// То же окно без нагрева (`w_mech`).
    pub fn without_heat(&self) -> Self {
        AirWindowCase {
            case: self.case.without_heat(),
            ..self.clone()
        }
    }

    /// Плоскости окна (`AirWindowCase.prepare`): плоскости области, затем зона релаксации — боковые
    /// грани `sponge_cells` клеток для импульса и θ′ (одна плоскость на оба), потолок `sponge_top_m`;
    /// `prm[P_NEST] = 1`.
    pub fn prepare(&self) -> Result<PreparedPlanes, Error> {
        let mut c = self.case.clone();
        c.taper = false;
        let mut pl = c.prepare()?;
        let (nx_h, ny_h, nz_h) = (pl.nx_h, pl.ny_h, pl.nz_h);
        let nyx = nx_h * ny_h;
        let dx = pl.dx;
        let rate = self.case.p.sponge_rate;
        let ls = self.sponge_cells * dx;
        let lx = pl.nx as f64 * dx;
        let ly = pl.ny as f64 * dx;
        {
            let (head, tail) = pl.col.split_at_mut(C_SCS * nyx);
            let side = &mut head[C_SIDE * nyx..];
            let scs = &mut tail[..nyx];
            side.par_chunks_mut(nx_h)
                .zip(scs.par_chunks_mut(nx_h))
                .enumerate()
                .for_each(|(j, (srow, crow))| {
                    let yj = (j as f64 - 0.5) * dx;
                    let ry = ramp(yj, ls, rate).max(ramp(ly - yj, ls, rate));
                    for i in 0..nx_h {
                        let xi = (i as f64 - 0.5) * dx;
                        let s = ramp(xi, ls, rate).max(ramp(lx - xi, ls, rate)).max(ry) as f32;
                        srow[i] = s;
                        crow[i] = s;
                    }
                });
        }
        debug_assert_eq!(pl.lev.len(), NLEV * nz_h);
        let ztop = pl.z_bot + pl.nz as f64 * pl.dz;
        for k in 0..nz_h {
            let z = pl.zc(k);
            pl.lev[L_SPZ * nz_h + k] = ramp(ztop - z, self.sponge_top_m, rate) as f32;
            pl.lev[L_SPZW * nz_h + k] =
                ramp(ztop - (z - 0.5 * pl.dz), self.sponge_top_m, rate) as f32;
        }
        pl.prm[P_NEST] = 1.0;
        Ok(pl)
    }
}

/// Уровень сетки окна (с ореолом) по плоскостям — вход [`nest`] и [`shift_warm`].
pub fn window_level(pl: &PreparedPlanes) -> Level {
    Level {
        nx: pl.nx_h,
        ny: pl.ny_h,
        nz: pl.nz_h,
        x0: pl.x0,
        y0: pl.y0,
        dx: pl.dx,
        dz: pl.dz,
        z_bot: pl.z_bot,
        halo: 1,
    }
}

/// Тип грани по типам двух клеток: 0 стенка, 1 неизвестная, 2 воздух–ореол, 3 ореол–ореол.
#[inline]
fn ftype(a: u8, b: u8) -> u8 {
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

/// Коды типов клеток и граней `cell + 4·tu + 16·tv + 64·tw` (`air_picard.glsl:K_SETUP`, `tcode`
/// эталона), раскладка `(k·ny_h + j)·nx_h + i`.
pub fn tcode(pl: &PreparedPlanes) -> Vec<u8> {
    let (nx, ny, nz) = (pl.nx_h, pl.ny_h, pl.nz_h);
    let nyx = nx * ny;
    let mut tc = vec![0u8; nx * ny * nz];
    tc.par_chunks_mut(nyx).enumerate().for_each(|(k, plane)| {
        let cell = |k: usize, j: usize, i: usize| pl.cell_type(k, j, i);
        for j in 0..ny {
            for i in 0..nx {
                let c = cell(k, j, i);
                let tu = if i == 0 {
                    3
                } else {
                    ftype(cell(k, j, i - 1), c)
                };
                let tv = if j == 0 {
                    3
                } else {
                    ftype(cell(k, j - 1, i), c)
                };
                let tw = if k == 0 {
                    0
                } else {
                    ftype(cell(k - 1, j, i), c)
                };
                plane[j * nx + i] = c + 4 * tu + 16 * tv + 64 * tw;
            }
        }
    });
    tc
}

// ---------------------------------------------------------------------------------------------
// граница от родителя
// ---------------------------------------------------------------------------------------------

/// Граница окна: значения граней `u`, `v`, `w` и центров θ′, θ′_d, все с ореолом в раскладке окна
/// — цель зоны релаксации и значения на граничных гранях (`ubu`, `ubv`, `ubw`, `thb`, `thbd`
/// эталона); `net`/`area` — поток через грани типа 2 до поправки (м³/с, м²) и `corr = net/area`,
/// вычтенная из этих граней по нормали (м/с).
#[derive(Clone, Debug, PartialEq)]
pub struct NestBc {
    pub ubu: Vec<f32>,
    pub ubv: Vec<f32>,
    pub ubw: Vec<f32>,
    pub thb: Vec<f32>,
    pub thbd: Vec<f32>,
    pub net: f64,
    pub area: f64,
    pub corr: f32,
}

/// Поток через граничные грани окна (тип 2) и их площадь (`K_FLUX` и две редукции): на грани
/// `s·u·A`, `s = −1`, если клетка — воздух (внешняя нормаль грани смотрит против оси), иначе
/// `+1`; `A = dx·dz` для `u`, `v` и `dx²` для `w`. Возвращает `(net, area)`.
pub fn boundary_flux(
    (dx, dz): (f64, f64),
    nyx: usize,
    tc: &[u8],
    ub: [&[f32]; 3],
) -> Result<(f64, f64), Error> {
    if nyx == 0 || !tc.len().is_multiple_of(nyx) || ub.iter().any(|a| a.len() != tc.len()) {
        return Err(Error::bad_input("window flux: длины не совпадают"));
    }
    let a_side = (dx as f32) * (dz as f32);
    let a_top = (dx as f32) * (dx as f32);
    let parts: Vec<(f64, f64)> = tc
        .par_chunks(nyx)
        .enumerate()
        .map(|(k, plane)| {
            let (mut f, mut a) = (0.0f64, 0.0f64);
            for (q, &t) in plane.iter().enumerate() {
                let g = k * nyx + q;
                let s = if t & 3 == 1 { -1.0f32 } else { 1.0 };
                let (mut fc, mut ac) = (0.0f32, 0.0f32);
                if (t >> 2) & 3 == 2 {
                    fc += s * ub[0][g] * a_side;
                    ac += a_side;
                }
                if (t >> 4) & 3 == 2 {
                    fc += s * ub[1][g] * a_side;
                    ac += a_side;
                }
                if (t >> 6) & 3 == 2 {
                    fc += s * ub[2][g] * a_top;
                    ac += a_top;
                }
                f += f64::from(fc);
                a += f64::from(ac);
            }
            (f, a)
        })
        .collect();
    Ok(parts
        .iter()
        .fold((0.0, 0.0), |(f, a), (pf, pa)| (f + pf, a + pa)))
}

/// Поправка потока Σ = 0 (`K_CORR`): грани типа 2 `−= (net/area)·s`. Возвращает `corr`.
pub fn apply_flux_correction(
    nyx: usize,
    tc: &[u8],
    ub: [&mut [f32]; 3],
    net: f64,
    area: f64,
) -> Result<f32, Error> {
    if nyx == 0 || !tc.len().is_multiple_of(nyx) || ub.iter().any(|a| a.len() != tc.len()) {
        return Err(Error::bad_input("window corr: длины не совпадают"));
    }
    let corr = if area > 0.0 { (net / area) as f32 } else { 0.0 };
    let [ubu, ubv, ubw] = ub;
    ubu.par_chunks_mut(nyx)
        .zip(ubv.par_chunks_mut(nyx))
        .zip(ubw.par_chunks_mut(nyx))
        .zip(tc.par_chunks(nyx))
        .for_each(|(((pu, pv), pw), pt)| {
            for (q, &t) in pt.iter().enumerate() {
                let s = if t & 3 == 1 { -1.0f32 } else { 1.0 };
                if (t >> 2) & 3 == 2 {
                    pu[q] -= corr * s;
                }
                if (t >> 4) & 3 == 2 {
                    pv[q] -= corr * s;
                }
                if (t >> 6) & 3 == 2 {
                    pw[q] -= corr * s;
                }
            }
        });
    Ok(corr)
}

/// Граница окна от родителя целиком: [`nest`] → поток → поправка. `parent` — уровень родителя
/// (область или окно крупнее) и его решение (с нагревом или без — по случаю), `pl`/`tc` — окно.
pub fn window_boundary(
    parent: &Level,
    src: &NestSrc,
    pl: &PreparedPlanes,
    tc: &[u8],
) -> Result<NestBc, Error> {
    let win = window_level(pl);
    let n = win.len();
    let mut bc = NestBc {
        ubu: vec![0.0; n],
        ubv: vec![0.0; n],
        ubw: vec![0.0; n],
        thb: vec![0.0; n],
        thbd: vec![0.0; n],
        net: 0.0,
        area: 0.0,
        corr: 0.0,
    };
    nest(
        parent,
        src,
        &win,
        tc,
        NestDst {
            u: &mut bc.ubu,
            v: &mut bc.ubv,
            w: &mut bc.ubw,
            th: &mut bc.thb,
            thd: &mut bc.thbd,
        },
    )?;
    let nyx = win.nx * win.ny;
    let (net, area) = boundary_flux((pl.dx, pl.dz), nyx, tc, [&bc.ubu, &bc.ubv, &bc.ubw])?;
    bc.net = net;
    bc.area = area;
    bc.corr = apply_flux_correction(nyx, tc, [&mut bc.ubu, &mut bc.ubv, &mut bc.ubw], net, area)?;
    Ok(bc)
}

// ---------------------------------------------------------------------------------------------
// старт окна
// ---------------------------------------------------------------------------------------------

/// Состояние окна в раскладке уровня с ореолом: `u, v, w, θ′, θ′_d, p` (как `picard_rs::State`).
#[derive(Clone, Debug, PartialEq)]
pub struct WindowState {
    pub u: Vec<f32>,
    pub v: Vec<f32>,
    pub w: Vec<f32>,
    pub th: Vec<f32>,
    pub thd: Vec<f32>,
    pub p: Vec<f32>,
}

impl WindowState {
    pub fn zeros(n: usize) -> Self {
        WindowState {
            u: vec![0.0; n],
            v: vec![0.0; n],
            w: vec![0.0; n],
            th: vec![0.0; n],
            thd: vec![0.0; n],
            p: vec![0.0; n],
        }
    }
}

/// Старт «родитель» (`K_BC`, `init = 1`): все грани и клетки — из границы (стенки 0), `p = 0`.
/// Дальше эталон делает 30 V-циклов проекции без изменения `p`.
pub fn init_from_boundary(tc: &[u8], bc: &NestBc) -> WindowState {
    let mut s = WindowState::zeros(tc.len());
    s.u.par_iter_mut()
        .zip(s.v.par_iter_mut())
        .zip(s.w.par_iter_mut())
        .zip(s.th.par_iter_mut())
        .zip(s.thd.par_iter_mut())
        .zip(tc.par_iter())
        .enumerate()
        .for_each(|(q, (((((u, v), w), th), thd), &t))| {
            let (cell, tu, tv, tw) = (t & 3, (t >> 2) & 3, (t >> 4) & 3, (t >> 6) & 3);
            *u = if tu == 0 { 0.0 } else { bc.ubu[q] };
            *v = if tv == 0 { 0.0 } else { bc.ubv[q] };
            *w = if tw == 0 { 0.0 } else { bc.ubw[q] };
            *th = if cell == 0 { 0.0 } else { bc.thb[q] };
            *thd = if cell == 0 { 0.0 } else { bc.thbd[q] };
        });
    s
}

/// Тёплый старт сдвинутого окна: [`init_from_boundary`] и поверх — прошлое окно со сдвигом на
/// целое число клеток ([`shift_warm`]); дальше эталон делает 4 V-цикла. `None` — прошлое окно не
/// подходит ([`shift_between`]: другая клетка, дробный сдвиг, нет пересечения): старт «родитель».
pub fn warm_from_previous(
    old_level: &Level,
    old: &WindowState,
    new_level: &Level,
    tc: &[u8],
    bc: &NestBc,
) -> Result<Option<WindowState>, Error> {
    warm_from_src(
        old_level,
        &ShiftSrc {
            u: &old.u,
            v: &old.v,
            w: &old.w,
            th: &old.th,
            thd: &old.thd,
            p: &old.p,
        },
        new_level,
        tc,
        bc,
    )
}

/// То же, прошлое окно — срезы состояния решателя (без копий).
pub fn warm_from_src(
    old_level: &Level,
    old: &ShiftSrc,
    new_level: &Level,
    tc: &[u8],
    bc: &NestBc,
) -> Result<Option<WindowState>, Error> {
    let Some(sh) = shift_between(old_level, new_level) else {
        return Ok(None);
    };
    let mut s = init_from_boundary(tc, bc);
    shift_warm(
        old_level,
        old,
        new_level,
        tc,
        sh,
        ShiftDst {
            u: &mut s.u,
            v: &mut s.v,
            w: &mut s.w,
            th: &mut s.th,
            thd: &mut s.thd,
            p: &mut s.p,
        },
    )?;
    Ok(Some(s))
}

// ---------------------------------------------------------------------------------------------
// случай решателя
// ---------------------------------------------------------------------------------------------

/// `picard_rs::Case` окна: сборка области (`build_solver_case`) с границей от родителя — фон
/// `ubg`/`vbg` (цель зоны релаксации импульса) и жёсткие значения граней типа 2 (`fixed_u`/
/// `fixed_v`) из `bc`, `Case.nest` (грани `w` типа 2, θ′ и θ′_d ореола и цель релаксации).
pub fn window_solver_case(
    pl: &PreparedPlanes,
    p: &CaseParams,
    cfg: &SolverCfg,
    bc: &NestBc,
) -> Result<Case, Error> {
    let bad = |m: &str| Error::bad_input(format!("window case: {m}"));
    let n = pl.nx_h * pl.ny_h * pl.nz_h;
    if bc.ubu.len() != n || bc.ubv.len() != n {
        return Err(bad("boundary size"));
    }
    let mut area = pl.clone();
    area.prm[P_NEST] = 0.0;
    let cfg = SolverCfg {
        u10: cfg.u10.max(1e-6),
        ..cfg.clone()
    };
    let mut case = build_solver_case(&area, p, &cfg)?;
    for (name, bidx, fixed, src) in [
        ("ubg", "b_u", "fixed_u", &bc.ubu),
        ("vbg", "b_v", "fixed_v", &bc.ubv),
    ] {
        let idx: Vec<usize> = case
            .arrays
            .get(bidx)
            .ok_or_else(|| bad("no face indices"))?
            .iter()
            .map(|&q| q as usize)
            .collect();
        let vals: Vec<f32> = idx.iter().map(|&q| src[q]).collect();
        case.arrays.insert(fixed.to_string(), vals);
        case.arrays.insert(name.to_string(), src.clone());
    }
    case.nest = Some(SolverNest {
        ubw: bc.ubw.clone(),
        thb: bc.thb.clone(),
        thbd: Some(bc.thbd.clone()),
    });
    Ok(case)
}

// ---------------------------------------------------------------------------------------------
// пара mech/heat окна (RW-6o)
// ---------------------------------------------------------------------------------------------

/// Родитель окна: уровень и два решения — без нагрева (`mech`, граница решения без нагрева) и с
/// нагревом (`heat`); типы клеток у обоих одни (`AirPicardJob.parent_data()`).
#[derive(Clone, Copy, Debug)]
pub struct ParentPair<'a> {
    pub level: &'a Level,
    pub heat: NestSrc<'a>,
    pub mech: NestSrc<'a>,
}

/// Прошлое окно той же клетки: уровень и два решения (тёплый старт каждого — своим).
#[derive(Clone, Copy, Debug)]
pub struct PrevPair<'a> {
    pub level: &'a Level,
    pub heat: ShiftSrc<'a>,
    pub mech: ShiftSrc<'a>,
}

/// Одно решение пары до итераций: плоскости, случай решателя, старт.
pub struct SetInput {
    pub planes: PreparedPlanes,
    pub case: Case,
    pub start: WindowState,
    /// Поправка потока границы, м/с (`corr`).
    pub corr: f32,
}

/// Пара окна до итераций (`AirWindowJob` для `mech = true`): решение без нагрева идёт от
/// родителя без нагрева, с нагревом — от родителя с нагревом, каждое со своей границей. Старт
/// «родитель» (`init_cycles = 30`) или тёплый — прошлое окно того же набора (`mech` — прошлое
/// `mech`, `heat` — прошлое `heat`, 4 V-цикла).
pub struct PairInputs {
    pub level: Level,
    pub tc: Vec<u8>,
    pub heat: SetInput,
    pub mech: SetInput,
    /// Старт тёплый (сдвиг прошлого окна).
    pub warm: bool,
}

/// Вход пары: плоскости обоих случаев, граница от родителя и старт. `heat` — окно с нагревом.
pub fn window_pair_inputs(
    heat: &AirWindowCase,
    parent: &ParentPair,
    prev: Option<&PrevPair>,
) -> Result<PairInputs, Error> {
    let mech = heat.without_heat();
    let (ph, pm) = rayon::join(|| heat.prepare(), || mech.prepare());
    let (ph, pm) = (ph?, pm?);
    let tc = tcode(&ph);
    let level = window_level(&ph);
    let prev = prev.filter(|p| shift_between(p.level, &level).is_some());
    let u10 = heat.case.u10;
    let set = |pl: PreparedPlanes,
               w: &AirWindowCase,
               src: &NestSrc,
               old: Option<ShiftSrc>|
     -> Result<SetInput, Error> {
        let bc = window_boundary(parent.level, src, &pl, &tc)?;
        let warm = match (prev, old) {
            (Some(p), Some(o)) => warm_from_src(p.level, &o, &level, &tc, &bc)?,
            _ => None,
        };
        let start = warm.unwrap_or_else(|| init_from_boundary(&tc, &bc));
        let case = window_solver_case(&pl, &w.case.p, &SolverCfg::new(u10), &bc)?;
        Ok(SetInput {
            planes: pl,
            case,
            start,
            corr: bc.corr,
        })
    };
    let (h, m) = rayon::join(
        || set(ph, heat, &parent.heat, prev.map(|p| p.heat)),
        || set(pm, &mech, &parent.mech, prev.map(|p| p.mech)),
    );
    Ok(PairInputs {
        level,
        tc,
        heat: h?,
        mech: m?,
        warm: prev.is_some(),
    })
}
