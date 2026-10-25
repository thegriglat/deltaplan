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
