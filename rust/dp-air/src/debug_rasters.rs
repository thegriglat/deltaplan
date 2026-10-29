//! Отладочные растры W7 (`debug_raster`): поток тепла `heat_flux` (F7) и главная фаза `phase_main`
//! (F4). Оси W1: строка растёт к +Z, `x0`/`z0` - центр первой ячейки; значения `f32`, слой `data`.
//! Без игрового: только данные поля и фаз, рисует Godot.

use crate::Raster;
use crate::field::weather_core::Domain;
use crate::field::wind_field::Field;
use std::sync::atomic::{AtomicU64, Ordering};

/// Имена фаз по индексам `phase_main` (порядок `field::phase::prepare::PH_*`).
pub const PHASE_LABELS: [&str; 7] = ["A", "B", "C", "D", "F", "G", "H"];

static PHASE_VERSION: AtomicU64 = AtomicU64::new(0);

/// Строки с севера на юг (`j` растёт к +Y = −Z) → строки к +Z. `nx·ny` значений.
fn flip_rows(src: &[f32], nx: usize, ny: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(nx * ny);
    for r in 0..ny {
        let j = ny - 1 - r;
        out.extend_from_slice(&src[j * nx..(j + 1) * nx]);
    }
    out
}

fn raster(dom: &Domain, version: u64, data: Vec<f32>) -> Raster {
    Raster {
        version,
        nx: dom.nx as u32,
        ny: dom.ny as u32,
        dx: dom.dx as f32,
        x0: (dom.x0 + 0.5 * dom.dx) as f32,
        z0: (-(dom.y0 + (dom.ny as f64 - 0.5) * dom.dx)) as f32,
        base_msl: f32::NAN,
        time_s: f64::NAN,
        layers: vec![("data".to_string(), data)],
    }
}

/// Поток тепла H, Вт/м² (грубейший уровень поля); нет нагрева или размер не сошёлся - `None`.
pub fn heat_flux(f: &Field, version: u64) -> Option<Raster> {
    let g = f.grid();
    let heat = f.heat_flux();
    if g.nx == 0 || g.ny == 0 || heat.len() != g.nx * g.ny {
        return None;
    }
    let dom = Domain {
        x0: g.x0,
        y0: g.y0,
        nx: g.nx,
        ny: g.ny,
        dx: g.dx,
    };
    Some(raster(&dom, version, flip_rows(heat, g.nx, g.ny)))
}

/// Индекс главной фазы клетки (наибольший вес; при равных - меньший индекс) по `weights[k·n² + c]`
/// варианта с нагревом. `None` - вес не того размера.
pub fn phase_main(dom: &Domain, weights: &[f64]) -> Option<Raster> {
    let n2 = dom.nx * dom.ny;
    let k = PHASE_LABELS.len();
    if n2 == 0 || weights.len() != k * n2 {
        return None;
    }
    let main: Vec<f32> = (0..n2)
        .map(|c| {
            let mut best = 0;
            for i in 1..k {
                if weights[i * n2 + c] > weights[best * n2 + c] {
                    best = i;
                }
            }
            best as f32
        })
        .collect();
    let version = PHASE_VERSION.fetch_add(1, Ordering::Relaxed) + 1;
    Some(raster(dom, version, flip_rows(&main, dom.nx, dom.ny)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dom(nx: usize, ny: usize) -> Domain {
        Domain {
            x0: -400.0,
            y0: -200.0,
            nx,
            ny,
            dx: 100.0,
        }
    }

    #[test]
    fn phase_main_picks_max_and_flips_rows() {
        let d = dom(2, 2);
        let n2 = 4;
        let mut w = vec![0.0; 7 * n2];
        // столбцы c = j·nx + i: (0,0) -> B, (1,0) -> A, (0,1) -> H, (1,1) -> D
        w[n2] = 1.0;
        w[1] = 0.0;
        w[6 * n2 + 2] = 0.7;
        w[3 * n2 + 3] = 0.6;
        let r = phase_main(&d, &w).unwrap();
        let data = &r.layers[0].1;
        // строка 0 растра - северная (j = 1): H, D; затем южная (j = 0): B, A
        assert_eq!(data, &[6.0, 3.0, 1.0, 0.0]);
        assert_eq!((r.nx, r.ny), (2, 2));
        assert_eq!(r.x0, -350.0);
        // z центра первой строки = -(y центра северной строки) = -(-200 + 1.5·100)
        assert_eq!(r.z0, 50.0);
        assert!(r.version > 0);
    }

    #[test]
    fn wrong_size_is_none() {
        assert!(phase_main(&dom(2, 2), &[0.0; 5]).is_none());
    }
}
