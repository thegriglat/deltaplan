//! PT-9: `Cut::rebalance` of a window case (`Case.nest = Some`) balances the sides against the
//! top flux `nest.ubw`: after it the total flux through the open boundary is zero. Without a
//! window the sides balance among themselves, as before.
//! Synthetic case: repository fixture `flat_wind` with unit fractions and a constant `ubw` on
//! the top faces (added in memory).

use picard_rs::case::{Case, NestBc};
use picard_rs::cut::Cut;
use std::path::PathBuf;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

/// Fractions 1 on air cells and their faces, 0 in the ground; the open boundary faces get a
/// share 0.7 (a cut boundary), so that the balance by open areas differs from the plain one.
fn fractions(c: &mut Case) {
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
    for q in 0..n3 {
        if q % 3 == 0 {
            af[0][q] *= 0.7;
        }
        if q % 5 == 0 {
            af[1][q] *= 0.6;
        }
        if q % 4 == 0 {
            af[2][q] *= 0.8;
        }
    }
    c.arrays.insert("vf".into(), vf);
    let [au, av, aw] = af;
    c.arrays.insert("af_u".into(), au);
    c.arrays.insert("af_v".into(), av);
    c.arrays.insert("af_w".into(), aw);
    c.params.cut_cells = true;
}

/// Total outward flux and open boundary area (units `dx*dz`) of sides and top.
fn total(c: &Case, af: &[Vec<f32>; 3], fu: &[f32], fv: &[f32], ubw: &[f32]) -> (f64, f64) {
    let (nxh, nyh) = (c.nxh, c.nyh);
    let cell = c.bytes("cell").unwrap();
    let tw = c.bytes("tw").unwrap();
    let b_u: Vec<usize> = c.arr("b_u").unwrap().iter().map(|&x| x as usize).collect();
    let b_v: Vec<usize> = c.arr("b_v").unwrap().iter().map(|&x| x as usize).collect();
    let (mut net, mut area) = (0.0f64, 0.0f64);
    for (n, &q) in b_u.iter().enumerate() {
        let s = if q % nxh == 1 { -1.0 } else { 1.0 };
        net += s * f64::from(fu[n]) * f64::from(af[0][q]);
        area += f64::from(af[0][q]);
    }
    for (n, &q) in b_v.iter().enumerate() {
        let s = if (q / nxh) % nyh == 1 { -1.0 } else { 1.0 };
        net += s * f64::from(fv[n]) * f64::from(af[1][q]);
        area += f64::from(af[1][q]);
    }
    let r = f64::from(c.dx) / f64::from(c.dz);
    for q in 0..tw.len() {
        if tw[q] == 2 {
            let s = if cell[q] == 1 { -1.0 } else { 1.0 };
            net += s * f64::from(ubw[q]) * f64::from(af[2][q]) * r;
            area += f64::from(af[2][q]) * r;
        }
    }
    (net, area)
}

fn rebalance(c: &Case) -> (Vec<f32>, Vec<f32>, [Vec<f32>; 3]) {
    let cell = c.bytes("cell").unwrap();
    let tt = [
        c.bytes("tu").unwrap(),
        c.bytes("tv").unwrap(),
        c.bytes("tw").unwrap(),
    ];
    let k = [
        c.arr("Kx").unwrap().clone(),
        c.arr("Ky").unwrap().clone(),
        c.arr("Kz").unwrap().clone(),
    ];
    let ct = Cut::from_case(c, &cell, [&tt[0], &tt[1], &tt[2]], [&k[0], &k[1], &k[2]]).unwrap();
    let b_u: Vec<usize> = c.arr("b_u").unwrap().iter().map(|&x| x as usize).collect();
    let b_v: Vec<usize> = c.arr("b_v").unwrap().iter().map(|&x| x as usize).collect();
    let mut fu = c.arr("fixed_u").unwrap().clone();
    let mut fv = c.arr("fixed_v").unwrap().clone();
    ct.rebalance((c.nxh, c.nyh), &b_u, &mut fu, &b_v, &mut fv);
    (fu, fv, ct.af.clone())
}

#[test]
fn window_sides_balance_against_the_top_flux() {
    let mut c = load("flat_wind");
    fractions(&mut c);
    let n3 = c.n3();
    let tw = c.bytes("tw").unwrap();
    assert!(tw.iter().any(|&t| t == 2), "fixture has top boundary faces");
    // a top flux of a nonzero net: ubw = 0.3 on the top faces
    let ubw: Vec<f32> = (0..n3).map(|q| if tw[q] == 2 { 0.3 } else { 0.0 }).collect();
    c.nest = Some(NestBc {
        ubw: ubw.clone(),
        thb: vec![0.0; n3],
        thbd: None,
    });
    let (fu, fv, af) = rebalance(&c);
    let (net, area) = total(&c, &af, &fu, &fv, &ubw);
    assert!(area > 0.0);
    assert!(
        net.abs() / area <= 1e-6,
        "window: |net|/|area| = {:.3e}",
        net.abs() / area
    );
    // without the window the sides alone are balanced (the top flux is not counted)
    c.nest = None;
    let (fu0, fv0, af0) = rebalance(&c);
    let (net0, _) = total(&c, &af0, &fu0, &fv0, &vec![0.0; n3]);
    assert!(net0.abs() / area <= 1e-6, "domain: net {net0:.3e}");
    assert_ne!(fu, fu0, "the window changes the balance");
}
