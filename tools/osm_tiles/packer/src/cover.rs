//! O5 `cover`: тайлы O1, пересекающие полигон `.poly` (Osmosis: кольца, `!` — дыра).
//!
//! Тайл — прямоугольник `[lon0, lon0+dlon] × [lat0, lat0+DLAT]`. Тайл пересекает область, если
//! какое-либо ребро любого кольца (внешнего или дыры) задевает его, иначе тайл целиком внутри
//! или целиком снаружи — решает чётность пересечений горизонтали через центр тайла со всеми
//! кольцами (внешние и дыры вместе, кольца не пересекаются).

use crate::grid::{Band, DLAT};
use crate::Result;
use std::collections::BTreeSet;

#[derive(Debug, Clone, Default)]
pub struct Poly {
    /// (кольцо, дыра?)
    pub rings: Vec<(Vec<(f64, f64)>, bool)>,
}

pub fn parse_poly(text: &str) -> Result<Poly> {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    lines.next().ok_or("пустой .poly")?; // имя файла
    let mut poly = Poly::default();
    loop {
        let Some(head) = lines.next() else { return Err(".poly: нет завершающего END".into()) };
        if head.eq_ignore_ascii_case("END") {
            break;
        }
        let hole = head.starts_with('!');
        let mut ring = Vec::new();
        loop {
            let l = lines.next().ok_or(".poly: кольцо без END")?;
            if l.eq_ignore_ascii_case("END") {
                break;
            }
            let mut it = l.split_whitespace();
            let lon: f64 = it.next().and_then(|s| s.parse().ok()).ok_or_else(|| format!(".poly: строка «{l}»"))?;
            let lat: f64 = it.next().and_then(|s| s.parse().ok()).ok_or_else(|| format!(".poly: строка «{l}»"))?;
            ring.push((lon, lat));
        }
        if ring.len() >= 3 {
            poly.rings.push((ring, hole));
        }
    }
    Ok(poly)
}

/// Отрезок задевает замкнутый прямоугольник (Лианг — Барски).
fn seg_hits_rect(a: (f64, f64), b: (f64, f64), x0: f64, y0: f64, x1: f64, y1: f64) -> bool {
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    for (p, q) in [(-dx, a.0 - x0), (dx, x1 - a.0), (-dy, a.1 - y0), (dy, y1 - a.1)] {
        if p == 0.0 {
            if q < 0.0 {
                return false;
            }
        } else {
            let r = q / p;
            if p < 0.0 {
                if r > t1 {
                    return false;
                }
                t0 = t0.max(r);
            } else {
                if r < t0 {
                    return false;
                }
                t1 = t1.min(r);
            }
        }
    }
    t0 <= t1
}

pub fn cover(poly: &Poly) -> BTreeSet<(i32, u32)> {
    let mut out = BTreeSet::new();
    let edges: Vec<((f64, f64), (f64, f64))> = poly
        .rings
        .iter()
        .flat_map(|(r, _)| (0..r.len()).map(move |k| (r[k], r[(k + 1) % r.len()])))
        .collect();
    if edges.is_empty() {
        return out;
    }
    let ymin = edges.iter().map(|e| e.0 .1.min(e.1 .1)).fold(f64::MAX, f64::min);
    let ymax = edges.iter().map(|e| e.0 .1.max(e.1 .1)).fold(f64::MIN, f64::max);
    let j0 = crate::grid::band_of_lat(ymin);
    let j1 = crate::grid::band_of_lat(ymax);
    for j in j0..=j1 {
        let b = Band::new(j);
        let (lat0, lat1) = (b.lat0, b.lat0 + DLAT);
        let latc = (lat0 + lat1) / 2.0;
        // рёбра, задевающие пояс
        let in_band: Vec<_> = edges
            .iter()
            .filter(|e| e.0 .1.max(e.1 .1) >= lat0 && e.0 .1.min(e.1 .1) <= lat1)
            .collect();
        for e in &in_band {
            let (xa, xb) = (e.0 .0.min(e.1 .0), e.0 .0.max(e.1 .0));
            let ia = b.index_of(xa.clamp(-180.0, 179.999999999));
            let ib = b.index_of(xb.clamp(-180.0, 179.999999999));
            for i in ia..=ib {
                if out.contains(&(j, i)) {
                    continue;
                }
                let lo = b.lon0(i);
                if seg_hits_rect(e.0, e.1, lo, lat0, lo + b.dlon, lat1) {
                    out.insert((j, i));
                }
            }
        }
        // внутренность: чётность пересечений горизонтали latc
        let mut xs: Vec<f64> = Vec::new();
        for e in &in_band {
            let ((x0, y0), (x1, y1)) = **e;
            if (y0 <= latc) != (y1 <= latc) {
                xs.push(x0 + (latc - y0) / (y1 - y0) * (x1 - x0));
            }
        }
        xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        for pair in xs.chunks(2) {
            if pair.len() < 2 {
                break;
            }
            let ia = b.index_of(pair[0].clamp(-180.0, 179.999999999));
            let ib = b.index_of(pair[1].clamp(-180.0, 179.999999999));
            for i in ia..=ib {
                let lo = b.lon0(i);
                let c = lo + b.dlon / 2.0;
                if c >= pair[0] && c <= pair[1] {
                    out.insert((j, i));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(a: f64, b: f64, c: f64, d: f64, hole: bool) -> (Vec<(f64, f64)>, bool) {
        (vec![(a, b), (c, b), (c, d), (a, d)], hole)
    }

    #[test]
    fn tiny_poly_one_tile() {
        let p = Poly { rings: vec![sq(14.50, 46.05, 14.51, 46.06, false)] };
        let c = cover(&p); assert!(!c.is_empty() && c.len() <= 2, "{c:?}");
    }

    #[test]
    fn hole_excludes_inner_tiles() {
        let full = Poly { rings: vec![sq(10.0, 40.0, 14.0, 44.0, false)] };
        let holed = Poly { rings: vec![sq(10.0, 40.0, 14.0, 44.0, false), sq(11.0, 41.0, 13.0, 43.0, true)] };
        let a = cover(&full).len();
        let b = cover(&holed).len();
        assert!(b < a && b > a / 3, "{a} {b}");
    }

    #[test]
    fn parse() {
        let p = parse_poly("x\n1\n 1.0E+01 4.0E+01\n 1.1E+01 4.0E+01\n 1.1E+01 4.1E+01\nEND\n!2\n 1 1\n 2 1\n 2 2\nEND\nEND\n").unwrap();
        assert_eq!(p.rings.len(), 2);
        assert!(p.rings[1].1);
    }
}
