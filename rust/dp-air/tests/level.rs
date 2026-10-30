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

// ---------------------------------------------------------------------------------------------
// nest и shift (RW-6n): общие операции уровней для окон клипмапа
// ---------------------------------------------------------------------------------------------

mod window_ops {
    use dp_air::field::window::{
        NestDst, NestSrc, Shift, ShiftDst, ShiftSrc, nest, shift_between, shift_warm,
    };
    use dp_air::{Code, Level};

    fn level(n: [usize; 3], x0: f64, y0: f64, dx: f64, dz: f64, z_bot: f64) -> Level {
        Level {
            nx: n[0],
            ny: n[1],
            nz: n[2],
            x0,
            y0,
            dx,
            dz,
            z_bot,
            halo: 1,
        }
    }

    /// Поле, линейное по координатам, в точке индекса: грань — в узле своей оси, центр — в середине.
    fn fill(l: &Level, node: [bool; 3], f: &dyn Fn(f64, f64, f64) -> f64) -> Vec<f32> {
        let p = |o: f64, d: f64, i: usize, n: bool| o + (i as f64 - if n { 1.0 } else { 0.5 }) * d;
        let mut v = Vec::with_capacity(l.len());
        for k in 0..l.nz {
            for j in 0..l.ny {
                for i in 0..l.nx {
                    v.push(f(
                        p(l.x0, l.dx, i, node[0]),
                        p(l.y0, l.dx, j, node[1]),
                        p(l.z_bot, l.dz, k, node[2]),
                    ) as f32);
                }
            }
        }
        v
    }

    fn lin(x: f64, y: f64, z: f64) -> f64 {
        3.0 + 0.004 * x - 0.003 * y + 0.01 * z
    }

    fn all_air(l: &Level) -> Vec<u8> {
        // клетки воздуха, все грани неизвестные
        vec![1 + 4 + 16 + 64; l.len()]
    }

    #[derive(Debug)]
    struct Out {
        u: Vec<f32>,
        v: Vec<f32>,
        w: Vec<f32>,
        th: Vec<f32>,
        thd: Vec<f32>,
    }

    fn run(c: &Level, src: &NestSrc, f: &Level, tc: &[u8]) -> Result<Out, dp_air::Error> {
        let n = f.len();
        let mut o = Out {
            u: vec![9.0; n],
            v: vec![9.0; n],
            w: vec![9.0; n],
            th: vec![9.0; n],
            thd: vec![9.0; n],
        };
        nest(
            c,
            src,
            f,
            tc,
            NestDst {
                u: &mut o.u,
                v: &mut o.v,
                w: &mut o.w,
                th: &mut o.th,
                thd: &mut o.thd,
            },
        )?;
        Ok(o)
    }

    #[test]
    fn nest_linear_field_exact_inside_parent() {
        // родитель 400 м, дочерний 100 м (r = 4) и 200 м (r = 2); дочерний целиком внутри
        let c = level([14, 14, 12], 0.0, 0.0, 400.0, 50.0, 100.0);
        let tcp = vec![1u8; c.len()];
        let (u, v, w) = (
            fill(&c, [true, false, false], &lin),
            fill(&c, [false, true, false], &lin),
            fill(&c, [false, false, true], &lin),
        );
        let (th, thd) = (
            fill(&c, [false; 3], &lin),
            fill(&c, [false; 3], &|x, y, z| 0.5 * lin(x, y, z)),
        );
        let src = NestSrc {
            tc: &tcp,
            u: &u,
            v: &v,
            w: &w,
            th: &th,
            thd: Some(&thd),
        };
        for (r, x0, y0, zb) in [(4usize, 1300.0, 1550.0, 250.0), (2, 1010.0, 990.0, 300.0)] {
            // dz дочернего ≠ родителя: отношение rz = 25/50
            let f = level([16, 20, 12], x0, y0, 400.0 / r as f64, 25.0, zb);
            let tc = all_air(&f);
            let o = run(&c, &src, &f, &tc).unwrap();
            let want = |node: [bool; 3], g: &dyn Fn(f64, f64, f64) -> f64| fill(&f, node, g);
            for (got, node, g) in [
                (
                    &o.u,
                    [true, false, false],
                    &lin as &dyn Fn(f64, f64, f64) -> f64,
                ),
                (&o.v, [false, true, false], &lin),
                (&o.w, [false, false, true], &lin),
                (&o.th, [false; 3], &lin),
            ] {
                let wnt = want(node, g);
                let mut n = 0;
                for (a, b) in got.iter().zip(&wnt) {
                    assert!(
                        (a - b).abs() <= 2e-4 * b.abs().max(1.0),
                        "r={r}: got {a} want {b}"
                    );
                    n += 1;
                }
                assert!(n > 1000);
            }
            let half = want([false; 3], &|x, y, z| 0.5 * lin(x, y, z));
            assert!(
                o.thd
                    .iter()
                    .zip(&half)
                    .all(|(a, b)| (a - b).abs() <= 2e-4 * b.abs().max(1.0))
            );
        }
    }

    #[test]
    fn nest_zero_where_fine_type_is_wall_and_in_ground_cells() {
        let c = level([10, 10, 8], 0.0, 0.0, 400.0, 50.0, 0.0);
        let mut tcp = vec![1u8; c.len()];
        // нижняя плоскость грубого — земля: центры 0
        tcp[..c.nx * c.ny].fill(0);
        let ones = vec![1.0f32; c.len()];
        let src = NestSrc {
            tc: &tcp,
            u: &ones,
            v: &ones,
            w: &ones,
            th: &ones,
            thd: None,
        };
        let f = level([8, 8, 6], 1000.0, 1000.0, 200.0, 25.0, 0.0);
        let mut tc = all_air(&f);
        // клетка (k=3, j=3, i=3): стенка по u; клетка (2,2,2): земля
        let q = (3 * f.ny + 3) * f.nx + 3;
        tc[q] = 1 + 16 + 64;
        let q2 = (2 * f.ny + 2) * f.nx + 2;
        tc[q2] = 0;
        let o = run(&c, &src, &f, &tc).unwrap();
        assert_eq!(o.u[q], 0.0);
        assert!(o.v[q] > 0.9, "{}", o.v[q]);
        assert_eq!(o.th[q2], 0.0);
        assert_eq!(o.thd[q2], 0.0, "нет thd родителя — нули");
        assert_eq!(o.u[q2], 0.0);
        // у дна (низ мелкого = низ родителя): центры нижнего уровня смешивают землю родителя
        let low = 4 * f.nx + 4;
        assert!(o.th[low] < 0.95, "{}", o.th[low]);
        // выше — константа
        let hi = (5 * f.ny + 4) * f.nx + 4;
        assert!((o.th[hi] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn nest_clamps_outside_parent_and_rejects_bad_input() {
        let c = level([6, 6, 6], 0.0, 0.0, 400.0, 50.0, 0.0);
        let tcp = vec![1u8; c.len()];
        let th = fill(&c, [false; 3], &|x, _, _| x);
        let z = vec![0.0f32; c.len()];
        let src = NestSrc {
            tc: &tcp,
            u: &z,
            v: &z,
            w: &z,
            th: &th,
            thd: None,
        };
        // мелкий уровень шире родителя: за краем — значение края
        let f = level([40, 8, 6], -3000.0, 800.0, 200.0, 50.0, 0.0);
        let o = run(&c, &src, &f, &all_air(&f)).unwrap();
        let q = |i: usize| (2 * f.ny + 3) * f.nx + i;
        // зажим индекса в [0, n − 1,0001]: до края не хватает 1e-4 индекса (0,04 при наклоне 400/индекс)
        assert!((o.th[q(0)] - th[(2 * c.ny + 3) * c.nx]).abs() < 0.1);
        assert!((o.th[q(f.nx - 1)] - th[(2 * c.ny + 3) * c.nx + c.nx - 1]).abs() < 0.1);
        // длины
        let e = run(&c, &src, &f, &all_air(&f)[1..]).unwrap_err();
        assert_eq!(e.code, Code::BadInput);
        let short = NestSrc {
            tc: &tcp[1..],
            ..src
        };
        assert_eq!(
            run(&c, &short, &f, &all_air(&f)).unwrap_err().code,
            Code::BadInput
        );
        let mut bad = f;
        bad.dx = 0.0;
        assert!(run(&c, &src, &bad, &all_air(&f)).is_err());
    }

    #[test]
    fn shift_between_rules() {
        let old = level([66, 66, 64], 0.0, 0.0, 100.0, 50.0, 500.0);
        let at = |dx: f64, dy: f64, dz: f64| level([66, 66, 64], dx, dy, 100.0, 50.0, 500.0 + dz);
        assert_eq!(
            shift_between(&old, &at(1600.0, 0.0, 0.0)),
            Some(Shift { i: 16, j: 0, k: 0 })
        );
        assert_eq!(
            shift_between(&old, &at(-300.0, 800.0, 100.0)),
            Some(Shift { i: -3, j: 8, k: 2 })
        );
        assert_eq!(
            shift_between(&old, &at(1650.0, 0.0, 0.0)),
            None,
            "дробный сдвиг"
        );
        assert_eq!(
            shift_between(&old, &at(0.0, 0.0, 25.0)),
            None,
            "дробный сдвиг по z"
        );
        assert_eq!(
            shift_between(&old, &at(6400.0, 0.0, 0.0)),
            None,
            "нет пересечения"
        );
        assert!(shift_between(&old, &at(6300.0, 0.0, 0.0)).is_some());
        let mut other = at(0.0, 0.0, 0.0);
        other.dx = 50.0;
        assert_eq!(shift_between(&old, &other), None, "другая клетка");
    }

    #[test]
    fn shift_warm_moves_unknowns_and_keeps_boundary() {
        let old = level([10, 9, 8], 0.0, 0.0, 100.0, 50.0, 0.0);
        let new = level([10, 9, 8], 200.0, 100.0, 100.0, 50.0, 50.0);
        let sh = shift_between(&old, &new).unwrap();
        assert_eq!(sh, Shift { i: 2, j: 1, k: 1 });
        let n = old.len();
        let mk = |a: f32| -> Vec<f32> { (0..n).map(|q| a + q as f32).collect() };
        let (ou, ov, ow, oth, othd, op) = (mk(0.0), mk(1e4), mk(2e4), mk(3e4), mk(4e4), mk(5e4));
        let mut tc = vec![0u8; n];
        // внутренность — воздух с неизвестными гранями, ореол — тип 2/3
        for k in 0..new.nz {
            for j in 0..new.ny {
                for i in 0..new.nx {
                    let inner = (1..new.nx - 1).contains(&i)
                        && (1..new.ny - 1).contains(&j)
                        && (1..new.nz - 1).contains(&k);
                    tc[(k * new.ny + j) * new.nx + i] = if inner {
                        1 + 4 + 16 + 64
                    } else {
                        2 + 8 + 32 + 128
                    };
                }
            }
        }
        let fill9 = || vec![-9.0f32; n];
        let (mut du, mut dv, mut dw, mut dth, mut dthd, mut dp) =
            (fill9(), fill9(), fill9(), fill9(), fill9(), fill9());
        shift_warm(
            &old,
            &ShiftSrc {
                u: &ou,
                v: &ov,
                w: &ow,
                th: &oth,
                thd: &othd,
                p: &op,
            },
            &new,
            &tc,
            sh,
            ShiftDst {
                u: &mut du,
                v: &mut dv,
                w: &mut dw,
                th: &mut dth,
                thd: &mut dthd,
                p: &mut dp,
            },
        )
        .unwrap();
        let ix = |l: &Level, i: usize, j: usize, k: usize| (k * l.ny + j) * l.nx + i;
        for k in 1..new.nz - 1 {
            for j in 1..new.ny - 1 {
                for i in 1..new.nx - 1 {
                    let (io, jo, ko) = (i + 2, j + 1, k + 1);
                    let q = ix(&new, i, j, k);
                    if io < old.nx && jo < old.ny && ko < old.nz {
                        let o = ix(&old, io, jo, ko);
                        assert_eq!((du[q], dv[q], dw[q]), (ou[o], ov[o], ow[o]));
                        assert_eq!((dth[q], dthd[q]), (oth[o], othd[o]));
                        if io <= old.nx - 2 && jo <= old.ny - 2 && ko <= old.nz - 2 {
                            assert_eq!(dp[q], op[o]);
                        }
                    } else {
                        // вне старого окна: граничное состояние осталось, p — ближайшее внутреннее
                        assert_eq!((du[q], dth[q]), (-9.0, -9.0));
                        let o = ix(
                            &old,
                            io.clamp(1, old.nx - 2),
                            jo.clamp(1, old.ny - 2),
                            ko.clamp(1, old.nz - 2),
                        );
                        assert_eq!(dp[q], op[o]);
                    }
                }
            }
        }
        // ореол нового окна не тронут
        let h = ix(&new, 0, 4, 4);
        assert_eq!((du[h], dth[h], dp[h]), (-9.0, -9.0, -9.0));
        // длины
        let e = shift_warm(
            &old,
            &ShiftSrc {
                u: &ou[1..],
                v: &ov,
                w: &ow,
                th: &oth,
                thd: &othd,
                p: &op,
            },
            &new,
            &tc,
            sh,
            ShiftDst {
                u: &mut du,
                v: &mut dv,
                w: &mut dw,
                th: &mut dth,
                thd: &mut dthd,
                p: &mut dp,
            },
        )
        .unwrap_err();
        assert_eq!(e.code, Code::BadInput);
    }
}
