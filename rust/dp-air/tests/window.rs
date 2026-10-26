//! RW-6n: окна клипмапа 100/50 м (Rust) против GDScript и GPU игры на Онгудае. Дамп:
//! `tools/research/rust_wind/dump_window.sh` (rust/dp-air/tests/data/window: `inputs.*` — вход и
//! плоскости prepare, CPU; `gpu.json` + `gpu.bin.zst` — результат GPU).
//!
//! A. «случай»: вход окна из дампа (рельеф, поток тепла, gam, z_i по столбцам, карта z0, α и
//!    max_profile) → `AirWindowCase::prepare` пар mech/heat обязан совпасть с плоскостями
//!    `AirWindowCase.prepare` (зона релаксации к родителю, P_NEST) — поэлементно.
//! B. «цепочка»: те же условия W5 → `field_weather` → `build_window_input` с `z_i` от поля области
//!    (рельеф, карта z0, поток тепла, gam, z_i по столбцам).
//! C. типы клеток и граней окна (`tcode`) — точно против GPU.
//! D. граница от родителя: `nest` + поток + поправка (`window_boundary`) против буферов GPU
//!    после `corr` (срез плоскостей k), число `net/area/corr`; Σ потока после поправки ≈ 0.
//! E. старт со сдвигом: прошлое окно (GPU) + `warm_from_previous` против состояния GPU сразу
//!    после `K_BC(init) + K_SHIFT`.
//! Допуски: числа входа и nest/flux/corr — 1e-5 от масштаба массива (порядок f32-арифметики
//! GPU и Rust различается: fma, редукция); типы — точно; поток после поправки — 1e-6 от потока
//! через грань.
use dp_air::field::case_prepare::{CaseOpts, PreparedPlanes};
use dp_air::field::place_input::ZiCfg;
use dp_air::field::weather_core::{
    Cells, Climate, ClimateCell, Domain, WeatherConfigs, field_weather, hour_at,
};
use dp_air::field::wind_profile::CaseProfile;
use dp_air::field::window::*;
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, InflowMode, Place};
use serde_json::Value;
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

struct Dump {
    meta: Value,
    bin: Vec<u8>,
}

impl Dump {
    fn inputs() -> Dump {
        let d = root().join("tests/data/window");
        Dump {
            meta: serde_json::from_str(&std::fs::read_to_string(d.join("inputs.json")).unwrap())
                .unwrap(),
            bin: std::fs::read(d.join("inputs.bin")).unwrap(),
        }
    }

    fn gpu() -> Dump {
        let d = root().join("tests/data/window");
        let packed = std::fs::read(d.join("gpu.bin.zst")).unwrap();
        let meta: Value =
            serde_json::from_str(&std::fs::read_to_string(d.join("gpu.json")).unwrap()).unwrap();
        let bin = zstd::decode_all(&packed[..]).unwrap();
        assert_eq!(bin.len() as u64, meta["raw_bytes"].as_u64().unwrap());
        Dump { meta, bin }
    }

    fn span(&self, k: &str, dtype: &str, size: usize) -> &[u8] {
        let a = &self.meta["arrays"][k];
        assert_eq!(a["dtype"], dtype, "{k}");
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        &self.bin[o..o + size * n]
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        self.span(k, "f64", 8)
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        self.span(k, "f32", 4)
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn u8s(&self, k: &str) -> Vec<u8> {
        self.span(k, "u8", 1).to_vec()
    }
}

fn num(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap_or_else(|| panic!("no number {k}"))
}

fn real_configs() -> Configs {
    let r = root().join("../..");
    let rd = |n: &str| std::fs::read_to_string(r.join("configs").join(n)).unwrap();
    Configs::new(vec![
        ("atmosphere".into(), rd("atmosphere.json")),
        ("surface_heat".into(), rd("surface_heat.json")),
        ("weather_model".into(), rd("weather_model.json")),
    ])
}

struct Table(Vec<(i64, i64, ClimateCell)>);

impl Climate for Table {
    fn cell(&self, _lat: f64, _lon: f64, month: i64, day: i64) -> ClimateCell {
        self.0
            .iter()
            .find(|(m, d, _)| *m == month && *d == day)
            .unwrap_or_else(|| panic!("no climate cell for {month}-{day}"))
            .2
    }
}

fn climate(v: &Value) -> Table {
    Table(
        v.as_array()
            .unwrap()
            .iter()
            .map(|c| {
                (
                    num(c, "month") as i64,
                    num(c, "day") as i64,
                    ClimateCell {
                        tx_c: num(c, "tx_c"),
                        dtr_k: num(c, "dtr_k"),
                        z_cell_m: num(c, "z_cell_m"),
                        has_hh1: c["has_hh1"].as_bool().unwrap(),
                        has_hh5: c["has_hh5"].as_bool().unwrap(),
                    },
                )
            })
            .collect(),
    )
}

/// Наибольшее |a − b| и наибольшее |b| двух массивов.
fn max_diff(got: &[f32], want: &[f32]) -> (f64, f64) {
    assert_eq!(got.len(), want.len(), "length");
    let (mut d, mut m) = (0.0f64, 0.0f64);
    for (g, w) in got.iter().zip(want) {
        assert!(g.is_finite(), "not finite");
        d = d.max((f64::from(*g) - f64::from(*w)).abs());
        m = m.max(f64::from(*w).abs());
    }
    (d, m)
}

/// Отличие от эталона не больше `tol` от масштаба эталона (с полом `floor`). Возвращает отн. отличие.
fn assert_close(tag: &str, got: &[f32], want: &[f32], tol: f64, floor: f64) -> f64 {
    let (d, m) = max_diff(got, want);
    let rel = d / m.max(floor);
    assert!(
        rel <= tol,
        "{tag}: max|Δ| {d:.3e} при масштабе {m:.3e} (отн. {rel:.2e} > {tol:.0e})"
    );
    rel
}

fn words_differ(got: &[f32], want: &[f32]) -> usize {
    got.iter()
        .zip(want)
        .filter(|(a, b)| a.to_bits() != b.to_bits())
        .count()
}

fn domain_of(w: &Value) -> Domain {
    Domain {
        x0: num(w, "x0"),
        y0: num(w, "y0"),
        nx: num(w, "nx") as usize,
        ny: num(w, "ny") as usize,
        dx: num(w, "dx"),
    }
}

fn opts_of(mode: &str) -> CaseOpts {
    CaseOpts {
        k: 1.0,
        inflow_mode: InflowMode::Start,
        heat: mode == "heat",
    }
}

/// Окно (heat, mech) из входа дампа — режим A.
fn window_a(inp: &Dump, w: &Value) -> (AirWindowCase, AirWindowCase) {
    let tag = w["tag"].as_str().unwrap();
    let dom = domain_of(w);
    let di = dp_air::field::place_input::DomainInput {
        dom,
        nz: num(w, "nz") as usize,
        dz: num(w, "dz"),
        z_bot: num(w, "z_bot"),
        hc: inp.f64s(&format!("{tag}_hc")),
        gam: inp.f64s(&format!("{tag}_gam")),
        z_i: num(w, "z_i"),
        z_i_col: inp.f32s(&format!("{tag}_z_i_col")),
        z0_map: inp.f64s(&format!("{tag}_z0_map")),
        cells: Cells {
            fr: Vec::new(),
            m: Vec::new(),
        },
    };
    let wind = CaseProfile {
        sun_elev_deg: 0.0,
        class: 0,
        alpha: num(w, "alpha"),
        z_sat: 0.0,
        max_profile: num(w, "max_profile"),
    };
    let heat = inp.f64s(&format!("{tag}_heat"));
    let c = AirWindowCase::from_input(
        &di,
        &wind,
        num(w, "u10_menu"),
        num(w, "wdir"),
        Some(&heat),
        &opts_of("heat"),
    )
    .unwrap();
    let m = c.without_heat();
    (c, m)
}

fn check_scalars(tag: &str, pp: &PreparedPlanes, s: &Value) {
    let f = |k: &str| num(s, k);
    let nu: Vec<u64> = s["n_unk"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_u64().unwrap())
        .collect();
    assert_eq!(pp.n_unk.to_vec(), nu, "{tag}: n_unk");
    assert_eq!(pp.n_fluid as f64, f("n_fluid"), "{tag}: n_fluid");
    for (k, got) in [
        ("cd", pp.cd),
        ("fixed_scale", pp.fixed_scale),
        ("ustar", pp.ustar),
        ("u_a", pp.u_a),
        ("ex", pp.ex),
        ("ey", pp.ey),
        ("h_mech", pp.h_mech),
        ("wstar_max", pp.wstar_max),
        ("h_max", pp.h_max),
        ("z0", pp.z0),
        ("alpha", pp.alpha),
    ] {
        let w = f(k);
        assert!(
            (got - w).abs() <= 1e-12 * w.abs().max(1e-3),
            "{tag}: {k} got {got} want {w}"
        );
    }
}

// ---------------------------------------------------------------------------------------------
// A. случай окна
// ---------------------------------------------------------------------------------------------

#[test]
fn a_planes_match_game() {
    let inp = Dump::inputs();
    let mut report = String::new();
    for w in inp.meta["windows"].as_array().unwrap() {
        let tag = w["tag"].as_str().unwrap();
        let (heat, mech) = window_a(&inp, w);
        for s in w["sets"].as_array().unwrap() {
            let mode = s["mode"].as_str().unwrap();
            let pp = (if mode == "heat" { &heat } else { &mech })
                .prepare()
                .unwrap();
            let t = format!("{tag} {mode}");
            check_scalars(&t, &pp, s);
            let key = s["key"].as_str().unwrap();
            let (mut n, mut bits) = (0usize, 0usize);
            for (name, got) in [
                ("col", &pp.col[..]),
                ("lev", &pp.lev[..]),
                ("prm", &pp.prm[..]),
            ] {
                let want = inp.f32s(&format!("{name}_{key}"));
                assert_eq!(got.len(), want.len(), "{t}: {name} length");
                n += got.len();
                bits += words_differ(got, &want);
                assert_close(&format!("{t} {name}"), got, &want, 1e-6, 1e-12);
            }
            let hu = inp.f64s(&format!("hused_{key}"));
            let e = pp
                .heat_used
                .iter()
                .zip(&hu)
                .map(|(a, b)| (a - b).abs())
                .fold(0.0, f64::max);
            assert!(e == 0.0, "{t}: heat_used differs by {e}");
            // окно: P_NEST, зона релаксации
            assert_eq!(pp.prm[19], 1.0, "{t}: P_NEST");
            report += &format!("\n  {t}: {bits}/{n} слов плоскостей отличаются");
            // mech: без нагрева
            if mode == "mech" {
                assert!(pp.col_plane(8).iter().all(|&q| q == 0.0), "{t}: Q");
            }
        }
    }
    println!("A: плоскости окон против AirWindowCase.prepare:{report}");
}

#[test]
fn a_sponge_zone_is_four_cells_and_top_1000m() {
    let inp = Dump::inputs();
    let w = &inp.meta["windows"][0];
    let (heat, _) = window_a(&inp, w);
    let pp = heat.prepare().unwrap();
    let (nx_h, ny_h) = (pp.nx_h, pp.ny_h);
    let side = pp.col_plane(6);
    let dx = pp.dx;
    let rate = heat.case.p.sponge_rate as f32;
    // у западной границы — рейт·1 (внутри 4 клеток от края), в центре — 0
    assert!(side[(ny_h / 2) * nx_h + 1] > 0.0);
    assert_eq!(side[(ny_h / 2) * nx_h + nx_h / 2], 0.0);
    // зона кончается на 4 клетках от любого края: центр клетки i (x = (i − ½)dx) вне зоны при
    // расстоянии до края ≥ 4dx
    let lx = pp.nx as f64 * dx;
    for i in 0..nx_h {
        let x = (i as f64 - 0.5) * dx;
        let inside = x.min(lx - x) < NEST_SPONGE_CELLS * dx;
        assert_eq!(side[(ny_h / 2) * nx_h + i] > 0.0, inside, "i = {i}");
    }
    assert!(side.iter().all(|&s| s <= rate * 1.0000001));
    assert_eq!(side, pp.col_plane(7), "один профиль для импульса и θ′");
    // потолок: 1000 м
    let nz_h = pp.nz_h;
    let ztop = pp.z_bot + pp.nz as f64 * pp.dz;
    let top = pp.lev_plane(3);
    for (k, &t) in top.iter().enumerate().take(nz_h) {
        let z = pp.zc(k);
        assert_eq!(t > 0.0, ztop - z < NEST_SPONGE_TOP_M, "k = {k}");
    }
}

// ---------------------------------------------------------------------------------------------
// B. цепочка W5 → окно
// ---------------------------------------------------------------------------------------------

#[test]
fn b_chain_matches_game() {
    let inp = Dump::inputs();
    let place: Place =
        read_place(&root().join("../../tests/fixtures/wind/places/ongudai.json")).unwrap();
    let configs = real_configs();
    let wc = WeatherConfigs::from_configs(&configs).unwrap();
    let zi = ZiCfg::from_configs(&configs).unwrap();
    let cond = Conditions::from_json(&inp.meta["conditions"].to_string()).unwrap();
    let clim = climate(&inp.meta["climate"]);
    let hour = hour_at(&cond, 0.0);
    let area = &inp.meta["area"];
    let azc = inp.f32s("area_z_i_col");
    let pz = ParentZi {
        nx: num(area, "nx") as usize,
        ny: num(area, "ny") as usize,
        dx: num(area, "dx"),
        x0: num(area, "x0"),
        y0: num(area, "y0"),
        z_i: num(area, "z_i"),
        z_i_col: &azc,
        alpha_on: area["alpha_on"].as_bool().unwrap(),
    };
    let mut report = String::new();
    for w in inp.meta["windows"].as_array().unwrap() {
        let tag = w["tag"].as_str().unwrap();
        let (cx, cy) = (
            num(w, "x0") + 32.0 * num(w, "dx"),
            num(w, "y0") + 32.0 * num(w, "dx"),
        );
        // сам угол окна: window_domain(cx, cy) возвращает тот же угол
        let dom = window_domain(num(w, "dx"), cx, cy, N_WINDOW);
        assert_eq!(dom, domain_of(w), "{tag}: угол окна");
        let fw = field_weather(&cond, &place, &wc, &configs, &clim, hour, &dom).unwrap();
        let di = build_window_input(&place, &wc.sh, &zi, &dom, &fw.day, Some(&pz)).unwrap();
        // сетка по высоте
        assert_eq!(di.nz, num(w, "nz") as usize, "{tag}: nz");
        assert_eq!(di.dz, num(w, "dz"), "{tag}: dz");
        assert_eq!(di.z_bot, num(w, "z_bot"), "{tag}: z_bot");
        assert_eq!(window_vertical(&di.hc, dom.dx), (di.dz, di.z_bot, di.nz));
        let hc = inp.f64s(&format!("{tag}_hc"));
        assert_eq!(di.hc, hc, "{tag}: hc");
        let rel = |a: &[f64], b: &[f64]| {
            assert_eq!(a.len(), b.len());
            a.iter()
                .zip(b)
                .map(|(x, y)| (x - y).abs() / y.abs().max(1e-6))
                .fold(0.0, f64::max)
        };
        let e_gam = rel(&di.gam, &inp.f64s(&format!("{tag}_gam")));
        let e_z0 = rel(&di.z0_map, &inp.f64s(&format!("{tag}_z0_map")));
        let e_heat = rel(&fw.heat, &inp.f64s(&format!("{tag}_heat")));
        let zc_want = inp.f32s(&format!("{tag}_z_i_col"));
        let e_zi = assert_close(&format!("{tag} z_i_col"), &di.z_i_col, &zc_want, 1e-5, 1.0);
        assert!(e_gam < 1e-6, "{tag}: gam {e_gam}");
        assert!(e_z0 < 1e-6, "{tag}: z0 {e_z0}");
        assert!(e_heat < 1e-5, "{tag}: heat {e_heat}");
        // случай целиком
        let c = AirWindowCase::from_input(
            &di,
            &fw.wind,
            fw.inputs.u10,
            fw.inputs.wdir,
            Some(&fw.heat),
            &opts_of("heat"),
        )
        .unwrap();
        let pp = c.prepare().unwrap();
        let want = inp.f32s(&format!("col_{}", w["sets"][0]["key"].as_str().unwrap()));
        let e_col = assert_close(&format!("{tag} col"), &pp.col, &want, 1e-3, 1e-6);
        report += &format!(
            "\n  {tag}: hc точно; gam {e_gam:.1e}, z0 {e_z0:.1e}, heat {e_heat:.1e}, z_i_col {e_zi:.1e}, col {e_col:.1e}"
        );
    }
    println!("B: цепочка условий → вход окна против AirWindowCase.window_at:{report}");
}

#[test]
fn b_zi_from_parent_rules() {
    let col: Vec<f32> = (0..16).map(|q| 2000.0 + q as f32).collect(); // 4×4, x + 4y
    let p = ParentZi {
        nx: 4,
        ny: 4,
        dx: 400.0,
        x0: 0.0,
        y0: 0.0,
        z_i: 1900.0,
        z_i_col: &col,
        alpha_on: false,
    };
    // окно 2×2 клетки по 200 м, центры в (500, 500) … билинейно по центрам родителя (200 + 400 i)
    let hc = [100.0; 4];
    let out = zi_from_parent(&p, &hc, (2, 2), 200.0, (400.0, 400.0), 300.0);
    assert!((out[0] - (2000.0 + 0.75 + 3.0)).abs() < 1e-3, "{out:?}");
    // нижняя граница hc + zi_min только при α > 0
    let hc_hi = [2500.0; 4];
    let low = zi_from_parent(&p, &hc_hi, (2, 2), 200.0, (400.0, 400.0), 300.0);
    assert!(low[0] < 2100.0);
    let on = ParentZi {
        alpha_on: true,
        ..p
    };
    let high = zi_from_parent(&on, &hc_hi, (2, 2), 200.0, (400.0, 400.0), 300.0);
    assert!(high.iter().all(|&v| v == 2800.0), "{high:?}");
    // нет столбцов — скаляр; нет скаляра — пусто
    let none = ParentZi { z_i_col: &[], ..p };
    assert_eq!(
        zi_from_parent(&none, &hc, (2, 2), 200.0, (0.0, 0.0), 300.0),
        vec![1900.0; 4]
    );
    let nan = ParentZi {
        z_i: f64::NAN,
        z_i_col: &[],
        ..p
    };
    assert!(zi_from_parent(&nan, &hc, (2, 2), 200.0, (0.0, 0.0), 300.0).is_empty());
    // размеры не сошлись
    assert!(zi_from_parent(&p, &hc[..3], (2, 2), 200.0, (0.0, 0.0), 300.0).is_empty());
}

#[test]
fn window_domain_corner_is_multiple_of_25() {
    for (dx, cx, cy) in [
        (100.0, 7224.77, -324.69),
        (50.0, 7224.77, -324.69),
        (100.0, -3.0, 0.0),
    ] {
        let d = window_domain(dx, cx, cy, N_WINDOW);
        assert_eq!((d.nx, d.ny), (64, 64));
        assert_eq!(d.x0 % 25.0, 0.0);
        assert_eq!(d.y0 % 25.0, 0.0);
        assert!((d.x0 + 32.0 * dx - cx).abs() <= 12.5 + 1e-9);
        assert!((d.y0 + 32.0 * dx - cy).abs() <= 12.5 + 1e-9);
    }
}

// ---------------------------------------------------------------------------------------------
// C, D, E. против GPU
// ---------------------------------------------------------------------------------------------

/// Родитель окна из дампа GPU: уровень и поля набора (`heat` / `mech`).
struct ParentDump {
    level: Level,
    tc: Vec<u8>,
    f: [Vec<f32>; 5],
}

fn parent_of(g: &Dump, w: &Value, set: &str) -> ParentDump {
    let tag = w["tag"].as_str().unwrap();
    let p = &w["parent"];
    let pg = &p["grid"];
    let d: Vec<usize> = p["dims"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_u64().unwrap() as usize)
        .collect();
    let level = Level {
        nx: d[0],
        ny: d[1],
        nz: d[2],
        x0: num(pg, "x0"),
        y0: num(pg, "y0"),
        dx: num(pg, "dx"),
        dz: num(pg, "dz"),
        z_bot: num(pg, "z_bot"),
        halo: 1,
    };
    let f = ["u", "v", "w", "th", "thd"].map(|c| g.f32s(&format!("{tag}_par_{set}_{c}")));
    let tc = g.u8s(&format!("{tag}_par_tc"));
    assert_eq!(tc.len(), level.len());
    ParentDump { level, tc, f }
}

fn src_of(p: &ParentDump) -> NestSrc<'_> {
    NestSrc {
        tc: &p.tc,
        u: &p.f[0],
        v: &p.f[1],
        w: &p.f[2],
        th: &p.f[3],
        thd: Some(&p.f[4]),
    }
}

/// Планes k среза: `planes` строки по `nyx` значений.
fn slab(a: &[f32], nyx: usize, planes: &[usize]) -> Vec<f32> {
    planes
        .iter()
        .flat_map(|&k| a[k * nyx..(k + 1) * nyx].iter().copied())
        .collect()
}

fn planes_of(w: &Value) -> Vec<usize> {
    w["planes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_u64().unwrap() as usize)
        .collect()
}

/// Σ|s·u·A| по граням типа 2 — поток «через грань» (для допусков).
fn through_flux(pl: &PreparedPlanes, tc: &[u8], bc: &NestBc) -> f64 {
    let (a_side, a_top) = (pl.dx * pl.dz, pl.dx * pl.dx);
    let mut s = 0.0;
    for (q, &t) in tc.iter().enumerate() {
        if (t >> 2) & 3 == 2 {
            s += f64::from(bc.ubu[q]).abs() * a_side;
        }
        if (t >> 4) & 3 == 2 {
            s += f64::from(bc.ubv[q]).abs() * a_side;
        }
        if (t >> 6) & 3 == 2 {
            s += f64::from(bc.ubw[q]).abs() * a_top;
        }
    }
    s
}

/// Остаточный поток Σ s·u·A по граням типа 2 (после поправки).
fn residual_flux(pl: &PreparedPlanes, tc: &[u8], bc: &NestBc) -> f64 {
    let (a_side, a_top) = (pl.dx * pl.dz, pl.dx * pl.dx);
    let mut s = 0.0;
    for (q, &t) in tc.iter().enumerate() {
        let sg = if t & 3 == 1 { -1.0 } else { 1.0 };
        if (t >> 2) & 3 == 2 {
            s += sg * f64::from(bc.ubu[q]) * a_side;
        }
        if (t >> 4) & 3 == 2 {
            s += sg * f64::from(bc.ubv[q]) * a_side;
        }
        if (t >> 6) & 3 == 2 {
            s += sg * f64::from(bc.ubw[q]) * a_top;
        }
    }
    s
}

struct Built {
    heat: PreparedPlanes,
    mech: PreparedPlanes,
    tc: Vec<u8>,
}

fn build(inp: &Dump, tag: &str) -> Built {
    let w = inp.meta["windows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["tag"] == tag)
        .unwrap();
    let (h, m) = window_a(inp, w);
    let heat = h.prepare().unwrap();
    let mech = m.prepare().unwrap();
    let tc = tcode(&heat);
    assert_eq!(tc, tcode(&mech), "{tag}: типы heat и mech одни");
    Built { heat, mech, tc }
}

#[test]
fn c_d_types_and_boundary_match_gpu() {
    let inp = Dump::inputs();
    let g = Dump::gpu();
    let mut report = String::new();
    for w in g.meta["windows"].as_array().unwrap() {
        let tag = w["tag"].as_str().unwrap();
        let b = build(&inp, tag);
        // C. типы клеток и граней
        let tc_gpu = g.u8s(w["tcode"].as_str().unwrap());
        assert_eq!(b.tc.len(), tc_gpu.len(), "{tag}: tcode length");
        let bad = b.tc.iter().zip(&tc_gpu).filter(|(a, b)| a != b).count();
        assert_eq!(bad, 0, "{tag}: tcode differs in {bad} cells");
        let planes = planes_of(w);
        let nyx = b.heat.nx_h * b.heat.ny_h;
        for s in w["sets"].as_array().unwrap() {
            let mode = s["mode"].as_str().unwrap();
            let pl = if mode == "heat" { &b.heat } else { &b.mech };
            let par = parent_of(&g, w, mode);
            // D. граница
            let bc = window_boundary(&par.level, &src_of(&par), pl, &b.tc).unwrap();
            let t = format!("{tag} {mode}");
            let mut worst = 0.0f64;
            for (name, got) in [
                ("ubu", &bc.ubu),
                ("ubv", &bc.ubv),
                ("ubw", &bc.ubw),
                ("thb", &bc.thb),
                ("thbd", &bc.thbd),
            ] {
                let want = g.f32s(s["arrays"][name].as_str().unwrap());
                let r = assert_close(
                    &format!("{t} {name}"),
                    &slab(got, nyx, &planes),
                    &want,
                    1e-5,
                    1e-3,
                );
                worst = worst.max(r);
            }
            // поток: площадь точно, net — от потока через грань
            let through = through_flux(pl, &b.tc, &bc);
            let area_gpu = num(s, "area");
            assert!(
                (bc.area - area_gpu).abs() <= 1e-6 * area_gpu,
                "{t}: area {} vs {area_gpu}",
                bc.area
            );
            // net GPU — f32-сумма до поправки; нашу сверяем с ним от потока через грань
            let net_gpu = num(s, "net");
            let e_net = (bc.net - net_gpu).abs() / through;
            assert!(
                e_net <= 1e-6,
                "{t}: net {} vs {net_gpu} ({e_net:.2e} потока)",
                bc.net
            );
            let corr_gpu = num(s, "corr");
            let e_corr = (f64::from(bc.corr) - corr_gpu).abs();
            assert!(
                e_corr <= 1e-6 * through / bc.area,
                "{t}: corr {} vs {corr_gpu}",
                bc.corr
            );
            // Σ после поправки ≈ 0
            let resid = residual_flux(pl, &b.tc, &bc).abs() / through;
            assert!(
                resid <= 1e-6,
                "{t}: остаточный поток {resid:.2e} от потока через грань"
            );
            assert!(
                bc.corr.abs() > 0.0,
                "{t}: поправка нулевая — граница уже сбалансирована?"
            );
            report += &format!(
                "\n  {t}: граница {worst:.1e} от масштаба; corr {:.4e} (GPU {corr_gpu:.4e}) м/с, net/через грань {:.2e}, остаток {resid:.1e}",
                bc.corr,
                bc.net / through
            );
        }
    }
    println!("C/D: типы точно; nest/flux/corr против GPU:{report}");
}

#[test]
fn e_shift_start_matches_gpu() {
    let inp = Dump::inputs();
    let g = Dump::gpu();
    let wins = g.meta["windows"].as_array().unwrap();
    let new_w = wins.iter().find(|w| w["tag"] == "w100s").unwrap();
    let sh = &new_w["shift"];
    let old_b = build(&inp, "w100");
    let new_b = build(&inp, "w100s");
    let old_level = window_level(&old_b.heat);
    let new_level = window_level(&new_b.heat);
    let want_shift: Vec<i64> = sh["shift"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_i64().unwrap())
        .collect();
    assert_eq!(
        shift_between(&old_level, &new_level),
        Some(Shift {
            i: want_shift[0],
            j: want_shift[1],
            k: want_shift[2]
        })
    );
    // прошлое окно — решение GPU (heat) целиком
    let oa = |c: &str| g.f32s(sh["old"][c].as_str().unwrap());
    let old = WindowState {
        u: oa("u"),
        v: oa("v"),
        w: oa("w"),
        th: oa("th"),
        thd: oa("thd"),
        p: oa("p"),
    };
    assert_eq!(old.u.len(), old_level.len());
    // граница нового окна — от родителя (область)
    let par = parent_of(&g, new_w, "heat");
    let bc = window_boundary(&par.level, &src_of(&par), &new_b.heat, &new_b.tc).unwrap();
    let st = warm_from_previous(&old_level, &old, &new_level, &new_b.tc, &bc)
        .unwrap()
        .expect("окно подходит для тёплого старта");
    let planes = planes_of(new_w);
    let nyx = new_level.nx * new_level.ny;
    let mut report = String::new();
    for (name, got) in [
        ("u", &st.u),
        ("v", &st.v),
        ("w", &st.w),
        ("th", &st.th),
        ("thd", &st.thd),
        ("p", &st.p),
    ] {
        let want = g.f32s(sh["arrays"][name].as_str().unwrap());
        let r = assert_close(
            &format!("shift {name}"),
            &slab(got, nyx, &planes),
            &want,
            1e-5,
            1e-3,
        );
        report += &format!(" {name} {r:.1e}");
    }
    println!("E: старт со сдвигом против GPU (отн. к масштабу):{report}");
    // свойства: неизвестные внутри старого окна — копия старых, p воздуха — из старого
    let (onx, ony) = (old_level.nx, old_level.ny);
    let mut copied = 0usize;
    for k in 1..new_level.nz - 1 {
        for j in 1..new_level.ny - 1 {
            for i in 1..new_level.nx - 1 {
                let q = (k * new_level.ny + j) * new_level.nx + i;
                let t = new_b.tc[q];
                let (io, jo, ko) = (
                    i as i64 + want_shift[0],
                    j as i64 + want_shift[1],
                    k as i64 + want_shift[2],
                );
                let inside = io >= 1
                    && jo >= 1
                    && ko >= 1
                    && io < onx as i64
                    && jo < ony as i64
                    && ko < old_level.nz as i64;
                if inside && (t >> 2) & 3 == 1 {
                    let o = (ko as usize * ony + jo as usize) * onx + io as usize;
                    assert_eq!(st.u[q], old.u[o]);
                    copied += 1;
                }
            }
        }
    }
    assert!(copied > 10_000, "скопировано мало неизвестных: {copied}");
}

#[test]
fn e_no_overlap_gives_cold_start_marker() {
    let inp = Dump::inputs();
    let b = build(&inp, "w100");
    let lv = window_level(&b.heat);
    let n = lv.len();
    let far = Level {
        x0: lv.x0 + 100.0 * 70.0,
        ..lv
    };
    let st = WindowState::zeros(n);
    let bc = NestBc {
        ubu: vec![0.0; n],
        ubv: vec![0.0; n],
        ubw: vec![0.0; n],
        thb: vec![0.0; n],
        thbd: vec![0.0; n],
        net: 0.0,
        area: 0.0,
        corr: 0.0,
    };
    assert!(
        warm_from_previous(&lv, &st, &far, &b.tc, &bc)
            .unwrap()
            .is_none()
    );
    // тот же уровень (сдвиг 0): неизвестные = старые, граница не нужна внутри
    let same = warm_from_previous(&lv, &st, &lv, &b.tc, &bc)
        .unwrap()
        .unwrap();
    assert_eq!(
        same,
        init_from_boundary(&b.tc, &bc),
        "нулевые поля — нулевой старт"
    );
}

// ---------------------------------------------------------------------------------------------
// свойства границы
// ---------------------------------------------------------------------------------------------

#[test]
fn flux_correction_zeroes_the_sum() {
    // случайное поле на гранях типа 2 синтетического окна: Σ → 0 с точностью f32
    let inp = Dump::inputs();
    let b = build(&inp, "w100");
    let pl = &b.heat;
    let n = pl.nx_h * pl.ny_h * pl.nz_h;
    let mut seed = 12345u64;
    let mut rnd = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((seed >> 33) as f32 / (1u64 << 31) as f32) * 10.0 - 4.0
    };
    let mut u: Vec<f32> = (0..n).map(|_| rnd()).collect();
    let mut v: Vec<f32> = (0..n).map(|_| rnd()).collect();
    let mut w: Vec<f32> = (0..n).map(|_| rnd()).collect();
    let nyx = pl.nx_h * pl.ny_h;
    let (net, area) = boundary_flux((pl.dx, pl.dz), nyx, &b.tc, [&u, &v, &w]).unwrap();
    assert!(
        net.abs() > 1e-3 * area,
        "случайный поток должен быть несбалансирован"
    );
    let corr = apply_flux_correction(nyx, &b.tc, [&mut u, &mut v, &mut w], net, area).unwrap();
    assert!(corr != 0.0);
    let (net2, area2) = boundary_flux((pl.dx, pl.dz), nyx, &b.tc, [&u, &v, &w]).unwrap();
    assert_eq!(area, area2);
    assert!(net2.abs() <= 1e-6 * area * 10.0, "остаток {net2} при {net}");
    // длины
    assert!(boundary_flux((pl.dx, pl.dz), nyx, &b.tc[1..], [&u, &v, &w]).is_err());
}

#[test]
fn init_state_respects_walls_and_zero_pressure() {
    let inp = Dump::inputs();
    let g = Dump::gpu();
    let w = &g.meta["windows"][0];
    let b = build(&inp, "w100");
    let par = parent_of(&g, w, "heat");
    let bc = window_boundary(&par.level, &src_of(&par), &b.heat, &b.tc).unwrap();
    let st = init_from_boundary(&b.tc, &bc);
    assert!(st.p.iter().all(|&p| p == 0.0));
    for (q, &t) in b.tc.iter().enumerate() {
        if (t >> 2) & 3 == 0 {
            assert_eq!(st.u[q], 0.0);
        }
        if t & 3 == 0 {
            assert_eq!((st.th[q], st.thd[q]), (0.0, 0.0));
        }
    }
    let moving = st.u.iter().filter(|&&u| u != 0.0).count();
    assert!(moving > 100_000, "поле родителя перенесено: {moving}");
}

// ---------------------------------------------------------------------------------------------
// F. решение окна против GPU (release: окно 280–500 тыс. клеток)
// ---------------------------------------------------------------------------------------------

/// Коробка `n × n` вокруг центра окна, все плоскости `k`, из поля с ореолом (раскладка дампа).
fn box_of(a: &[f32], lv: &Level, i0: usize, j0: usize, n: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(n * n * lv.nz);
    for k in 0..lv.nz {
        for j in 0..n {
            let b = (k * lv.ny + j0 + j) * lv.nx + i0;
            out.extend_from_slice(&a[b..b + n]);
        }
    }
    out
}

/// Решение окон `picard_rs` против GPU игры: итерации (|Δ| ≤ max(20, iters/10)), скорость
/// (`u_rel` ≤ 1e-3 от масштаба скорости коробки), θ′ (≤ 0,05 К). Загрузка 100/50 м mech/heat —
/// старт от родителя (30 V-циклов); сдвиг 100 м — тёплый старт (4 V-цикла). Печатает итерации и
/// время на 8 и 2 потоках. `cargo test --release -p dp-air --test window -- --ignored --nocapture solve_matches_gpu`.
#[test]
#[ignore = "release: cargo test --release -p dp-air --test window -- --ignored --nocapture solve_matches_gpu"]
fn solve_matches_gpu() {
    use dp_air::field::case_build::SolverCfg;
    use picard_rs::api::{SolveOpts, solve};
    use picard_rs::state::State;
    let inp = Dump::inputs();
    let g = Dump::gpu();
    let mut report = String::new();
    let mut worst_u = 0.0f64;
    let mut worst_th = 0.0f64;
    for w in g.meta["windows"].as_array().unwrap() {
        let tag = w["tag"].as_str().unwrap();
        let b = build(&inp, tag);
        let wi = inp.meta["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["tag"] == tag)
            .unwrap();
        let (heat, mech) = window_a(&inp, wi);
        for s in w["sets"].as_array().unwrap() {
            let mode = s["mode"].as_str().unwrap();
            let (pl, case_rs) = if mode == "heat" {
                (&b.heat, &heat)
            } else {
                (&b.mech, &mech)
            };
            let level = window_level(pl);
            let par = parent_of(&g, w, mode);
            let bc = window_boundary(&par.level, &src_of(&par), pl, &b.tc).unwrap();
            let cfg = SolverCfg::new(case_rs.case.u10);
            let case = window_solver_case(pl, &case_rs.case.p, &cfg, &bc).unwrap();
            let warm = w["warm"].as_bool().unwrap();
            let st0 = if warm {
                let sh = &w["shift"];
                let oa = |c: &str| g.f32s(sh["old"][c].as_str().unwrap());
                let old = WindowState {
                    u: oa("u"),
                    v: oa("v"),
                    w: oa("w"),
                    th: oa("th"),
                    thd: oa("thd"),
                    p: oa("p"),
                };
                let ol = window_level(&build(&inp, "w100").heat);
                warm_from_previous(&ol, &old, &level, &b.tc, &bc)
                    .unwrap()
                    .unwrap()
            } else {
                init_from_boundary(&b.tc, &bc)
            };
            let st = State {
                case: tag.into(),
                input: String::new(),
                it: 0,
                dims: [pl.nx_h, pl.ny_h, pl.nz_h],
                halo: 1,
                n: [pl.nx, pl.ny, pl.nz],
                u: st0.u,
                v: st0.v,
                w: st0.w,
                th: st0.th,
                thd: st0.thd,
                p: st0.p,
                nu: None,
                nuh: None,
                residuals: None,
            };
            let gpu_it = s["iters"].as_u64().unwrap() as i64;
            let bx = &s["box"];
            let (i0, j0, n) = (
                bx["i0"].as_u64().unwrap() as usize,
                bx["j0"].as_u64().unwrap() as usize,
                bx["n"].as_u64().unwrap() as usize,
            );
            let mut times = String::new();
            for threads in [8usize, 2] {
                let opts = SolveOpts {
                    threads,
                    init: Some(st.clone()),
                    init_cycles: (!warm).then_some(30),
                    max_iters: 400,
                    ..SolveOpts::default()
                };
                let t = std::time::Instant::now();
                let r = solve(&case, &opts).unwrap();
                let secs = t.elapsed().as_secs_f64();
                times += &format!(" {threads} пот. {secs:.2} с;");
                if threads != 8 {
                    continue;
                }
                let t = format!("{tag} {mode}");
                assert!(
                    (r.iters as i64 - gpu_it).abs() <= 20.max(gpu_it / 10),
                    "{t}: итераций {} (GPU {gpu_it})",
                    r.iters
                );
                let gb = |c: &str| g.f32s(bx["arrays"][c].as_str().unwrap());
                let rb = |a: &[f32]| box_of(a, &level, i0, j0, n);
                let scale = ["u", "v", "w"]
                    .iter()
                    .flat_map(|c| gb(c))
                    .fold(0.0f32, |m, x| m.max(x.abs())) as f64;
                let du = [(&r.state.u, "u"), (&r.state.v, "v"), (&r.state.w, "w")]
                    .iter()
                    .map(|(a, c)| max_diff(&rb(a), &gb(c)).0)
                    .fold(0.0, f64::max);
                let dth = max_diff(&rb(&r.state.th), &gb("th")).0;
                let dthd = max_diff(&rb(&r.state.thd), &gb("thd")).0;
                assert!(du / scale <= 1e-3, "{t}: u_rel {:.2e}", du / scale);
                assert!(
                    dth <= 0.05 && dthd <= 0.05,
                    "{t}: θ′ {dth:.3e}, θ′_d {dthd:.3e} К"
                );
                worst_u = worst_u.max(du / scale);
                worst_th = worst_th.max(dth);
                report += &format!(
                    "\n  {t}: итераций {} (GPU {gpu_it}), u_rel {:.1e}, θ′ {dth:.1e} К, θ′_d {dthd:.1e} К;",
                    r.iters,
                    du / scale
                );
            }
            report += &times;
        }
    }
    println!(
        "F: решение окон против GPU (худшее u_rel {worst_u:.1e}, θ′ {worst_th:.1e} К):{report}"
    );
}
