//! Descent driver: setup, whole-field descent, point-by-point query, result files (F1, F2).

use crate::f1::{self, WriteMeta};
use crate::geo::Geo;
use crate::geosrc::{GeoSrc, cfg_from};
use crate::level::{Lazy, Level, step_full};
use crate::rules::{Cfg, Ctx, Diag, Src, Variant};
use crate::util;
use anyhow::{Context, Result, bail};
use serde_json::json;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

pub struct RunOpts {
    pub parent: PathBuf,
    pub case: String,
    pub to: usize,
    pub var: Variant,
    pub seed: u64,
    pub threads: usize,
    pub out_dir: PathBuf,
    pub runs_dir: Option<PathBuf>,
    pub geom: GeoSrc,
    pub n_bg: Option<f64>,
}

pub struct Setup {
    pub case: String,
    pub parent_dx: usize,
    pub parent: Level,
    #[allow(dead_code)]
    pub pgeo: Arc<Geo>,
    pub cgeos: Vec<Arc<Geo>>,
    pub ctxs: Vec<Ctx>,
    pub dxs: Vec<usize>,
    pub u_ref: f64,
    pub diag: Arc<Diag>,
    pub setup_s: f64,
}

/// Steps from `pgeo` through `cgeos` (one context per child level).
pub fn make_ctxs(
    pgeo: &Arc<Geo>,
    cgeos: &[Arc<Geo>],
    var: Variant,
    seed: u64,
    cfg: &Arc<Cfg>,
    diag: &Arc<Diag>,
    first_level: u32,
) -> Vec<Ctx> {
    (0..cgeos.len())
        .map(|j| Ctx {
            var,
            seed,
            n: first_level + j as u32,
            pg: if j == 0 {
                pgeo.clone()
            } else {
                cgeos[j - 1].clone()
            },
            cg: cgeos[j].clone(),
            cfg: cfg.clone(),
            diag: diag.clone(),
        })
        .collect()
}

pub fn setup(o: &RunOpts) -> Result<Setup> {
    let t0 = Instant::now();
    let (meta, parent, pgeo) = f1::read_f1(&o.parent)?;
    if meta.case != o.case {
        bail!("parent F1 is case {}, --case {}", meta.case, o.case);
    }
    if meta.dx <= o.to || !meta.dx.is_multiple_of(o.to) || !(meta.dx / o.to).is_power_of_two() {
        bail!("--to {} is not below parent dx {}", o.to, meta.dx);
    }
    let mut dxs = vec![meta.dx];
    while *dxs.last().unwrap() > o.to {
        dxs.push(dxs.last().unwrap() / 2);
    }
    let mut pgeo = pgeo;
    if !o.var.inherits_geometry() {
        // Background gradient of the parent level comes from its case (F1 has only theta').
        pgeo.gam = o.geom.load(&o.case, meta.dx, pgeo.nz)?.0.gam;
    }
    let pgeo = Arc::new(pgeo);
    let mut cgeos: Vec<Arc<Geo>> = Vec::new();
    let mut consts = None;
    let mut prev = pgeo.clone();
    for &dx in &dxs[1..] {
        let g = if o.var.inherits_geometry() {
            prev.inherit()
        } else {
            let (g, c) = o.geom.load(&o.case, dx, 2 * prev.nz - 1)?;
            consts = c.or(consts);
            g
        };
        prev = Arc::new(g);
        cgeos.push(prev.clone());
    }
    let cfg = Arc::new(cfg_from(consts, o.n_bg));
    let diag = Arc::new(Diag::default());
    let first = (400 / meta.dx).trailing_zeros() + 1;
    let ctxs = make_ctxs(&pgeo, &cgeos, o.var, o.seed, &cfg, &diag, first);
    let u_ref = f1::u_ref(&parent, &pgeo);
    Ok(Setup {
        case: o.case.clone(),
        parent_dx: meta.dx,
        parent,
        pgeo,
        cgeos,
        ctxs,
        dxs,
        u_ref,
        diag,
        setup_s: t0.elapsed().as_secs_f64(),
    })
}

/// Whole-field descent; returns the child levels (coarse to fine).
pub fn descend(ctxs: &[Ctx], parent: &Level, threads: usize) -> Result<Vec<Level>> {
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()?;
    Ok(pool.install(|| {
        let mut out: Vec<Level> = Vec::new();
        for c in ctxs {
            let next = step_full(c, out.last().unwrap_or(parent));
            out.push(next);
        }
        out
    }))
}

pub struct QueryRes {
    pub n_points: usize,
    pub us_cold: f64,
    pub us_warm: f64,
    pub warm_total_s: f64,
    pub max_abs_diff: f64,
    pub total_s: f64,
}

fn chain(ctxs: &[Ctx], base: &Rc<Level>) -> Rc<dyn Src> {
    let mut src: Rc<dyn Src> = base.clone();
    for c in ctxs {
        src = Rc::new(Lazy::new(c.clone(), src));
    }
    src
}

/// Values of a cell of the finest level: u at both x faces, w at both z faces, theta'.
fn cell_values(s: &dyn Src, r: usize, i: usize) -> [f32; 5] {
    [
        s.u(r, i),
        s.u(r, i + 1),
        s.w(r, i),
        s.w(r + 1, i),
        s.th(r, i),
    ]
}

/// Random air cells of the finest level, evaluated one by one from the parent only (1 thread),
/// compared bit for bit with the whole field.
pub fn query(st: &Setup, full: &Level, n: usize, seed: u64) -> QueryRes {
    let cg = st.cgeos.last().expect("at least one level");
    let air: Vec<(usize, usize)> = (0..cg.nz)
        .flat_map(|k| (0..cg.nx).map(move |i| (k, i)))
        .filter(|&(k, i)| cg.cell[k * cg.nx + i] != 0)
        .collect();
    let mut rng = util::Rng(seed ^ 0xC0FF_EE00);
    let pts: Vec<(usize, usize)> = (0..n)
        .map(|_| air[(rng.next_u64() % air.len() as u64) as usize])
        .collect();
    let base = Rc::new(st.parent.clone());
    let mut diff = 0.0f64;
    let mut check = |p: (usize, usize), v: [f32; 5]| {
        let f = cell_values(full, p.0, p.1);
        for (a, b) in v.iter().zip(f.iter()) {
            if a.to_bits() != b.to_bits() {
                diff = diff.max((*a as f64 - *b as f64).abs().max(f64::MIN_POSITIVE));
            }
        }
    };
    let mut cold = 0.0;
    for &p in &pts {
        let t = Instant::now();
        let src = chain(&st.ctxs, &base);
        let v = cell_values(src.as_ref(), p.0, p.1);
        cold += t.elapsed().as_secs_f64();
        check(p, v);
    }
    let warm_src = chain(&st.ctxs, &base);
    let tw = Instant::now();
    let vals: Vec<[f32; 5]> = pts
        .iter()
        .map(|&p| cell_values(warm_src.as_ref(), p.0, p.1))
        .collect();
    let warm = tw.elapsed().as_secs_f64();
    for (&p, v) in pts.iter().zip(vals) {
        check(p, v);
    }
    let nn = n.max(1) as f64;
    QueryRes {
        n_points: n,
        us_cold: cold / nn * 1e6,
        us_warm: warm / nn * 1e6,
        warm_total_s: warm,
        max_abs_diff: diff,
        total_s: cold,
    }
}

/// Writes F1 of every level and F2 of the run.
#[allow(clippy::too_many_arguments)]
pub fn write_results(
    o: &RunOpts,
    st: &Setup,
    levels: &[Level],
    work_s: f64,
    total_t0: Instant,
    q: Option<&QueryRes>,
    cmd: &str,
) -> Result<()> {
    let git = util::git_rev();
    let seed = (o.var == Variant::V3h).then_some(o.seed);
    let mut lv = Vec::new();
    let mut last_name = String::new();
    let (mut max_all, mut s2_all, mut n_all) = (0.0f64, 0.0f64, 0usize);
    for (j, l) in levels.iter().enumerate() {
        let g = &st.cgeos[j];
        let dx = st.dxs[j + 1];
        let name = format!("cascade_{}_d{}_from{}", o.var.name(), dx, st.parent_dx);
        let wm = WriteMeta {
            case: &st.case,
            source: "cascade",
            variant: Some(o.var.name()),
            parent_dx: Some(st.parent_dx),
            seed,
            git: git.clone(),
        };
        f1::write_f1(&o.out_dir.join(format!("{name}.json")), &wm, l, g)?;
        let b = f1::balance(l, g, st.u_ref);
        max_all = max_all.max(b.max_rel);
        s2_all += b.s2;
        n_all += b.n;
        lv.push(json!({"dx": dx, "max_rel_div": b.max_rel}));
        last_name = name;
    }
    let rms_all = if n_all > 0 {
        (s2_all / n_all as f64).sqrt()
    } else {
        0.0
    };
    let fin = levels.last().context("no levels")?;
    let fg = st.cgeos.last().unwrap();
    let arrays_mb = (fin.u.len()
        + fin.w.len()
        + fin.th.len()
        + fg.cell.len()
        + fg.tu.len()
        + fg.tw.len()
        + fg.h.len()) as f64
        * 4.0
        / 1e6;
    let geom_note = if o.var.inherits_geometry() {
        "geometry of the parent repeated on all levels (no terrain knowledge)"
    } else {
        "geometry of each level from the geometry source (case middle row or synthetic)"
    };
    let notes = format!(
        "{geom_note}; U_ref from the parent field (|u| at x=-4800 m, 100 m above ground), not from P25; rules: {}{}",
        st.diag.summary(),
        q.map_or(String::new(), |q| format!(
            "; query cold {:.2} us/point, warm (shared cache) {:.2} us/point ({:.4} s in total), {} points; work_s = cold passes only, without the comparison with the full field and the warm pass",
            q.us_cold, q.us_warm, q.warm_total_s, q.n_points
        )),
    );
    let total = total_t0.elapsed().as_secs_f64();
    let (work, query) = match q {
        Some(q) => (
            q.total_s,
            json!({"n_points": q.n_points, "us_per_point": q.us_cold, "threads": 1, "max_abs_diff_vs_full": q.max_abs_diff}),
        ),
        None => (work_s, serde_json::Value::Null),
    };
    let run = json!({
        "format": "cascade2d-run", "version": 1, "case": st.case, "source": "cascade",
        "variant": o.var.name(), "dx": *st.dxs.last().unwrap(), "parent_dx": st.parent_dx, "seed": seed,
        "threads": if q.is_some() { 1 } else { o.threads }, "ny": 1, "status": "ok", "iters": null,
        "time": {"total_s": total, "setup_s": st.setup_s, "work_s": work, "per_row_s": work},
        "memory": {"peak_rss_mb": util::peak_rss_mb(), "arrays_mb": arrays_mb},
        "balance": {"max_rel_div": max_all, "rms_rel_div": rms_all, "levels": lv},
        "y_uniform": null, "query": query,
        "field": o.out_dir.join(format!("{last_name}.json")).to_string_lossy(),
        "cmd": cmd, "host": {"cpu": util::cpu_name(), "rustc": util::rustc_version()},
        "git": git, "notes": notes,
    });
    let fname = format!(
        "{last_name}{}.run.json",
        if q.is_some() { ".query" } else { "" }
    );
    let text = serde_json::to_string_pretty(&run)?;
    std::fs::create_dir_all(&o.out_dir)?;
    std::fs::write(o.out_dir.join(&fname), &text)?;
    let runs = o
        .runs_dir
        .clone()
        .or_else(|| util::repo_root().map(|r| r.join("tools/research/cascade_2d/out/runs")));
    if let Some(r) = runs {
        let d = r.join(&st.case);
        std::fs::create_dir_all(&d)?;
        std::fs::write(d.join(&fname), &text)?;
    }
    println!(
        "{} {} -> {} m: max_rel_div={:.3e} work={:.3}s {}",
        st.case,
        o.var.name(),
        st.dxs.last().unwrap(),
        max_all,
        work,
        q.map_or(String::new(), |q| format!(
            "query cold={:.2}us warm={:.2}us diff={}",
            q.us_cold, q.us_warm, q.max_abs_diff
        ))
    );
    Ok(())
}
