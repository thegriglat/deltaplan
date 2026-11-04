use crate::f1;
use crate::level::Level;
use crate::rules::{Src, Variant};
use crate::run::{descend, query};
use crate::selftest::{CONFIGS, build};

fn bits_eq(a: &Level, b: &Level) -> bool {
    a.u.iter()
        .zip(&b.u)
        .all(|(x, y)| x.to_bits() == y.to_bits())
        && a.w
            .iter()
            .zip(&b.w)
            .all(|(x, y)| x.to_bits() == y.to_bits())
        && a.th
            .iter()
            .zip(&b.th)
            .all(|(x, y)| x.to_bits() == y.to_bits())
}

#[test]
fn parent_is_balanced_and_children_too() {
    for c in &CONFIGS {
        for var in Variant::ALL {
            let st = build(c, var, 3);
            let b0 = f1::balance(&st.parent, &st.pgeo, st.u_ref);
            assert!(
                b0.max_rel < 1e-5,
                "synthetic parent not divergence-free: {}",
                b0.max_rel
            );
            let levels = descend(&st.ctxs, &st.parent, 2).unwrap();
            for (j, l) in levels.iter().enumerate() {
                let b = f1::balance(l, &st.cgeos[j], st.u_ref);
                assert!(
                    b.max_rel <= 1e-5,
                    "{} parent {} {}: level {} rel_div {}",
                    c.case,
                    st.parent_dx,
                    var.name(),
                    st.dxs[j + 1],
                    b.max_rel
                );
            }
        }
    }
}

#[test]
fn subfaces_sum_to_parent_face() {
    let c = &CONFIGS[1];
    for var in Variant::ALL {
        let st = build(c, var, 5);
        let ctx = &st.ctxs[0];
        let (pg, p) = (&st.pgeo, &st.parent);
        let mut checked = 0;
        for k in 0..pg.nz {
            for i in 0..=pg.nx {
                let (lo, hi) = ctx.split_x(p, k, i);
                let u = p.u(k, i) as f64;
                let both = ctx.cg.u_open(ctx_row(k, 0), 2 * i as i64)
                    && ctx.cg.u_open(ctx_row(k, 1), 2 * i as i64);
                if pg.u_open(k as i64, i as i64) && (both || lo != 0.0 || hi != 0.0) {
                    let err = (lo as f64 + hi as f64 - 2.0 * u).abs();
                    assert!(
                        err <= 1e-6 * u.abs().max(1e-3),
                        "x face {k},{i}: {lo}+{hi} vs 2*{u}"
                    );
                    checked += 1;
                }
            }
        }
        for k in 0..=pg.nz {
            for i in 0..pg.nx {
                let (l, r) = ctx.split_z(p, k, i);
                let w = p.w(k, i) as f64;
                if pg.w_open(k as i64, i as i64) && (l != 0.0 || r != 0.0) {
                    let err = (l as f64 + r as f64 - 2.0 * w).abs();
                    assert!(
                        err <= 1e-6 * (l.abs().max(r.abs()) as f64).max(w.abs()).max(1e-3),
                        "z face {k},{i}"
                    );
                    checked += 1;
                }
            }
        }
        assert!(checked > 100);
    }
}

fn ctx_row(k: usize, s: usize) -> i64 {
    crate::rules::Ctx::crow(k, s)
}

#[test]
fn split_depends_only_on_the_face_and_its_neighbours() {
    // Neighbouring cells use the same face: the split must not depend on anything but the data
    // next to the face. Perturb far-away faces and compare.
    let st = build(&CONFIGS[1], Variant::V3h, 11);
    let ctx = &st.ctxs[0];
    let mut other = st.parent.clone();
    let (k, i) = (12, 20);
    for kk in 0..other.nz {
        for ii in 0..=other.nx {
            if kk.abs_diff(k) > 2 || ii.abs_diff(i) > 3 {
                other.u[kk * (other.nx + 1) + ii] += 0.37;
            }
        }
    }
    let a = ctx.split_x(&st.parent, k, i);
    let b = ctx.split_x(&other, k, i);
    assert_eq!(a.0.to_bits(), b.0.to_bits());
    assert_eq!(a.1.to_bits(), b.1.to_bits());
}

#[test]
fn neighbours_see_the_same_sub_faces() {
    let st = build(&CONFIGS[2], Variant::V3, 2);
    let ctx = &st.ctxs[0];
    let p = &st.parent;
    let lv = descend(&st.ctxs[..1], p, 1).unwrap().remove(0);
    for k in 0..st.pgeo.nz {
        for i in 1..st.pgeo.nx {
            let (lo, hi) = ctx.split_x(p, k, i);
            for (s, v) in [(0, lo), (1, hi)] {
                let r = ctx_row(k, s);
                if r >= 0 {
                    let a = lv.u[r as usize * (lv.nx + 1) + 2 * i];
                    assert_eq!(a.to_bits(), v.to_bits());
                }
            }
        }
    }
}

#[test]
fn threads_do_not_change_bits() {
    for var in [Variant::V0, Variant::V3, Variant::V3h] {
        let st = build(&CONFIGS[3], var, 17);
        let a = descend(&st.ctxs, &st.parent, 1).unwrap();
        let b = descend(&st.ctxs, &st.parent, 8).unwrap();
        for (x, y) in a.iter().zip(&b) {
            assert!(bits_eq(x, y), "{}", var.name());
        }
    }
}

#[test]
fn query_equals_full_field_bit_for_bit() {
    for c in &CONFIGS[..3] {
        for var in Variant::ALL {
            let st = build(c, var, 23);
            let levels = descend(&st.ctxs, &st.parent, 4).unwrap();
            let q = query(&st, levels.last().unwrap(), 200, 5);
            assert_eq!(q.max_abs_diff, 0.0, "{} {}", c.case, var.name());
        }
    }
}

#[test]
fn walls_stay_zero() {
    for var in Variant::ALL {
        let st = build(&CONFIGS[2], var, 1);
        let levels = descend(&st.ctxs, &st.parent, 2).unwrap();
        for (j, l) in levels.iter().enumerate() {
            let g = &st.cgeos[j];
            for (idx, &t) in g.tu.iter().enumerate() {
                if t == 0 {
                    assert_eq!(l.u[idx], 0.0, "{} u wall", var.name());
                }
            }
            for (idx, &t) in g.tw.iter().enumerate() {
                if t == 0 {
                    assert_eq!(l.w[idx], 0.0, "{} w wall", var.name());
                }
            }
        }
    }
}

#[test]
fn v0_repeats_the_parent_on_outer_faces_and_hash_changes_v3() {
    let st = build(&CONFIGS[0], Variant::V0, 1);
    let l = descend(&st.ctxs[..1], &st.parent, 1).unwrap().remove(0);
    let (k, i) = (10usize, 30usize);
    let u = st.parent.u[k * (st.parent.nx + 1) + i];
    assert_eq!(l.u[Ctx2::row(k, 0) * (l.nx + 1) + 2 * i], u);
    assert_eq!(l.u[Ctx2::row(k, 1) * (l.nx + 1) + 2 * i], u);
    let a = build(&CONFIGS[1], Variant::V3h, 1);
    let b = build(&CONFIGS[1], Variant::V3h, 2);
    let la = descend(&a.ctxs[..1], &a.parent, 1).unwrap().remove(0);
    let lb = descend(&b.ctxs[..1], &b.parent, 1).unwrap().remove(0);
    assert!(!bits_eq(&la, &lb), "seed must change the fluctuation");
}

struct Ctx2;
impl Ctx2 {
    fn row(k: usize, s: usize) -> usize {
        crate::rules::Ctx::crow(k, s) as usize
    }
}

#[test]
fn n2_comes_from_case_gam_and_gives_the_froude_formula() {
    // C2-like synthetic: gam = N^2 theta0 / g, N = 0.01. Uniform theta' -> N^2 = 1e-4.
    let mut st = build(&CONFIGS[2], Variant::V3, 1);
    st.parent.th.iter_mut().for_each(|t| *t = 0.0);
    let ctx = &st.ctxs[0];
    let n2 = ctx.n2(&st.parent, 15, 40);
    assert!((n2 - 1e-4).abs() < 1e-9, "{n2}");
    // Override (tests only) replaces the case value.
    let mut c2 = ctx.clone();
    let mut cfg = (*c2.cfg).clone();
    cfg.n_bg = Some(0.02);
    c2.cfg = std::sync::Arc::new(cfg);
    assert!((c2.n2(&st.parent, 15, 40) - 4e-4).abs() < 1e-9);
    // Neutral case has no stability.
    let st0 = build(&CONFIGS[0], Variant::V3, 1);
    assert_eq!(st0.ctxs[0].n2(&st0.parent, 15, 40).max(0.0) < 1e-3, true);
}

#[test]
fn froude_clips_reverse_flow_and_z_split_never_opposes_parent() {
    use crate::rules::Ctx;
    // Reverse flow: the clipped shift is the one with d*u > 0 (flux to the upper sub-face).
    let st = build(&CONFIGS[2], Variant::V3, 4);
    let mut v1 = st.ctxs[0].clone();
    v1.var = Variant::V1;
    let ctx = &st.ctxs[0];
    let (mut checked, mut clipped) = (0, 0);
    for k in 2..st.pgeo.nz - 2 {
        for i in 1..st.pgeo.nx {
            let u = st.parent.u[k * (st.pgeo.nx + 1) + i] as f64;
            let (l1, h1) = v1.split_x(&st.parent, k, i);
            let (l3, h3) = ctx.split_x(&st.parent, k, i);
            let (d1, d3) = ((h1 - l1) as f64 / 2.0, (h3 - l3) as f64 / 2.0);
            if d1 * u > 0.0 && d3.abs() < d1.abs() - 1e-6 {
                clipped += 1;
            }
            if d1 * u <= 0.0 && d1 != 0.0 {
                assert!((d3 - d1).abs() < 1e-5, "downward shift must stay");
            }
            checked += 1;
        }
    }
    assert!(checked > 0 && clipped > 0);
    // z faces: sub-face velocities share the sign of the parent flux (V3h, strong hash).
    for var in [Variant::V3, Variant::V3h] {
        let st = build(&CONFIGS[1], var, 9);
        let ctx: &Ctx = &st.ctxs[0];
        for k in 0..=st.pgeo.nz {
            for i in 0..st.pgeo.nx {
                let w = st.parent.w[k * st.pgeo.nx + i];
                let (l, r) = ctx.split_z(&st.parent, k, i);
                assert!(
                    l * w >= 0.0 && r * w >= 0.0,
                    "z split against parent at {k},{i}"
                );
            }
        }
    }
}
