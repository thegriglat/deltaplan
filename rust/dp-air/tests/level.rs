//! Модульная часть T4a: перенос «грубый уровень → мелкий» (`dp_air::prolong`).

use dp_air::{Code, Level, Stag, prolong, prolong_state};

fn lvl(n: [usize; 3], x0: f64, y0: f64, dx: f64, z_bot: f64) -> Level {
    Level {
        nx: n[0],
        ny: n[1],
        nz: n[2],
        x0,
        y0,
        dx,
        dz: 50.0,
        z_bot,
        halo: 1,
    }
}

/// Положение индекса вдоль оси: грань — узел `x0 + (i−1)·dx`, центр — `x0 + (i−½)·dx`.
fn pos(o: f64, d: f64, i: usize, node: bool) -> f64 {
    o + (i as f64 - if node { 1.0 } else { 0.5 }) * d
}

fn fill(l: &Level, st: Stag, f: &dyn Fn(f64, f64, f64) -> f64) -> Vec<f32> {
    let mut v = Vec::with_capacity(l.len());
    for k in 0..l.nz {
        for j in 0..l.ny {
            for i in 0..l.nx {
                let x = pos(l.x0, l.dx, i, st == Stag::U);
                let y = pos(l.y0, l.dx, j, st == Stag::V);
                v.push(f(x, y, l.z_bot + k as f64 * l.dz) as f32);
            }
        }
    }
    v
}

const STAGS: [Stag; 4] = [Stag::U, Stag::V, Stag::W, Stag::C];

/// Внутренность мелкого уровня, не затронутая зажимом на краю грубого.
fn inside(c: &Level, f: &Level, st: Stag, i: usize, j: usize, k: usize, ksh: i64) -> bool {
    let xs = pos(f.x0, f.dx, i, st == Stag::U);
    let ys = pos(f.y0, f.dx, j, st == Stag::V);
    let (xlo, xhi) = (
        pos(c.x0, c.dx, 0, st == Stag::U),
        pos(c.x0, c.dx, c.nx - 1, st == Stag::U),
    );
    let (ylo, yhi) = (
        pos(c.y0, c.dx, 0, st == Stag::V),
        pos(c.y0, c.dx, c.ny - 1, st == Stag::V),
    );
    let kc = k as i64 + ksh;
    xs >= xlo && xs <= xhi && ys >= ylo && ys <= yhi && kc >= 0 && kc < c.nz as i64
}

fn pair(r: usize, x0f: f64, y0f: f64, zf: f64) -> (Level, Level) {
    let dxc = 1200.0;
    let c = lvl([12, 10, 8], 0.0, 0.0, dxc, 100.0);
    let fine = lvl([20, 17, 8], x0f, y0f, dxc / r as f64, zf);
    (c, fine)
}

#[test]
fn constant_exact_every_stag() {
    for r in [3usize, 2] {
        let (c, f) = pair(r, 1300.0, 2100.0, 100.0);
        for st in STAGS {
            let src = fill(&c, st, &|_, _, _| 7.25);
            let mut dst = vec![0.0; f.len()];
            prolong(&c, &src, &f, &mut dst, st).unwrap();
            assert!(dst.iter().all(|v| (v - 7.25).abs() <= 1e-6), "{st:?} r={r}");
        }
    }
}

fn linear_check(r: usize, x0f: f64, y0f: f64, zf: f64) -> usize {
    let (c, f) = pair(r, x0f, y0f, zf);
    let ksh = ((zf - 100.0) / 50.0).round() as i64;
    let lin = |x: f64, y: f64, z: f64| 3.0 + 0.002 * x - 0.0015 * y + 0.01 * z;
    let mut n = 0;
    for st in STAGS {
        let src = fill(&c, st, &lin);
        let mut dst = vec![0.0; f.len()];
        prolong(&c, &src, &f, &mut dst, st).unwrap();
        let want = fill(&f, st, &lin);
        for k in 0..f.nz {
            for j in 0..f.ny {
                for i in 0..f.nx {
                    if !inside(&c, &f, st, i, j, k, ksh) {
                        continue;
                    }
                    let t = (k * f.ny + j) * f.nx + i;
                    let (a, b) = (dst[t] as f64, want[t] as f64);
                    assert!(
                        (a - b).abs() <= 1e-5 * b.abs().max(1.0),
                        "{st:?} r={r} ({i},{j},{k}): {a} vs {b}"
                    );
                    n += 1;
                }
            }
        }
    }
    n
}

#[test]
fn linear_field_exact_inside() {
    // совпадающие начала; затем начало не кратно dxc; затем сдвиг по z
    assert!(linear_check(3, 0.0, 0.0, 100.0) > 1000);
    assert!(linear_check(2, 0.0, 0.0, 100.0) > 1000);
}

#[test]
fn origin_and_z_shift_respected() {
    assert!(linear_check(3, 1300.0, 2150.0, 100.0) > 500);
    assert!(linear_check(2, 457.0, 311.0, 100.0) > 500);
    // ksh = 2 и ksh = -1 (низ мелкого ниже грубого: нижние уровни зажимаются)
    assert!(linear_check(3, 1300.0, 2150.0, 200.0) > 300);
    assert!(linear_check(3, 1300.0, 2150.0, 50.0) > 300);
}

#[test]
fn edges_clamp_to_coarse_border() {
    // мелкий уровень шире грубого: за краем — значение края грубой области
    let c = lvl([4, 4, 3], 0.0, 0.0, 1200.0, 0.0);
    let f = lvl([30, 30, 3], -2000.0, -2000.0, 400.0, 0.0);
    let src = fill(&c, Stag::C, &|x, y, _| x + y);
    let mut dst = vec![0.0; f.len()];
    prolong(&c, &src, &f, &mut dst, Stag::C).unwrap();
    assert!((dst[0] - src[0]).abs() < 1e-3);
    let last = dst.len() - 1;
    assert!((dst[last] - src[c.len() - 1]).abs() < 1e-3);
}

#[test]
fn boundary_mass_flux_vs_analytic() {
    // гладкое u(x,y); поток через западную и восточную грани мелкой области против точного
    let (dxc, r) = (1200.0, 3usize);
    let c = lvl([14, 12, 6], 0.0, 0.0, dxc, 0.0);
    let f = lvl(
        [3 * 6 + 2, 3 * 6 + 2, 6],
        3.0 * dxc,
        3.0 * dxc,
        dxc / r as f64,
        0.0,
    );
    let l = 6000.0f64;
    let u = |x: f64, y: f64, _z: f64| 5.0 * (1.0 + 0.3 * (x / l).sin() * (y / l).cos());
    let src = fill(&c, Stag::U, &u);
    let mut dst = vec![0.0; f.len()];
    prolong(&c, &src, &f, &mut dst, Stag::U).unwrap();
    let (mut flux, mut exact, mut absum) = (0.0f64, 0.0f64, 0.0f64);
    for &i in &[1usize, f.nx - 2] {
        for k in 0..f.nz {
            for j in 1..f.ny - 1 {
                let t = (k * f.ny + j) * f.nx + i;
                flux += dst[t] as f64;
                let (x, y) = (pos(f.x0, f.dx, i, true), pos(f.y0, f.dx, j, false));
                exact += u(x, y, 0.0);
                absum += u(x, y, 0.0).abs();
            }
        }
    }
    let rel = (flux - exact).abs() / (absum / 2.0);
    eprintln!("поток через внешние грани: относительное отличие {rel:.3e}");
    assert!(rel < 0.01, "{rel}");
}

#[test]
fn bad_lengths_are_errors() {
    let (c, f) = pair(3, 0.0, 0.0, 100.0);
    let src = vec![0.0; c.len()];
    let mut dst = vec![0.0; f.len()];
    let e = prolong(&c, &src[1..], &f, &mut dst, Stag::C).unwrap_err();
    assert_eq!(e.code, Code::BadInput);
    let e = prolong(&c, &src, &f, &mut dst[1..], Stag::C).unwrap_err();
    assert_eq!(e.code, Code::BadInput);
    let tiny = lvl([1, 5, 5], 0.0, 0.0, 1200.0, 0.0);
    assert!(prolong(&tiny, &[0.0; 25], &f, &mut dst, Stag::C).is_err());
    let mut bad = f;
    bad.dx = 0.0;
    assert!(prolong(&c, &src, &bad, &mut dst, Stag::C).is_err());
}

#[test]
fn state_six_fields() {
    let (c, f) = pair(3, 1300.0, 2150.0, 100.0);
    let lin = |x: f64, y: f64, z: f64| 1.0 + 0.001 * x + 0.002 * y + 0.01 * z;
    let srcs: Vec<Vec<f32>> = [Stag::U, Stag::V, Stag::W, Stag::C, Stag::C, Stag::C]
        .iter()
        .map(|&s| fill(&c, s, &lin))
        .collect();
    let mut d: Vec<Vec<f32>> = (0..6).map(|_| vec![0.0; f.len()]).collect();
    {
        let mut it = d.iter_mut().map(|v| v.as_mut_slice());
        let dst = [(); 6].map(|_| it.next().unwrap());
        let sr: [&[f32]; 6] = [0, 1, 2, 3, 4, 5].map(|i| srcs[i].as_slice());
        prolong_state(&c, sr, &f, dst).unwrap();
    }
    // отдельный вызов даёт то же, что prolong по полю
    let mut one = vec![0.0; f.len()];
    prolong(&c, &srcs[0], &f, &mut one, Stag::U).unwrap();
    assert_eq!(one, d[0]);
    // неверная длина — Err, приёмники не тронуты
    let mut z: Vec<Vec<f32>> = (0..6).map(|_| vec![9.0; f.len()]).collect();
    let mut it = z.iter_mut().map(|v| v.as_mut_slice());
    let dst = [(); 6].map(|_| it.next().unwrap());
    let sr: [&[f32]; 6] = [0, 1, 2, 3, 4, 5].map(|i| {
        if i == 5 {
            &srcs[5][1..]
        } else {
            srcs[i].as_slice()
        }
    });
    assert!(prolong_state(&c, sr, &f, dst).is_err());
    assert!(z.iter().all(|v| v.iter().all(|&x| x == 9.0)));
}
