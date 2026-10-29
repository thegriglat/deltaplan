//! Выбор источников по убыванию Φ и водосборы столбцов (`build` GD: «выбор источников», `_owner_band`).
use super::{B, run_bands};

/// Выбор: кандидат берётся, если в радиусе его плотности (`cand_r`) нет уже взятого (или столбец в
/// маске ведущего). Порядок — по убыванию Φ, равенство — по меньшему номеру; итог отсортирован по
/// номеру столбца.
#[allow(clippy::too_many_arguments)]
pub(super) fn choose(
    nx: usize,
    ny: usize,
    nz: usize,
    dx: f64,
    k1s: &[u32],
    cand: &[usize],
    phi: &[f32],
    cand_r: &[f32],
    nbx: usize,
    nby: usize,
    forced: Option<&[u8]>,
) -> Vec<usize> {
    let n_col = nx * ny;
    if let Some(m) = forced {
        return (0..n_col)
            .filter(|&c| {
                c >> 3 < m.len() && (m[c >> 3] >> (c & 7)) & 1 == 1 && (k1s[c] as usize) < nz
            })
            .collect();
    }
    let mut order: Vec<usize> = cand.to_vec();
    order.sort_by(|&a, &b| {
        phi[b]
            .partial_cmp(&phi[a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.cmp(&b))
    });
    let mut grid: Vec<Vec<usize>> = vec![Vec::new(); nbx * nby];
    let mut chosen: Vec<usize> = Vec::new();
    for c in order {
        let (ci, cj) = (c % nx, c / nx);
        let r = cand_r[c] as f64;
        let rb = (r / (B as f64 * dx)).ceil() as i64;
        let (bi, bj) = ((ci / B) as i64, (cj / B) as i64);
        let mut free = true;
        'scan: for dj in (bj - rb).max(0)..=(bj + rb).min(nby as i64 - 1) {
            for di in (bi - rb).max(0)..=(bi + rb).min(nbx as i64 - 1) {
                for &sc in &grid[dj as usize * nbx + di as usize] {
                    let ddx = (sc % nx) as f64 - ci as f64;
                    let ddy = (sc / nx) as f64 - cj as f64;
                    let (ddx, ddy) = (ddx * dx, ddy * dx);
                    if ddx * ddx + ddy * ddy < r * r {
                        free = false;
                        break 'scan;
                    }
                }
            }
        }
        if !free {
            continue;
        }
        chosen.push(c);
        grid[bj as usize * nbx + bi as usize].push(c);
    }
    chosen.sort_unstable();
    chosen
}

/// Водосборы: каждый воздушный столбец (с сушей) — ближайшему источнику в досягаемости (2 радиуса
/// плотности источника); равные расстояния — меньший номер источника; −1 — ничей.
#[allow(clippy::too_many_arguments)]
pub(super) fn watersheds(
    nx: usize,
    ny: usize,
    nz: usize,
    dx: f64,
    k1s: &[u32],
    land: Option<&[f32]>,
    chosen: &[usize],
    cand_r: &[f32],
    nbx: usize,
    nby: usize,
    bands: usize,
) -> (Vec<i32>, Vec<f32>) {
    let ns = chosen.len();
    let n_col = nx * ny;
    let reach: Vec<f32> = chosen
        .iter()
        .map(|&c| (2.0 * cand_r[c] as f64) as f32)
        .collect();
    let mut max_reach = 0.0f64;
    let mut sgrid: Vec<Vec<usize>> = vec![Vec::new(); nbx * nby];
    for (s, &c) in chosen.iter().enumerate() {
        max_reach = max_reach.max(reach[s] as f64);
        sgrid[(c / nx / B) * nbx + (c % nx) / B].push(s);
    }
    let ring_max = (max_reach / (B as f64 * dx)).ceil() as i64 + 1;
    let parts = run_bands(n_col, bands, |lo, hi| {
        let mut out = vec![-1i32; hi - lo];
        for c in lo..hi {
            if k1s[c] as usize >= nz || land.is_some_and(|l| l[c] <= 0.0) {
                continue;
            }
            let (ci, cj) = (c % nx, c / nx);
            let (bi, bj) = ((ci / B) as i64, (cj / B) as i64);
            let mut best: i64 = -1;
            let mut bd = f64::INFINITY;
            for ring_n in 0..=ring_max {
                // после кольца ring_n всё ближе ring_n·B·dx уже просмотрено
                let lim = ((ring_n - 1).max(0) as f64) * B as f64 * dx;
                if best >= 0 && bd <= lim * lim {
                    break;
                }
                for dj in -ring_n..=ring_n {
                    let jj = bj + dj;
                    if jj < 0 || jj >= nby as i64 {
                        continue;
                    }
                    for di in -ring_n..=ring_n {
                        if di.abs().max(dj.abs()) != ring_n {
                            continue;
                        }
                        let ii = bi + di;
                        if ii < 0 || ii >= nbx as i64 {
                            continue;
                        }
                        for &s2 in &sgrid[jj as usize * nbx + ii as usize] {
                            let sc = chosen[s2];
                            let ddx = ((sc % nx) as f64 - ci as f64) * dx;
                            let ddy = ((sc / nx) as f64 - cj as f64) * dx;
                            let d2 = ddx * ddx + ddy * ddy;
                            let rr = reach[s2] as f64;
                            if d2 <= rr * rr && (d2 < bd || (d2 == bd && (s2 as i64) < best)) {
                                bd = d2;
                                best = s2 as i64;
                            }
                        }
                    }
                }
            }
            out[c - lo] = best as i32;
        }
        out
    });
    let _ = ns;
    (parts.into_iter().flatten().collect(), reach)
}
