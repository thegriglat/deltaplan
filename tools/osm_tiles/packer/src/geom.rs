//! Геометрия упаковщика (O3): клип линии по прямоугольнику, Дуглас — Пекер, округление,
//! площадь и центроид полигона, минимальный по площади прямоугольник, сборка колец мультиполигона.
//! Всё в f64, без внешних библиотек; поведение — как у эталона (shapely/GEOS) в пределах допусков.

pub type P = (f64, f64);

/// Округление к чётному (как `numpy.rint`, Python `round`).
#[inline]
pub fn rint(v: f64) -> i64 {
    v.round_ties_even() as i64
}

/// Клип ломаной по замкнутому прямоугольнику `[x0,x1]×[y0,y1]`: части в порядке обхода.
/// Части из одной точки не возвращаются.
pub fn clip_line(pts: &[P], x0: f64, y0: f64, x1: f64, y1: f64) -> Vec<Vec<P>> {
    let mut out: Vec<Vec<P>> = Vec::new();
    let mut cur: Vec<P> = Vec::new();
    for w in pts.windows(2) {
        let (a, b) = (w[0], w[1]);
        match clip_seg(a, b, x0, y0, x1, y1) {
            Some((t0, t1)) => {
                let pa = if t0 == 0.0 { a } else { (a.0 + t0 * (b.0 - a.0), a.1 + t0 * (b.1 - a.1)) };
                let pb = if t1 == 1.0 { b } else { (a.0 + t1 * (b.0 - a.0), a.1 + t1 * (b.1 - a.1)) };
                let cont = t0 == 0.0 && !cur.is_empty() && *cur.last().unwrap() == a;
                if !cont {
                    if cur.len() >= 2 {
                        out.push(std::mem::take(&mut cur));
                    } else {
                        cur.clear();
                    }
                    cur.push(pa);
                }
                cur.push(pb);
                if t1 < 1.0 {
                    if cur.len() >= 2 {
                        out.push(std::mem::take(&mut cur));
                    } else {
                        cur.clear();
                    }
                }
            }
            None => {
                if cur.len() >= 2 {
                    out.push(std::mem::take(&mut cur));
                } else {
                    cur.clear();
                }
            }
        }
    }
    if cur.len() >= 2 {
        out.push(cur);
    }
    out
}

/// Лианг — Барски: параметры `[t0, t1]` части отрезка внутри прямоугольника.
fn clip_seg(a: P, b: P, x0: f64, y0: f64, x1: f64, y1: f64) -> Option<(f64, f64)> {
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    for (p, q) in [(-dx, a.0 - x0), (dx, x1 - a.0), (-dy, a.1 - y0), (dy, y1 - a.1)] {
        if p == 0.0 {
            if q < 0.0 {
                return None;
            }
        } else {
            let r = q / p;
            if p < 0.0 {
                if r > t1 {
                    return None;
                }
                if r > t0 {
                    t0 = r;
                }
            } else {
                if r < t0 {
                    return None;
                }
                if r < t1 {
                    t1 = r;
                }
            }
        }
    }
    if t0 > t1 {
        None
    } else {
        Some((t0, t1))
    }
}

fn seg_dist2(p: P, a: P, b: P) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let (ex, ey) = if l2 == 0.0 {
        (p.0 - a.0, p.1 - a.1)
    } else {
        let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0);
        (p.0 - (a.0 + t * dx), p.1 - (a.1 + t * dy))
    };
    ex * ex + ey * ey
}

/// Дуглас — Пекер (концы сохраняются; точка остаётся, если дальше `eps` от отрезка).
pub fn simplify(pts: &[P], eps: f64) -> Vec<P> {
    let n = pts.len();
    if n <= 2 {
        return pts.to_vec();
    }
    let mut keep = vec![false; n];
    keep[0] = true;
    keep[n - 1] = true;
    let e2 = eps * eps;
    let mut stack = vec![(0usize, n - 1)];
    while let Some((s, e)) = stack.pop() {
        if e <= s + 1 {
            continue;
        }
        let (mut best, mut bi) = (-1.0f64, 0usize);
        for k in s + 1..e {
            let d = seg_dist2(pts[k], pts[s], pts[e]);
            if d > best {
                best = d;
                bi = k;
            }
        }
        if best > e2 {
            keep[bi] = true;
            stack.push((s, bi));
            stack.push((bi, e));
        }
    }
    pts.iter().zip(keep).filter(|(_, k)| *k).map(|(p, _)| *p).collect()
}

/// Округление к целым метрам и удаление подряд идущих повторов.
pub fn round_dedup(pts: &[P]) -> Vec<(i64, i64)> {
    let mut v: Vec<(i64, i64)> = Vec::with_capacity(pts.len());
    for &(x, y) in pts {
        let q = (rint(x), rint(y));
        if v.last() != Some(&q) {
            v.push(q);
        }
    }
    v
}

/// Знаковая площадь кольца (без повтора первой точки), > 0 — против часовой.
pub fn ring_area(r: &[P]) -> f64 {
    if r.len() < 3 {
        return 0.0;
    }
    let (ox, oy) = r[0];
    let mut s = 0.0;
    for k in 1..r.len() - 1 {
        let (ax, ay) = (r[k].0 - ox, r[k].1 - oy);
        let (bx, by) = (r[k + 1].0 - ox, r[k + 1].1 - oy);
        s += ax * by - bx * ay;
    }
    s / 2.0
}

/// (|площадь|, центроид) кольца.
pub fn ring_centroid(r: &[P]) -> (f64, P) {
    let (ox, oy) = r[0];
    let (mut a, mut cx, mut cy) = (0.0, 0.0, 0.0);
    for k in 1..r.len().saturating_sub(1) {
        let (ax, ay) = (r[k].0 - ox, r[k].1 - oy);
        let (bx, by) = (r[k + 1].0 - ox, r[k + 1].1 - oy);
        let c = ax * by - bx * ay;
        a += c;
        cx += (ax + bx) * c;
        cy += (ay + by) * c;
    }
    if a == 0.0 {
        let n = r.len() as f64;
        let sx: f64 = r.iter().map(|p| p.0).sum();
        let sy: f64 = r.iter().map(|p| p.1).sum();
        return (0.0, (sx / n, sy / n));
    }
    ((a / 2.0).abs(), (ox + cx / (3.0 * a), oy + cy / (3.0 * a)))
}

/// Площадь (с дырами) и центроид полигона: внешнее кольцо + дыры.
pub fn polygon_centroid(outer: &[P], holes: &[Vec<P>]) -> (f64, P) {
    let (ao, co) = ring_centroid(outer);
    let (mut a, mut sx, mut sy) = (ao, ao * co.0, ao * co.1);
    for h in holes {
        let (ah, ch) = ring_centroid(h);
        a -= ah;
        sx -= ah * ch.0;
        sy -= ah * ch.1;
    }
    if a <= 0.0 {
        return (a.max(0.0), co);
    }
    (a, (sx / a, sy / a))
}

/// Точка внутри кольца (чётность).
pub fn point_in_ring(p: P, r: &[P]) -> bool {
    let mut inside = false;
    let n = r.len();
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = r[i];
        let (xj, yj) = r[j];
        if (yi > p.1) != (yj > p.1) && p.0 < (xj - xi) * (p.1 - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn cross(o: P, a: P, b: P) -> f64 {
    (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
}

/// Выпуклая оболочка (монотонная цепь), против часовой, без повтора.
pub fn convex_hull(pts: &[P]) -> Vec<P> {
    let mut p: Vec<P> = pts.to_vec();
    p.sort_by(|a, b| a.partial_cmp(b).unwrap());
    p.dedup();
    if p.len() < 3 {
        return p;
    }
    let mut h: Vec<P> = Vec::with_capacity(2 * p.len());
    for &q in &p {
        while h.len() >= 2 && cross(h[h.len() - 2], h[h.len() - 1], q) <= 0.0 {
            h.pop();
        }
        h.push(q);
    }
    let lo = h.len() + 1;
    for &q in p.iter().rev().skip(1) {
        while h.len() >= lo && cross(h[h.len() - 2], h[h.len() - 1], q) <= 0.0 {
            h.pop();
        }
        h.push(q);
    }
    h.pop();
    h
}

/// Минимальный по площади ориентированный прямоугольник: (центр, короткая, длинная, угол длинной
/// стороны от +x, градусы `[0, 180)`). `None` — вырожденная оболочка.
pub fn min_area_rect(pts: &[P]) -> Option<(P, f64, f64, f64)> {
    let h = convex_hull(pts);
    if h.len() < 3 {
        return None;
    }
    let n = h.len();
    let mut best: Option<(f64, P, f64, f64, f64)> = None; // (area, center, len_u, len_v, ang_u)
    for k in 0..n {
        let (a, b) = (h[k], h[(k + 1) % n]);
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let l = (dx * dx + dy * dy).sqrt();
        if l == 0.0 {
            continue;
        }
        let (ux, uy) = (dx / l, dy / l);
        let (vx, vy) = (-uy, ux);
        let (mut mu0, mut mu1, mut mv0, mut mv1) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
        for &q in &h {
            let (px, py) = (q.0 - a.0, q.1 - a.1);
            let u = px * ux + py * uy;
            let v = px * vx + py * vy;
            mu0 = mu0.min(u);
            mu1 = mu1.max(u);
            mv0 = mv0.min(v);
            mv1 = mv1.max(v);
        }
        let area = (mu1 - mu0) * (mv1 - mv0);
        if best.map_or(true, |bb| area < bb.0) {
            let cu = (mu0 + mu1) / 2.0;
            let cv = (mv0 + mv1) / 2.0;
            let c = (a.0 + cu * ux + cv * vx, a.1 + cu * uy + cv * vy);
            best = Some((area, c, mu1 - mu0, mv1 - mv0, uy.atan2(ux)));
        }
    }
    let (_, c, lu, lv, au) = best?;
    let (short, long, ang) = if lu >= lv {
        (lv, lu, au)
    } else {
        (lu, lv, au + std::f64::consts::FRAC_PI_2)
    };
    Some((c, short, long, ang.to_degrees().rem_euclid(180.0)))
}

/// Сборка колец из путей (списков id узлов) по общим концам. `None` — есть незамкнутое кольцо.
pub fn assemble_rings(ways: &[&[i64]]) -> Option<Vec<Vec<i64>>> {
    use std::collections::HashMap;
    let mut rings: Vec<Vec<i64>> = Vec::new();
    let mut open: Vec<Vec<i64>> = Vec::new();
    for w in ways {
        if w.len() < 2 {
            continue;
        }
        if w.first() == w.last() {
            if w.len() >= 4 {
                rings.push(w.to_vec());
            } else {
                return None;
            }
        } else {
            open.push(w.to_vec());
        }
    }
    let mut used = vec![false; open.len()];
    let mut by_end: HashMap<i64, Vec<usize>> = HashMap::new();
    for (k, w) in open.iter().enumerate() {
        by_end.entry(w[0]).or_default().push(k);
        by_end.entry(*w.last().unwrap()).or_default().push(k);
    }
    for s in 0..open.len() {
        if used[s] {
            continue;
        }
        used[s] = true;
        let mut cur = open[s].clone();
        loop {
            if cur.first() == cur.last() {
                break;
            }
            let end = *cur.last().unwrap();
            let next = by_end.get(&end).and_then(|v| v.iter().copied().find(|&k| !used[k]));
            let Some(k) = next else { return None };
            used[k] = true;
            let w = &open[k];
            if w[0] == end {
                cur.extend_from_slice(&w[1..]);
            } else {
                cur.extend(w.iter().rev().skip(1));
            }
        }
        if cur.len() < 4 {
            return None;
        }
        rings.push(cur);
    }
    Some(rings)
}

/// Кольца → полигоны (внешнее, дыры) по вложенности: глубина чётная — внешнее.
pub fn rings_to_polygons(rings: Vec<Vec<P>>) -> Vec<(Vec<P>, Vec<Vec<P>>)> {
    let n = rings.len();
    if n == 1 {
        return vec![(rings.into_iter().next().unwrap(), vec![])];
    }
    // parent[k]: наименьшее (по площади) кольцо, содержащее k
    let areas: Vec<f64> = rings.iter().map(|r| ring_area(r).abs()).collect();
    let mut parent: Vec<Option<usize>> = vec![None; n];
    for k in 0..n {
        let p = rings[k][0];
        for m in 0..n {
            if m != k && areas[m] > areas[k] && point_in_ring(p, &rings[m]) {
                if parent[k].map_or(true, |q| areas[m] < areas[q]) {
                    parent[k] = Some(m);
                }
            }
        }
    }
    let depth: Vec<usize> = (0..n)
        .map(|k| {
            let mut d = 0;
            let mut c = parent[k];
            while let Some(q) = c {
                d += 1;
                c = parent[q];
                if d > n {
                    break;
                }
            }
            d
        })
        .collect();
    let mut out: Vec<(usize, Vec<Vec<P>>)> = Vec::new();
    let mut idx = vec![usize::MAX; n];
    for k in 0..n {
        if depth[k] % 2 == 0 {
            idx[k] = out.len();
            out.push((k, vec![]));
        }
    }
    for k in 0..n {
        if depth[k] % 2 == 1 {
            if let Some(p) = parent[k] {
                out[idx[p]].1.push(rings[k].clone());
            }
        }
    }
    out.into_iter().map(|(k, h)| (rings[k].clone(), h)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_parts() {
        let l = [(-5.0, 5.0), (5.0, 5.0), (15.0, 5.0), (15.0, 8.0), (5.0, 8.0), (-1.0, 8.0)];
        let parts = clip_line(&l, 0.0, 0.0, 10.0, 10.0);
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0], vec![(0.0, 5.0), (5.0, 5.0), (10.0, 5.0)]);
        assert_eq!(parts[1], vec![(10.0, 8.0), (5.0, 8.0), (0.0, 8.0)]);
        assert!(clip_line(&[(20.0, 20.0), (30.0, 30.0)], 0.0, 0.0, 10.0, 10.0).is_empty());
    }

    #[test]
    fn dp() {
        let l = [(0.0, 0.0), (5.0, 0.4), (10.0, 0.0), (10.0, 10.0)];
        assert_eq!(simplify(&l, 1.0), vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0)]);
        let l = [(0.0, 0.0), (5.0, 1.5), (10.0, 0.0)];
        assert_eq!(simplify(&l, 1.0).len(), 3);
    }

    #[test]
    fn rint_even() {
        assert_eq!(rint(0.5), 0);
        assert_eq!(rint(1.5), 2);
        assert_eq!(rint(-0.5), 0);
        assert_eq!(rint(2.5), 2);
    }

    #[test]
    fn rect() {
        // прямоугольник 10×4 под 30°
        let a = 30f64.to_radians();
        let (c, s) = (a.cos(), a.sin());
        let pts: Vec<P> = [(0.0, 0.0), (10.0, 0.0), (10.0, 4.0), (0.0, 4.0)]
            .iter()
            .map(|&(x, y)| (100.0 + x * c - y * s, 50.0 + x * s + y * c))
            .collect();
        let (ctr, w, l, ang) = min_area_rect(&pts).unwrap();
        assert!((w - 4.0).abs() < 1e-9 && (l - 10.0).abs() < 1e-9);
        assert!((ang - 30.0).abs() < 1e-9, "{ang}");
        assert!((ctr.0 - (100.0 + 5.0 * c - 2.0 * s)).abs() < 1e-9);
    }

    #[test]
    fn centroid_with_hole() {
        let o = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        let h = vec![(0.0, 0.0), (5.0, 0.0), (5.0, 10.0), (0.0, 10.0)];
        let (a, c) = polygon_centroid(&o, &[h]);
        assert!((a - 50.0).abs() < 1e-9 && (c.0 - 7.5).abs() < 1e-9 && (c.1 - 5.0).abs() < 1e-9);
    }

    #[test]
    fn rings() {
        let a: &[i64] = &[1, 2, 3];
        let b: &[i64] = &[5, 4, 3];
        let c: &[i64] = &[5, 1];
        let r = assemble_rings(&[a, b, c]).unwrap();
        assert_eq!(r, vec![vec![1, 2, 3, 4, 5, 1]]);
        assert!(assemble_rings(&[a, b]).is_none());
    }

    #[test]
    fn nesting() {
        let sq = |a: f64, b: f64| vec![(a, a), (b, a), (b, b), (a, b)];
        let p = rings_to_polygons(vec![sq(0.0, 10.0), sq(2.0, 8.0), sq(4.0, 6.0), sq(20.0, 30.0)]);
        assert_eq!(p.len(), 3);
        assert_eq!(p[0].1.len(), 1);
    }
}
