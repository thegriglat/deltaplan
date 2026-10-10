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

fn wrap180(d: f64) -> f64 {
    let mut d = d;
    while d > 180.0 {
        d -= 360.0;
    }
    while d < -180.0 {
        d += 360.0;
    }
    d
}

/// Кольцо с «развёрнутой» долготой (O1: ребро с |Δlon| > 180° идёт через антимеридиан).
/// Кольцо вокруг полюса (сумма Δlon ≈ ±360°) замыкается через полюс.
fn unwrap_ring(r: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let mut u = Vec::with_capacity(r.len() + 3);
    u.push(r[0]);
    for k in 1..r.len() {
        let x = u[k - 1].0 + wrap180(r[k].0 - r[k - 1].0);
        u.push((x, r[k].1));
    }
    let last = *u.last().unwrap();
    let end = last.0 + wrap180(r[0].0 - r[r.len() - 1].0);
    let total = end - r[0].0;
    if total.abs() > 180.0 {
        let mean = r.iter().map(|p| p.1).sum::<f64>() / r.len() as f64;
        let pole = if mean >= 0.0 { 90.0 } else { -90.0 };
        u.push((end, r[0].1));
        u.push((end, pole));
        u.push((r[0].0, pole));
    }
    u
}

/// Сдвиги на 360°, при которых отрезок `[x0, x1]` задевает `[-180, 180]`.
fn shifts(x0: f64, x1: f64) -> std::ops::RangeInclusive<i64> {
    (((x0 + 180.0) / 360.0).ceil() as i64 - 1).max(((x0 + 180.0) / 360.0).floor() as i64 - 1)
        ..=((x1 + 180.0) / 360.0).floor() as i64
}

pub fn cover(poly: &Poly) -> BTreeSet<(i32, u32)> {
    let mut out = BTreeSet::new();
    let rings: Vec<Vec<(f64, f64)>> = poly.rings.iter().filter(|(r, _)| r.len() >= 3).map(|(r, _)| unwrap_ring(r)).collect();
    let edges: Vec<((f64, f64), (f64, f64), usize)> = rings
        .iter()
        .enumerate()
        .flat_map(|(ri, r)| (0..r.len()).map(move |k| (r[k], r[(k + 1) % r.len()], ri)))
        .collect();
    if edges.is_empty() {
        return out;
    }
    let ymin = edges.iter().map(|e| e.0 .1.min(e.1 .1)).fold(f64::MAX, f64::min);
    let ymax = edges.iter().map(|e| e.0 .1.max(e.1 .1)).fold(f64::MIN, f64::max);
    let j0 = crate::grid::band_of_lat(ymin);
    let j1 = crate::grid::band_of_lat(ymax);
    let clampx = |x: f64| x.clamp(-180.0, 179.999999999);
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
            for sh in shifts(xa, xb) {
                let d = sh as f64 * 360.0;
                let (p, q) = ((e.0 .0 - d, e.0 .1), (e.1 .0 - d, e.1 .1));
                if xb - d < -180.0 || xa - d > 180.0 {
                    continue;
                }
                let ia = b.index_of(clampx(xa - d));
                let ib = b.index_of(clampx(xb - d));
                for i in ia..=ib {
                    if out.contains(&(j, i)) {
                        continue;
                    }
                    let lo = b.lon0(i);
                    if seg_hits_rect(p, q, lo, lat0, lo + b.dlon, lat1) {
                        out.insert((j, i));
                    }
                }
            }
        }
        // внутренность: по каждому кольцу — отрезки горизонтали latc внутри (чётность в развёрнутой
        // долготе), приведённые к [-180, 180); кольца складываются по XOR (кольца не пересекаются)
        let mut ev: Vec<f64> = Vec::new();
        for ri in 0..rings.len() {
            let mut xs: Vec<f64> = Vec::new();
            for e in in_band.iter().filter(|e| e.2 == ri) {
                let ((x0, y0), (x1, y1), _) = **e;
                if (y0 <= latc) != (y1 <= latc) {
                    xs.push(x0 + (latc - y0) / (y1 - y0) * (x1 - x0));
                }
            }
            xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
            for pair in xs.chunks(2) {
                if pair.len() < 2 {
                    break;
                }
                let (mut a, mut c) = (pair[0], pair[1]);
                let sh = ((a + 180.0) / 360.0).floor() * 360.0;
                a -= sh;
                c -= sh;
                if c > 180.0 {
                    ev.extend([a, 180.0, -180.0, c - 360.0]);
                } else {
                    ev.extend([a, c]);
                }
            }
        }
        ev.sort_by(|a, b| a.partial_cmp(b).unwrap());
        for pair in ev.chunks(2) {
            if pair.len() < 2 || pair[0] >= pair[1] {
                continue;
            }
            let ia = b.index_of(clampx(pair[0]));
            let ib = b.index_of(clampx(pair[1]));
            for i in ia..=ib {
                let c = b.lon0(i) + b.dlon / 2.0;
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
    fn antimeridian() {
        // полоса 170°E…170°W через 180°: только ~20° по долготе, а не весь пояс
        let ring = vec![(170.0, 60.0), (-170.0, 60.0), (-170.0, 62.0), (170.0, 62.0)];
        let c = cover(&Poly { rings: vec![(ring, false)] });
        for &(j, i) in &c {
            let b = Band::new(j);
            let lo = b.lon0(i);
            assert!(lo >= 169.0 || lo + b.dlon <= -169.0, "тайл {j} {i} lon0 {lo}");
        }
        let b = Band::new(crate::grid::band_of_lat(61.0));
        let per_band = c.iter().filter(|t| t.0 == b.j).count() as f64;
        let expect = 20.0 / b.dlon;
        assert!((per_band - expect).abs() <= 3.0, "{per_band} vs {expect}");
        // с дырой по ту сторону антимеридиана
        let hole = vec![(-178.0, 60.5), (-172.0, 60.5), (-172.0, 61.5), (-178.0, 61.5)];
        let ring = vec![(170.0, 60.0), (-170.0, 60.0), (-170.0, 62.0), (170.0, 62.0)];
        let ch = cover(&Poly { rings: vec![(ring, false), (hole, true)] });
        assert!(ch.len() < c.len());
        assert!(!ch.contains(&crate::grid::tile_of(61.0, -175.0)));
        assert!(ch.contains(&crate::grid::tile_of(61.0, 175.0)));
    }

    #[test]
    fn parse() {
        let p = parse_poly("x\n1\n 1.0E+01 4.0E+01\n 1.1E+01 4.0E+01\n 1.1E+01 4.1E+01\nEND\n!2\n 1 1\n 2 1\n 2 2\nEND\nEND\n").unwrap();
        assert_eq!(p.rings.len(), 2);
        assert!(p.rings[1].1);
    }
}
