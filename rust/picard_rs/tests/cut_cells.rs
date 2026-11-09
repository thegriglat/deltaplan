//! PT2 (picard-terrain): cut cells (FAVOR) behind `params.cut_cells`.
//!
//! Synthetic cases from the repository fixtures `flat_wind`, `agnesi` (the files are not
//! changed: the fractions are added in memory).
//! 1. All fractions 1 on every air cell: the iteration repeats the plain one (iterations equal,
//!    fields within 1e-6 relative).
//! 2. A flat floor 0.4 dz above a layer face (not on a face): no spurious vertical wind and a
//!    field uniform in x, y, as with a floor on a face.
//! 3. Mass: the PT2 divergence of the delivered field is below the criterion `tol_div_rms`.
//! 4. A case with `cut_cells` and without the fractions is an error, not a default.

use picard_rs::api::{self, SolveOpts, Solved, StopReason};
use picard_rs::case::Case;
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

/// Mean and spread (max - min) of `a` over the interior columns of level `k`, `ring` cells
/// away from the lateral boundary.
fn level_stats(c: &Case, a: &[f32], k: usize, ring: usize) -> (f64, f64) {
    let (nx, ny) = (c.nxh, c.nyh);
    let (mut lo, mut hi, mut s, mut n) = (f64::MAX, f64::MIN, 0.0, 0usize);
    for j in 1 + ring..ny - 1 - ring {
        for i in 1 + ring..nx - 1 - ring {
            let x = f64::from(a[(k * ny + j) * nx + i]);
            lo = lo.min(x);
            hi = hi.max(x);
            s += x;
            n += 1;
        }
    }
    (s / n as f64, hi - lo)
}

fn max_abs_w(c: &Case, r: &Solved) -> f64 {
    let (nx, ny) = (c.nxh, c.nyh);
    let mut m = 0.0f64;
    for k in 1..c.nzh - 1 {
        for j in 1..ny - 1 {
            for i in 1..nx - 1 {
                m = m.max(f64::from(r.state.w[(k * ny + j) * nx + i]).abs());
            }
        }
    }
    m
}

/// Makes `c` horizontally uniform: the sponges of the centre column everywhere (no side
/// sponges), then the background, the sponge target and the boundary values of `u`, `v` from
/// the centre column of the solution, repeated until the profile is the column's own (the
/// equilibrium of the top sponge and the wall friction). Returns the last solve.
fn equilibrium(c: &mut Case, rounds: usize) -> Solved {
    let (nx, ny, nz) = (c.nxh, c.nyh, c.nzh);
    let ctr = (ny / 2) * nx + nx / 2;
    for a in ["sp_u", "sp_w", "spc"] {
        let v = c.arrays.get_mut(a).unwrap();
        for k in 0..nz {
            let x = v[k * nx * ny + ctr];
            v[k * nx * ny..(k + 1) * nx * ny].fill(x);
        }
    }
    let col = |a: &[f32]| (0..nz).map(|k| a[k * nx * ny + ctr]).collect::<Vec<f32>>();
    let (mut pu, mut pv) = (col(&c.arrays["ubg"]), col(&c.arrays["vbg"]));
    let mut last = None;
    for _ in 0..rounds {
        for (bg, t, p) in [("ubg", "tu", &pu), ("vbg", "tv", &pv)] {
            let tt = c.arrays[t].clone();
            let v = c.arrays.get_mut(bg).unwrap();
            for (q, x) in v.iter_mut().enumerate() {
                *x = if tt[q] == 0.0 { 0.0 } else { p[q / (nx * ny)] };
            }
        }
        for (fx, b, p) in [("fixed_u", "b_u", &pu), ("fixed_v", "b_v", &pv)] {
            let bi = c.arrays[b].clone();
            let v = c.arrays.get_mut(fx).unwrap();
            for (n, x) in v.iter_mut().enumerate() {
                *x = p[bi[n] as usize / (nx * ny)];
            }
        }
        let r = api::solve(
            c,
            &SolveOpts {
                tol_scale: 0.01,
                ..opts()
            },
        )
        .unwrap();
        assert_eq!(r.stop, StopReason::Converged);
        pu = col(&r.state.u);
        pv = col(&r.state.v);
        last = Some(r);
    }
    last.unwrap()
}

/// A flat floor 0.4 dz above the face under the first air layer: the cut-cell field stays uniform
/// in x, y and without vertical wind, as the plain one with the floor on the face. The case is
/// made uniform by [`equilibrium`] (the fixture itself is not: side sponges and the inflow profile
/// make max|w| 0.17 m/s).
#[test]
fn flat_floor_inside_a_layer() {
    let u_ref = f64::from(load("flat_wind").case_params.u10 as f32);
    let mut plain_c = load("flat_wind");
    let plain = equilibrium(&mut plain_c, 16);
    let mut cc = load("flat_wind");
    unit_fractions(&mut cc);
    // flat_wind: ground cells k <= 1 (top at z = 0, the face under k = 2). Raise the floor by
    // 0.4 dz inside k = 2: vf = 0.6, side faces 0.6, the bottom face closed (0).
    let (nx, ny) = (cc.nxh, cc.nyh);
    let k2 = 2 * nx * ny;
    for q in k2..k2 + nx * ny {
        cc.arrays.get_mut("vf").unwrap()[q] = 0.6;
        cc.arrays.get_mut("af_u").unwrap()[q] = 0.6;
        cc.arrays.get_mut("af_v").unwrap()[q] = 0.6;
        cc.arrays.get_mut("af_w").unwrap()[q] = 0.0;
    }
    let cut = equilibrium(&mut cc, 16);
    for (nm, r, cs) in [("plain", &plain, &plain_c), ("cut", &cut, &cc)] {
        let mw = max_abs_w(cs, r);
        eprintln!("{nm}: iters {} max|w| {mw:.3e} (U10 {u_ref})", r.iters);
        assert!(mw <= 1e-3 * u_ref, "{nm}: max|w| {mw:e}");
        for k in 2..cs.nzh - 1 {
            for (f, a) in [("u", &r.state.u), ("v", &r.state.v)] {
                let (m, sp) = level_stats(cs, a, k, 0);
                if k < 6 {
                    eprintln!("  k {k}: {f} mean {m:.4} spread {sp:.3e}");
                }
                assert!(sp <= 1e-3 * u_ref, "{nm}: {f} spread {sp:e} at k {k}");
            }
        }
    }
    // The raised floor slows the first layer (its open centre is 0.3 dz above the wall, not 0.5).
    let (m_plain, _) = level_stats(&plain_c, &plain.state.u, 2, 0);
    let (m_cut, _) = level_stats(&cc, &cut.state.u, 2, 0);
    eprintln!("first layer u: plain {m_plain:.4}, cut {m_cut:.4}");
    assert!(m_cut < m_plain);
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

/// Mass: the PT2 divergence (open-area weighted, per full cell volume) of the delivered field is
/// below the criterion, with unit fractions and with a smooth sub-grid ridge (agnesi).
#[test]
fn mass_is_exact_with_cut_cells() {
    for smooth in [false, true] {
        let mut cc = load("agnesi");
        if smooth {
            terrain_fractions(&mut cc, 9, 0.1);
        } else {
            unit_fractions(&mut cc);
        }
        let r = api::solve(&cc, &opts()).unwrap();
        let d = div_rms_f64(&r.picard, &r.state.u, &r.state.v, &r.state.w);
        let n = &r.picard.k.cut.as_ref().unwrap().n_drag;
        eprintln!(
            "agnesi cut (smooth {smooth}): {:?} iters {} div_rms {d:.3e} tol {:.1e} drag faces {n:?}",
            r.stop, r.iters, cc.criterion.tol_div_rms
        );
        assert_eq!(r.stop, StopReason::Converged);
        assert!(d <= cc.criterion.tol_div_rms);
        assert!(r.residuals.div_rms <= cc.criterion.tol_div_rms);
    }
}

#[test]
fn cut_cells_without_fractions_is_an_error() {
    let mut c = load("flat_wind");
    c.params.cut_cells = true;
    let e = api::solve(&c, &opts()).err().expect("no fractions");
    assert!(e.to_string().contains("vf"), "{e}");
}
