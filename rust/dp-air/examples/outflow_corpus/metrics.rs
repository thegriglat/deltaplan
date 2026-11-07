//! Метрики OB2 и срезы OB3: поле решателя на высотах над рельефом, сравнение двух полей,
//! разброс поздних итераций, полоса у выхода. Функции принимают срез (а не решатель), поэтому
//! годятся для сравнения любого снимка с эталоном (этап 2 плана — `--start`, снимки на N итераций).
//!
//! Раскладка среза: `[высота][компонента u, v, w][ny][nx]`, f32, центры клеток области без ореола,
//! индекс `((h·3 + c)·ny + j)·nx + i`.
use dp_air::field::case_prepare::PreparedPlanes;
use picard_rs::state::State;

/// Высоты над рельефом для OB2/OB3, м.
pub const AGL_M: [f64; 3] = [10.0, 50.0, 300.0];
/// Высота для разброса поздних итераций, м (как `airlite_gen.at60`).
pub const SPREAD_AGL_M: f64 = 60.0;

/// Геометрия области без ореола и рельеф (из `PreparedPlanes`).
pub struct Geo {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub nxh: usize,
    pub nyh: usize,
    pub z_bot: f64,
    pub dz: f64,
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
    /// Рельеф с ореолом, `nyh·nxh`.
    pub hp: Vec<f32>,
    /// Первая клетка воздуха столбца (индекс с ореолом), `nyh·nxh`.
    pub kf: Vec<i32>,
}

impl Geo {
    pub fn from_planes(p: &PreparedPlanes) -> Geo {
        Geo {
            nx: p.nx,
            ny: p.ny,
            nz: p.nz,
            nxh: p.nx_h,
            nyh: p.ny_h,
            z_bot: p.z_bot,
            dz: p.dz,
            x0: p.x0,
            y0: p.y0,
            dx: p.dx,
            hp: p.col_plane(0).to_vec(),
            kf: p.kf.clone(),
        }
    }
}

/// Срезы поля `st` на высотах `agl` над рельефом: линейно по высоте между центрами клеток колонны
/// (центр клетки `k` с ореолом: `z_bot + (k − ½)·dz`); ниже центра первой воздушной клетки — её
/// значение (как `air3d/synth.py::agl`). u, v, w центра клетки — среднее двух граней.
pub fn slice(g: &Geo, st: &State, agl: &[f64]) -> Vec<f32> {
    let (nx, ny, nxh, nyh) = (g.nx, g.ny, g.nxh, g.nyh);
    let idx = |k: usize, jh: usize, ih: usize| (k * nyh + jh) * nxh + ih;
    let mut out = vec![0f32; agl.len() * 3 * ny * nx];
    for j in 0..ny {
        for i in 0..nx {
            let (jh, ih) = (j + 1, i + 1);
            let h = f64::from(g.hp[jh * nxh + ih]);
            let kfa = f64::from(g.kf[jh * nxh + ih]).max(1.0);
            let c = |k: usize| -> [f64; 3] {
                [
                    0.5 * f64::from(st.u[idx(k, jh, ih)] + st.u[idx(k, jh, ih + 1)]),
                    0.5 * f64::from(st.v[idx(k, jh, ih)] + st.v[idx(k, jh + 1, ih)]),
                    0.5 * f64::from(st.w[idx(k, jh, ih)] + st.w[idx(k + 1, jh, ih)]),
                ]
            };
            for (hi, a) in agl.iter().enumerate() {
                let kfl = ((h + a - g.z_bot) / g.dz + 0.5).max(kfa);
                let k0 = (kfl.floor().min((g.nz - 1) as f64)).max(1.0);
                let t = (kfl - k0).clamp(0.0, 1.0);
                let (p, q) = (c(k0 as usize), c(k0 as usize + 1));
                for cc in 0..3 {
                    out[((hi * 3 + cc) * ny + j) * nx + i] = (p[cc] + (q[cc] - p[cc]) * t) as f32;
                }
            }
        }
    }
    out
}

/// Процентиль `p ∈ [0, 1]` с линейной интерполяцией (как `numpy.nanpercentile`), нечисловые пропускаются.
pub fn percentile(v: &[f64], p: f64) -> f64 {
    let mut s: Vec<f64> = v.iter().copied().filter(|x| x.is_finite()).collect();
    if s.is_empty() {
        return f64::NAN;
    }
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pos = (s.len() - 1) as f64 * p.clamp(0.0, 1.0);
    let lo = pos.floor() as usize;
    let hi = (lo + 1).min(s.len() - 1);
    s[lo] + (s[hi] - s[lo]) * (pos - lo as f64)
}

/// Разброс поздних итераций (`airlite_gen.late_spread60_p90`): на каждой клетке без `edge` клеток у
/// края RMS по снимкам |Δ(u, v)| от среднего снимков, затем 90-й процентиль, м/с. `snaps` — срезы
/// [`slice`] на одной высоте (60 м): `[u, v, w][ny][nx]`.
pub fn late_spread_p90(snaps: &[Vec<f32>], nx: usize, ny: usize, edge: usize) -> f64 {
    let n = snaps.len() as f64;
    let np = nx * ny;
    let mut rms = Vec::with_capacity(np);
    for j in edge..ny.saturating_sub(edge) {
        for i in edge..nx.saturating_sub(edge) {
            let q = j * nx + i;
            let mean = |c: usize| snaps.iter().map(|s| f64::from(s[c * np + q])).sum::<f64>() / n;
            let (mu, mv) = (mean(0), mean(1));
            let acc: f64 = snaps
                .iter()
                .map(|s| {
                    let (du, dv) = (f64::from(s[q]) - mu, f64::from(s[np + q]) - mv);
                    du * du + dv * dv
                })
                .sum();
            rms.push((acc / n).sqrt());
        }
    }
    percentile(&rms, 0.9)
}

/// Сравнение двух срезов на одной высоте (индекс `hi`): |Δ(u, v)| центров клеток.
#[derive(Debug, Default, PartialEq)]
pub struct Cmp {
    /// Наибольшее в точках стартов (билинейно по четырём центрам); `None` — точек в области нет.
    pub start_max: Option<f64>,
    pub int_rms: f64,
    pub int_p99: f64,
    pub int_max: f64,
    pub band_max: f64,
}

/// Дробные координаты точки старта в клетках (центр клетки 0 — 0.0); `None` — вне области.
pub fn site_cell(g: &Geo, x: f64, y: f64) -> Option<(f64, f64)> {
    let (fx, fy) = ((x - g.x0) / g.dx, (y - g.y0) / g.dx);
    if fx < 0.0 || fy < 0.0 || fx > g.nx as f64 || fy > g.ny as f64 {
        return None;
    }
    Some((fx - 0.5, fy - 0.5))
}

pub fn compare(
    a: &[f32],
    b: &[f32],
    hi: usize,
    nx: usize,
    ny: usize,
    edge: usize,
    sites: &[(f64, f64)],
) -> Cmp {
    let np = nx * ny;
    let d: Vec<f64> = (0..np)
        .map(|q| {
            let (u, v) = ((hi * 3) * np + q, (hi * 3 + 1) * np + q);
            f64::from(a[u] - b[u]).hypot(f64::from(a[v] - b[v]))
        })
        .collect();
    let mut int = Vec::new();
    let mut band_max = 0.0f64;
    for j in 0..ny {
        for i in 0..nx {
            let x = d[j * nx + i];
            if i >= edge && i + edge < nx && j >= edge && j + edge < ny {
                int.push(x);
            } else {
                band_max = band_max.max(x);
            }
        }
    }
    let int_rms = (int.iter().map(|x| x * x).sum::<f64>() / int.len().max(1) as f64).sqrt();
    let int_max = int.iter().copied().fold(0.0, f64::max);
    let mut start_max: Option<f64> = None;
    for &(fx, fy) in sites {
        let (fx, fy) = (
            fx.clamp(0.0, (nx - 1) as f64),
            fy.clamp(0.0, (ny - 1) as f64),
        );
        let (i0, j0) = (
            (fx.floor() as usize).min(nx - 2),
            (fy.floor() as usize).min(ny - 2),
        );
        let (tx, ty) = (fx - i0 as f64, fy - j0 as f64);
        let at = |j: usize, i: usize| d[j * nx + i];
        let top = at(j0, i0) * (1.0 - tx) + at(j0, i0 + 1) * tx;
        let bot = at(j0 + 1, i0) * (1.0 - tx) + at(j0 + 1, i0 + 1) * tx;
        let v = top * (1.0 - ty) + bot * ty;
        start_max = Some(start_max.map_or(v, |m| m.max(v)));
    }
    Cmp {
        start_max,
        int_rms,
        int_p99: percentile(&int, 0.99),
        int_max,
        band_max,
    }
}

/// Q5: у граней выхода — среднее s·u_n в полосе `edge` клеток и доля клеток с s·u_n < 0. Стороны
/// выхода — где фон дует наружу (`ex`, `ey` — «куда дует», порог 1e-9 как в `prepare`); клетка
/// угла при двух сторонах выхода считается по каждой стороне. `None` — сторон выхода нет.
pub fn edge_out(
    s: &[f32],
    hi: usize,
    nx: usize,
    ny: usize,
    edge: usize,
    ex: f64,
    ey: f64,
) -> Option<(f64, f64)> {
    let np = nx * ny;
    let (mut sum, mut neg, mut n) = (0.0f64, 0usize, 0usize);
    let mut add = |un: f64| {
        sum += un;
        n += 1;
        if un < 0.0 {
            neg += 1;
        }
    };
    let comp = |c: usize, j: usize, i: usize| f64::from(s[(hi * 3 + c) * np + j * nx + i]);
    for j in 0..ny {
        for i in 0..nx {
            if ex > 1e-9 && i + edge >= nx {
                add(comp(0, j, i));
            }
            if ex < -1e-9 && i < edge {
                add(-comp(0, j, i));
            }
            if ey > 1e-9 && j + edge >= ny {
                add(comp(1, j, i));
            }
            if ey < -1e-9 && j < edge {
                add(-comp(1, j, i));
            }
        }
    }
    (n > 0).then(|| (sum / n as f64, neg as f64 / n as f64))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(nxh: usize, nyh: usize, nzh: usize, f: impl Fn(usize) -> f32) -> State {
        let n = nxh * nyh * nzh;
        let u: Vec<f32> = (0..n).map(|q| f(q / (nxh * nyh))).collect();
        State {
            case: String::new(),
            input: String::new(),
            it: 0,
            dims: [nxh, nyh, nzh],
            halo: 1,
            n: [nxh - 2, nyh - 2, nzh - 2],
            v: vec![0.0; n],
            w: vec![0.0; n],
            th: vec![0.0; n],
            thd: vec![0.0; n],
            p: vec![0.0; n],
            u,
            nu: None,
            nuh: None,
            residuals: None,
        }
    }

    fn geo(nx: usize, ny: usize, nz: usize, h: f32, kf: i32) -> Geo {
        let (nxh, nyh) = (nx + 2, ny + 2);
        Geo {
            nx,
            ny,
            nz,
            nxh,
            nyh,
            z_bot: 0.0,
            dz: 100.0,
            x0: -400.0 * nx as f64 / 2.0,
            y0: -400.0 * ny as f64 / 2.0,
            dx: 400.0,
            hp: vec![h; nxh * nyh],
            kf: vec![kf; nxh * nyh],
        }
    }

    #[test]
    fn slice_interpolates_between_cell_centres() {
        // u растёт с индексом клетки k на 1 м/с; центр k — (k − ½)·100 м
        let g = geo(4, 4, 8, 0.0, 1);
        let st = state(6, 6, 10, |k| k as f32);
        let s = slice(&g, &st, &[150.0, 300.0]);
        // z = 150 -> k = 2.0, u = 2; z = 300 -> k = 3.5, u = 3.5
        assert!((s[0] - 2.0).abs() < 1e-5, "{}", s[0]);
        assert!((s[3 * 16] - 3.5).abs() < 1e-5, "{}", s[3 * 16]);
    }

    #[test]
    fn slice_below_first_air_cell_takes_its_value() {
        // рельеф 200 м: первая клетка воздуха k = 3 (центр 250 м); на 10 м над рельефом (210 м,
        // ниже центра) — u(k=3)
        let g = geo(4, 4, 8, 200.0, 3);
        let st = state(6, 6, 10, |k| k as f32);
        let s = slice(&g, &st, &[10.0]);
        assert!((s[0] - 3.0).abs() < 1e-5, "{}", s[0]);
    }

    #[test]
    fn percentile_matches_numpy_linear() {
        let v = [1.0, 2.0, 3.0, 4.0, f64::NAN];
        assert!((percentile(&v, 0.5) - 2.5).abs() < 1e-12);
        assert!((percentile(&v, 0.9) - 3.7).abs() < 1e-12);
    }

    #[test]
    fn spread_of_identical_snapshots_is_zero_and_of_alternating_is_known() {
        let (nx, ny) = (12, 12);
        let np = nx * ny;
        let mk = |u: f32| {
            let mut s = vec![0f32; 3 * np];
            s[..np].fill(u);
            s
        };
        assert_eq!(late_spread_p90(&[mk(2.0), mk(2.0)], nx, ny, 5), 0.0);
        // u = 1, 3 -> среднее 2, отклонение 1, RMS 1
        let r = late_spread_p90(&[mk(1.0), mk(3.0)], nx, ny, 5);
        assert!((r - 1.0).abs() < 1e-6, "{r}");
    }

    #[test]
    fn compare_regions_and_sites() {
        let (nx, ny) = (12, 12);
        let np = nx * ny;
        let a = vec![0f32; 9 * np];
        let mut b = vec![0f32; 9 * np];
        b[0] = 3.0; // u в углу (0, 0): полоса
        b[6 * nx + 6] = 4.0; // u в (6, 6): внутри
        b[np + 6 * nx + 6] = 3.0; // v там же -> |Δ| = 5
        let g = geo(nx, ny, 4, 0.0, 1);
        let sites = [site_cell(&g, 400.0 * 0.5, 400.0 * 0.5).unwrap()]; // центр клетки (6, 6)
        let c = compare(&a, &b, 0, nx, ny, 5, &sites);
        assert_eq!(c.band_max, 3.0);
        assert_eq!(c.int_max, 5.0);
        assert!(
            (c.start_max.unwrap() - 5.0).abs() < 1e-9,
            "{:?}",
            c.start_max
        );
        assert!(c.int_rms > 0.0 && c.int_p99 <= 5.0);
        assert!(site_cell(&g, 1.0e6, 0.0).is_none());
    }

    #[test]
    fn edge_out_sides_follow_the_wind() {
        let (nx, ny) = (12, 12);
        let np = nx * ny;
        let mut s = vec![0f32; 9 * np];
        s[..np].fill(2.0); // u = 2 везде
        // ветер на восток (ex > 0): выход — восточная сторона, s·u_n = u = 2
        let (m, f) = edge_out(&s, 0, nx, ny, 5, 1.0, 0.0).unwrap();
        assert_eq!((m, f), (2.0, 0.0));
        // ветер на запад: выход — западная сторона, s·u_n = −u = −2, обратный ток везде
        let (m, f) = edge_out(&s, 0, nx, ny, 5, -1.0, 0.0).unwrap();
        assert_eq!((m, f), (-2.0, 1.0));
        assert!(edge_out(&s, 0, nx, ny, 5, 0.0, 0.0).is_none());
    }
}
