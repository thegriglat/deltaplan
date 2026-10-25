//! Block-by-block check of one iteration against the R1 reference blocks, the same way as
//! `tests/atmosphere/test_air_picard_gpu.gd` (`test_blocks_vs_reference`): the input of
//! each block comes from the case file, the error is `max|a - b| / max|b|`.

use crate::case::{Case, Consts};
use crate::kernels::{Vel, apply_bc, kloc};
use crate::lines::sweep;
use crate::solver::Picard;
use crate::util::Row;
use anyhow::Result;

/// One table row: block name, relative error, and whether it counts for the maximum.
pub struct BlockRow {
    pub name: String,
    pub rel: f64,
    pub checked: bool,
}

/// Relative error `max|a - b| / max|b|` (denominator at least 1e-30).
pub fn rel_err(a: &[f32], b: &[f32]) -> f64 {
    if a.len() != b.len() {
        return f64::INFINITY;
    }
    let mut e = 0.0f64;
    let mut m = 0.0f64;
    for (x, y) in a.iter().zip(b) {
        e = e.max((f64::from(*x) - f64::from(*y)).abs());
        m = m.max(f64::from(*y).abs());
    }
    e / m.max(1e-30)
}

/// Subtracts the mean over active cells and zeroes inactive ones.
pub fn centered(a: &[f32], act: &[f32]) -> Vec<f32> {
    let mut s = 0.0f64;
    let mut c = 0.0f64;
    for (x, m) in a.iter().zip(act) {
        s += f64::from(*x) * f64::from(*m);
        c += f64::from(*m);
    }
    let mm = s / c.max(1.0);
    a.iter()
        .zip(act)
        .map(|(x, m)| ((f64::from(*x) - mm) * f64::from(*m)) as f32)
        .collect()
}

fn planes(rows: &[Row]) -> (Vec<f32>, Vec<f32>) {
    let n = rows.len();
    let mut c = vec![0.0f32; 7 * n];
    let mut b = vec![0.0f32; n];
    for (i, r) in rows.iter().enumerate() {
        for o in 0..7 {
            c[o * n + i] = r[o];
        }
        b[i] = r[7];
    }
    (c, b)
}

fn rows_from(c: &[f32], b: &[f32]) -> Vec<Row> {
    let n = b.len();
    (0..n)
        .map(|i| {
            let mut r = [0.0f32; 8];
            for o in 0..7 {
                r[o] = c[o * n + i];
            }
            r[7] = b[i];
            r
        })
        .collect()
}

/// Interior `(nz, ny, nx)` copy of a halo array.
fn interior(k: &Consts, a: &[f32]) -> Vec<f32> {
    let mut out = Vec::with_capacity(k.nx * k.ny * k.nz);
    for kk in 0..k.nz {
        for j in 0..k.ny {
            for i in 0..k.nx {
                out.push(a[((kk + 1) * k.nyh + j + 1) * k.nxh + i + 1]);
            }
        }
    }
    out
}

/// Runs all blocks of one case; call inside the thread pool.
pub fn check_case(c: &Case) -> Result<Vec<BlockRow>> {
    let mut rows = Vec::new();
    let mut add = |name: &str, rel: f64, checked: bool| {
        rows.push(BlockRow {
            name: name.to_string(),
            rel,
            checked,
        });
    };
    let a = |n: &str| -> Result<Vec<f32>> { Ok(c.arr(n)?.clone()) };
    let mut s = Picard::new(Consts::from_case(c)?);
    let shape = (s.k.nzh, s.k.nyh, s.k.nxh);

    // 1. boundary conditions
    s.f.u = a("in_u")?;
    s.f.v = a("in_v")?;
    apply_bc(&s.k, &mut s.f.u, &mut s.f.v);
    add(
        "boundary conditions u",
        rel_err(&s.f.u, c.arr("bc_u")?),
        true,
    );
    add(
        "boundary conditions v",
        rel_err(&s.f.v, c.arr("bc_v")?),
        true,
    );

    // 2. local K
    s.f.u = a("bc_u")?;
    s.f.v = a("bc_v")?;
    s.f.w = a("in_w")?;
    s.f.th = a("in_th")?;
    s.f.nu = a("nu_in")?;
    s.f.nuh = a("nuh_in")?;
    {
        let f = &mut s.f;
        let vel = Vel {
            u: &f.u,
            v: &f.v,
            w: &f.w,
        };
        kloc(&s.k, &vel, &f.th, &mut f.nu, &mut f.nuh);
    }
    add(
        "local K (kloc) K",
        rel_err(&s.f.nu, c.arr("kloc_nu")?),
        true,
    );
    add(
        "local K (kloc) K_h",
        rel_err(&s.f.nuh, c.arr("kloc_nuh")?),
        true,
    );

    // 3. momentum stencils
    s.f.p = a("in_p")?;
    s.f.nu = a("kloc_nu")?;
    s.f.nuh = a("kloc_nuh")?;
    s.build_all_mom();
    for (comp, nm) in ["u", "v", "w"].iter().enumerate() {
        let rows_c = [&s.cu, &s.cv, &s.cw][comp];
        let (cm, bm) = planes(rows_c);
        add(
            &format!("momentum stencil C_{nm}"),
            rel_err(&cm, c.arr(&format!("Cm_{nm}"))?),
            true,
        );
        add(
            &format!("momentum stencil b_{nm}"),
            rel_err(&bm, c.arr(&format!("bm_{nm}"))?),
            true,
        );
    }

    // 4. momentum sweeps
    let mut u1 = a("bc_u")?;
    let ru = rows_from(c.arr("Cm_u")?, c.arr("bm_u")?);
    sweep(&ru, &mut u1, &mut s.sc, shape, &[2, 0, 1]);
    add(
        "sweep u (z, x, y) x1",
        rel_err(&u1, c.arr("sweep1_u")?),
        true,
    );
    let rv = rows_from(c.arr("Cm_v")?, c.arr("bm_v")?);
    let rw = rows_from(c.arr("Cm_w")?, c.arr("bm_w")?);
    s.cu = ru.into();
    s.cv = rv.into();
    s.cw = rw.into();
    s.f.u = a("bc_u")?;
    s.f.v = a("bc_v")?;
    s.f.w = a("in_w")?;
    s.mom_step();
    add("momentum step u", rel_err(&s.f.u, c.arr("mom_u")?), true);
    add("momentum step v", rel_err(&s.f.v, c.arr("mom_v")?), true);
    add("momentum step w", rel_err(&s.f.w, c.arr("mom_w")?), true);

    // 5. projection
    let ni = s.k.nx * s.k.ny * s.k.nz;
    let mut div = vec![0.0f32; ni];
    Picard::divergence(
        &s.k,
        c.arr("mom_u")?,
        c.arr("mom_v")?,
        c.arr("mom_w")?,
        &mut div,
    );
    add(
        "div u* vs reference (info: input rounding floor)",
        rel_err(&div, c.arr("div_star")?),
        false,
    );
    let div64 = div_f64(&s.k, c.arr("mom_u")?, c.arr("mom_v")?, c.arr("mom_w")?);
    let d32: Vec<f32> = div.clone();
    add(
        "div u* (f64 from the same inputs)",
        rel_err(&d32, &div64),
        true,
    );
    let act = interior(&s.k, &s.k.fluid);
    let nf = s.k.n_fluid as f32;
    let ds = c.arr("div_star")?;
    let mean = ds.iter().map(|&x| f64::from(x)).sum::<f64>() as f32 / nf;
    let rhs: Vec<f32> = ds.iter().zip(&act).map(|(&d, &f)| d - mean * f).collect();
    add("rhs (minus mean)", rel_err(&rhs, c.arr("proj_rhs")?), true);
    s.mg.set_rhs(c.arr("proj_rhs")?);
    s.mg.phi_mut().fill(0.0);
    s.mg.vcycle();
    let phi = s.mg.phi().to_vec();
    let raw = c.arr("vcycle_phi_raw")?;
    add(
        "V-cycle x1 (phi minus mean)",
        rel_err(&centered(&phi, &act), &centered(raw, &act)),
        true,
    );
    add("V-cycle x1 raw (info)", rel_err(&phi, raw), false);
    let phic = centered(raw, &act);
    let pref = interior(&s.k, c.arr("proj_phi")?);
    add("phi minus mean", rel_err(&phic, &pref), true);
    s.f.u = a("mom_u")?;
    s.f.v = a("mom_v")?;
    s.f.w = a("mom_w")?;
    s.f.p = a("in_p")?;
    s.pfull = vec![0.0; s.k.n3()];
    for (q, &x) in pref.iter().enumerate() {
        let (nx, ny) = (s.k.nx, s.k.ny);
        let g = (((q / (nx * ny)) + 1) * s.k.nyh + (q / nx) % ny + 1) * s.k.nxh + q % nx + 1;
        s.pfull[g] = x;
    }
    Picard::apply_phi(&s.k, &s.pfull, &mut s.f, true);
    add("projection u", rel_err(&s.f.u, c.arr("proj_u")?), true);
    add("projection v", rel_err(&s.f.v, c.arr("proj_v")?), true);
    add("projection w", rel_err(&s.f.w, c.arr("proj_w")?), true);
    add("projection p", rel_err(&s.f.p, c.arr("proj_p")?), true);

    // 6. heat
    s.f.u = a("proj_u")?;
    s.f.v = a("proj_v")?;
    s.f.w = a("proj_w")?;
    s.f.th = a("in_th")?;
    s.f.thd = a("in_thd")?;
    s.f.nu = a("kloc_nu")?;
    s.f.nuh = a("kloc_nuh")?;
    s.build_heat_d();
    let (cd, bd) = planes(&s.ctd);
    add("heat stencil theta_d C", rel_err(&cd, c.arr("Ch_d")?), true);
    add("heat stencil theta_d b", rel_err(&bd, c.arr("bh_d")?), true);
    s.ctd = rows_from(c.arr("Ch_d")?, c.arr("bh_d")?).into();
    for _ in 0..s.k.heat_sweeps {
        sweep(&s.ctd, &mut s.f.thd, &mut s.sc, shape, &[2, 0, 1]);
    }
    add(
        "heat step theta_d",
        rel_err(&s.f.thd, c.arr("heat_thd")?),
        true,
    );
    s.f.th = a("in_th")?;
    s.f.thd = a("heat_thd")?;
    s.build_heat_t();
    let (ch, bh) = planes(&s.ct);
    add("heat stencil theta C", rel_err(&ch, c.arr("Ch")?), true);
    add("heat stencil theta b", rel_err(&bh, c.arr("bh")?), true);
    s.ct = rows_from(c.arr("Ch")?, c.arr("bh")?).into();
    for _ in 0..s.k.heat_sweeps {
        sweep(&s.ct, &mut s.f.th, &mut s.sc, shape, &[2, 0, 1]);
    }
    add("heat step theta", rel_err(&s.f.th, c.arr("heat_th")?), true);
    Ok(rows)
}

/// Divergence in `f64` from the (f32) face velocities, interior layout.
pub fn div_f64(k: &Consts, u: &[f32], v: &[f32], w: &[f32]) -> Vec<f32> {
    let mut out = vec![0.0f32; k.nx * k.ny * k.nz];
    for (q, o) in out.iter_mut().enumerate() {
        let i = q % k.nx;
        let j = (q / k.nx) % k.ny;
        let kk = q / (k.nx * k.ny);
        let g = ((kk + 1) * k.nyh + j + 1) * k.nxh + i + 1;
        if k.cell[g] != 1 {
            continue;
        }
        let d = (f64::from(u[g + 1]) - f64::from(u[g])) / f64::from(k.dx)
            + (f64::from(v[g + k.nxh]) - f64::from(v[g])) / f64::from(k.dx)
            + (f64::from(w[g + k.nxh * k.nyh]) - f64::from(w[g])) / f64::from(k.dz);
        *o = d as f32;
    }
    out
}
