//! Точка источника в столбце (`pick_in_column`) и доля суши столбцов (`land_fraction`).
use super::LAND_N;
use crate::compat::hash::hash_v3i;
use crate::compat::rng::Pcg32;
use crate::field::wind_field::{Field, FieldGrid};
use rayon::prelude::*;

/// Земля для выбора точки источника: сила источника в точке (освещённость склона, скалы, опушки;
/// `GroundField.sun`) и вода (`GroundField.is_water`). Реализует снаружи (RW-10c / место).
pub trait PickGround: Sync {
    /// Сила источника в точке (x, z мира); клампится в 0..1 здесь. «Нет функции силы» — вернуть 1.
    fn sun(&self, x: f64, z: f64) -> f64;
    /// Вода (источник термика здесь не ставится).
    fn is_water(&self, x: f64, z: f64) -> bool;
}

/// Точка источника в столбце `(i, j)` уровня с сеткой `g`: лучшая по освещённости земли из
/// `candidates` точек столбца, не на воде; сид — столбец и сид мира (у всех клиентов одна).
/// `ground = None` (земли нет) — центр столбца. `None` в ответе — в столбце источника нет:
/// все кандидаты без силы или на воде (`NO_SOURCE`).
pub fn pick_in_column(
    i: usize,
    j: usize,
    g: &FieldGrid,
    ground: Option<&dyn PickGround>,
    seed: u64,
    candidates: usize,
) -> Option<[f32; 2]> {
    // Vector3i(seed_value, i, j): компоненты int32
    let mut rng = Pcg32::from_seed(hash_v3i(seed as i32, i as i32, j as i32) as u64);
    let mut best = [
        (g.x0 + (i as f64 + 0.5) * g.dx) as f32,
        (-(g.y0 + (j as f64 + 0.5) * g.dx)) as f32,
    ];
    let mut best_s = -1.0f64;
    for _ in 0..candidates {
        let x = g.x0 + (i as f64 + rng.randf_range(0.1, 0.9) as f64) * g.dx;
        let z = -(g.y0 + (j as f64 + rng.randf_range(0.1, 0.9) as f64) * g.dx);
        let mut s = 0.0f64;
        if let Some(gr) = ground {
            s = super::gclamp(gr.sun(x, z), 0.0, 1.0);
        }
        // над водой источника нет, как бы ни грела вода (тёплое море — H > 0)
        if let Some(gr) = ground
            && s > super::gmax(best_s, 0.0)
            && gr.is_water(x, z)
        {
            s = 0.0;
        }
        if s > best_s {
            best_s = s;
            best = [x as f32, z as f32];
        }
    }
    if ground.is_some() && best_s <= 0.0 {
        return None;
    }
    Some(best)
}

/// Доля суши по столбцам уровня (`ny·nx`); `water_fn(x, z мира)` → вода. Сначала углы (общие у соседей)
/// и центр столбца: все пять одно — столбец целиком вода (0) или суша (1); иначе (берег) — доля из
/// `LAND_N²` центров подклеток. Вода/суша мельче столбца, не задевшая ни угла, ни центра, не видна
/// (её точку источника всё равно отсеет `pick_in_column`). Столбцы в земле — 1.
pub fn land_fraction(f: &Field, water_fn: &(dyn Fn(f64, f64) -> bool + Sync)) -> Vec<f32> {
    let g = *f.grid();
    let (nx, ny) = (g.nx, g.ny);
    let k1s = f.raw_k1();
    let cw = nx + 1;
    let corner: Vec<u8> = (0..cw * (ny + 1))
        .into_par_iter()
        .map(|q| {
            let (i, j) = (q % cw, q / cw);
            water_fn(g.x0 + i as f64 * g.dx, -(g.y0 + j as f64 * g.dx)) as u8
        })
        .collect();
    let step = g.dx / LAND_N as f64;
    let inv = 1.0 / (LAND_N * LAND_N) as f64;
    let mut out = vec![1.0f32; nx * ny];
    out.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            if k1s[j * nx + i] as usize >= g.nz {
                continue;
            }
            let (x0, y0) = (g.x0 + i as f64 * g.dx, g.y0 + j as f64 * g.dx);
            let mut nc = corner[j * cw + i] as u32
                + corner[j * cw + i + 1] as u32
                + corner[(j + 1) * cw + i] as u32
                + corner[(j + 1) * cw + i + 1] as u32;
            nc += water_fn(x0 + 0.5 * g.dx, -(y0 + 0.5 * g.dx)) as u32;
            if nc == 0 || nc == 5 {
                *o = if nc == 5 { 0.0 } else { 1.0 };
                continue;
            }
            let mut nw = 0u32;
            for b in 0..LAND_N {
                let z = -(y0 + (b as f64 + 0.5) * step);
                for a in 0..LAND_N {
                    if water_fn(x0 + (a as f64 + 0.5) * step, z) {
                        nw += 1;
                    }
                }
            }
            *o = (1.0 - nw as f64 * inv) as f32;
        }
    });
    out
}
