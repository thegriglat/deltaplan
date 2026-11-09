//! OBC-6: стенд этапа 2 outflow-bc (контракт OB4, `docs/contracts/outflow-bc.md`; пп. 6–9 плана):
//! старты Пикара на 400 м и снимки каждые 10 итераций.
//!
//! Сборка случая — как `outflow_corpus` (OB2): место → `domain_for` (96 × 96 клеток по 400 м) → `field_weather` →
//! `build_domain_input` → `build_case` → `prepare` → `build_solver_case` → `picard_rs::api::solve`, чистый Пикар,
//! `tol_scale` игры. Старт задаёт `SolveOpts.init` решения 400 м и повторяет путь игры (`field/runtime.rs`):
//!
//! - `bg` — холодный старт (фон), `init = None`;
//! - `coarse3` — `coarse_start`: Пикар на `coarse_domain(fine, 3)` (32 × 32, 1200 м) холодным стартом, критерии
//!   и `max_iters` игры (`RtCfg`), без запасных правил и заморозки; затем `level_of` + `prolong_to` на 400 м;
//! - `chain` — то же ступенями `coarse_domain(fine, 4)` (24 × 24, 1600 м) → `coarse_domain(fine, 2)` (48 × 48, 800 м)
//!   → 400 м: старт каждой ступени — `prolong_to` предыдущей, первая — холодная;
//! - `phase` — тёплый старт сборки фаз (`phase::assembly::assemble`): `warm` для случая с нагревом,
//!   `warm_mech` без нагрева (как в игре фазы считаются по случаю с нагревом, `phases_of`), у игры Пикару стартом
//!   не служит — здесь служит;
//! - `chain_phase` — `chain`, у которого первая ступень (1600 м) стартует с поля сборки фаз на этой сетке.
//!
//! Варианты `hard` / `soft` / `soft_ns` — как OB2; для `soft*` грубые ступени решаются тем же выходом (`Outflow::Soft`,
//! для `soft_ns` — и той же губкой), чтобы старт был совместим с решением 400 м.
//!
//! Снимки: `SolveOpts.snapshot_at = [every, 2·every, …, max_iters]` (финализированные копии); при остановке раньше
//! снимки после остановки равны итоговому полю. Метрики — в `outflow_stage2/analysis.rs`.
//!
//! ## Запуск
//! `cargo run --release -p dp-air --example outflow_stage2 -- --spec S.json [--variants hard,soft,soft_ns]
//! [--starts bg,coarse3,chain,phase,chain_phase] [--out F.jsonl] [--raw DIR] [--save-slices] [--shard i/n]
//! [--threads N] [--list]`. Повтор пропускает готовые тройки `case_id` + `variant` + `start`.
#[path = "outflow_stage2/analysis.rs"]
mod analysis;
#[path = "outflow_corpus/ideal.rs"]
#[allow(dead_code)]
mod ideal;
#[path = "outflow_corpus/metrics.rs"]
#[allow(dead_code)]
mod metrics;

use dp_air::field::case_build::{SolverCfg, build_solver_case};
use dp_air::field::case_prepare::{AirCaseRs, CaseOpts, PreparedPlanes, build_case};
use dp_air::field::phase::assembly::{PhaseResult, assemble};
use dp_air::field::phase::config::PhaseCfg;
use dp_air::field::phase::prepare::{PhaseCase, prepare as phase_prepare};
use dp_air::field::place_input::build_domain_input;
use dp_air::field::runtime::{RtCfg, coarse_domain, domain_for, level_of, prolong_to};
use dp_air::field::weather_core::{Domain, field_weather, hour_at};
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, InflowMode, Place};
use metrics::{AGL_M, Geo};
use picard_rs::api::{Outflow, SolveOpts, Solved, StopReason, solve};
use picard_rs::case::Case;
use picard_rs::state::State;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

type R<T> = Result<T, String>;

fn es<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

// ---------------------------------------------------------------- спецификация

#[derive(Deserialize, Clone)]
struct PlaceSpec {
    id: String,
    kind: String,
    file: Option<String>,
    shape: Option<String>,
    h_m: Option<f64>,
    sigma_m: Option<f64>,
    dirs_deg: Vec<f64>,
}

#[derive(Deserialize, Clone)]
struct SnapSpec {
    every: usize,
    n_eval: Vec<usize>,
    late_from: usize,
    late_step: usize,
    edge_cells: usize,
}

#[derive(Deserialize, Clone)]
struct CaseSpec {
    place: String,
    dir_deg: f64,
    u10_ms: f64,
    heat: bool,
}

fn d_t_max() -> f64 {
    22.0
}
fn d_sky() -> String {
    "clear".into()
}
fn d_k() -> f64 {
    1.0
}

#[derive(Deserialize, Clone)]
struct Spec {
    places: Vec<PlaceSpec>,
    u10_ms: Vec<f64>,
    heat: Vec<bool>,
    hour: f64,
    max_iters: usize,
    threads: usize,
    #[serde(default = "d_t_max")]
    t_max_c: f64,
    #[serde(default = "d_sky")]
    sky: String,
    #[serde(default = "d_k")]
    k: f64,
    starts: Vec<String>,
    snap: SnapSpec,
    /// Явный список случаев (пилот) вместо произведения places × dirs × u10 × heat.
    cases: Option<Vec<CaseSpec>>,
}

impl Spec {
    fn check(&self) -> R<()> {
        let s = &self.snap;
        if s.every == 0 || self.max_iters == 0 {
            return Err("spec: snap.every and max_iters must be positive".into());
        }
        let limit = self.max_iters.div_ceil(s.every) * s.every;
        for &n in &s.n_eval {
            if n == 0 || n % s.every != 0 || n > limit {
                return Err(format!("spec: n_eval {n}: multiple of every, <= {limit}"));
            }
        }
        if s.late_from == 0 || s.late_from % s.every != 0 || s.late_step % s.every != 0 {
            return Err("spec: late_from, late_step must be multiples of every".into());
        }
        if s.late_from > limit {
            return Err("spec: late_from above the iteration limit".into());
        }
        for st in &self.starts {
            Start::parse(st)?;
        }
        Ok(())
    }
}

#[derive(Clone)]
struct CaseRef {
    pi: usize,
    dir: f64,
    u10: f64,
    heat: bool,
    id: String,
}

/// `<place>_d<dir, 3 цифры>_u<u10·10, 3 цифры>_<m|h>`.
fn case_id(place: &str, dir: f64, u10: f64, heat: bool) -> String {
    format!(
        "{place}_d{:03}_u{:03}_{}",
        dir.round() as i64,
        (u10 * 10.0).round() as i64,
        if heat { 'h' } else { 'm' }
    )
}

fn enumerate(spec: &Spec) -> R<Vec<CaseRef>> {
    let mut v = Vec::new();
    if let Some(cs) = &spec.cases {
        for c in cs {
            let pi = spec
                .places
                .iter()
                .position(|p| p.id == c.place)
                .ok_or(format!("no place '{}'", c.place))?;
            v.push(CaseRef {
                pi,
                dir: c.dir_deg,
                u10: c.u10_ms,
                heat: c.heat,
                id: case_id(&c.place, c.dir_deg, c.u10_ms, c.heat),
            });
        }
        return Ok(v);
    }
    for (pi, p) in spec.places.iter().enumerate() {
        for &dir in &p.dirs_deg {
            for &u10 in &spec.u10_ms {
                for &heat in &spec.heat {
                    v.push(CaseRef {
                        pi,
                        dir,
                        u10,
                        heat,
                        id: case_id(&p.id, dir, u10, heat),
                    });
                }
            }
        }
    }
    Ok(v)
}

// ---------------------------------------------------------------- варианты и старты

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Variant {
    Hard,
    Soft,
    SoftNs,
}

impl Variant {
    const ALL: [Variant; 3] = [Variant::Hard, Variant::Soft, Variant::SoftNs];
    fn name(self) -> &'static str {
        match self {
            Variant::Hard => "hard",
            Variant::Soft => "soft",
            Variant::SoftNs => "soft_ns",
        }
    }
    fn parse(s: &str) -> R<Variant> {
        Self::ALL
            .into_iter()
            .find(|v| v.name() == s)
            .ok_or(format!("unknown variant '{s}'"))
    }
    fn outflow(self) -> Outflow {
        if self == Variant::Hard {
            Outflow::Hard
        } else {
            Outflow::Soft
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Start {
    Bg,
    Coarse3,
    Chain,
    Phase,
    ChainPhase,
}

impl Start {
    const ALL: [Start; 5] = [
        Start::Bg,
        Start::Coarse3,
        Start::Chain,
        Start::Phase,
        Start::ChainPhase,
    ];
    fn name(self) -> &'static str {
        match self {
            Start::Bg => "bg",
            Start::Coarse3 => "coarse3",
            Start::Chain => "chain",
            Start::Phase => "phase",
            Start::ChainPhase => "chain_phase",
        }
    }
    fn parse(s: &str) -> R<Start> {
        Self::ALL
            .into_iter()
            .find(|v| v.name() == s)
            .ok_or(format!("unknown start '{s}'"))
    }
}

/// `soft_ns`: боковая губка импульса `sp_u`, `sp_w` — как губка θ (`C_SCS`), только у приточных граней
/// (`outflow_corpus::apply_soft_ns`).
fn apply_soft_ns(case: &mut Case, p: &PreparedPlanes) -> R<()> {
    const C_SCS: usize = 7;
    const L_SPZ: usize = 3;
    const L_SPZW: usize = 4;
    let (nxh, nyh, nzh) = (p.nx_h, p.ny_h, p.nz_h);
    let (scs, spz, spzw) = (p.col_plane(C_SCS), p.lev_plane(L_SPZ), p.lev_plane(L_SPZW));
    for (name, lev) in [("sp_u", spz), ("sp_w", spzw)] {
        let a = case
            .arrays
            .get_mut(name)
            .ok_or(format!("no array {name}"))?;
        if a.len() != nxh * nyh * nzh {
            return Err(format!("array {name}: size"));
        }
        for k in 0..nzh {
            for q in 0..nxh * nyh {
                a[k * nxh * nyh + q] = lev[k].max(scs[q]);
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------- окружение

struct Env {
    spec: Spec,
    cfg: RtCfg,
    configs: Configs,
    repo: PathBuf,
    git: String,
    threads: usize,
    out: PathBuf,
    raw: PathBuf,
    save_slices: bool,
}

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

fn configs(repo: &Path) -> Configs {
    let mut files = Vec::new();
    collect(&repo.join("configs"), "", &mut files);
    files.sort();
    Configs::new(files)
}

fn git_rev(repo: &Path) -> String {
    let run = |a: &[&str]| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(a)
            .output()
            .ok()
            .filter(|o| o.status.success())
    };
    let rev = run(&["rev-parse", "--short", "HEAD"])
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let dirty = run(&[
        "status",
        "--porcelain",
        "--untracked-files=no",
        "--",
        "rust",
    ])
    .is_some_and(|o| !o.stdout.is_empty());
    match rev {
        Some(r) if dirty => format!("{r}+dirty"),
        Some(r) => r,
        None => "unknown".into(),
    }
}

// ---------------------------------------------------------------- место

fn load_place(env: &Env, ps: &PlaceSpec, dir: f64) -> R<Place> {
    match ps.kind.as_str() {
        "real" => read_place(
            &env.repo
                .join(ps.file.as_deref().ok_or("real place needs 'file'")?),
        )
        .map_err(es),
        "ideal" => ideal::build(&ideal_of(ps, dir)?),
        k => Err(format!("unknown place kind '{k}'")),
    }
}

fn ideal_of(ps: &PlaceSpec, dir: f64) -> R<ideal::Ideal<'_>> {
    Ok(ideal::Ideal {
        id: &ps.id,
        shape: ps.shape.as_deref().ok_or("ideal place needs 'shape'")?,
        h_m: ps.h_m.ok_or("ideal place needs 'h_m'")?,
        sigma_m: ps.sigma_m.ok_or("ideal place needs 'sigma_m'")?,
        dir_deg: dir,
    })
}

fn sites_of(ps: &PlaceSpec, place: &Place, dir: f64) -> R<Vec<(f64, f64)>> {
    if ps.kind == "ideal" {
        return Ok(ideal::start_sites(&ideal_of(ps, dir)?));
    }
    Ok(place
        .header()
        .start_sites
        .iter()
        .map(|s| (s.x, -s.z))
        .collect())
}

// ---------------------------------------------------------------- уровень решения

/// Уровень решения: область, случай с нагревом (для фаз), плоскости и случай решателя решаемого варианта.
struct Lvl {
    dom: Domain,
    heat_ac: AirCaseRs,
    heat: bool,
    planes: PreparedPlanes,
    case: Case,
    stats: Option<Stats>,
    wstar: f64,
}

struct Stats {
    u10: f64,
    fr: f64,
    n_bv: f64,
    relief: f64,
}

/// Колонночные массивы входа фаз из плоскостей (как `runtime::phases_of`).
struct PcData {
    h_bl: Vec<f64>,
    wst: Vec<f64>,
    zic: Vec<f64>,
}

fn pc_data(ac: &AirCaseRs, pl: &PreparedPlanes) -> PcData {
    let (nx, n) = (ac.dom.nx, ac.dom.nx * ac.dom.ny);
    let inner = |plane: &[f32]| -> Vec<f64> {
        (0..n)
            .map(|c| f64::from(plane[(c / nx + 1) * pl.nx_h + c % nx + 1]))
            .collect()
    };
    PcData {
        h_bl: inner(pl.col_plane(2)),
        wst: inner(pl.col_plane(3)),
        zic: ac.z_i_col.iter().map(|&v| f64::from(v)).collect(),
    }
}

fn phase_case<'a>(ac: &'a AirCaseRs, pl: &'a PreparedPlanes, d: &'a PcData) -> PhaseCase<'a> {
    PhaseCase {
        nx: ac.dom.nx,
        ny: ac.dom.ny,
        nz: ac.nz,
        dx: ac.dom.dx,
        dz: ac.dz,
        z_bot: ac.z_bot,
        ex: pl.ex,
        ey: pl.ey,
        u_a: pl.u_a,
        z_sat: f64::from(pl.prm[12]),
        alpha: pl.alpha,
        z0: pl.z0,
        ustar: pl.ustar,
        tau_cool: ac.p.tau_cool,
        u10: ac.u10,
        z_i: ac.z_i,
        hc: &ac.hc,
        gam: &ac.gam,
        heat: &ac.heat,
        heat_used: &pl.heat_used,
        h_bl: &d.h_bl,
        wst: &d.wst,
        z_i_col: &d.zic,
        g: None,
    }
}

fn conditions(env: &Env, c: &CaseRef) -> R<Conditions> {
    Conditions::from_json(
        &json!({
            "forecast": {"temperature_c": env.spec.t_max_c, "wind_speed_kmh": c.u10 * 3.6, "wind_from_deg": c.dir, "sky": env.spec.sky},
            "quantum_h": 0.5, "speed": 1.0, "start_hour": env.spec.hour
        })
        .to_string(),
    )
    .map_err(es)
}

/// Уровень области `dom` для случая `c`: путь `outflow_corpus::build` (= `runtime::build_level`).
fn build_lvl(
    env: &Env,
    place: &Place,
    dom: &Domain,
    c: &CaseRef,
    v: Variant,
    want_stats: bool,
) -> R<Lvl> {
    let cfg = &env.cfg;
    let cond = conditions(env, c)?;
    let hour = hour_at(&cond, 0.0);
    let fw =
        field_weather(&cond, place, &cfg.wc, &env.configs, &cfg.climate, hour, dom).map_err(es)?;
    let inp = build_domain_input(place, &cfg.wc.sh, &cfg.zi, dom, &fw.day).map_err(es)?;
    let heat_ac = build_case(
        &inp,
        &fw,
        &CaseOpts {
            k: env.spec.k,
            inflow_mode: InflowMode::Start,
            heat: true,
        },
    )
    .map_err(es)?;
    let (planes, case, stats) = {
        let mech;
        let ac = if c.heat {
            &heat_ac
        } else {
            mech = heat_ac.without_heat();
            &mech
        };
        let planes = ac.prepare().map_err(es)?;
        let mut case = build_solver_case(&planes, &ac.p, &SolverCfg::new(ac.u10)).map_err(es)?;
        if v == Variant::SoftNs {
            apply_soft_ns(&mut case, &planes)?;
        }
        let stats = if want_stats {
            let d = pc_data(ac, &planes);
            let pr = phase_prepare(&phase_case(ac, &planes, &d), &cfg.phase)?;
            Some(Stats {
                u10: pr.u10,
                fr: pr.fr,
                n_bv: pr.n_bv,
                relief: pr.relief,
            })
        } else {
            None
        };
        (planes, case, stats)
    };
    let wstar = if c.heat { planes.wstar_max } else { 0.0 };
    Ok(Lvl {
        dom: *dom,
        heat_ac,
        heat: c.heat,
        planes,
        case,
        stats,
        wstar,
    })
}

/// Тёплый старт сборки фаз уровня: `warm` (с нагревом) или `warm_mech`. Фазы, как в игре, считаются
/// по случаю с нагревом (`phases_of`), плоскости которого для варианта без нагрева готовятся отдельно.
fn phase_warm(env: &Env, l: &Lvl) -> R<State> {
    let own;
    let pl = if l.heat {
        &l.planes
    } else {
        own = l.heat_ac.prepare().map_err(es)?;
        &own
    };
    let d = pc_data(&l.heat_ac, pl);
    let r: PhaseResult = assemble(&phase_case(&l.heat_ac, pl, &d), &env.cfg.phase as &PhaseCfg)?;
    Ok(if l.heat { r.warm } else { r.warm_mech })
}

/// Решение ступени (как `runtime::solve_with` без запасных правил, заморозки и отмены).
fn stage_solve(env: &Env, l: &Lvl, init: Option<State>, v: Variant) -> R<Solved> {
    let opts = SolveOpts {
        threads: env.threads,
        max_iters: env.cfg.max_iters,
        tol_scale: env.cfg.tol_scale,
        init,
        outflow: v.outflow(),
        ..SolveOpts::default()
    };
    let s = solve(&l.case, &opts).map_err(|e| format!("solve: {e:#}"))?;
    if s.stop == StopReason::Diverged {
        return Err(format!("stage diverged at iteration {}", s.iters));
    }
    Ok(s)
}

/// Старт решения 400 м: `init` и итерации ступеней от грубой.
struct StartInit {
    init: Option<State>,
    iters: Vec<usize>,
}

/// Ступени грубее 400 м: коэффициенты `coarse_domain`, от грубой к мелкой; `phase0` — первая ступень
/// стартует с поля сборки фаз.
fn make_start(
    env: &Env,
    place: &Place,
    c: &CaseRef,
    v: Variant,
    fine: &Lvl,
    start: Start,
) -> R<StartInit> {
    let factors: &[usize] = match start {
        Start::Bg => {
            return Ok(StartInit {
                init: None,
                iters: vec![],
            });
        }
        Start::Phase => {
            return Ok(StartInit {
                init: Some(checked_warm(fine, phase_warm(env, fine)?)?),
                iters: vec![],
            });
        }
        Start::Coarse3 => &[3],
        Start::Chain | Start::ChainPhase => &[4, 2],
    };
    let fine_level = level_of(&fine.planes, &fine.dom);
    let mut iters = Vec::new();
    let mut prev: Option<(dp_air::Level, State)> = None;
    for (n, &f) in factors.iter().enumerate() {
        let dom = coarse_domain(&fine.dom, f);
        let l = build_lvl(env, place, &dom, c, v, false)?;
        let lv = level_of(&l.planes, &dom);
        let init = match prev.take() {
            Some((pl, st)) => Some(prolong_to(&pl, &st, &lv).map_err(es)?),
            None if start == Start::ChainPhase && n == 0 => {
                Some(checked_warm(&l, phase_warm(env, &l)?)?)
            }
            None => None,
        };
        let s =
            stage_solve(env, &l, init, v).map_err(|e| format!("{f}x stage ({} m): {e}", dom.dx))?;
        iters.push(s.iters);
        prev = Some((lv, s.state));
    }
    let (pl, st) = prev.expect("at least one stage");
    let init = prolong_to(&pl, &st, &fine_level).map_err(es)?;
    Ok(StartInit {
        init: Some(init),
        iters,
    })
}

/// Размеры тёплого старта сборки фаз должны совпасть с размерами случая решателя.
fn checked_warm(l: &Lvl, w: State) -> R<State> {
    let want = [l.case.nxh, l.case.nyh, l.case.nzh];
    if w.dims != want {
        return Err(format!("phase warm dims {:?} != case {:?}", w.dims, want));
    }
    Ok(w)
}

// ---------------------------------------------------------------- рез и запись

fn slice_paths(raw: &Path, id: &str, v: Variant, s: Start) -> (PathBuf, PathBuf) {
    let d = raw.join("stage2").join("slices");
    (
        d.join(format!("{id}__{}__{}.bin", v.name(), s.name())),
        d.join(format!("{id}__{}__{}.json", v.name(), s.name())),
    )
}

fn write_atomic(path: &Path, data: &[u8]) -> R<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(es)?;
    std::fs::rename(&tmp, path).map_err(es)
}

#[allow(clippy::too_many_arguments)]
fn write_slices(
    env: &Env,
    c: &CaseRef,
    v: Variant,
    s: Start,
    g: &Geo,
    fields: &[(String, &[f32])],
    status: &str,
    iters: usize,
    ref_kind: &str,
) -> R<()> {
    let (bin, js) = slice_paths(&env.raw, &c.id, v, s);
    std::fs::create_dir_all(bin.parent().unwrap()).map_err(es)?;
    let bytes: Vec<u8> = fields
        .iter()
        .flat_map(|(_, f)| f.iter().flat_map(|x| x.to_le_bytes()))
        .collect();
    write_atomic(&bin, &bytes)?;
    let names: Vec<&str> = fields.iter().map(|(n, _)| n.as_str()).collect();
    let meta = json!({"version": 1, "nx": g.nx, "ny": g.ny, "dx_m": g.dx, "agl_m": AGL_M, "comps": ["u", "v", "w"],
        "fields": names, "case_id": c.id, "variant": v.name(), "start": s.name(), "status": status,
        "iters": iters, "ref_kind": ref_kind});
    write_atomic(&js, meta.to_string().as_bytes())
}

fn status_of(s: StopReason) -> &'static str {
    match s {
        StopReason::Cancelled => "cancelled",
        other => other.status(),
    }
}

fn base_record(env: &Env, c: &CaseRef, ps: &PlaceSpec, v: Variant, s: Start) -> Map<String, Value> {
    let mut r = Map::new();
    let mut put = |k: &str, x: Value| {
        r.insert(k.to_string(), x);
    };
    put("case_id", json!(c.id));
    put("place", json!(ps.id));
    put("kind", json!(ps.kind));
    put("shape", json!(ps.shape));
    put("h_m", json!(ps.h_m));
    put("dir_deg", json!(c.dir));
    put("u10_in", json!(c.u10));
    put("heat", json!(c.heat));
    put("variant", json!(v.name()));
    put("start", json!(s.name()));
    put("git", json!(env.git));
    put("threads", json!(env.threads));
    r
}

#[allow(clippy::too_many_arguments)]
fn run_start(
    env: &Env,
    place: &Place,
    c: &CaseRef,
    ps: &PlaceSpec,
    v: Variant,
    start: Start,
    geo: &Geo,
    cells: &[(f64, f64)],
    out: &mut std::fs::File,
) -> R<()> {
    let fine_dom = domain_for(place, &env.cfg).map_err(es)?;
    let fine = build_lvl(env, place, &fine_dom, c, v, true)?;
    let st = fine.stats.as_ref().ok_or("no stats")?;
    let mut r = base_record(env, c, ps, v, start);
    let (u10, wstar) = (st.u10, fine.wstar);
    for (k, x) in [
        ("u10", json!(u10)),
        ("fr", json!(st.fr)),
        ("n_bv", json!(st.n_bv)),
        ("relief_m", json!(st.relief)),
        ("wstar", json!(wstar)),
        ("scale", json!(u10.max(wstar))),
    ] {
        r.insert(k.into(), x);
    }
    let t0 = Instant::now();
    let si = make_start(env, place, c, v, &fine, start);
    let t_start = if start == Start::Bg {
        0.0
    } else {
        t0.elapsed().as_secs_f64()
    };
    let si = match si {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{} {} {}: start failed: {e}", c.id, v.name(), start.name());
            for (k, x) in [
                ("status", json!("start_failed")),
                ("start_err", json!(e)),
                ("t_start_s", json!(t_start)),
            ] {
                r.insert(k.into(), x);
            }
            writeln!(out, "{}", Value::Object(r)).map_err(es)?;
            return out.flush().map_err(es);
        }
    };
    let sn = &env.spec.snap;
    let pts = analysis::snap_points(sn.every, env.spec.max_iters);
    let opts = SolveOpts {
        threads: env.threads,
        max_iters: env.spec.max_iters,
        tol_scale: env.cfg.tol_scale,
        init: si.init,
        snapshot_at: pts.clone(),
        outflow: v.outflow(),
        ..SolveOpts::default()
    };
    let sol = solve(&fine.case, &opts).map_err(|e| format!("solve: {e:#}"))?;
    let status = status_of(sol.stop);
    let tm = &sol.timing;
    let t_snap = (tm.total_s - tm.setup_s - tm.iter_s - tm.check_s).max(0.0);
    for (k, x) in [
        ("status", json!(status)),
        ("iters", json!(sol.iters)),
        ("t_solve_s", json!(tm.total_s)),
        ("t_start_s", json!(t_start)),
        ("t_setup_s", json!(tm.setup_s)),
        ("t_iter_s", json!(tm.iter_s)),
        ("t_check_s", json!(tm.check_s)),
        ("t_snap_s", json!(t_snap)),
        ("start_iters", json!(si.iters)),
    ] {
        r.insert(k.into(), x);
    }
    r.insert("start_err".into(), Value::Null);
    let hist: Vec<Value> = sol
        .history
        .iter()
        .map(|h| {
            json!([
                h.it,
                h.res.mom_rms,
                h.res.mom_max,
                h.res.th_rms,
                h.res.thd_rms,
                h.res.div_rms
            ])
        })
        .collect();
    r.insert("res_hist".into(), Value::Array(hist));
    let ok = status == "ok";
    let reached = pts.iter().filter(|&&n| n <= sol.iters).count();
    if status == "diverged" || sol.snapshots.len() != reached {
        if status != "diverged" {
            eprintln!(
                "WARN {} {} {}: snapshots {} != {}",
                c.id,
                v.name(),
                start.name(),
                sol.snapshots.len(),
                reached
            );
        }
        for k in ["ref_kind", "err_hist", "inc_hist"] {
            r.insert(k.into(), Value::Null);
        }
    } else {
        let p = analysis::Params {
            nx: geo.nx,
            ny: geo.ny,
            edge: sn.edge_cells,
            every: sn.every,
            n_eval: &sn.n_eval,
            late_from: sn.late_from,
            late_step: sn.late_step,
        };
        let last = metrics::slice(geo, &sol.state, &AGL_M);
        let slices: Vec<Vec<f32>> = (0..pts.len())
            .map(|k| {
                sol.snapshots
                    .get(k)
                    .map_or_else(|| last.clone(), |s| metrics::slice(geo, s, &AGL_M))
            })
            .collect();
        let eff: Vec<&State> = (0..pts.len())
            .map(|k| sol.snapshots.get(k).unwrap_or(&sol.state))
            .collect();
        let a = analysis::analyze(&slices, &pts, &last, ok, &p, cells);
        for (k, x) in &a.fields {
            r.insert(k.clone(), x.clone());
        }
        r.insert("ref_kind".into(), json!(a.ref_kind));
        r.insert(
            "inc_hist".into(),
            Value::Array(analysis::inc_hist(geo, &eff, &slices, &pts, &p)),
        );
        if env.save_slices {
            let mut fl: Vec<(String, &[f32])> = vec![("ref".into(), a.reference.as_slice())];
            for &n in &sn.n_eval {
                if let Some(k) = pts.iter().position(|&x| x == n) {
                    fl.push((format!("n{n}"), slices[k].as_slice()));
                }
            }
            write_slices(env, c, v, start, geo, &fl, status, sol.iters, a.ref_kind)?;
        }
    }
    writeln!(out, "{}", Value::Object(r)).map_err(es)?;
    out.flush().map_err(es)?;
    eprintln!(
        "{} {:8} {:11} {:8} iters {:4} t_start {:7.1} s t_solve {:7.1} s (snap {:5.1} s) start_iters {:?}",
        c.id,
        v.name(),
        start.name(),
        status,
        sol.iters,
        t_start,
        tm.total_s,
        t_snap,
        si.iters
    );
    Ok(())
}

// ---------------------------------------------------------------- запуск

struct Args {
    spec: PathBuf,
    variants: Vec<Variant>,
    starts: Option<Vec<Start>>,
    out: Option<PathBuf>,
    raw: PathBuf,
    save_slices: bool,
    shard: (usize, usize),
    threads: Option<usize>,
    list: bool,
}

fn parse_args() -> R<Args> {
    let mut a = std::env::args().skip(1);
    let mut r = Args {
        spec: PathBuf::new(),
        variants: Variant::ALL.to_vec(),
        starts: None,
        out: None,
        raw: std::env::var_os("OBC_RAW")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var("HOME").unwrap_or_default()).join("data/outflow_bc")
            }),
        save_slices: false,
        shard: (0, 1),
        threads: None,
        list: false,
    };
    while let Some(k) = a.next() {
        let mut val = || a.next().ok_or(format!("{k}: value expected"));
        match k.as_str() {
            "--spec" => r.spec = val()?.into(),
            "--variants" => r.variants = val()?.split(',').map(Variant::parse).collect::<R<_>>()?,
            "--starts" => r.starts = Some(val()?.split(',').map(Start::parse).collect::<R<_>>()?),
            "--out" => r.out = Some(val()?.into()),
            "--raw" => r.raw = val()?.into(),
            "--save-slices" => r.save_slices = true,
            "--shard" => {
                let s = val()?;
                let (i, n) = s.split_once('/').ok_or("--shard i/n")?;
                r.shard = (i.parse().map_err(es)?, n.parse().map_err(es)?);
                if r.shard.1 == 0 || r.shard.0 >= r.shard.1 {
                    return Err("--shard i/n: 0 <= i < n".into());
                }
            }
            "--threads" => r.threads = Some(val()?.parse().map_err(es)?),
            "--list" => r.list = true,
            other => return Err(format!("unknown argument '{other}'")),
        }
    }
    if r.spec.as_os_str().is_empty() {
        return Err("--spec is required".into());
    }
    Ok(r)
}

/// Готовые тройки `case_id`+`variant`+`start` в файле записей.
fn done_keys(out: &Path) -> HashSet<(String, String, String)> {
    let mut s = HashSet::new();
    if let Ok(t) = std::fs::read_to_string(out) {
        for l in t.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(l)
                && let (Some(c), Some(w), Some(st)) = (
                    v["case_id"].as_str(),
                    v["variant"].as_str(),
                    v["start"].as_str(),
                )
            {
                s.insert((c.to_string(), w.to_string(), st.to_string()));
            }
        }
    }
    s
}

fn real_main() -> R<()> {
    let args = parse_args()?;
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let spec: Spec =
        serde_json::from_str(&std::fs::read_to_string(&args.spec).map_err(es)?).map_err(es)?;
    spec.check()?;
    let all = enumerate(&spec)?;
    let mine: Vec<(usize, &CaseRef)> = all
        .iter()
        .enumerate()
        .filter(|(n, _)| n % args.shard.1 == args.shard.0)
        .collect();
    let starts: Vec<Start> = {
        let in_spec: Vec<Start> = spec
            .starts
            .iter()
            .map(|s| Start::parse(s))
            .collect::<R<_>>()?;
        let want = args.starts.clone().unwrap_or_else(|| in_spec.clone());
        Start::ALL
            .into_iter()
            .filter(|s| want.contains(s) && in_spec.contains(s))
            .collect()
    };
    if args.list {
        for (_, c) in &mine {
            println!("{}", c.id);
        }
        eprintln!(
            "{} of {} cases, {} variants, starts {:?}",
            mine.len(),
            all.len(),
            args.variants.len(),
            starts.iter().map(|s| s.name()).collect::<Vec<_>>()
        );
        return Ok(());
    }
    let configs = configs(&repo);
    let cfg = RtCfg::from_configs(&configs).map_err(es)?;
    let out_path = args
        .out
        .unwrap_or_else(|| args.raw.join("stage2").join("stage2.jsonl"));
    let env = Env {
        threads: args.threads.unwrap_or(spec.threads),
        spec,
        cfg,
        configs,
        git: git_rev(&repo),
        repo,
        out: out_path,
        raw: args.raw,
        save_slices: args.save_slices,
    };
    if let Some(d) = env.out.parent() {
        std::fs::create_dir_all(d).map_err(es)?;
    }
    let done = done_keys(&env.out);
    let mut out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&env.out)
        .map_err(es)?;
    let mut cache: Option<((usize, u64), Place)> = None;
    let (t0, mut n_rec) = (Instant::now(), 0usize);
    for (n, c) in mine {
        let pending: Vec<(Variant, Start)> = Variant::ALL
            .into_iter()
            .filter(|v| args.variants.contains(v))
            .flat_map(|v| starts.iter().map(move |&s| (v, s)))
            .filter(|(v, s)| !done.contains(&(c.id.clone(), v.name().into(), s.name().into())))
            .collect();
        if pending.is_empty() {
            continue;
        }
        let ps = &env.spec.places[c.pi];
        let key = (c.pi, c.dir.to_bits());
        if cache.as_ref().is_none_or(|(k, _)| *k != key) {
            drop(cache.take());
            cache = Some((key, load_place(&env, ps, c.dir)?));
        }
        let place = &cache.as_ref().unwrap().1;
        let fine_dom = domain_for(place, &env.cfg).map_err(es)?;
        let g = build_lvl(&env, place, &fine_dom, c, Variant::Hard, false)
            .map_err(|e| format!("{}: {e}", c.id))?;
        let geo = Geo::from_planes(&g.planes);
        drop(g);
        let cells: Vec<(f64, f64)> = sites_of(ps, place, c.dir)?
            .iter()
            .filter_map(|&(x, y)| metrics::site_cell(&geo, x, y))
            .collect();
        eprintln!("[{n}/{}] {}", all.len(), c.id);
        for (v, s) in pending {
            run_start(&env, place, c, ps, v, s, &geo, &cells, &mut out)
                .map_err(|e| format!("{} {} {}: {e}", c.id, v.name(), s.name()))?;
            n_rec += 1;
        }
        eprintln!("-- {n_rec} records, {:.0} s", t0.elapsed().as_secs_f64());
    }
    Ok(())
}

fn main() {
    if let Err(e) = real_main() {
        eprintln!("outflow_stage2: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_spec(name: &str) -> Spec {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tools/research/outflow_bc")
            .join(name);
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    #[test]
    fn case_id_format() {
        assert_eq!(case_id("ongudai", 45.0, 1.5, true), "ongudai_d045_u015_h");
        assert_eq!(case_id("x", 0.0, 9.0, false), "x_d000_u090_m");
    }

    #[test]
    fn starts_and_variants_parse() {
        for s in Start::ALL {
            assert_eq!(Start::parse(s.name()).unwrap(), s);
        }
        assert!(Start::parse("x").is_err());
        assert_eq!(Variant::parse("soft_ns").unwrap(), Variant::SoftNs);
    }

    #[test]
    fn full_spec_is_90_cases() {
        let s = read_spec("corpus_stage2.json");
        s.check().unwrap();
        let all = enumerate(&s).unwrap();
        assert_eq!(all.len(), 90);
        let ids: HashSet<&str> = all.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids.len(), 90);
        assert!(ids.contains("ongudai_d225_u005_m") && ids.contains("ridge_h600_d270_u060_h"));
        assert_eq!(s.starts.len(), 5);
        assert_eq!(s.snap.n_eval, vec![50, 100, 200, 300]);
    }

    #[test]
    fn pilot_spec_is_two_cases() {
        let s = read_spec("corpus_stage2_pilot.json");
        s.check().unwrap();
        let all = enumerate(&s).unwrap();
        let ids: Vec<&str> = all.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["ongudai_d000_u010_h", "hill_h300_d270_u060_m"]);
        assert_eq!((s.max_iters, s.snap.late_from), (300, 150));
    }

    #[test]
    fn spec_check_rejects_bad_n_eval() {
        let mut s = read_spec("corpus_stage2_pilot.json");
        s.snap.n_eval = vec![55];
        assert!(s.check().is_err());
        s.snap.n_eval = vec![400];
        assert!(s.check().is_err());
    }

    // ---- интеграция: старты на настоящем месте (холм 300 м; быстрый — несколько секунд)

    fn test_env() -> Env {
        let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut spec = read_spec("corpus_stage2_pilot.json");
        spec.max_iters = 20;
        let configs = configs(&repo);
        let cfg = RtCfg::from_configs(&configs).unwrap();
        Env {
            threads: 2,
            spec,
            cfg,
            configs,
            git: String::new(),
            repo,
            out: PathBuf::new(),
            raw: PathBuf::new(),
            save_slices: false,
        }
    }

    fn hill_case(env: &Env) -> (Place, CaseRef, usize) {
        let pi = env
            .spec
            .places
            .iter()
            .position(|p| p.id == "hill_h300")
            .unwrap();
        let c = CaseRef {
            pi,
            dir: 270.0,
            u10: 6.0,
            heat: false,
            id: case_id("hill_h300", 270.0, 6.0, false),
        };
        let place = load_place(env, &env.spec.places[pi], 270.0).unwrap();
        (place, c, pi)
    }

    #[test]
    fn coarse3_init_equals_runtime_continuation() {
        let env = test_env();
        let (place, c, _) = hill_case(&env);
        let fine_dom = domain_for(&place, &env.cfg).unwrap();
        assert_eq!((fine_dom.nx, fine_dom.dx), (96, 400.0));
        let fine = build_lvl(&env, &place, &fine_dom, &c, Variant::Hard, false).unwrap();
        let si = make_start(&env, &place, &c, Variant::Hard, &fine, Start::Coarse3).unwrap();
        // то же вручную, как coarse_start: Пикар на 1200 м и prolong_to
        let cd = coarse_domain(&fine_dom, 3);
        assert_eq!((cd.nx, cd.dx), (32, 1200.0));
        let cl = build_lvl(&env, &place, &cd, &c, Variant::Hard, false).unwrap();
        let sm = solve(
            &cl.case,
            &SolveOpts {
                threads: env.cfg.threads,
                max_iters: env.cfg.max_iters,
                tol_scale: env.cfg.tol_scale,
                ..SolveOpts::default()
            },
        )
        .unwrap();
        let want = prolong_to(
            &level_of(&cl.planes, &cd),
            &sm.state,
            &level_of(&fine.planes, &fine_dom),
        )
        .unwrap();
        let got = si.init.unwrap();
        assert_eq!(si.iters, vec![sm.iters]);
        assert_eq!(got.dims, want.dims);
        for (a, b) in [
            (&got.u, &want.u),
            (&got.v, &want.v),
            (&got.w, &want.w),
            (&got.th, &want.th),
            (&got.p, &want.p),
        ] {
            assert!(a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits()));
        }
        assert_eq!(got.dims, [fine.case.nxh, fine.case.nyh, fine.case.nzh]);
    }

    #[test]
    fn phase_warm_and_chain_dims() {
        let env = test_env();
        let (place, c, _) = hill_case(&env);
        let fine_dom = domain_for(&place, &env.cfg).unwrap();
        let fine = build_lvl(&env, &place, &fine_dom, &c, Variant::Hard, true).unwrap();
        let w = phase_warm(&env, &fine).unwrap();
        assert_eq!(w.dims, [fine.case.nxh, fine.case.nyh, fine.case.nzh]);
        let st = fine.stats.as_ref().unwrap();
        assert!(st.u10 > 5.9 && st.relief > 250.0 && fine.wstar == 0.0);
        // сборка фаз на 1600 м (первая ступень chain_phase)
        let cd = coarse_domain(&fine_dom, 4);
        assert_eq!((cd.nx, cd.dx), (24, 1600.0));
        let cl = build_lvl(&env, &place, &cd, &c, Variant::Hard, false).unwrap();
        let w4 = phase_warm(&env, &cl).unwrap();
        assert_eq!(w4.dims, [cl.case.nxh, cl.case.nyh, cl.case.nzh]);
    }
}
