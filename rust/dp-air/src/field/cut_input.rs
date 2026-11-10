//! Срезанные клетки в случаях игры (PT-9, контракт PT7 v1): доли `vf`, `af_u/v/w` и граница воздуха
//! `hc_type` уровня из растра места 25 м через `picard_rs::cut_build` (PT6 v1).
//!
//! Порядок PT6: `fractions` → `type_height` → типы клеток и граней из `kf` (общий код с
//! `PreparedPlanes::cell_type`/`face_type`) → `finish`. Растр места — строки `j` к югу
//! (`place_input`), `Raster` ждёт `j` на север: строки разворачиваются (`y = −z`). Подсетка игры —
//! 25 м (узлы растра): на 400 и 1200 м точки доли = узлы растра, на окнах — билинейно внутри
//! ячейки растра. Сетка долей — та же, что сетка уровня (`dz`, `z_bot`, `nz`).
//!
//! Границы модели: область целиком в растре места (за краем растра `Raster::sample` держит край).
use super::case_prepare::{kf_of_type, types_of_kf};
use super::weather_core::{Domain, NODE_STEP};
use crate::{Error, Place};
use picard_rs::cut_build::{
    CutGrid, Fractions, Raster, SAMPLES, VF_MIN, finish, fractions, type_height,
};
use std::sync::Arc;

/// Доли срезанных клеток уровня (раскладка R1 с ореолом `(nz + 2, ny + 2, nx + 2)`), после `finish`.
#[derive(Clone, Debug)]
pub struct CutFrac(pub Fractions);

impl PartialEq for CutFrac {
    fn eq(&self, o: &Self) -> bool {
        self.0.vf == o.0.vf
            && self.0.af_u == o.0.af_u
            && self.0.af_v == o.0.af_v
            && self.0.af_w == o.0.af_w
    }
}

/// Растр места под область: узлы 25 м от `x0` до `x0 + nx·dx` и от `y0` до `y0 + ny·dx`,
/// `j` на север. Возвращает данные и начало `(x0, y0)` (может сдвинуться, если область у края).
fn raster_of(place: &Place, dom: &Domain) -> Result<(Vec<f32>, usize, usize, f64, f64), Error> {
    let g = &place.header().grid;
    let (w, h) = (g.width as usize, g.height as usize);
    let bad = || Error::bad_input("cut input: domain outside the place raster");
    let s = g.spacing;
    let (lx, ly) = (dom.nx as f64 * dom.dx, dom.ny as f64 * dom.dx);
    let col = |x: f64| (x - g.origin_x) / s;
    let row = |y: f64| (-y - g.origin_z) / s;
    // индексы растра: столбцы по x; строки r (к югу) от севера области к югу
    let c_lo = col(dom.x0).round().max(0.0) as usize;
    let c_hi = (col(dom.x0 + lx).round() as i64).min(w as i64 - 1);
    let r_lo = row(dom.y0 + ly).round().max(0.0) as usize;
    let r_hi = (row(dom.y0).round() as i64).min(h as i64 - 1);
    if c_hi < c_lo as i64 + 1 || r_hi < r_lo as i64 + 1 {
        return Err(bad());
    }
    let (c_hi, r_hi) = (c_hi as usize, r_hi as usize);
    let (nxr, nyr) = (c_hi - c_lo + 1, r_hi - r_lo + 1);
    let hs = place.heights();
    let mut out = vec![0f32; nxr * nyr];
    for jr in 0..nyr {
        let r = r_hi - jr; // j на север
        out[jr * nxr..(jr + 1) * nxr].copy_from_slice(&hs[r * w + c_lo..r * w + c_lo + nxr]);
    }
    let x0 = g.origin_x + c_lo as f64 * s;
    let y0 = -(g.origin_z + r_hi as f64 * s);
    Ok((out, nxr, nyr, x0, y0))
}

/// Граница воздуха `hc_type` (`ny·nx`, `[j·nx + i]`) и доли уровня `dom` на сетке `nz, dz, z_bot`.
pub fn cut_level(
    place: &Place,
    dom: &Domain,
    nz: usize,
    dz: f64,
    z_bot: f64,
) -> Result<(Vec<f64>, Arc<CutFrac>), Error> {
    let g = &place.header().grid;
    if (g.spacing - NODE_STEP).abs() > 1e-9 {
        return Err(Error::bad_input("cut input: place grid must be 25 m"));
    }
    let (h, nxr, nyr, rx0, ry0) = raster_of(place, dom)?;
    let r = Raster {
        h: &h,
        nx: nxr,
        ny: nyr,
        x0: rx0,
        y0: ry0,
        dx: g.spacing,
    };
    let grid = CutGrid {
        nx: dom.nx,
        ny: dom.ny,
        nz,
        x0: dom.x0,
        y0: dom.y0,
        dx: dom.dx,
        dz,
        z_bot,
    };
    let mut f = fractions(&r, &grid, SAMPLES);
    let hc_type = type_height(&grid, &f.vf, VF_MIN)
        .map_err(|e| Error::bad_input(format!("cut input: {e:#}")))?;
    let (nx_h, ny_h, nz_h) = grid.dims();
    let kf = kf_of_type(&hc_type, (dom.nx, dom.ny), z_bot, dz, nz_h);
    let [cell, tu, tv, tw] = types_of_kf(&kf, (nx_h, ny_h, nz_h));
    finish(&grid, &mut f, &cell, &tu, &tv, &tw);
    Ok((hc_type, Arc::new(CutFrac(f))))
}
