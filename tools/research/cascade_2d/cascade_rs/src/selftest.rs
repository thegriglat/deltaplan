//! `cascade selftest`: balance and path-vs-full on synthetic divergence-free parents.

use crate::f1;
use crate::geo::Geo;
use crate::rules::{Cfg, Diag, Variant};
use crate::run::{Setup, descend, make_ctxs, query};
use crate::synth;
use std::sync::Arc;

pub struct Config {
    pub case: &'static str,
    pub parent_level: usize,
    pub u0: f64,
    pub noise: f64,
    pub n_bg: Option<f64>,
}

pub const CONFIGS: [Config; 4] = [
    Config {
        case: "C1",
        parent_level: 0,
        u0: 5.0,
        noise: 0.0,
        n_bg: None,
    },
    Config {
        case: "C1",
        parent_level: 1,
        u0: 5.0,
        noise: 3.0,
        n_bg: None,
    },
    Config {
        case: "C2",
        parent_level: 0,
        u0: 3.0,
        noise: 2.5,
        n_bg: None,
    },
    Config {
        case: "C2",
        parent_level: 1,
        u0: 3.0,
        noise: 2.5,
        n_bg: Some(0.02),
    },
];

/// Builds the setup of a synthetic configuration for one variant.
pub fn build(c: &Config, var: Variant, seed: u64) -> Setup {
    let geos: Vec<Geo> = (0..=4).map(|n| synth::geo(c.case, n, true)).collect();
    let pgeo = Arc::new(geos[c.parent_level].clone());
    let parent = synth::parent(&pgeo, c.u0, c.noise, 1234 + c.parent_level as u64);
    let mut cgeos: Vec<Arc<Geo>> = Vec::new();
    for g in geos.iter().skip(c.parent_level + 1) {
        let prev = cgeos.last().cloned().unwrap_or_else(|| pgeo.clone());
        cgeos.push(Arc::new(if var.inherits_geometry() {
            prev.inherit()
        } else {
            g.clone()
        }));
    }
    let cfg = Arc::new(Cfg {
        n_bg: c.n_bg,
        ..Cfg::default()
    });
    let diag = Arc::new(Diag::default());
    let ctxs = make_ctxs(
        &pgeo,
        &cgeos,
        var,
        seed,
        &cfg,
        &diag,
        c.parent_level as u32 + 1,
    );
    let dxs: Vec<usize> = (c.parent_level..=4).map(|n| 400 >> n).collect();
    let u_ref = f1::u_ref(&parent, &pgeo);
    Setup {
        case: c.case.to_string(),
        parent_dx: 400 >> c.parent_level,
        parent,
        pgeo,
        cgeos,
        ctxs,
        dxs,
        u_ref,
        diag,
        setup_s: 0.0,
    }
}

/// Returns (max relative divergence, max path-vs-full difference) and prints the table.
pub fn run(points: usize) -> (f64, f64) {
    let (mut worst, mut worst_path) = (0.0f64, 0.0f64);
    for c in &CONFIGS {
        for var in Variant::ALL {
            let st = build(c, var, 7);
            let levels = descend(&st.ctxs, &st.parent, 4).expect("descent");
            let mut per = String::new();
            let mut m = 0.0f64;
            for (j, l) in levels.iter().enumerate() {
                let b = f1::balance(l, &st.cgeos[j], st.u_ref);
                m = m.max(b.max_rel);
                per += &format!(" {}m:{:.1e}", st.dxs[j + 1], b.max_rel);
            }
            let q = query(&st, levels.last().unwrap(), points, 99);
            println!(
                "{} parent={} {:>3}: rel_div{per} | path_diff={} | {}",
                c.case,
                st.parent_dx,
                var.name(),
                q.max_abs_diff,
                st.diag.summary()
            );
            worst = worst.max(m);
            worst_path = worst_path.max(q.max_abs_diff);
        }
    }
    (worst, worst_path)
}
