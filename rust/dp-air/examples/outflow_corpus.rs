//! OBC-2: стенд корпуса outflow-bc (контракты OB1/OB2/OB3, `docs/contracts/outflow-bc.md`).
//!
//! По спецификации корпуса (`tools/research/outflow_bc/corpus.json`) строит случаи области 400 м (места игры и
//! идеальные формы), решает варианты `hard` / `soft` / `soft_ns` чистым Пикаром (`picard_rs`, без заморозки
//! фаз, запасных правил и окон) и пишет записи OB2 (`cases.jsonl`, построчно) и резы полей OB3
//! (`<raw>/slices/<case_id>__<variant>.bin|json`).
//!
//! ## Сборка случая (как игра, без Godot; цепочка режима B теста `tests/case_prepare.rs`)
//! место (`fixtures::read_place` или идеальная форма в памяти, `ideal.rs`) → `domain_for` (96 × 96 клеток по
//! 400 м) → `field_weather` (условия: прогноз `u10`, `dir`, ясно, `t_max_c`; час `hour`, `speed = 1`) →
//! `build_domain_input` → `build_case` (`CaseOpts { k, Start, heat: true }`; без нагрева — `without_heat()`, как
//! `runtime::build_level`) → `prepare` → `build_solver_case` → `picard_rs::api::solve`. `k` — множитель притока
//! первого прохода игры (по умолчанию `INFLOW_K_MAX = 1`; подбор `k` вторым проходом не делается).
//! Параметры решателя — как у игры: `tol_scale` из `air.tol_scale` конфига, `max_iters` из спецификации.
//!
//! ## Варианты
//! `hard` — `Outflow::Hard`; `soft` — `Outflow::Soft`, губки как в игре; `soft_ns` — `Outflow::Soft` и боковая
//! губка импульса только у приточных граней: `sp_u = max(губка потолка центра, C_SCS)`,
//! `sp_w = max(губка потолка грани w, C_SCS)` (как θ в `case_build.rs`, блок «губки»). Плоскости — по докстрингу
//! `case_prepare.rs` (стр. 20–21): `col` 7 = губка по ветру (`C_SCS`), `lev` 3 = губка верха (центр, `L_SPZ`),
//! `lev` 4 = губка верха (грань, `L_SPZW`). `Kx/Ky/Kz` (весá SIMPLEC проекции) не пересчитываются — в `src` их
//! строит `build_solver_case` по боковой губке игры.
//!
//! ## Fr, N, рельеф
//! `phase::prepare::prepare` (то же, что `PhaseStats` в `assemble`): `n_bv` — N над слоем перемешивания,
//! `relief` = max − min рельефа области, `fr = U_a / (N · max(relief, 1 м))`, `Fr = fr_inf` (1000) при `N = 0`
//! (`phase/prepare.rs`, стр. ~436–454).
//!
//! ## Запуск
//! `cargo run --release -p dp-air --example outflow_corpus -- --spec S.json --variants hard,soft,soft_ns --out
//! cases.jsonl --raw DIR [--save-slices] [--shard i/n] [--threads N] [--start bg] [--list]`.
//! Повтор пропускает готовые пары `case_id` + `variant`. Для вариантов `soft*` нужен эталон `hard` того же случая
//! (метрики `d_*`): из этого же запуска, иначе — из рез `hard` в `<raw>/slices` (нужен `--save-slices` в первом
//! запуске), иначе `hard` решается заново без записи.
//!
//! Этап 2 плана (OB2 v2): ключ `--start` пока принимает только `bg` (холодный старт); код метрик (`metrics.rs`)
//! принимает срезы, а не решатель, и пригоден для сравнения любого снимка с эталоном.
#[path = "outflow_corpus/ideal.rs"]
mod ideal;
#[path = "outflow_corpus/metrics.rs"]
mod metrics;

use dp_air::field::case_build::{SolverCfg, build_solver_case};
use dp_air::field::case_prepare::{CaseOpts, PreparedPlanes, build_case};
use dp_air::field::phase::prepare::{PhaseCase, prepare as phase_prepare};
use dp_air::field::place_input::build_domain_input;
use dp_air::field::runtime::{RtCfg, domain_for};
use dp_air::field::weather_core::{field_weather, hour_at};
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, InflowMode, Place};
use metrics::{AGL_M, Geo, SPREAD_AGL_M};
use picard_rs::api::{Outflow, SolveOpts, StopReason, solve};
use picard_rs::case::Case;
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
struct Late {
    from: usize,
    step: usize,
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
    late: Late,
    threads: usize,
    /// Дневной максимум температуры, °C (ключ прогноза).
    #[serde(default = "d_t_max")]
    t_max_c: f64,
    #[serde(default = "d_sky")]
    sky: String,
    /// Множитель притока `k` (первый проход игры — 1).
    #[serde(default = "d_k")]
    k: f64,
    /// Явный список случаев (пилот) вместо произведения places × dirs × u10 × heat.
    cases: Option<Vec<CaseSpec>>,
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

// ---------------------------------------------------------------- варианты

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
}

/// `soft_ns`: боковая губка импульса `sp_u`, `sp_w` — как губка θ (`C_SCS`), только у приточных граней.
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

/// Точки стартов (восток, север), м: у места — `start_sites` заголовка (`y = −z`), у идеальных — вершина,
/// середина наветренного и подветренного склона.
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

// ---------------------------------------------------------------- сборка случая

struct Built {
    planes: PreparedPlanes,
    case: Case,
    stats: Stats,
}

struct Stats {
    u10: f64,
    fr: f64,
    n_bv: f64,
    relief: f64,
}

fn build(env: &Env, place: &Place, dir: f64, u10: f64, heat: bool) -> R<Built> {
    let cfg = &env.cfg;
    let dom = domain_for(place, cfg).map_err(es)?;
    let cond = Conditions::from_json(
        &json!({
            "forecast": {"temperature_c": env.spec.t_max_c, "wind_speed_kmh": u10 * 3.6, "wind_from_deg": dir, "sky": env.spec.sky},
            "quantum_h": 0.5, "speed": 1.0, "start_hour": env.spec.hour
        })
        .to_string(),
    )
    .map_err(es)?;
    let hour = hour_at(&cond, 0.0);
    let fw = field_weather(
        &cond,
        place,
        &cfg.wc,
        &env.configs,
        &cfg.climate,
        hour,
        &dom,
    )
    .map_err(es)?;
    let inp = build_domain_input(place, &cfg.wc.sh, &cfg.zi, &dom, &fw.day).map_err(es)?;
    let heat_case = build_case(
        &inp,
        &fw,
        &CaseOpts {
            k: env.spec.k,
            inflow_mode: InflowMode::Start,
            heat: true,
        },
    )
    .map_err(es)?;
    let ac = if heat {
        heat_case
    } else {
        heat_case.without_heat()
    };
    let planes = ac.prepare().map_err(es)?;
    let case = build_solver_case(&planes, &ac.p, &SolverCfg::new(ac.u10)).map_err(es)?;
    // Fr, N, рельеф — как PhaseStats (phases_of в runtime.rs)
    let (nx, n) = (ac.dom.nx, ac.dom.nx * ac.dom.ny);
    let inner = |plane: &[f32]| -> Vec<f64> {
        (0..n)
            .map(|c| f64::from(plane[(c / nx + 1) * planes.nx_h + c % nx + 1]))
            .collect()
    };
    let (h_bl, wst) = (inner(planes.col_plane(2)), inner(planes.col_plane(3)));
    let zic: Vec<f64> = ac.z_i_col.iter().map(|&v| f64::from(v)).collect();
    let pr = phase_prepare(
        &PhaseCase {
            nx,
            ny: ac.dom.ny,
            nz: ac.nz,
            dx: ac.dom.dx,
            dz: ac.dz,
            z_bot: ac.z_bot,
            ex: planes.ex,
            ey: planes.ey,
            u_a: planes.u_a,
            z_sat: f64::from(planes.prm[12]),
            alpha: planes.alpha,
            z0: planes.z0,
            ustar: planes.ustar,
            tau_cool: ac.p.tau_cool,
            u10: ac.u10,
            z_i: ac.z_i,
            hc: &ac.hc,
            gam: &ac.gam,
            heat: &ac.heat,
            heat_used: &planes.heat_used,
            h_bl: &h_bl,
            wst: &wst,
            z_i_col: &zic,
            g: None,
        },
        &cfg.phase,
    )?;
    let stats = Stats {
        u10: pr.u10,
        fr: pr.fr,
        n_bv: pr.n_bv,
        relief: pr.relief,
    };
    Ok(Built {
        planes,
        case,
        stats,
    })
}

// ---------------------------------------------------------------- резы OB3 и записи OB2

fn slice_paths(raw: &Path, id: &str, v: Variant) -> (PathBuf, PathBuf) {
    let d = raw.join("slices");
    (
        d.join(format!("{id}__{}.bin", v.name())),
        d.join(format!("{id}__{}.json", v.name())),
    )
}

fn write_atomic(path: &Path, data: &[u8]) -> R<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, data).map_err(es)?;
    std::fs::rename(&tmp, path).map_err(es)
}

fn write_slices(
    env: &Env,
    c: &CaseRef,
    v: Variant,
    g: &Geo,
    s: &[f32],
    status: &str,
    iters: usize,
) -> R<()> {
    std::fs::create_dir_all(env.raw.join("slices")).map_err(es)?;
    let (bin, js) = slice_paths(&env.raw, &c.id, v);
    let bytes: Vec<u8> = s.iter().flat_map(|x| x.to_le_bytes()).collect();
    write_atomic(&bin, &bytes)?;
    let meta = json!({"version": 1, "nx": g.nx, "ny": g.ny, "dx_m": g.dx, "agl_m": AGL_M, "comps": ["u", "v", "w"],
        "case_id": c.id, "variant": v.name(), "status": status, "iters": iters});
    write_atomic(&js, meta.to_string().as_bytes())
}

/// Эталон `hard` для сравнений: срез (3 высоты) и сошёлся ли.
struct RefField {
    slices: Vec<f32>,
    ok: bool,
}

fn load_ref(env: &Env, c: &CaseRef, np: usize) -> Option<RefField> {
    let (bin, js) = slice_paths(&env.raw, &c.id, Variant::Hard);
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(js).ok()?).ok()?;
    let b = std::fs::read(bin).ok()?;
    if b.len() != 4 * 9 * np {
        return None;
    }
    let slices = b
        .chunks_exact(4)
        .map(|x| f32::from_le_bytes([x[0], x[1], x[2], x[3]]))
        .collect();
    Some(RefField {
        slices,
        ok: meta["status"] == "ok",
    })
}

fn status_of(s: StopReason) -> &'static str {
    match s {
        StopReason::Cancelled => "cancelled",
        other => other.status(),
    }
}

/// Номера итераций снимков позднего разброса: from, from + step, …, предел (кратный check_every = 10).
fn late_points(late: &Late, max_iters: usize) -> Vec<usize> {
    let limit = max_iters.div_ceil(10) * 10;
    let mut v: Vec<usize> = (late.from..=limit).step_by(late.step.max(1)).collect();
    if v.last() != Some(&limit) {
        v.push(limit);
    }
    v
}

#[allow(clippy::too_many_arguments)]
fn run_variant(
    env: &Env,
    c: &CaseRef,
    ps: &PlaceSpec,
    b: &mut Built,
    geo: &Geo,
    sites: &[(f64, f64)],
    v: Variant,
    reference: Option<&RefField>,
    write_record: bool,
    out: &mut std::fs::File,
) -> R<Option<RefField>> {
    let pts = late_points(&env.spec.late, env.spec.max_iters);
    if v == Variant::SoftNs {
        apply_soft_ns(&mut b.case, &b.planes)?;
    }
    let opts = SolveOpts {
        threads: env.threads,
        max_iters: env.spec.max_iters,
        tol_scale: env.cfg.tol_scale,
        snapshot_at: pts.clone(),
        outflow: if v == Variant::Hard {
            Outflow::Hard
        } else {
            Outflow::Soft
        },
        ..SolveOpts::default()
    };
    let sol = solve(&b.case, &opts).map_err(|e| format!("solve: {e:#}"))?;
    let status = status_of(sol.stop);
    let t_solve = sol.timing.total_s;
    let cur = metrics::slice(geo, &sol.state, &AGL_M);
    if env.save_slices {
        write_slices(env, c, v, geo, &cur, status, sol.iters)?;
    }
    let edge = env.spec.late.edge_cells;
    let spread = match status {
        "ok" => json!(0.0),
        "max" if sol.snapshots.len() == pts.len() => {
            let sn: Vec<Vec<f32>> = sol
                .snapshots
                .iter()
                .map(|s| metrics::slice(geo, s, &[SPREAD_AGL_M]))
                .collect();
            json!(metrics::late_spread_p90(&sn, geo.nx, geo.ny, edge))
        }
        "max" => {
            eprintln!(
                "WARN {} {}: snapshots {} != {}",
                c.id,
                v.name(),
                sol.snapshots.len(),
                pts.len()
            );
            Value::Null
        }
        _ => Value::Null,
    };
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
    put("git", json!(env.git));
    put("status", json!(status));
    put("iters", json!(sol.iters));
    put("t_solve_s", json!(t_solve));
    put("threads", json!(env.threads));
    put("u10", json!(b.stats.u10));
    put("fr", json!(b.stats.fr));
    put("n_bv", json!(b.stats.n_bv));
    put("relief_m", json!(b.stats.relief));
    put("late_spread60_p90", spread);
    let od = sol.outflow;
    put("faces_out", json!(od.map(|o| o.faces_out)));
    put("flux_in", json!(od.map(|o| o.flux_in)));
    put("flux_net_max_rel", json!(od.map(|o| o.flux_net_max_rel)));
    put("backflow_faces", json!(od.map(|o| o.backflow_faces)));
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
    put("res_hist", Value::Array(hist));
    // сравнение с hard
    let cells: Vec<(f64, f64)> = sites
        .iter()
        .filter_map(|&(x, y)| metrics::site_cell(geo, x, y))
        .collect();
    match (v, reference) {
        (Variant::Hard, _) | (_, None) => {
            put("both_ok", Value::Null);
            for a in AGL_M {
                let a = a as i64;
                for k in [
                    format!("d_start_{a}_max"),
                    format!("d_int_{a}_rms"),
                    format!("d_int_{a}_p99"),
                    format!("d_int_{a}_max"),
                    format!("d_band_{a}_max"),
                    format!("d_int_{a}_max_rel"),
                ] {
                    put(&k, Value::Null);
                }
            }
        }
        (_, Some(rf)) => {
            put("both_ok", json!(rf.ok && status == "ok"));
            for (hi, a) in AGL_M.iter().enumerate() {
                let a = *a as i64;
                let m = metrics::compare(&cur, &rf.slices, hi, geo.nx, geo.ny, edge, &cells);
                put(&format!("d_start_{a}_max"), json!(m.start_max));
                put(&format!("d_int_{a}_rms"), json!(m.int_rms));
                put(&format!("d_int_{a}_p99"), json!(m.int_p99));
                put(&format!("d_int_{a}_max"), json!(m.int_max));
                put(&format!("d_band_{a}_max"), json!(m.band_max));
                put(
                    &format!("d_int_{a}_max_rel"),
                    json!(m.int_max / b.stats.u10),
                );
            }
        }
    }
    // Q5: полоса у граней выхода, у всех вариантов
    for (hi, a) in AGL_M.iter().enumerate() {
        let e = metrics::edge_out(&cur, hi, geo.nx, geo.ny, edge, b.planes.ex, b.planes.ey);
        put(
            &format!("edge_out_{}_un_mean", *a as i64),
            json!(e.map(|x| x.0)),
        );
        put(
            &format!("edge_out_{}_back_frac", *a as i64),
            json!(e.map(|x| x.1)),
        );
    }
    if write_record {
        writeln!(out, "{}", Value::Object(r)).map_err(es)?;
        out.flush().map_err(es)?;
    }
    eprintln!(
        "{} {:8} {:8} iters {:4} t {:7.1} s{}",
        c.id,
        v.name(),
        status,
        sol.iters,
        t_solve,
        od.map_or(String::new(), |o| format!(
            "  flux_net {:.1e} back {}",
            o.flux_net_max_rel, o.backflow_faces
        ))
    );
    Ok((v == Variant::Hard).then(|| RefField {
        slices: cur,
        ok: status == "ok",
    }))
}

// ---------------------------------------------------------------- запуск

struct Args {
    spec: PathBuf,
    variants: Vec<Variant>,
    out: PathBuf,
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
        out: PathBuf::from("cases.jsonl"),
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
            "--out" => r.out = val()?.into(),
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
            "--start" => {
                let s = val()?;
                if s != "bg" {
                    return Err(format!(
                        "--start {s}: only 'bg' (cold start) is implemented"
                    ));
                }
            }
            "--list" => r.list = true,
            other => return Err(format!("unknown argument '{other}'")),
        }
    }
    if r.spec.as_os_str().is_empty() {
        return Err("--spec is required".into());
    }
    Ok(r)
}

/// Готовые пары `case_id`+`variant` в файле записей.
fn done_pairs(out: &Path) -> HashSet<(String, String)> {
    let mut s = HashSet::new();
    if let Ok(t) = std::fs::read_to_string(out) {
        for l in t.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(l)
                && let (Some(c), Some(w)) = (v["case_id"].as_str(), v["variant"].as_str())
            {
                s.insert((c.to_string(), w.to_string()));
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
    let all = enumerate(&spec)?;
    let mine: Vec<(usize, &CaseRef)> = all
        .iter()
        .enumerate()
        .filter(|(n, _)| n % args.shard.1 == args.shard.0)
        .collect();
    if args.list {
        for (_, c) in &mine {
            println!("{}", c.id);
        }
        eprintln!(
            "{} of {} cases, {} variants",
            mine.len(),
            all.len(),
            args.variants.len()
        );
        return Ok(());
    }
    let configs = configs(&repo);
    let cfg = RtCfg::from_configs(&configs).map_err(es)?;
    let env = Env {
        threads: args.threads.unwrap_or(spec.threads),
        spec,
        cfg,
        configs,
        git: git_rev(&repo),
        repo,
        out: args.out,
        raw: args.raw,
        save_slices: args.save_slices,
    };
    if let Some(d) = env.out.parent() {
        std::fs::create_dir_all(d).map_err(es)?;
    }
    let done = done_pairs(&env.out);
    let mut out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&env.out)
        .map_err(es)?;
    let mut cache: Option<((usize, u64), Place)> = None;
    let (t0, mut pairs) = (Instant::now(), 0usize);
    for (n, c) in mine {
        let want: Vec<Variant> = Variant::ALL
            .into_iter()
            .filter(|v| args.variants.contains(v))
            .collect();
        let pending: Vec<Variant> = want
            .iter()
            .copied()
            .filter(|v| !done.contains(&(c.id.clone(), v.name().to_string())))
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
        let mut b =
            build(&env, place, c.dir, c.u10, c.heat).map_err(|e| format!("{}: {e}", c.id))?;
        let geo = Geo::from_planes(&b.planes);
        let sites = sites_of(ps, place, c.dir)?;
        eprintln!(
            "[{n}/{}] {} fr {:.3} n_bv {:.4} relief {:.0} m",
            all.len(),
            c.id,
            b.stats.fr,
            b.stats.n_bv,
            b.stats.relief
        );
        // эталон hard нужен soft*: из этого же запуска, из рез или решается заново без записи
        let mut reference: Option<RefField> = None;
        let need_ref = pending.iter().any(|v| *v != Variant::Hard);
        if need_ref && !pending.contains(&Variant::Hard) {
            reference = load_ref(&env, c, geo.nx * geo.ny);
        }
        let mut order: Vec<(Variant, bool)> = pending.iter().map(|&v| (v, true)).collect();
        if need_ref
            && reference.is_none()
            && !pending.contains(&Variant::Hard)
            && want.contains(&Variant::Hard)
        {
            order.insert(0, (Variant::Hard, false));
        }
        for (v, rec) in order {
            let got = run_variant(
                &env,
                c,
                ps,
                &mut b,
                &geo,
                &sites,
                v,
                reference.as_ref(),
                rec,
                &mut out,
            )
            .map_err(|e| format!("{} {}: {e}", c.id, v.name()))?;
            if got.is_some() {
                reference = got;
            }
            if rec {
                pairs += 1;
            }
        }
        eprintln!("-- {} pairs, {:.0} s", pairs, t0.elapsed().as_secs_f64());
    }
    Ok(())
}

fn main() {
    if let Err(e) = real_main() {
        eprintln!("outflow_corpus: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn case_id_format() {
        assert_eq!(case_id("ongudai", 45.0, 1.5, true), "ongudai_d045_u015_h");
        assert_eq!(
            case_id("hill_h300", 270.0, 0.5, false),
            "hill_h300_d270_u005_m"
        );
        assert_eq!(case_id("x", 0.0, 9.0, false), "x_d000_u090_m");
    }

    #[test]
    fn late_points_end_at_the_limit() {
        let l = Late {
            from: 500,
            step: 50,
            edge_cells: 5,
        };
        let p = late_points(&l, 1000);
        assert_eq!(p.len(), 11);
        assert_eq!((p[0], p[10]), (500, 1000));
        assert_eq!(late_points(&l, 1005).last(), Some(&1010));
    }

    #[test]
    fn enumerate_product_and_explicit() {
        let t = r#"{"places":[{"id":"a","kind":"real","dirs_deg":[0,90]},{"id":"b","kind":"real","dirs_deg":[270]}],
            "u10_ms":[1,2],"heat":[false,true],"hour":13,"max_iters":1000,
            "late":{"from":500,"step":50,"edge_cells":5},"threads":8}"#;
        let mut s: Spec = serde_json::from_str(t).unwrap();
        assert_eq!(enumerate(&s).unwrap().len(), (2 + 1) * 2 * 2);
        s.cases = Some(vec![CaseSpec {
            place: "b".into(),
            dir_deg: 270.0,
            u10_ms: 1.0,
            heat: true,
        }]);
        let v = enumerate(&s).unwrap();
        assert_eq!((v.len(), v[0].id.as_str()), (1, "b_d270_u010_h"));
    }

    #[test]
    fn variants_parse() {
        assert_eq!(Variant::parse("soft_ns").unwrap(), Variant::SoftNs);
        assert!(Variant::parse("x").is_err());
    }
}
