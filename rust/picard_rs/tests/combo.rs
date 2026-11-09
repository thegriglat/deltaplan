//! PT4 (picard-terrain): cut cells together with the second-order advection correction.
//!
//! 1. Unit fractions on every air cell: cut + adv2 repeats adv2 without cut (iterations equal,
//!    fields within 1e-6 relative), for every limiter; ref cases `agnesi`, `flat_wind` in memory.
//! 2. Mass: the PT2 divergence of the delivered field of a smooth sub-grid ridge is below
//!    `tol_div_rms`, with adv2.
//! 3. The correction carries the weight of the first-order flux of its face: a closed face
//!    (af = 0) gives no correction, a half-open face half of it.

use picard_rs::adv2::{self, Limiter};
use picard_rs::api::{self, SolveOpts, StopReason};
use picard_rs::case::{Case, Consts};
use picard_rs::kernels::Vel;
use picard_rs::report::div_rms_f64;
use std::path::PathBuf;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn opts() -> SolveOpts {
    SolveOpts {
        threads: 2,
        max_iters: 4000,
        ..SolveOpts::default()
    }
}

/// Fractions 1 on air cells and on all their faces, 0 in the ground (as `cut.py` writes for a
/// grid without sub-grid terrain); halo from the neighbour along the normal is also 1 / 0.
fn unit_fractions(c: &mut Case) {
    let n3 = c.n3();
    let cell = c.arrays["cell"].clone();
    let (nx, ny) = (c.nxh, c.nyh);
    let st = [1usize, nx, nx * ny];
    let vf: Vec<f32> = cell
        .iter()
        .map(|&t| if t == 0.0 { 0.0 } else { 1.0 })
        .collect();
    let mut af = [vec![0.0f32; n3], vec![0.0f32; n3], vec![0.0f32; n3]];
    for q in 0..n3 {
        if vf[q] == 1.0 {
            for d in 0..3 {
                af[d][q] = 1.0;
                if q + st[d] < n3 {
                    af[d][q + st[d]] = 1.0;
                }
            }
        }
    }
    c.arrays.insert("vf".into(), vf);
    let [au, av, aw] = af;
    c.arrays.insert("af_u".into(), au);
    c.arrays.insert("af_v".into(), av);
    c.arrays.insert("af_w".into(), aw);
    c.params.cut_cells = true;
}

fn rel(a: &[f32], b: &[f32]) -> f64 {
    let scale = a
        .iter()
        .fold(0.0f64, |m, &x| m.max(f64::from(x).abs()))
        .max(1e-30);
    let d = a.iter().zip(b).fold(0.0f64, |m, (&x, &y)| {
        m.max((f64::from(x) - f64::from(y)).abs())
    });
    d / scale
}

#[test]
fn unit_fractions_repeat_the_plain_iteration() {
    for name in ["flat_wind", "agnesi"] {
        let c = load(name);
        let plain = api::solve(&c, &opts()).unwrap();
        let mut cc = load(name);
        unit_fractions(&mut cc);
        let cut = api::solve(&cc, &opts()).unwrap();
        assert_eq!(plain.stop, StopReason::Converged, "{name}");
        assert_eq!(cut.stop, StopReason::Converged, "{name}");
        assert_eq!(plain.iters, cut.iters, "{name}: iterations");
        for (f, x, y) in [
            ("u", &plain.state.u, &cut.state.u),
            ("v", &plain.state.v, &cut.state.v),
            ("w", &plain.state.w, &cut.state.w),
            ("p", &plain.state.p, &cut.state.p),
        ] {
            let r = rel(x, y);
            eprintln!("{name}: {f} rel {r:.2e}");
            assert!(r <= 1e-6, "{name}: {f} rel {r:e}");
        }
    }
}

/// Fractions of a sub-grid terrain `h` = bilinear between the cell-centre heights `hc` of the
/// case (the grid's own steps smoothed): `n` x `n` points per cell / face (trapezoid weights),
/// `vf` = mean open height fraction, `af_w` = open fraction of the face plane, `af_u`, `af_v` =
/// mean open height fraction along the face edge. Air cells keep at least `vf_floor` (the types
/// of the fixture are not changed).
fn terrain_fractions(c: &mut Case, n: usize, vf_floor: f32) {
    let (nxh, nyh, nzh) = (c.nxh, c.nyh, c.nzh);
    let (nx, ny) = (c.nx, c.ny);
    let (dx, dz, zb) = (f64::from(c.dx), f64::from(c.dz), f64::from(c.z_bot));
    let hc = c.arrays["hc"].clone();
    // Cell centres of interior column (i, j) at x = (i + 0.5) dx (local), clamp outside.
    let hcell = |i: i64, j: i64| -> f64 {
        let ii = i.clamp(0, nx as i64 - 1) as usize;
        let jj = j.clamp(0, ny as i64 - 1) as usize;
        f64::from(hc[jj * nx + ii])
    };
    let h = |x: f64, y: f64| -> f64 {
        let fx = x / dx - 0.5;
        let fy = y / dx - 0.5;
        let (i0, j0) = (fx.floor(), fy.floor());
        let (a, b) = (fx - i0, fy - j0);
        let (i0, j0) = (i0 as i64, j0 as i64);
        (1.0 - b) * ((1.0 - a) * hcell(i0, j0) + a * hcell(i0 + 1, j0))
            + b * ((1.0 - a) * hcell(i0, j0 + 1) + a * hcell(i0 + 1, j0 + 1))
    };
    let wt = |m: usize| if m == 0 || m == n - 1 { 0.5 } else { 1.0 };
    let open = |z0: f64, hh: f64| ((z0 + dz - hh) / dz).clamp(0.0, 1.0);
    let n3 = c.n3();
    let (mut vf, mut au, mut av, mut aw) = (
        vec![0.0f32; n3],
        vec![0.0f32; n3],
        vec![0.0f32; n3],
        vec![0.0f32; n3],
    );
    let cell = c.arrays["cell"].clone();
    for k in 0..nzh {
        let zlo = zb + (k as f64 - 1.0) * dz;
        for j in 0..nyh {
            for i in 0..nxh {
                // Halo cells take the geometry of the nearest interior column.
                let ic = i.clamp(1, nxh - 2) as f64 - 1.0;
                let jc = j.clamp(1, nyh - 2) as f64 - 1.0;
                let q = (k * nyh + j) * nxh + i;
                let (mut sv, mut sw, mut s) = (0.0, 0.0, 0.0);
                let (mut su, mut ssu, mut svv, mut ssv) = (0.0, 0.0, 0.0, 0.0);
                for b in 0..n {
                    for a in 0..n {
                        let (fa, fb) = (a as f64 / (n - 1) as f64, b as f64 / (n - 1) as f64);
                        let hh = h((ic + fa) * dx, (jc + fb) * dx);
                        let w = wt(a) * wt(b);
                        sv += w * open(zlo, hh);
                        sw += w * f64::from(u8::from(hh < zlo));
                        s += w;
                    }
                    // west edge of the cell (u face q) and south edge (v face q)
                    let fb = b as f64 / (n - 1) as f64;
                    su += wt(b) * open(zlo, h(ic * dx, (jc + fb) * dx));
                    ssu += wt(b);
                    svv += wt(b) * open(zlo, h((ic + fb) * dx, jc * dx));
                    ssv += wt(b);
                }
                vf[q] = (sv / s) as f32;
                aw[q] = (sw / s) as f32;
                au[q] = (su / ssu) as f32;
                av[q] = (svv / ssv) as f32;
                if cell[q] != 0.0 {
                    vf[q] = vf[q].max(vf_floor);
                }
            }
        }
    }
    c.arrays.insert("vf".into(), vf);
    c.arrays.insert("af_u".into(), au);
    c.arrays.insert("af_v".into(), av);
    c.arrays.insert("af_w".into(), aw);
    c.params.cut_cells = true;
}

#[test]
fn unit_fractions_cut_adv2_repeats_adv2() {
    for name in ["flat_wind", "agnesi"] {
        for lim in [Limiter::VanLeer, Limiter::MinMod] {
            let mut c = load(name);
            c.params.adv2 = true;
            c.params.limiter = lim as i64;
            let plain = api::solve(&c, &opts()).unwrap();
            let mut cc = load(name);
            cc.params.adv2 = true;
            cc.params.limiter = lim as i64;
            unit_fractions(&mut cc);
            let cut = api::solve(&cc, &opts()).unwrap();
            assert_eq!(plain.stop, StopReason::Converged, "{name} {lim:?}");
            assert_eq!(cut.stop, StopReason::Converged, "{name} {lim:?}");
            assert_eq!(plain.iters, cut.iters, "{name} {lim:?}: iterations");
            for (f, x, y) in [
                ("u", &plain.state.u, &cut.state.u),
                ("v", &plain.state.v, &cut.state.v),
                ("w", &plain.state.w, &cut.state.w),
                ("p", &plain.state.p, &cut.state.p),
            ] {
                let r = rel(x, y);
                eprintln!("{name} {lim:?}: {f} rel {r:.2e}");
                assert!(r <= 1e-6, "{name} {lim:?}: {f} rel {r:e}");
            }
        }
    }
}

#[test]
fn mass_is_exact_with_cut_cells_and_adv2() {
    for lim in [Limiter::VanLeer, Limiter::MinMod] {
        let mut cc = load("agnesi");
        terrain_fractions(&mut cc, 9, 0.1);
        cc.params.adv2 = true;
        cc.params.limiter = lim as i64;
        let r = api::solve(&cc, &opts()).unwrap();
        let d = div_rms_f64(&r.picard, &r.state.u, &r.state.v, &r.state.w);
        eprintln!(
            "agnesi cut+adv2 {lim:?}: {:?} iters {} div_rms {d:.3e} tol {:.1e}",
            r.stop, r.iters, cc.criterion.tol_div_rms
        );
        assert_eq!(r.stop, StopReason::Converged);
        assert!(d <= cc.criterion.tol_div_rms);
        assert!(r.residuals.div_rms <= cc.criterion.tol_div_rms);
    }
}

/// Correction kernels with the face weights: scaling the open fractions of the faces scales the
/// correction of a step profile in the same way as the first-order flux.
#[test]
fn correction_follows_the_face_weights() {
    let mut c = load("flat_wind");
    unit_fractions(&mut c);
    c.params.adv2 = true;
    c.params.limiter = Limiter::VanLeer as i64;
    let k1 = Consts::from_case(&c).unwrap();
    let n3 = k1.n3();
    let (nxh, nyh) = (k1.nxh, k1.nyh);
    let (j0, k0) = (nyh / 2, k1.nzh / 2);
    let at = |i: usize| (k0 * nyh + j0) * nxh + i;
    let (u, zero) = (vec![1.0f32; n3], vec![0.0f32; n3]);
    let vel = Vel {
        u: &u,
        v: &zero,
        w: &zero,
    };
    // a smooth bump: non-zero correction
    let th: Vec<f32> = (0..n3)
        .map(|q| {
            let x = (q % nxh) as f32 - nxh as f32 / 2.0;
            (-x * x / 8.0).exp()
        })
        .collect();
    let mut c1 = vec![0.0f32; n3];
    adv2::adv2_heat(&k1, Limiter::VanLeer, &vel, &th, &mut c1);
    let mut cm = vec![0.0f32; n3];
    adv2::adv2_mom(
        &k1,
        Limiter::VanLeer,
        &Vel {
            u: &th,
            v: &zero,
            w: &zero,
        },
        0,
        &mut cm,
    );
    let i0 = nxh / 2 + 1;
    assert!(c1[at(i0)].abs() > 1e-4 && cm[at(i0)].abs() > 1e-4);
    // halve the open fraction of every u face (and the cell volume stays): heat correction of
    // this cell uses af_u / vf = 0.5 on both its u faces; closing all u faces removes it.
    for (frac, scale) in [(0.5f32, 0.5f32), (0.0, 0.0)] {
        let mut cf = load("flat_wind");
        unit_fractions(&mut cf);
        cf.params.adv2 = true;
        cf.params.limiter = Limiter::VanLeer as i64;
        for x in cf.arrays.get_mut("af_u").unwrap().iter_mut() {
            if *x == 1.0 {
                *x = frac;
            }
        }
        let k = Consts::from_case(&cf).unwrap();
        let mut ch = vec![0.0f32; n3];
        adv2::adv2_heat(&k, Limiter::VanLeer, &vel, &th, &mut ch);
        let r = f64::from(ch[at(i0)]) / f64::from(c1[at(i0)]);
        assert!(
            (r - f64::from(scale)).abs() < 1e-5,
            "heat frac {frac}: ratio {r}"
        );
        let mut cmw = vec![0.0f32; n3];
        adv2::adv2_mom(
            &k,
            Limiter::VanLeer,
            &Vel {
                u: &th,
                v: &zero,
                w: &zero,
            },
            0,
            &mut cmw,
        );
        // the u control volume of face i0 has its u-direction sides at the cell centres:
        // weight = mean of the two adjacent u faces / mean cell volume = frac
        let r = f64::from(cmw[at(i0)]) / f64::from(cm[at(i0)]);
        assert!(
            (r - f64::from(scale)).abs() < 1e-5,
            "mom frac {frac}: ratio {r}"
        );
    }
}
