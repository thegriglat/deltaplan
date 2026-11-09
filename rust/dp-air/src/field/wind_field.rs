//! Среднее поле воздуха одного уровня (масштаб 1) на CPU: перенос `WindField` (AM-01, AM-08).
//!
//! Раскладка — как у решателя без ореола: клетка `(k, j, i)` лежит в `(k·ny + j)·nx + i`; `i` —
//! восток (x мира), `j` — север (y = −z мира), `k` — вверх. Центр клетки:
//! `x = x0 + (i + ½)·dx`, `y = y0 + (j + ½)·dx`, `z = z_bot + (k + ½)·dz`. Клетка под землёй,
//! если центр ниже `hc` столбца (блочное среднее рельефа сетки).
//!
//! `Field` — структура массивов (SoA): `u, v, w_mech, w_conv, theta` — плоские `Vec<f32>` без
//! ореола; столбцы (`hc, k1, ustar, uout, aout, desc, wstar, hmix`) — `Vec<f32>` по `j·nx + i`.
//! Сырые массивы отдаются только чтением (`raw_*`), для `AirThermals` (RW-10).
//!
//! Опрос (`sample*`) — арифметика `f64`, хранение `f32`, как в эталоне. Точка — как в эталоне:
//! `[x, y, z]`, x — восток, y — вверх, z — юг. `ground_h` — высота настоящей земли под точкой
//! (NaN — рельеф сетки). Опрос не выделяет памяти; пачка (`*_many`) идёт `rayon::par_chunks`.
//! Нечисловая точка не проверяется — вызывающий отдаёт конечные числа (фасад W4 сам обнуляет).
//!
//! Первая воздушная клетка столбца `k1` — по типам клеток решения (`from_mac`, PT7 v2: срезанная
//! клетка может лежать ниже блочного среднего `hc`), из файла поля — как записана, без неё —
//! от `hc` (первая клетка с центром не ниже `hc`).
//!
//! Приземный слой: по четырём соседним столбцам линейно по высоте между центрами клеток; ниже
//! якоря (центр `k1`; если он ниже `hc` — `hc + dz/2`, значение — интерполяцией по клеткам)
//! — логарифмический профиль к нулю на `z0` над `hc`; затем
//! билинейно по столбцам. Столбец читается на высоте `z_c = y + (hc_c − h)·exp(−agl/dx)`
//! (`h` — настоящая земля под точкой, `agl = y − h`): у земли — та же высота над землёй сетки,
//! что у наблюдателя над настоящей, выше подсеточные неровности гаснут на масштабе клетки.
//!
//! Границы модели: поле — стационарное решение на сетке 400 м (в эталоне — и окна 100/50 м);
//! профиль ниже первой клетки — нейтральный лог-закон без поправки на устойчивость; `u*` —
//! по лог-закону первой клетки не ниже `dz/2` над рельефом; `w*` — масштаб Дирдорфа по потоку
//! тепла, сглаженному квадратом 1500 м.
use crate::error::Error;
use picard_rs::state::State;
use rayon::prelude::*;

pub const KAPPA: f64 = 0.4;
pub const G: f64 = 9.81;
pub const THETA0: f64 = 300.0;
pub const RHO_CP: f64 = 1.2 * 1005.0;
/// Слой, в котором ищется «внешний» ветер над следом за гребнем, м над `hc`.
pub const A_OUT: f64 = 600.0;
/// Сглаживание потока тепла для `w*` (площадь конвективной ячейки ~ z_i), м.
pub const HEAT_SMOOTH_M: f64 = 1500.0;
/// Минимальная толщина слоя перемешивания, м.
pub const ZI_MIN: f64 = 300.0;
/// Индексы результата `turb_at`.
pub const T_SHEAR: usize = 0;
pub const T_N2: usize = 1;
pub const T_USTAR: usize = 2;
pub const T_UOUT: usize = 3;
pub const T_AOUT: usize = 4;
pub const T_DESC: usize = 5;
pub const T_WSTAR: usize = 6;
pub const T_HMIX: usize = 7;
pub const T_SIZE: usize = 8;

/// Сетка поля (без ореола), метры.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FieldGrid {
    pub dx: f64,
    pub dz: f64,
    /// Западный и южный края (y = −z мира), низ сетки (над морем).
    pub x0: f64,
    pub y0: f64,
    pub z_bot: f64,
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
}

/// Шероховатость: одно число или карта `ny·nx`.
#[derive(Clone, Debug, PartialEq)]
pub enum Z0 {
    Uniform(f64),
    Map(Vec<f64>),
}

/// Метаданные источника для приземного слоя и столбцов (`meta` эталона).
#[derive(Clone, Debug)]
pub struct FieldMeta {
    pub z0: Z0,
    /// dθ̄/dz фона по уровням (`nz`), К/м; иной размер или пусто — устойчивость не известна.
    pub gam: Vec<f32>,
    /// Поток тепла `ny·nx`, Вт/м²; пусто — нет нагрева (`w* = 0`).
    pub heat: Vec<f32>,
    /// Верх слоя перемешивания над долиной, м над морем; NaN — нет конвекции.
    pub z_i: f64,
    /// `z_i` по столбцам (`ny·nx`); пусто — везде `z_i`.
    pub z_i_col: Vec<f32>,
}

impl Default for FieldMeta {
    fn default() -> Self {
        FieldMeta {
            z0: Z0::Uniform(0.1),
            gam: Vec::new(),
            heat: Vec::new(),
            z_i: f64::NAN,
            z_i_col: Vec::new(),
        }
    }
}

/// Ограничители значений: модуль горизонтали и модуль вертикалей, м/с.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Limits {
    pub max_speed: f64,
    pub max_w: f64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_speed: 40.0,
            max_w: 10.0,
        }
    }
}

/// Скалярный канал опроса.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    /// θ′, К (у земли — значение первой воздушной клетки).
    Theta,
    /// Конвективная вертикаль, м/с (у земли — лог-профиль).
    WConv,
}

/// Поле одного уровня.
#[derive(Clone, Debug)]
pub struct Field {
    grid: FieldGrid,
    /// Ширина полосы края, клеток: у боковых граней и верха поле плавно уступает аналитике.
    pub edge_cells: f64,
    limits: Limits,
    z0: f64,
    u: Vec<f32>,
    v: Vec<f32>,
    w_mech: Vec<f32>,
    w_conv: Vec<f32>,
    theta: Vec<f32>,
    hc: Vec<f32>,
    k1: Vec<u32>,
    /// Эффективная земля лог-профиля столбца, м (`hc`; с долями первой клетки — вариант B).
    hg: Vec<f64>,
    /// Дробный индекс якоря лог-профиля (`k1`, если центр `k1` не ниже земли `hg`; иначе выше).
    kfa: Vec<f64>,
    z0c: Vec<f64>,
    inv_log1: Vec<f32>,
    ustar: Vec<f32>,
    uout: Vec<f32>,
    aout: Vec<f32>,
    desc: Vec<f32>,
    wstar: Vec<f32>,
    hmix: Vec<f32>,
    gam: Vec<f32>,
    heat: Vec<f32>,
    z_i: f64,
    z_i_col: Vec<f32>,
    nxy: usize,
    inv_dx: f64,
    inv_dz: f64,
    z_top: f64,
}

fn finite(x: f32) -> f32 {
    if x.is_finite() { x } else { 0.0 }
}

/// Столбец, в котором лежит точка: индекс левого нижнего, доли.
#[derive(Clone, Copy)]
struct Loc {
    c: usize,
    fx: f64,
    fy: f64,
}

impl Field {
    /// Поле из решения Пикара (`WindField.from_mac`): `heat` — решение с нагревом (u, v, w, θ′),
    /// `mech` — без нагрева (его `w` — механическая вертикаль; без пары — то же состояние).
    /// Скорости переносятся в центры (среднее двух граней), клетки с `cell == 0` — земля (нули),
    /// `w_conv = w − w_mech`; значения не конечные → 0; затем ограничители `limits` и столбцы.
    /// `cell` — типы клеток с ореолом `(nz+2, ny+2, nx+2)` (`tcode & 3` в эталоне), `hc` — рельеф
    /// сетки `ny·nx`.
    pub fn from_mac(
        heat: &State,
        mech: &State,
        grid: &FieldGrid,
        cell: &[f32],
        hc: &[f32],
        meta: FieldMeta,
        limits: Limits,
    ) -> Result<Field, Error> {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz);
        let (hx, hy) = (nx + 2, ny + 2);
        let hn = hx * hy * (nz + 2);
        for (name, st) in [("heat", heat), ("mech", mech)] {
            if st.dims != [hx, hy, nz + 2] {
                return Err(Error::bad_input(format!(
                    "Field::from_mac: {name}.dims {:?} != {:?}",
                    st.dims,
                    [hx, hy, nz + 2]
                )));
            }
            for (a, v) in [("u", &st.u), ("v", &st.v), ("w", &st.w), ("th", &st.th)] {
                if v.len() != hn {
                    return Err(Error::bad_input(format!(
                        "Field::from_mac: {name}.{a} длина {} != {hn}",
                        v.len()
                    )));
                }
            }
        }
        if cell.len() != hn {
            return Err(Error::bad_input(format!(
                "Field::from_mac: cell длина {} != {hn}",
                cell.len()
            )));
        }
        let n = nx * ny * nz;
        let plane = nx * ny;
        let (mut cu, mut cv, mut cw) = (vec![0f32; n], vec![0f32; n], vec![0f32; n]);
        let (mut cc, mut ct) = (vec![0f32; n], vec![0f32; n]);
        let sy = hx;
        let sz = hx * hy;
        cu.par_chunks_mut(plane)
            .zip(cv.par_chunks_mut(plane))
            .zip(cw.par_chunks_mut(plane))
            .zip(cc.par_chunks_mut(plane))
            .zip(ct.par_chunks_mut(plane))
            .enumerate()
            .for_each(|(k, ((((pu, pv), pw), pc), pt))| {
                for j in 0..ny {
                    for i in 0..nx {
                        let h = ((k + 1) * hy + j + 1) * hx + i + 1;
                        let c = j * nx + i;
                        if cell[h] == 0.0 {
                            continue;
                        }
                        pu[c] = (0.5 * (heat.u[h] as f64 + heat.u[h + 1] as f64)) as f32;
                        pv[c] = (0.5 * (heat.v[h] as f64 + heat.v[h + sy] as f64)) as f32;
                        let wm = 0.5 * (mech.w[h] as f64 + mech.w[h + sz] as f64);
                        pw[c] = wm as f32;
                        pc[c] = (0.5 * (heat.w[h] as f64 + heat.w[h + sz] as f64) - wm) as f32;
                        pt[c] = heat.th[h];
                    }
                }
            });
        // первая воздушная клетка столбца — по типам (PT7 v2: граница воздуха не `hc`)
        let mut k1 = vec![nz as u32; plane];
        k1.par_iter_mut().enumerate().for_each(|(c, o)| {
            let (j, i) = (c / nx, c % nx);
            if let Some(k) = (0..nz).find(|&k| cell[((k + 1) * hy + j + 1) * hx + i + 1] != 0.0) {
                *o = k as u32;
            }
        });
        Self::from_arrays_k1(grid, cu, cv, cw, cc, ct, hc.to_vec(), Some(k1), meta, limits)
    }

    /// Поле из массивов в центрах клеток (`WindField.from_arrays`): `nz·ny·nx`, `hc` — `ny·nx`.
    /// Нечисловые значения → 0; ограничители — сразу. Ошибка — размеры не сходятся.
    #[allow(clippy::too_many_arguments)]
    pub fn from_arrays(
        grid: &FieldGrid,
        u: Vec<f32>,
        v: Vec<f32>,
        w_mech: Vec<f32>,
        w_conv: Vec<f32>,
        theta: Vec<f32>,
        hc: Vec<f32>,
        meta: FieldMeta,
        limits: Limits,
    ) -> Result<Field, Error> {
        Self::from_arrays_k1(grid, u, v, w_mech, w_conv, theta, hc, None, meta, limits)
    }

    /// То же, с первой воздушной клеткой столбца `k1` (`ny·nx`, `nz` — столбец в земле) из типов
    /// клеток; `None` — от `hc`: первая клетка с центром не ниже `hc` (поле без срезанных клеток).
    #[allow(clippy::too_many_arguments)]
    pub fn from_arrays_k1(
        grid: &FieldGrid,
        mut u: Vec<f32>,
        mut v: Vec<f32>,
        mut w_mech: Vec<f32>,
        mut w_conv: Vec<f32>,
        mut theta: Vec<f32>,
        hc: Vec<f32>,
        k1_in: Option<Vec<u32>>,
        meta: FieldMeta,
        limits: Limits,
    ) -> Result<Field, Error> {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz);
        if nx < 2 || ny < 2 || nz < 2 || hc.len() != nx * ny {
            return Err(Error::bad_input("Field: неверные размеры сетки"));
        }
        let nxy = nx * ny;
        let n = nxy * nz;
        if let Some(k) = &k1_in
            && (k.len() != nxy || k.iter().any(|&q| q as usize > nz))
        {
            return Err(Error::bad_input("Field: неверный массив k1"));
        }
        for (name, a) in [
            ("u", &u),
            ("v", &v),
            ("w_mech", &w_mech),
            ("w_conv", &w_conv),
            ("theta", &theta),
        ] {
            if a.len() != n {
                return Err(Error::bad_input(format!(
                    "Field: размер массива {name} {} != {n}",
                    a.len()
                )));
            }
        }
        let (z0c, z0) = match &meta.z0 {
            Z0::Map(m) => {
                if m.len() != nxy {
                    return Err(Error::bad_input("Field: размер карты z0 != nx·ny"));
                }
                let s: f64 = m.iter().map(|x| x.ln()).sum();
                (m.clone(), (s / nxy as f64).exp())
            }
            Z0::Uniform(z) => (vec![*z; nxy], *z),
        };
        for a in [&mut u, &mut v, &mut w_mech, &mut w_conv, &mut theta] {
            a.par_iter_mut().for_each(|x| *x = finite(*x));
        }
        let mut f = Field {
            grid: *grid,
            edge_cells: 5.0,
            limits: Limits {
                max_speed: f64::INFINITY,
                max_w: f64::INFINITY,
            },
            z0,
            u,
            v,
            w_mech,
            w_conv,
            theta,
            hc,
            k1: vec![0; nxy],
            hg: vec![0.0; nxy],
            kfa: vec![0.0; nxy],
            z0c,
            inv_log1: vec![0.0; nxy],
            ustar: vec![0.0; nxy],
            uout: vec![0.0; nxy],
            aout: vec![0.0; nxy],
            desc: vec![0.0; nxy],
            wstar: vec![0.0; nxy],
            hmix: vec![0.0; nxy],
            gam: Vec::new(),
            heat: meta.heat,
            z_i: meta.z_i,
            z_i_col: meta.z_i_col,
            nxy,
            inv_dx: 1.0 / grid.dx,
            inv_dz: 1.0 / grid.dz,
            z_top: grid.z_bot + nz as f64 * grid.dz,
        };
        if meta.gam.len() == nz {
            f.gam = meta.gam;
        }
        if f.z_i_col.len() != nxy {
            f.z_i_col = Vec::new();
        }
        f.build_columns(k1_in);
        f.apply_limits(limits);
        f.build_boundary_layer();
        f.build_convective();
        Ok(f)
    }

    /// Столбцы приземного слоя: `k1` (из типов или от `hc`), земля лог-профиля `hg` и его якорь.
    /// Якорь — центр `k1`; если он ниже земли (срезанная клетка: первая воздушная клетка лежит
    /// ниже блочного среднего `hc`), — `hg + dz/2` (как у `u*`: клетка ближе `dz/2` к земле сидит
    /// в «углу» ступеньки), а значение в нём интерполируется по клеткам.
    fn build_columns(&mut self, k1_in: Option<Vec<u32>>) {
        let g = self.grid;
        let (inv_dz, nz) = (self.inv_dz, g.nz);
        let (hc, z0c) = (&self.hc, &self.z0c);
        let k1_in = &k1_in;
        self.k1
            .par_iter_mut()
            .zip(self.hg.par_iter_mut())
            .zip(self.kfa.par_iter_mut())
            .zip(self.inv_log1.par_iter_mut())
            .enumerate()
            .for_each(|(c, (((k1, hg), kfa), il))| {
                let h = hc[c] as f64;
                let kk = match k1_in {
                    Some(v) => v[c] as usize,
                    // под землёй — центр ниже hc: первая воздушная — наименьшая k с центром ≥ hc
                    None => (((h - g.z_bot) * inv_dz - 0.5).ceil().max(0.0) as usize).min(nz),
                };
                *k1 = kk as u32;
                let zc0 = z0c[c];
                *hg = h;
                let zc = g.z_bot + (kk as f64 + 0.5) * g.dz;
                let za = if zc >= h { zc } else { h + 0.5 * g.dz };
                *kfa = if zc >= h {
                    kk as f64
                } else {
                    (za - g.z_bot) * inv_dz - 0.5
                };
                let a1 = (za - h).max(2.0 * zc0);
                *il = (1.0 / (a1 / zc0).ln()) as f32;
            });
    }

    /// Ограничители: модуль горизонтали ≤ `max_speed`, `|w_mech|`, `|w_conv|` ≤ `max_w`. Те же
    /// пределы повторно — без прохода; новые — пересчёт столбцов пограничного слоя.
    pub fn clamp_values(&mut self, limits: Limits) {
        if self.limits == limits {
            return;
        }
        self.apply_limits(limits);
        self.build_boundary_layer();
    }

    fn apply_limits(&mut self, limits: Limits) {
        self.limits = limits;
        self.u
            .par_chunks_mut(4096)
            .zip(self.v.par_chunks_mut(4096))
            .zip(self.w_mech.par_chunks_mut(4096))
            .zip(self.w_conv.par_chunks_mut(4096))
            .for_each(|(((u, v), w), q)| limit_chunk(limits, u, v, w, q));
    }

    /// Столбцы для масштаба 3: `u*` по лог-закону (первая воздушная клетка, центр которой не
    /// ниже `dz/2` над `hc`: ниже клетка сидит в «углу» ступеньки маски и тормозится её лобовым
    /// сопротивлением), «внешний» ветер `U_out` — наибольшая `|U_h|` столбца в слое `A_OUT` над
    /// `hc`, наклон опускания `desc = −min w_mech / max(U_out, 0,5)`.
    fn build_boundary_layer(&mut self) {
        let g = self.grid;
        let nz = g.nz;
        let nxy = self.nxy;
        let inv_dz = self.inv_dz;
        let (k1v, hc, z0c) = (&self.k1, &self.hc, &self.z0c);
        let (u, v, w) = (&self.u, &self.v, &self.w_mech);
        self.ustar
            .par_iter_mut()
            .zip(self.uout.par_iter_mut())
            .zip(self.aout.par_iter_mut())
            .zip(self.desc.par_iter_mut())
            .enumerate()
            .for_each(|(c, (((us, uo), ao), de))| {
                let k1 = k1v[c] as usize;
                if k1 >= nz {
                    *us = 0.0;
                    *uo = 0.0;
                    *ao = A_OUT as f32;
                    *de = 0.0;
                    return;
                }
                let hcc = hc[c] as f64;
                // столбец без среза (k1 от hc, как у GD) — первая клетка с центром не ниже dz/2 над
                // hc; срезанная k1 лежит ниже hc, её центр сидит в «углу» ступеньки маски: u для
                // u* — на hc + dz/2 интерполяцией по клеткам (якорь выборки)
                let k_hc = (((hcc - g.z_bot) * inv_dz - 0.5).ceil().max(0.0) as usize).min(nz);
                let (su, sv, ar);
                if k1 == k_hc {
                    let mut kr = k1;
                    let mut a = g.z_bot + (k1 as f64 + 0.5) * g.dz - hcc;
                    while a < 0.5 * g.dz && kr + 1 < nz {
                        kr += 1;
                        a += g.dz;
                    }
                    ar = a;
                    su = u[kr * nxy + c] as f64;
                    sv = v[kr * nxy + c] as f64;
                } else {
                    let kf = ((hcc + 0.5 * g.dz - g.z_bot) * inv_dz - 0.5)
                        .max(k1 as f64)
                        .min(nz as f64 - 1.0);
                    let kc = (kf as usize).min(nz.saturating_sub(2));
                    let t = if nz < 2 { 0.0 } else { kf - kc as f64 };
                    ar = g.z_bot + (kf + 0.5) * g.dz - hcc;
                    let (i, i2) = (kc * nxy + c, (kc + (nz > 1) as usize) * nxy + c);
                    su = u[i] as f64 + (u[i2] as f64 - u[i] as f64) * t;
                    sv = v[i] as f64 + (v[i2] as f64 - v[i] as f64) * t;
                }
                let zc0 = z0c[c];
                let sp = su.hypot(sv);
                *us = (KAPPA * sp / (ar.max(2.0 * zc0) / zc0).ln()) as f32;
                let mut u_max = 0.0f64;
                let mut a_max = ar;
                let mut w_min = 0.0f64;
                for k in k1..nz {
                    let a = g.z_bot + (k as f64 + 0.5) * g.dz - hcc;
                    if a > A_OUT {
                        break;
                    }
                    let j = k * nxy + c;
                    let s = (u[j] as f64).hypot(v[j] as f64);
                    if s > u_max {
                        u_max = s;
                        a_max = a;
                    }
                    w_min = w_min.min(w[j] as f64);
                }
                *uo = u_max as f32;
                *ao = a_max.max(2.0 * zc0) as f32;
                *de = (-w_min / u_max.max(0.5)) as f32;
            });
    }

    /// `w*` и толщина слоя перемешивания по столбцам, если есть поток тепла и `z_i`:
    /// `w* = (g/θ0 · H/(ρc_p) · h)^(1/3)`, `h = max(z_i − hc, ZI_MIN)`; `H` сглажен квадратом
    /// `HEAT_SMOOTH_M`. Нет данных — `w* = 0`.
    fn build_convective(&mut self) {
        self.wstar.fill(0.0);
        self.hmix.fill(0.0);
        if self.heat.len() != self.nxy || !self.z_i.is_finite() {
            return;
        }
        let (nx, ny) = (self.grid.nx, self.grid.ny);
        let r = ((0.5 * HEAT_SMOOTH_M / self.grid.dx).round().max(0.0)) as usize;
        let heat = &self.heat;
        let mut tmp = vec![0f32; self.nxy];
        tmp.par_chunks_mut(nx)
            .zip(heat.par_chunks(nx))
            .for_each(|(row, src)| box_row(src, r, row));
        let (hc, zic, zi) = (&self.hc, &self.z_i_col, self.z_i);
        self.wstar
            .par_chunks_mut(nx)
            .zip(self.hmix.par_chunks_mut(nx))
            .enumerate()
            .for_each(|(j, (ws, hm))| {
                let (a, b) = (j.saturating_sub(r), (j + r).min(ny - 1));
                for i in 0..nx {
                    let mut s = 0.0f64;
                    for q in a..=b {
                        s += tmp[q * nx + i] as f64;
                    }
                    let c = j * nx + i;
                    let zc = if zic.is_empty() { zi } else { zic[c] as f64 };
                    let h = hc[c] as f64;
                    hm[i] = (zc - h).max(ZI_MIN) as f32;
                    ws[i] = deardorff_wstar(s / (b - a + 1) as f64, zc, h) as f32;
                }
            });
    }

    // ------------------------------------------------------------------ геометрия

    pub fn grid(&self) -> &FieldGrid {
        &self.grid
    }

    /// Применённые ограничители.
    pub fn limits(&self) -> Limits {
        self.limits
    }

    /// Шероховатость области (лог-среднее карты), м.
    pub fn z0(&self) -> f64 {
        self.z0
    }

    /// Шероховатость столбца под точкой (ближайший столбец), м.
    pub fn z0_at(&self, pos: [f32; 3]) -> f64 {
        let g = &self.grid;
        let i = (((pos[0] as f64 - g.x0) * self.inv_dx).floor().max(0.0) as usize).min(g.nx - 1);
        let j = (((-(pos[2] as f64) - g.y0) * self.inv_dx).floor().max(0.0) as usize).min(g.ny - 1);
        self.z0c[j * g.nx + i]
    }

    /// Точка внутри поля (по горизонтали и между низом и верхом сетки).
    pub fn contains(&self, pos: [f32; 3]) -> bool {
        let g = &self.grid;
        let gx = (pos[0] as f64 - g.x0) * self.inv_dx;
        let gy = (-(pos[2] as f64) - g.y0) * self.inv_dx;
        let y = pos[1] as f64;
        gx >= 0.0
            && gx <= g.nx as f64
            && gy >= 0.0
            && gy <= g.ny as f64
            && y >= g.z_bot
            && y <= self.z_top
    }

    /// Вес поля 0..1: 1 внутри, в полосе края (`edge_cells` клеток у боковых граней, столько же
    /// клеток `dz` под верхом) плавно (smoothstep) → 0 на границе, 0 снаружи.
    pub fn edge_weight(&self, pos: [f32; 3]) -> f64 {
        let g = &self.grid;
        let gx = (pos[0] as f64 - g.x0) * self.inv_dx;
        let gy = (-(pos[2] as f64) - g.y0) * self.inv_dx;
        let d = gx
            .min(g.nx as f64 - gx)
            .min(gy)
            .min(g.ny as f64 - gy)
            .min((self.z_top - pos[1] as f64) * self.inv_dz);
        if d <= 0.0 {
            return 0.0;
        }
        if d >= self.edge_cells {
            return 1.0;
        }
        let t = d / self.edge_cells;
        t * t * (3.0 - 2.0 * t)
    }

    fn locate(&self, x: f64, z: f64) -> Loc {
        let g = &self.grid;
        let gx = ((x - g.x0) * self.inv_dx - 0.5).clamp(0.0, g.nx as f64 - 1.0);
        let gy = ((-z - g.y0) * self.inv_dx - 0.5).clamp(0.0, g.ny as f64 - 1.0);
        let i0 = (gx as usize).min(g.nx - 2);
        let j0 = (gy as usize).min(g.ny - 2);
        Loc {
            c: j0 * g.nx + i0,
            fx: gx - i0 as f64,
            fy: gy - j0 as f64,
        }
    }

    fn bilerp_hc(&self, l: Loc) -> f64 {
        let (c, nx) = (l.c, self.grid.nx);
        let lerp = |a: f64, b: f64, t: f64| a + (b - a) * t;
        let h0 = lerp(self.hc[c] as f64, self.hc[c + 1] as f64, l.fx);
        let h1 = lerp(self.hc[c + nx] as f64, self.hc[c + nx + 1] as f64, l.fx);
        lerp(h0, h1, l.fy)
    }

    /// Высота рельефа сетки (билинейно по центрам столбцов), м. `x`, `z` — мир.
    pub fn ground_height(&self, x: f32, z: f32) -> f64 {
        self.bilerp_hc(self.locate(x as f64, z as f64))
    }

    /// `(e, h)`: столбец c читается на высоте `y + (hc_c − h)·e`.
    fn shift(&self, y: f64, ground_h: f64, l: Loc) -> (f64, f64) {
        let h = if ground_h.is_nan() {
            self.bilerp_hc(l)
        } else {
            ground_h
        };
        ((-(y - h).max(0.0) * self.inv_dx).exp(), h)
    }

    // ------------------------------------------------------------------ опрос

    /// Скорость воздуха (u, w_mech, v → мир: x — восток, y — вверх, z — юг), м/с. Вне поля —
    /// значения ближайшего края.
    pub fn sample(&self, pos: [f32; 3], ground_h: f32) -> [f32; 3] {
        let (x, y, z) = (pos[0] as f64, pos[1] as f64, pos[2] as f64);
        let l = self.locate(x, z);
        let (e, h) = self.shift(y, ground_h as f64, l);
        let nx = self.grid.nx;
        let lerp3 = |a: [f64; 3], b: [f64; 3], t: f64| {
            [
                a[0] + (b[0] - a[0]) * t,
                a[1] + (b[1] - a[1]) * t,
                a[2] + (b[2] - a[2]) * t,
            ]
        };
        let r0 = lerp3(
            self.col_vel(l.c, y, e, h),
            self.col_vel(l.c + 1, y, e, h),
            l.fx,
        );
        let r1 = lerp3(
            self.col_vel(l.c + nx, y, e, h),
            self.col_vel(l.c + nx + 1, y, e, h),
            l.fx,
        );
        let r = lerp3(r0, r1, l.fy);
        [r[0] as f32, r[2] as f32, -r[1] as f32]
    }

    /// Пачка: `out[i] = sample(pos[i], ground_h[i])` по `min` длин; без выделений.
    pub fn sample_many(&self, pos: &[[f32; 3]], ground_h: &[f32], out: &mut [[f32; 3]]) {
        let n = pos.len().min(ground_h.len()).min(out.len());
        out[..n]
            .par_chunks_mut(256)
            .zip(pos[..n].par_chunks(256))
            .zip(ground_h[..n].par_chunks(256))
            .for_each(|((o, p), g)| sample_chunk(self, o, p, g));
    }

    /// θ′ (К) или `w_conv` (м/с) в точке.
    pub fn sample_scalar(&self, ch: Channel, pos: [f32; 3], ground_h: f32) -> f64 {
        let (x, y, z) = (pos[0] as f64, pos[1] as f64, pos[2] as f64);
        let l = self.locate(x, z);
        let (e, h) = self.shift(y, ground_h as f64, l);
        let nx = self.grid.nx;
        let (arr, log_prof) = match ch {
            Channel::Theta => (&self.theta, false),
            Channel::WConv => (&self.w_conv, true),
        };
        let s = |c: usize| self.col_scalar(arr, c, y, e, h, log_prof);
        let r0 = s(l.c) + (s(l.c + 1) - s(l.c)) * l.fx;
        let r1 = s(l.c + nx) + (s(l.c + nx + 1) - s(l.c + nx)) * l.fx;
        r0 + (r1 - r0) * l.fy
    }

    pub fn sample_theta(&self, pos: [f32; 3], ground_h: f32) -> f64 {
        self.sample_scalar(Channel::Theta, pos, ground_h)
    }

    pub fn sample_w_conv(&self, pos: [f32; 3], ground_h: f32) -> f64 {
        self.sample_scalar(Channel::WConv, pos, ground_h)
    }

    /// Пачка скаляров; без выделений.
    pub fn sample_scalar_many(
        &self,
        ch: Channel,
        pos: &[[f32; 3]],
        ground_h: &[f32],
        out: &mut [f32],
    ) {
        let n = pos.len().min(ground_h.len()).min(out.len());
        out[..n]
            .par_chunks_mut(256)
            .zip(pos[..n].par_chunks(256))
            .zip(ground_h[..n].par_chunks(256))
            .for_each(|((o, p), g)| scalar_chunk(self, ch, o, p, g));
    }

    /// Значение `at(i)` между клетками `k` и `k + 1` столбца `c` по дробному индексу `kf ≥ k1`.
    #[inline]
    fn kf_cell(&self, c: usize, kf: f64) -> (usize, f64) {
        let nz = self.grid.nz;
        let mut k = kf as usize;
        let mut t = kf - k as f64;
        if k >= nz - 1 {
            k = nz - 2;
            t = 1.0;
        }
        (k * self.nxy + c, t)
    }

    /// (u, v, w_mech) столбца `c` на высоте `y` (со сдвигом `(e, h)`).
    fn col_vel(&self, c: usize, y: f64, e: f64, h: f64) -> [f64; 3] {
        let k1 = self.k1[c] as usize;
        let nz = self.grid.nz;
        if k1 >= nz {
            return [0.0; 3];
        }
        let hcol = self.hc[c] as f64;
        let z = y + (hcol - h) * e;
        let kf = (z - self.grid.z_bot) * self.inv_dz - 0.5;
        let at = |i: usize| [self.u[i] as f64, self.v[i] as f64, self.w_mech[i] as f64];
        let between = |kf: f64| {
            let (i, t) = self.kf_cell(c, kf);
            let (p, q) = (at(i), at(i + self.nxy));
            [
                p[0] + (q[0] - p[0]) * t,
                p[1] + (q[1] - p[1]) * t,
                p[2] + (q[2] - p[2]) * t,
            ]
        };
        let kfa = self.kfa[c];
        if kf >= kfa {
            return between(kf);
        }
        // ниже якоря: лог-профиль к нулю на z0 над землёй hg
        let agl = z - self.hg[c];
        let zc0 = self.z0c[c];
        if agl <= zc0 {
            return [0.0; 3];
        }
        let p = if kfa == k1 as f64 {
            at(k1 * self.nxy + c)
        } else {
            between(kfa)
        };
        let f = ((agl / zc0).ln() * self.inv_log1[c] as f64).min(1.0);
        [p[0] * f, p[1] * f, p[2] * f]
    }

    fn col_scalar(&self, arr: &[f32], c: usize, y: f64, e: f64, h: f64, log_prof: bool) -> f64 {
        let k1 = self.k1[c] as usize;
        let nz = self.grid.nz;
        if k1 >= nz {
            return 0.0;
        }
        let hcol = self.hc[c] as f64;
        let z = y + (hcol - h) * e;
        let kf = (z - self.grid.z_bot) * self.inv_dz - 0.5;
        let between = |kf: f64| {
            let (i, t) = self.kf_cell(c, kf);
            let (a, b) = (arr[i] as f64, arr[i + self.nxy] as f64);
            a + (b - a) * t
        };
        let kfa = self.kfa[c];
        if kf >= kfa {
            return between(kf);
        }
        let v1 = if kfa == k1 as f64 {
            arr[k1 * self.nxy + c] as f64
        } else {
            between(kfa)
        };
        if !log_prof {
            return v1;
        }
        let agl = z - self.hg[c];
        let zc0 = self.z0c[c];
        if agl <= zc0 {
            return 0.0;
        }
        v1 * ((agl / zc0).ln() * self.inv_log1[c] as f64).min(1.0)
    }

    /// Величины пограничного слоя в точке для масштаба 3: сдвиг `|∂U_h/∂z|` (1/с) и
    /// `N² = g/θ0·(dθ̄/dz + ∂θ′/∂z)` (1/с²; NaN — нет `gam`) на высоте точки, по столбцам — `u*`,
    /// `U_out`, его высота над землёй, наклон опускания, `w*`, толщина слоя перемешивания (0 —
    /// нет нагрева). Индексы `T_*`; билинейно по 4 столбцам; вне поля — ближайший край.
    pub fn turb_at(&self, pos: [f32; 3], ground_h: f32) -> [f32; T_SIZE] {
        let (x, y, z) = (pos[0] as f64, pos[1] as f64, pos[2] as f64);
        let l = self.locate(x, z);
        let (e, h) = self.shift(y, ground_h as f64, l);
        let nx = self.grid.nx;
        let mut out = [0f32; T_SIZE];
        for (c, wq) in [
            (l.c, (1.0 - l.fx) * (1.0 - l.fy)),
            (l.c + 1, l.fx * (1.0 - l.fy)),
            (l.c + nx, (1.0 - l.fx) * l.fy),
            (l.c + nx + 1, l.fx * l.fy),
        ] {
            let (sh, n2) = self.col_grad(c, y, e, h);
            let mut add = |q: usize, v: f64| out[q] += (v * wq) as f32;
            add(T_SHEAR, sh);
            add(T_N2, n2);
            add(T_USTAR, self.ustar[c] as f64);
            add(T_UOUT, self.uout[c] as f64);
            add(T_AOUT, self.aout[c] as f64);
            add(T_DESC, self.desc[c] as f64);
            add(T_WSTAR, self.wstar[c] as f64);
            add(T_HMIX, self.hmix[c] as f64);
        }
        if self.gam.is_empty() {
            out[T_N2] = f32::NAN;
        }
        out
    }

    /// (`|∂U_h/∂z|`, N²) столбца `c` на высоте `y`: между центрами — разность пары клеток;
    /// ниже центра первой воздушной — производная лог-профиля `|U₁|/(a·ln(a₁/z0))`, N² первой пары.
    fn col_grad(&self, c: usize, y: f64, e: f64, h: f64) -> (f64, f64) {
        let nz = self.grid.nz;
        let k1 = self.k1[c] as usize;
        if k1 >= nz - 1 {
            return (0.0, 0.0);
        }
        let hcol = self.hc[c] as f64;
        let z = y + (hcol - h) * e;
        let kf = (z - self.grid.z_bot) * self.inv_dz - 0.5;
        let k = (kf as i64).clamp(k1 as i64, nz as i64 - 2) as usize;
        let i = k * self.nxy + c;
        let i2 = i + self.nxy;
        let mut n2 = 0.0;
        if !self.gam.is_empty() {
            let t = (kf - k as f64).clamp(0.0, 1.0);
            let dth = (self.theta[i2] as f64 - self.theta[i] as f64) * self.inv_dz;
            let g0 = self.gam[k] as f64;
            let g1 = self.gam[k + 1] as f64;
            n2 = G / THETA0 * (g0 + (g1 - g0) * t + dth);
        }
        if kf >= self.kfa[c] {
            let du = (self.u[i2] as f64 - self.u[i] as f64)
                .hypot(self.v[i2] as f64 - self.v[i] as f64)
                * self.inv_dz;
            return (du, n2);
        }
        let a = (z - self.hg[c]).max(self.z0c[c]);
        // |U| в якоре — как у выборки (col_vel): сдвиг лог-профиля совпадает с его производной
        let kfa = self.kfa[c];
        let (ia, ta) = self.kf_cell(c, kfa);
        let ua = self.u[ia] as f64 + (self.u[ia + self.nxy] as f64 - self.u[ia] as f64) * ta;
        let va = self.v[ia] as f64 + (self.v[ia + self.nxy] as f64 - self.v[ia] as f64) * ta;
        let u1 = ua.hypot(va);
        (u1 * self.inv_log1[c] as f64 / a, n2)
    }

    // ------------------------------------------------------------------ только чтение

    /// u по клеткам `(k·ny + j)·nx + i`, м/с.
    pub fn raw_u(&self) -> &[f32] {
        &self.u
    }
    pub fn raw_v(&self) -> &[f32] {
        &self.v
    }
    /// Механическая вертикаль, м/с.
    pub fn raw_w_mech(&self) -> &[f32] {
        &self.w_mech
    }
    /// Конвективная вертикаль, м/с.
    pub fn raw_w_conv(&self) -> &[f32] {
        &self.w_conv
    }
    /// θ′, К.
    pub fn raw_theta(&self) -> &[f32] {
        &self.theta
    }
    /// Рельеф сетки по столбцам (`j·nx + i`), м над морем.
    pub fn raw_hc(&self) -> &[f32] {
        &self.hc
    }
    /// Первая воздушная клетка столбца (`nz` — столбец в земле).
    pub fn raw_k1(&self) -> &[u32] {
        &self.k1
    }
    /// `u*` по столбцам, м/с.
    pub fn raw_ustar(&self) -> &[f32] {
        &self.ustar
    }
    pub fn raw_uout(&self) -> &[f32] {
        &self.uout
    }
    pub fn raw_aout(&self) -> &[f32] {
        &self.aout
    }
    pub fn raw_desc(&self) -> &[f32] {
        &self.desc
    }
    /// `w*` по столбцам, м/с.
    pub fn raw_wstar(&self) -> &[f32] {
        &self.wstar
    }
    /// Толщина слоя перемешивания `z_i − hc` по столбцам, м (0 — нет данных о нагреве).
    pub fn raw_hmix(&self) -> &[f32] {
        &self.hmix
    }
    /// Поток тепла решения (`ny·nx`), Вт/м²; пусто — нет.
    pub fn heat_flux(&self) -> &[f32] {
        &self.heat
    }
    /// Верх слоя перемешивания над долиной, м над морем; NaN — нет конвекции.
    pub fn z_i(&self) -> f64 {
        self.z_i
    }
    /// `z_i` по столбцам; пусто — нет данных (везде `z_i()`).
    pub fn z_i_col(&self) -> &[f32] {
        &self.z_i_col
    }
    /// dθ̄/dz фона по уровням (`nz`), К/м; пусто — нет.
    pub fn gam(&self) -> &[f32] {
        &self.gam
    }
}

/// Масштаб Дирдорфа `w* = (g/θ0 · H/(ρc_p) · h)^(1/3)`, `h = max(z_i − hc, ZI_MIN)`, м/с; `H ≤ 0`
/// или нет `z_i` — 0. `H` — поток тепла, Вт/м²; `z_i`, `hc` — м над морем.
pub fn deardorff_wstar(heat_wm2: f64, z_i: f64, hc: f64) -> f64 {
    if heat_wm2 <= 0.0 || !z_i.is_finite() {
        return 0.0;
    }
    (G / THETA0 * heat_wm2 / RHO_CP * (z_i - hc).max(ZI_MIN)).powf(1.0 / 3.0)
}

/// Ограничители на пачке клеток (`u`, `v`, `w_mech`, `w_conv` одной длины).
#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn limit_chunk(limits: Limits, u: &mut [f32], v: &mut [f32], w: &mut [f32], q: &mut [f32]) {
    let s2 = limits.max_speed * limits.max_speed;
    let mw = limits.max_w;
    let n = u.len().min(v.len()).min(w.len()).min(q.len());
    let it = u[..n]
        .iter_mut()
        .zip(v[..n].iter_mut())
        .zip(w[..n].iter_mut())
        .zip(q[..n].iter_mut());
    for (((u, v), w), q) in it {
        let (a, b) = (*u as f64, *v as f64);
        let ss = a * a + b * b;
        if ss > s2 {
            let k = limits.max_speed / ss.sqrt();
            *u = (a * k) as f32;
            *v = (b * k) as f32;
        }
        if (*w as f64).abs() > mw {
            *w = (*w as f64).clamp(-mw, mw) as f32;
        }
        if (*q as f64).abs() > mw {
            *q = (*q as f64).clamp(-mw, mw) as f32;
        }
    }
}

/// Скользящее среднее по строке (окно `[i-r, i+r]` с усечением по краям), f64-сумма.
#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn box_row(src: &[f32], r: usize, out: &mut [f32]) {
    let nx = src.len();
    for (i, t) in out.iter_mut().enumerate().take(nx) {
        let (a, b) = (i.saturating_sub(r), (i + r).min(nx - 1));
        let s: f64 = src[a..=b].iter().map(|&x| x as f64).sum();
        *t = (s / (b - a + 1) as f64) as f32;
    }
}

#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn sample_chunk(this: &Field, o: &mut [[f32; 3]], p: &[[f32; 3]], g: &[f32]) {
    let n = o.len().min(p.len()).min(g.len());
    for ((o, &p), &g) in o[..n].iter_mut().zip(&p[..n]).zip(&g[..n]) {
        *o = this.sample(p, g);
    }
}

#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn scalar_chunk(this: &Field, ch: Channel, o: &mut [f32], p: &[[f32; 3]], g: &[f32]) {
    let n = o.len().min(p.len()).min(g.len());
    for ((o, &p), &g) in o[..n].iter_mut().zip(&p[..n]).zip(&g[..n]) {
        *o = this.sample_scalar(ch, p, g) as f32;
    }
}
