//! Уровни сетки и перенос «грубый уровень → мелкий» (`prolong`).
//!
//! Построчный перенос ядра `K_PROLONG` (`air_picard.glsl`) и вызова `_prolong`
//! (`air_picard_job.gd`), записанный как общая операция иерархии уровней: она годится и для
//! грубого старта 1200 → 400 м (отношение 3), и для уровней живого воздуха «делением пополам»
//! (отношение 2). Раскладка массивов — как у `picard_rs::state::State`: плоский массив
//! `(k·ny + j)·nx + i` с ореолом, `nx, ny, nz` — размеры С ореолом (`dims` State).

use crate::error::Error;
use rayon::prelude::*;

/// Положение значения в клетке: грань `u` — в узле по x, грань `v` — в узле по y,
/// `w` и центр `C` (`th`, `thd`, `p`) — в середине клетки по x и y. По z у всех один и тот же
/// сдвиг уровней (`dz` общий), поэтому `W` и `C` переносятся одинаково (как `KIND_C` в ядре).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stag {
    U,
    V,
    W,
    C,
}

/// Описание уровня сетки.
///
/// `x0`, `y0` — координаты первой внутренней грани (индекс 1, сразу за ореолом) в общей для
/// всех уровней горизонтальной системе, м: грань `u[i]` лежит в `x0 + (i−1)·dx`, центр клетки
/// `i` — в `x0 + (i−½)·dx` (так же по y). Значение имеет только разность начал уровней, поэтому
/// оба уровня должны задавать начало одинаково (в `AirCase` — `x0`, `y0` случая; в W1 это
/// локальные метры места). `z_bot` — высота нижней плоскости, м; `dx` — шаг по x и y, `dz` — шаг
/// по z (у грубого и мелкого уровня один и тот же).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Level {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
    pub dz: f64,
    pub z_bot: f64,
    pub halo: usize,
}

impl Level {
    /// Число значений в массиве уровня.
    pub fn len(&self) -> usize {
        self.nx * self.ny * self.nz
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Параметры переноса, общие для всех полей пары уровней.
struct Map {
    fx0: f32,
    fy0: f32,
    r: f32,
    ksh: i64,
}

fn check(coarse: &Level, fine: &Level) -> Result<Map, Error> {
    if coarse.nx < 2 || coarse.ny < 2 || coarse.nz < 1 || fine.is_empty() {
        return Err(Error::bad_input(
            "prolong: пустой или слишком малый уровень",
        ));
    }
    let ok = |v: f64| v.is_finite() && v > 0.0;
    if !ok(coarse.dx) || !ok(fine.dx) || !ok(fine.dz) {
        return Err(Error::bad_input("prolong: шаг сетки должен быть > 0"));
    }
    let fin = [
        coarse.x0,
        coarse.y0,
        fine.x0,
        fine.y0,
        coarse.z_bot,
        fine.z_bot,
    ];
    if fin.iter().any(|v| !v.is_finite()) {
        return Err(Error::bad_input("prolong: начало уровня не конечно"));
    }
    let ksh = ((fine.z_bot - coarse.z_bot) / fine.dz).round() as i64;
    Ok(Map {
        fx0: ((fine.x0 - coarse.x0) / coarse.dx) as f32,
        fy0: ((fine.y0 - coarse.y0) / coarse.dx) as f32,
        r: (fine.dx / coarse.dx) as f32,
        ksh,
    })
}

#[inline]
fn mix(a: f32, b: f32, t: f32) -> f32 {
    a * (1.0 - t) + b * t
}

/// Одна строка мелкого уровня: `k`, `j` — её положение.
#[allow(clippy::too_many_arguments)]
fn row(
    coarse: &Level,
    src: &[f32],
    fine: &Level,
    m: &Map,
    (sx, sy): (f32, f32),
    k: usize,
    j: usize,
    out: &mut [f32],
) {
    let (nxc, nyc, nzc) = (coarse.nx, coarse.ny, coarse.nz);
    let jc = (m.fy0 + (j as f32 - sy) * m.r + sy).clamp(0.0, (nyc - 1) as f32);
    let kc = (k as i64 + m.ksh).clamp(0, nzc as i64 - 1) as usize;
    let j0 = (jc as usize).min(nyc - 2);
    let fy = jc - j0 as f32;
    let base = (kc * nyc + j0) * nxc;
    let lo = &src[base..base + nxc];
    let hi = &src[base + nxc..base + 2 * nxc];
    for (i, d) in out.iter_mut().enumerate().take(fine.nx) {
        let ic = (m.fx0 + (i as f32 - sx) * m.r + sx).clamp(0.0, (nxc - 1) as f32);
        let i0 = (ic as usize).min(nxc - 2);
        let fx = ic - i0 as f32;
        let a0 = mix(lo[i0], lo[i0 + 1], fx);
        let a1 = mix(hi[i0], hi[i0 + 1], fx);
        *d = mix(a0, a1, fy);
    }
}

fn run(
    coarse: &Level,
    src: &[f32],
    fine: &Level,
    dst: &mut [f32],
    stag: Stag,
    m: &Map,
) -> Result<(), Error> {
    if src.len() != coarse.len() {
        return Err(Error::bad_input(format!(
            "prolong: длина источника {} ≠ {} (размеры грубого уровня)",
            src.len(),
            coarse.len()
        )));
    }
    if dst.len() != fine.len() {
        return Err(Error::bad_input(format!(
            "prolong: длина приёмника {} ≠ {} (размеры мелкого уровня)",
            dst.len(),
            fine.len()
        )));
    }
    let s = (
        if stag == Stag::U { 1.0 } else { 0.5 },
        if stag == Stag::V { 1.0 } else { 0.5 },
    );
    let (nx, ny) = (fine.nx, fine.ny);
    dst.par_chunks_mut(nx).enumerate().for_each(|(g, out)| {
        row(coarse, src, fine, m, s, g / ny, g % ny, out);
    });
    Ok(())
}

/// Переносит поле `src` грубого уровня на мелкий уровень в `dst`.
///
/// Билинейно по горизонтали в индексах грубой сетки (грань — в узле, центр — в середине клетки,
/// индекс грубой сетки зажимается в `[0, n−1]`, то есть за краем грубой области — значение края),
/// по высоте — тот же `dz` со сдвигом `ksh = round((z_bot − z_bot_c)/dz)` и зажимом в `[0, nz_c−1]`.
/// Ореол мелкого уровня считается той же формулой, что и внутренность. Несовпадение длин или
/// негодные уровни — `BadInput`, без паники.
pub fn prolong(
    coarse: &Level,
    src: &[f32],
    fine: &Level,
    dst: &mut [f32],
    stag: Stag,
) -> Result<(), Error> {
    let m = check(coarse, fine)?;
    run(coarse, src, fine, dst, stag, &m)
}

/// Шесть полей состояния Пикара в порядке `u, v, w, θ′, θ′_d, p` (раскладка `picard_rs::State`).
/// Все длины проверяются до записи: при ошибке `dst` не меняется.
pub fn prolong_state(
    coarse: &Level,
    src: [&[f32]; 6],
    fine: &Level,
    dst: [&mut [f32]; 6],
) -> Result<(), Error> {
    let m = check(coarse, fine)?;
    if src.iter().any(|s| s.len() != coarse.len()) || dst.iter().any(|d| d.len() != fine.len()) {
        return Err(Error::bad_input(
            "prolong_state: длина поля не совпадает с уровнем",
        ));
    }
    let kinds = [Stag::U, Stag::V, Stag::W, Stag::C, Stag::C, Stag::C];
    for ((s, d), k) in src.into_iter().zip(dst).zip(kinds) {
        run(coarse, s, fine, d, k, &m)?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// nest: «грубый уровень → мелкий» для границы (окна клипмапа, RW-6n)
// ---------------------------------------------------------------------------------------------

/// Поля грубого уровня для [`nest`]: типы клеток (`cell + 4·tu + 16·tv + 64·tw`, как `tcode` игры)
/// и решение с ореолом в раскладке уровня. Нет `thd` — θ′_d родителя нулевое.
#[derive(Clone, Copy, Debug)]
pub struct NestSrc<'a> {
    pub tc: &'a [u8],
    pub u: &'a [f32],
    pub v: &'a [f32],
    pub w: &'a [f32],
    pub th: &'a [f32],
    pub thd: Option<&'a [f32]>,
}

/// Куда [`nest`] пишет: значения для граней `u`, `v`, `w` (раскладка граней мелкого уровня) и
/// для центров клеток θ′ и θ′_d. В ячейках, которых тип мелкого уровня не требует (стенка), 0.
pub struct NestDst<'a> {
    pub u: &'a mut [f32],
    pub v: &'a mut [f32],
    pub w: &'a mut [f32],
    pub th: &'a mut [f32],
    pub thd: &'a mut [f32],
}

/// Размеры и сдвиги пары уровней для [`nest`] (в `f32`, как `nprm` ядра `K_NEST`).
struct NestMap {
    ox: f32,
    oy: f32,
    oz: f32,
    rx: f32,
    rz: f32,
    pn: [usize; 3],
}

fn nest_map(coarse: &Level, fine: &Level) -> Result<NestMap, Error> {
    if coarse.nx < 2 || coarse.ny < 2 || coarse.nz < 2 || fine.is_empty() {
        return Err(Error::bad_input("nest: пустой или слишком малый уровень"));
    }
    let ok = |v: f64| v.is_finite() && v > 0.0;
    if !ok(coarse.dx) || !ok(coarse.dz) || !ok(fine.dx) || !ok(fine.dz) {
        return Err(Error::bad_input("nest: шаг сетки должен быть > 0"));
    }
    let fin = [
        coarse.x0,
        coarse.y0,
        fine.x0,
        fine.y0,
        coarse.z_bot,
        fine.z_bot,
    ];
    if fin.iter().any(|v| !v.is_finite()) {
        return Err(Error::bad_input("nest: начало уровня не конечно"));
    }
    Ok(NestMap {
        ox: ((fine.x0 - coarse.x0) / coarse.dx) as f32,
        oy: ((fine.y0 - coarse.y0) / coarse.dx) as f32,
        oz: ((fine.z_bot - coarse.z_bot) / coarse.dz) as f32,
        rx: (fine.dx / coarse.dx) as f32,
        rz: (fine.dz / coarse.dz) as f32,
        pn: [coarse.nx, coarse.ny, coarse.nz],
    })
}

/// Компоненты поля, которые `nest` переносит: порядок как в ядре (`pcen(comp, …)`).
#[derive(Clone, Copy)]
enum Comp {
    U,
    V,
    W,
    Th,
    Thd,
}

/// Значение родителя в центре клетки `(k, j, i)` с ореолом: среднее двух граней по своей оси
/// (последняя клетка по оси — 0), клетки земли — 0 (`pcen` ядра `K_NEST`, `Air.centers(full=True)`).
#[inline(always)]
fn pcen(s: &NestSrc, pn: [usize; 3], comp: Comp, k: usize, j: usize, i: usize) -> f32 {
    let (px, py, pz) = (pn[0], pn[1], pn[2]);
    let q = (k * py + j) * px + i;
    if s.tc[q] & 3 == 0 {
        return 0.0;
    }
    match comp {
        Comp::U => {
            if i < px - 1 {
                0.5 * (s.u[q] + s.u[q + 1])
            } else {
                0.0
            }
        }
        Comp::V => {
            if j < py - 1 {
                0.5 * (s.v[q] + s.v[q + px])
            } else {
                0.0
            }
        }
        Comp::W => {
            if k < pz - 1 {
                0.5 * (s.w[q] + s.w[q + px * py])
            } else {
                0.0
            }
        }
        Comp::Thd => s.thd.map_or(0.0, |t| t[q]),
        Comp::Th => s.th[q],
    }
}

/// Трилинейно по центрам родителя; `(fk, fj, fi)` — индексы с ореолом (`tri` ядра, `air.trilinear`).
#[inline(always)]
fn tri(s: &NestSrc, pn: [usize; 3], comp: Comp, fk: f32, fj: f32, fi: f32) -> f32 {
    let fk = fk.clamp(0.0, pn[2] as f32 - 1.0001);
    let fj = fj.clamp(0.0, pn[1] as f32 - 1.0001);
    let fi = fi.clamp(0.0, pn[0] as f32 - 1.0001);
    let (k0, j0, i0) = (fk as usize, fj as usize, fi as usize);
    let (a, b, c) = (fi - i0 as f32, fj - j0 as f32, fk - k0 as f32);
    let mut sum = 0.0f32;
    for dk in 0..2 {
        for dj in 0..2 {
            for di in 0..2 {
                let w = (if dk == 1 { c } else { 1.0 - c })
                    * (if dj == 1 { b } else { 1.0 - b })
                    * (if di == 1 { a } else { 1.0 - a });
                sum += w * pcen(s, pn, comp, k0 + dk, j0 + dj, i0 + di);
            }
        }
    }
    sum
}

/// Граница мелкого уровня от грубого (`air_window.glsl:K_NEST`, эталон AM-01 `Air.set_nest_bc`):
/// поле родителя в центрах его клеток (среднее двух граней, 0 в земле) трилинейно в грани и
/// клетки мелкого уровня. Грань `u` берётся в `(x узел, y центр, z центр)`, `v` — `(центр, узел,
/// центр)`, `w` — `(центр, центр, узел)`, θ′ и θ′_d — в центре клетки; грани и клетки, которых
/// тип мелкого уровня (`tc`) называет стенкой (`tu/tv/tw = 0`, `cell = 0`), получают 0. За краем
/// родителя — значение края (зажим индекса). Общая операция иерархии уровней: годится и для окна
/// 100/50 м от области, и для окна от окна (отношение шагов любое), и для живого воздуха
/// `air-cascade`. Арифметика — `f32` в порядке ядра. Несовпадение длин — `BadInput`, без паники.
pub fn nest(
    coarse: &Level,
    src: &NestSrc,
    fine: &Level,
    tc: &[u8],
    dst: NestDst,
) -> Result<(), Error> {
    let m = nest_map(coarse, fine)?;
    let (nc, nf) = (coarse.len(), fine.len());
    let src_ok = src.tc.len() == nc
        && [src.u, src.v, src.w, src.th].iter().all(|a| a.len() == nc)
        && src.thd.is_none_or(|t| t.len() == nc);
    if !src_ok {
        return Err(Error::bad_input(
            "nest: длина поля родителя не совпадает с уровнем",
        ));
    }
    let dst_ok = tc.len() == nf
        && [&*dst.u, &*dst.v, &*dst.w, &*dst.th, &*dst.thd]
            .iter()
            .all(|a| a.len() == nf);
    if !dst_ok {
        return Err(Error::bad_input(
            "nest: длина приёмника или типов не совпадает с мелким уровнем",
        ));
    }
    let (nx, ny) = (fine.nx, fine.ny);
    dst.u
        .par_chunks_mut(nx)
        .zip(dst.v.par_chunks_mut(nx))
        .zip(dst.w.par_chunks_mut(nx))
        .zip(dst.th.par_chunks_mut(nx))
        .zip(dst.thd.par_chunks_mut(nx))
        .enumerate()
        .for_each(|(g, ((((ou, ov), ow), oth), othd))| {
            let (k, j) = (g / ny, g % ny);
            let trow = &tc[g * nx..(g + 1) * nx];
            // индекс родителя с ореолом: (X − x0_p)/dx_p + ½; центр окна X = x0 + (i − ½)dx,
            // грань — (i − 1)dx
            let (fk, fj) = (k as f32, j as f32);
            let fkc = m.oz + (fk - 0.5) * m.rz + 0.5;
            let fkf = m.oz + (fk - 1.0) * m.rz + 0.5;
            let fjc = m.oy + (fj - 0.5) * m.rx + 0.5;
            let fjf = m.oy + (fj - 1.0) * m.rx + 0.5;
            for (i, &t) in trow.iter().enumerate() {
                let fi = i as f32;
                let fic = m.ox + (fi - 0.5) * m.rx + 0.5;
                let fif = m.ox + (fi - 1.0) * m.rx + 0.5;
                let (cell, tu, tv, tw) = (t & 3, (t >> 2) & 3, (t >> 4) & 3, (t >> 6) & 3);
                ou[i] = if tu == 0 {
                    0.0
                } else {
                    tri(src, m.pn, Comp::U, fkc, fjc, fif)
                };
                ov[i] = if tv == 0 {
                    0.0
                } else {
                    tri(src, m.pn, Comp::V, fkc, fjf, fic)
                };
                ow[i] = if tw == 0 {
                    0.0
                } else {
                    tri(src, m.pn, Comp::W, fkf, fjc, fic)
                };
                oth[i] = if cell == 0 {
                    0.0
                } else {
                    tri(src, m.pn, Comp::Th, fkc, fjc, fic)
                };
                othd[i] = if cell == 0 {
                    0.0
                } else {
                    tri(src, m.pn, Comp::Thd, fkc, fjc, fic)
                };
            }
        });
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// shift: тёплый старт сдвинутого окна (RW-6n)
// ---------------------------------------------------------------------------------------------

/// Сдвиг нового уровня относительно старого в целых клетках: индекс старого = индекс нового +
/// сдвиг (`AirWindowJob._prev_shift`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shift {
    pub i: i64,
    pub j: i64,
    pub k: i64,
}

/// Подходит ли старый уровень для тёплого старта нового (`AirWindowJob._prev_ok`): та же клетка
/// (`dx`, `dz`), сдвиг начала — целое число клеток (допуск 1e-3 клетки), новый уровень пересекается
/// со старым (|сдвиг| меньше размера старого: по x, y — без ореола, по z — с ореолом).
pub fn shift_between(old: &Level, new: &Level) -> Option<Shift> {
    let near = |a: f64, b: f64| (a - b).abs() <= 1e-9 * a.abs().max(b.abs()).max(1.0);
    if !near(old.dx, new.dx) || !near(old.dz, new.dz) {
        return None;
    }
    let f = |a: f64, b: f64, d: f64| (a - b) / d;
    let (fx, fy, fz) = (
        f(new.x0, old.x0, new.dx),
        f(new.y0, old.y0, new.dx),
        f(new.z_bot, old.z_bot, new.dz),
    );
    if [fx, fy, fz].iter().any(|v| !v.is_finite()) {
        return None;
    }
    if [fx, fy, fz].iter().any(|v| (v - v.round()).abs() > 1e-3) {
        return None;
    }
    let s = Shift {
        i: fx.round() as i64,
        j: fy.round() as i64,
        k: fz.round() as i64,
    };
    let overlap = s.i.unsigned_abs() < (old.nx as u64).saturating_sub(2)
        && s.j.unsigned_abs() < (old.ny as u64).saturating_sub(2)
        && s.k.unsigned_abs() < old.nz as u64;
    overlap.then_some(s)
}

/// Старое решение окна (раскладка уровня) — источник [`shift_warm`].
#[derive(Clone, Copy, Debug)]
pub struct ShiftSrc<'a> {
    pub u: &'a [f32],
    pub v: &'a [f32],
    pub w: &'a [f32],
    pub th: &'a [f32],
    pub thd: &'a [f32],
    pub p: &'a [f32],
}

/// Новое решение окна: уже записано граничное состояние (старт от родителя), `shift_warm`
/// перезаписывает в нём то, что есть в старом окне.
pub struct ShiftDst<'a> {
    pub u: &'a mut [f32],
    pub v: &'a mut [f32],
    pub w: &'a mut [f32],
    pub th: &'a mut [f32],
    pub thd: &'a mut [f32],
    pub p: &'a mut [f32],
}

/// Тёплый старт сдвинутого окна (`air_window.glsl:K_SHIFT`): неизвестные новой сетки (грани типа 1,
/// клетки воздуха) — из старого окна по тому же положению, где оно есть (индексы старого
/// `≥ 1` и `≤ n − 1`, без нулевых индексов: грань 0 и ореол 0 — не решение), остальное в `dst`
/// остаётся (родитель); `p` воздуха — из старого, у края старого окна — ближайшее внутреннее.
/// `tc` — типы клеток нового уровня. Несовпадение длин — `BadInput`.
pub fn shift_warm(
    old: &Level,
    src: &ShiftSrc,
    new: &Level,
    tc: &[u8],
    sh: Shift,
    dst: ShiftDst,
) -> Result<(), Error> {
    if old.nx < 4 || old.ny < 4 || old.nz < 4 || new.is_empty() {
        return Err(Error::bad_input("shift: пустой или слишком малый уровень"));
    }
    let (no, nn) = (old.len(), new.len());
    let src_ok = [src.u, src.v, src.w, src.th, src.thd, src.p]
        .iter()
        .all(|a| a.len() == no);
    let dst_ok = tc.len() == nn
        && [&*dst.u, &*dst.v, &*dst.w, &*dst.th, &*dst.thd, &*dst.p]
            .iter()
            .all(|a| a.len() == nn);
    if !src_ok || !dst_ok {
        return Err(Error::bad_input("shift: длина поля не совпадает с уровнем"));
    }
    let (onx, ony, onz) = (old.nx as i64, old.ny as i64, old.nz as i64);
    let (nx, ny) = (new.nx, new.ny);
    let plane = nx * ny;
    dst.u
        .par_chunks_mut(plane)
        .zip(dst.v.par_chunks_mut(plane))
        .zip(dst.w.par_chunks_mut(plane))
        .zip(dst.th.par_chunks_mut(plane))
        .zip(dst.thd.par_chunks_mut(plane))
        .zip(dst.p.par_chunks_mut(plane))
        .enumerate()
        .for_each(|(k, (((((pu, pv), pw), pth), pthd), pp))| {
            let ko = k as i64 + sh.k;
            let tpl = &tc[k * plane..(k + 1) * plane];
            for j in 0..ny {
                let jo = j as i64 + sh.j;
                for i in 0..nx {
                    let io = i as i64 + sh.i;
                    let (t, o) = (tpl[j * nx + i], j * nx + i);
                    let (cell, tu, tv, tw) = (t & 3, (t >> 2) & 3, (t >> 4) & 3, (t >> 6) & 3);
                    let inside = io >= 1 && jo >= 1 && ko >= 1 && io < onx && jo < ony && ko < onz;
                    if inside {
                        let q = ((ko * ony + jo) * onx + io) as usize;
                        if tu == 1 {
                            pu[o] = src.u[q];
                        }
                        if tv == 1 {
                            pv[o] = src.v[q];
                        }
                        if tw == 1 {
                            pw[o] = src.w[q];
                        }
                        if cell == 1 {
                            pth[o] = src.th[q];
                            pthd[o] = src.thd[q];
                        }
                    }
                    if cell == 1 {
                        let ic = io.clamp(1, onx - 2);
                        let jc = jo.clamp(1, ony - 2);
                        let kc = ko.clamp(1, onz - 2);
                        pp[o] = src.p[((kc * ony + jc) * onx + ic) as usize];
                    }
                }
            }
        });
    Ok(())
}
