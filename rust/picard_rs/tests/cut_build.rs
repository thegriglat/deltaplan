//! PT6 v1: `cut_build` on synthetic rasters (analytic shares, halo, type height, finish).

use picard_rs::cut_build::{
    AF_FLOOR, CutGrid, Fractions, Raster, SAMPLES, finish, fractions, type_height,
};

fn grid(nx: usize, ny: usize, nz: usize) -> CutGrid {
    CutGrid {
        nx,
        ny,
        nz,
        x0: 100.0,
        y0: 200.0,
        dx: 30.0,
        dz: 20.0,
        z_bot: -20.0,
    }
}

/// Raster covering the grid with margin: nodes every 30 m, `f(x, y)` heights.
fn raster_data(g: &CutGrid, f: impl Fn(f64, f64) -> f64) -> (Vec<f32>, usize, usize) {
    let (rx, ry) = (g.nx + 3, g.ny + 3);
    let mut h = vec![0f32; rx * ry];
    for j in 0..ry {
        for i in 0..rx {
            h[j * rx + i] = f(
                g.x0 + (i as f64 - 1.0) * 30.0,
                g.y0 + (j as f64 - 1.0) * 30.0,
            ) as f32;
        }
    }
    (h, rx, ry)
}

fn ras<'a>(h: &'a [f32], rx: usize, ry: usize, g: &CutGrid) -> Raster<'a> {
    Raster {
        h,
        nx: rx,
        ny: ry,
        x0: g.x0 - 30.0,
        y0: g.y0 - 30.0,
        dx: 30.0,
    }
}

fn at(g: &CutGrid, i: usize, j: usize, k: usize) -> usize {
    let (nxh, nyh, _) = g.dims();
    (k * nyh + j) * nxh + i
}

#[test]
fn flat_terrain_in_half_a_cell() {
    // z_bot = -20, dz = 20: layer k spans [-20 + 20(k-1), -20 + 20k]; terrain at 10 m = middle of k = 2
    let g = grid(4, 3, 5);
    let (h, rx, ry) = raster_data(&g, |_, _| 10.0);
    let f = fractions(&ras(&h, rx, ry, &g), &g, SAMPLES);
    let (nxh, nyh, nzh) = g.dims();
    for k in 0..nzh {
        for j in 0..nyh {
            for i in 0..nxh {
                let q = at(&g, i, j, k);
                let (vf, w) = match k {
                    0 | 1 => (0.0, 0.0), // layers below 0 m: [-20, 0] (k = 1) and k = 0
                    2 => (0.5, 0.0),
                    _ => (1.0, 1.0),
                };
                assert!((f64::from(f.vf[q]) - vf).abs() < 1e-7, "vf k={k}");
                // bottom of k = 2 is z = 0 < 10: terrain above it (h <= zlo false), bottom of k = 3 is 20 > 10
                assert_eq!(f64::from(f.af_w[q]), w, "af_w k={k} {i} {j}");
            }
        }
    }
    // side faces: open share of the face height
    for k in 0..nzh {
        let want = [0.0, 0.0, 0.5, 1.0, 1.0, 1.0, 1.0][k];
        for j in 1..=g.ny {
            for i in 1..=g.nx + 1 {
                assert!((f64::from(f.af_u[at(&g, i, j, k)]) - want).abs() < 1e-7);
            }
        }
        for j in 1..=g.ny + 1 {
            for i in 1..=g.nx {
                assert!((f64::from(f.af_v[at(&g, i, j, k)]) - want).abs() < 1e-7);
            }
        }
    }
}

#[test]
fn flat_terrain_on_a_layer_face_uses_the_h_le_z_rule() {
    // terrain exactly at the bottom of k = 2 (z = 0): the bottom face is open (h <= z), vf(k = 1) = 0, vf(k = 2) = 1
    let g = grid(3, 3, 4);
    let (h, rx, ry) = raster_data(&g, |_, _| 0.0);
    let f = fractions(&ras(&h, rx, ry, &g), &g, SAMPLES);
    let q = at(&g, 2, 2, 2);
    assert_eq!(f.vf[q], 1.0);
    assert_eq!(f.af_w[q], 1.0);
    assert_eq!(f.vf[at(&g, 2, 2, 1)], 0.0);
    assert_eq!(f.af_w[at(&g, 2, 2, 1)], 0.0);
}

/// Mean over the cell of clip((zhi - h)/dz, 0, 1) with trapezoid weights on the same lattice, f64.
fn brute_vf(
    h: impl Fn(f64, f64) -> f64,
    x: f64,
    y: f64,
    dx: f64,
    zhi: f64,
    dz: f64,
    n: usize,
) -> f64 {
    let m = (n - 1) as f64;
    let w = |a: usize| {
        if a == 0 || a == n - 1 {
            0.5 / m
        } else {
            1.0 / m
        }
    };
    let mut s = 0.0;
    for b in 0..n {
        for a in 0..n {
            s += w(a)
                * w(b)
                * ((zhi - h(x + a as f64 * dx / m, y + b as f64 * dx / m)) / dz).clamp(0.0, 1.0);
        }
    }
    s
}

#[test]
fn sloped_plane_matches_analytic_trapezoids() {
    // h = 3 + 0.2 (x - x0) + 0.1 (y - y0): bilinear exact; inside a cell the open share is linear while 0 < s < 1
    let g = grid(5, 4, 8);
    let hf = |x: f64, y: f64| 3.0 + 0.2 * (x - 100.0) + 0.1 * (y - 200.0);
    let (h, rx, ry) = raster_data(&g, hf);
    let f = fractions(&ras(&h, rx, ry, &g), &g, SAMPLES);
    let mut checked_cut = 0;
    for k in 1..=g.nz {
        let zhi = g.z_bot + k as f64 * g.dz;
        for j in 1..=g.ny {
            for i in 1..=g.nx {
                let (x, y) = (
                    g.x0 + (i as f64 - 1.0) * g.dx,
                    g.y0 + (j as f64 - 1.0) * g.dx,
                );
                // cell lying inside the linear branch: the open share at the centre is the mean exactly
                let hc = hf(x + 15.0, y + 15.0);
                let s = (zhi - hc) / g.dz;
                let want = brute_vf(hf, x, y, g.dx, zhi, g.dz, SAMPLES);
                assert!((f64::from(f.vf[at(&g, i, j, k)]) - want).abs() < 1e-6);
                if (0.0..=1.0).contains(&s)
                    && (0.0..=1.0).contains(&((zhi - hf(x, y)) / g.dz))
                    && (0.0..=1.0).contains(&((zhi - hf(x + 30.0, y + 30.0)) / g.dz))
                {
                    // linear branch: closed form
                    assert!((want - s).abs() < 1e-12, "analytic {want} {s}");
                    checked_cut += 1;
                }
            }
        }
    }
    assert!(checked_cut > 0);
}

#[test]
fn halo_copies_the_neighbour_along_the_normal() {
    let g = grid(4, 3, 6);
    let hf = |x: f64, y: f64| 25.0 + 0.3 * (x - 100.0) + 7.0 * ((y - 200.0) / 20.0).sin();
    let (h, rx, ry) = raster_data(&g, hf);
    let f = fractions(&ras(&h, rx, ry, &g), &g, SAMPLES);
    let (nxh, nyh, nzh) = g.dims();
    for k in 0..nzh {
        for i in 0..nxh {
            assert_eq!(f.vf[at(&g, i, 0, k)], f.vf[at(&g, i, 1, k)]);
            assert_eq!(f.vf[at(&g, i, nyh - 1, k)], f.vf[at(&g, i, nyh - 2, k)]);
            assert_eq!(f.af_w[at(&g, i, 0, k)], f.af_w[at(&g, i, 1, k)]);
            assert_eq!(f.af_u[at(&g, i, 0, k)], f.af_u[at(&g, i, 1, k)]);
            assert_eq!(f.af_u[at(&g, i, nyh - 1, k)], f.af_u[at(&g, i, nyh - 2, k)]);
        }
        for j in 0..nyh {
            assert_eq!(f.vf[at(&g, 0, j, k)], f.vf[at(&g, 1, j, k)]);
            assert_eq!(f.vf[at(&g, nxh - 1, j, k)], f.vf[at(&g, nxh - 2, j, k)]);
            assert_eq!(f.af_u[at(&g, 0, j, k)], f.af_u[at(&g, 1, j, k)]);
            assert_eq!(f.af_v[at(&g, 0, j, k)], f.af_v[at(&g, 1, j, k)]);
            assert_eq!(f.af_v[at(&g, nxh - 1, j, k)], f.af_v[at(&g, nxh - 2, j, k)]);
        }
    }
    // interior equals the brute-force lattice sum over the bilinear surface (shortcut layers included)
    let r = ras(&h, rx, ry, &g);
    for k in 0..nzh {
        let zhi = g.z_bot + k as f64 * g.dz;
        for j in 1..=g.ny {
            for i in 1..=g.nx {
                let (x, y) = (
                    g.x0 + (i as f64 - 1.0) * g.dx,
                    g.y0 + (j as f64 - 1.0) * g.dx,
                );
                let want = brute_vf(|a, b| r.sample(a, b), x, y, g.dx, zhi, g.dz, SAMPLES);
                assert!(
                    (f64::from(f.vf[at(&g, i, j, k)]) - want).abs() < 1e-6,
                    "k={k} i={i} j={j}"
                );
            }
        }
    }
}

#[test]
fn type_height_and_errors() {
    let g = grid(3, 2, 4);
    let (nxh, nyh, nzh) = g.dims();
    let mut vf = vec![0f32; nxh * nyh * nzh];
    for k in 0..nzh {
        for j in 0..nyh {
            for i in 0..nxh {
                // column (i, j): first open at k = 1 + (i + j) % 3 (monotone)
                let kb = 1 + (i + j) % 3;
                vf[at(&g, i, j, k)] = if k >= kb {
                    1.0
                } else if k + 1 == kb {
                    0.04
                } else {
                    0.0
                };
            }
        }
    }
    let hc = type_height(&g, &vf, 0.05).unwrap();
    for j in 0..g.ny {
        for i in 0..g.nx {
            let kb = 1 + (i + 1 + j + 1) % 3;
            assert_eq!(hc[j * g.nx + i], g.z_bot + (kb as f64 - 1.0) * g.dz);
        }
    }
    // column without an open cell
    let mut bad = vf.clone();
    for k in 0..nzh {
        bad[at(&g, 2, 2, k)] = 0.01;
    }
    assert!(
        type_height(&g, &bad, 0.05)
            .unwrap_err()
            .to_string()
            .contains("without an open")
    );
    // open then closed again
    let mut bad = vf.clone();
    bad[at(&g, 1, 1, g.nz)] = 0.0;
    assert!(
        type_height(&g, &bad, 0.05)
            .unwrap_err()
            .to_string()
            .contains("monotone")
    );
}

#[test]
fn finish_full_cell_and_face_floor() {
    let g = grid(3, 3, 3);
    let (nxh, nyh, nzh) = g.dims();
    let n = nxh * nyh * nzh;
    let mut f = Fractions {
        vf: vec![0.0; n],
        af_u: vec![0.0; n],
        af_v: vec![0.0; n],
        af_w: vec![0.0; n],
    };
    let (mut cell, mut tu, mut tv, mut tw) =
        (vec![0u8; n], vec![0u8; n], vec![0u8; n], vec![0u8; n]);
    // cell A: almost full (snap), cell B: cut cell, cell C: full already
    let a = at(&g, 1, 1, 1);
    let b = at(&g, 2, 2, 2);
    let c = at(&g, 3, 3, 3);
    f.vf[a] = 1.0 - 5e-7;
    f.vf[b] = 0.4;
    f.vf[c] = 1.0;
    for q in [a, b, c] {
        cell[q] = 1;
    }
    // types: faces of A open (type 1) with zero share on its high-x face; B has a type-1 v face with 0 share
    tu[a] = 1;
    tu[a + 1] = 1;
    tv[b] = 1;
    f.af_v[b] = 0.0;
    // a ridge face of a cut cell
    tw[b] = 1;
    f.af_w[b] = 0.2;
    let st = finish(&g, &mut f, &cell, &tu, &tv, &tw);
    assert_eq!(st.n_snap_full, 1);
    assert_eq!(f.vf[a], 1.0);
    // A's six faces are 1 (high-side faces are the next index); the floor does not touch them
    assert_eq!(f.af_u[a], 1.0);
    assert_eq!(f.af_u[a + 1], 1.0);
    assert_eq!(f.af_v[a + nxh], 1.0);
    assert_eq!(f.af_w[a + nxh * nyh], 1.0);
    // B: v face type 1 with zero share -> floor; counted once
    assert_eq!(f.af_v[b], AF_FLOOR);
    assert_eq!(st.n_face_floor, 1);
    assert_eq!(f.af_w[b], 0.2);
    // cut cells: B only (A snapped, C full)
    assert_eq!(st.n_cut_cells, 1);
}
