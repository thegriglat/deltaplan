//! RW-6d: случай области и плоскости `prepare` (Rust) против дампа GDScript (`AirPlace.domain_case`,
//! `AirCase.prepare`) на тех же растрах места. Дамп: `tools/research/rust_wind/dump_case_prepare.sh`
//! (rust/dp-air/tests/data/case_prepare).
//!
//! Режим A («случай»): входы случая — из дампа (рельеф, `gam`, `z_i_col`, карта z0, поток тепла,
//! α и `max_profile` в f64) → плоскости обязаны совпасть побитно (где дамп хранит целиком — поэлементно,
//! иначе — по хешу FNV-1a слов f32). Режим B («цепочка»): те же условия W5 через `field_weather` и
//! `build_domain_input` (RW-6b/6c) → допуск от погоды, достигнутое печатается.
//! Свойства (T2): конечность плоскостей, согласие `kf` с рельефом, счёт неизвестных по типам клеток,
//! непротекание у земли в фоне, баланс потоков по граням типа 2.
use dp_air::field::case_prepare::*;
use dp_air::field::place_input::{DomainInput, ZiCfg, build_domain_input};
use dp_air::field::weather_core::{
    Cells, Climate, ClimateCell, Domain, WeatherConfigs, field_weather, hour_at,
};
use dp_air::field::wind_profile::CaseProfile;
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, Place};
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
    fn load(name: &str) -> Dump {
        let d = root().join("tests/data/case_prepare");
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join(format!("{name}.json"))).unwrap())
                .unwrap();
        let bin = std::fs::read(d.join(format!("{name}.bin"))).unwrap();
        Dump { meta, bin }
    }
    fn num(&self, k: &str) -> f64 {
        self.meta[k].as_f64().unwrap()
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
    let n = |x: &Value| x.as_f64().unwrap();
    Table(
        v.as_array()
            .unwrap()
            .iter()
            .map(|c| {
                (
                    n(&c["month"]) as i64,
                    n(&c["day"]) as i64,
                    ClimateCell {
                        tx_c: n(&c["tx_c"]),
                        dtr_k: n(&c["dtr_k"]),
                        z_cell_m: n(&c["z_cell_m"]),
                        has_hh1: c["has_hh1"].as_bool().unwrap(),
                        has_hh5: c["has_hh5"].as_bool().unwrap(),
                    },
                )
            })
            .collect(),
    )
}

/// FNV-1a 64 по словам f32 (как `_fnv` дампера).
fn fnv(v: &[f32]) -> i64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for x in v {
        h = (h ^ x.to_bits() as u64).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h as i64
}

#[derive(Default, Debug)]
struct Diff {
    n: usize,
    bits: usize,
    max_rel: f64,
}

fn diff(got: &[f32], want: &[f32]) -> Diff {
    assert_eq!(got.len(), want.len(), "plane length");
    let mut d = Diff {
        n: got.len(),
        ..Default::default()
    };
    for (g, w) in got.iter().zip(want) {
        if g.to_bits() != w.to_bits() {
            d.bits += 1;
            let rel = if g.is_infinite() || w.is_infinite() || g.is_nan() || w.is_nan() {
                f64::INFINITY
            } else {
                (*g as f64 - *w as f64).abs() / (*w as f64).abs().max(1e-30)
            };
            d.max_rel = d.max_rel.max(rel);
        }
    }
    d
}

/// Скаляры набора против дампа (f64, точность 1e-12 отн.; счёт неизвестных — точно).
fn check_scalars(tag: &str, pp: &PreparedPlanes, s: &Value, tol: f64) {
    let f = |k: &str| s[k].as_f64().unwrap();
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
            (got - w).abs() <= tol * w.abs().max(1e-3),
            "{tag}: {k} got {got} want {w}"
        );
    }
}

/// Плоскости набора против дампа. Возвращает (разных слов, наибольшее отн. отличие) по всем плоскостям.
/// `tol` — допуск относительного отличия; `bitwise` — требовать побитное совпадение.
fn check_planes(
    dump: &Dump,
    tag: &str,
    pp: &PreparedPlanes,
    s: &Value,
    tol: f64,
    bitwise: bool,
) -> Option<(usize, usize, f64)> {
    let parse = |k: &str| s[k].as_str().unwrap().parse::<i64>().unwrap();
    if s["full"].as_bool().unwrap() {
        let key = s["key"].as_str().unwrap();
        let (mut n, mut bits, mut mx) = (0usize, 0usize, 0.0f64);
        for (name, got) in [
            ("col", &pp.col[..]),
            ("lev", &pp.lev[..]),
            ("prm", &pp.prm[..]),
        ] {
            let want = dump.f32s(&format!("{name}_{key}"));
            let d = diff(got, &want);
            n += d.n;
            bits += d.bits;
            mx = mx.max(d.max_rel);
            if bitwise {
                assert_eq!(
                    d.bits, 0,
                    "{tag}: {name} differs in {} of {} words",
                    d.bits, d.n
                );
            }
            assert!(d.max_rel <= tol, "{tag}: {name} max rel {}", d.max_rel);
        }
        let hu = dump.f64s(&format!("hused_{key}"));
        assert_eq!(pp.heat_used.len(), hu.len());
        let e = pp
            .heat_used
            .iter()
            .zip(&hu)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f64::max);
        assert!(!bitwise || e == 0.0, "{tag}: heat_used differs by {e}");
        Some((n, bits, mx))
    } else {
        if bitwise {
            assert_eq!(fnv(&pp.col), parse("hash_col"), "{tag}: col hash");
            assert_eq!(fnv(&pp.lev), parse("hash_lev"), "{tag}: lev hash");
            assert_eq!(fnv(&pp.prm), parse("hash_prm"), "{tag}: prm hash");
        }
        None
    }
}

/// Свойства плоскостей, не зависящие от дампа (T2).
fn check_properties(tag: &str, pp: &PreparedPlanes) {
    let (nx_h, ny_h, nz_h) = (pp.nx_h, pp.ny_h, pp.nz_h);
    let nyx = nx_h * ny_h;
    // конечность
    for p in 0..NCOL {
        assert!(
            pp.col_plane(p).iter().all(|v| v.is_finite()),
            "{tag}: col plane {p} not finite"
        );
    }
    assert!(pp.lev.iter().all(|v| v.is_finite()), "{tag}: lev");
    assert!(pp.prm.iter().all(|v| v.is_finite()), "{tag}: prm");
    assert!(
        pp.fixed_scale.is_finite() && pp.fixed_scale > 0.0,
        "{tag}: fixed_scale"
    );
    // kf согласован с рельефом: клетки ниже kf — земля (центр ниже рельефа), kf — первая клетка воздуха
    let hp = pp.col_plane(0);
    let kfp = pp.col_plane(1);
    for q in 0..nyx {
        let kf = pp.kf[q] as usize;
        assert_eq!(kfp[q], pp.kf[q] as f32, "{tag}: kf plane");
        assert!((1..=nz_h).contains(&kf), "{tag}: kf range");
        let h = hp[q] as f64;
        let eps = 1e-3 * h.abs().max(1.0); // рельеф в плоскости — f32
        if kf > 1 {
            assert!(pp.zc(kf - 1) < h + eps, "{tag}: cell kf-1 is not ground");
        }
        if kf < nz_h {
            assert!(pp.zc(kf) >= h - eps, "{tag}: cell kf is below terrain");
        }
    }
    // счёт неизвестных по типам клеток (независимо от формулы kf-арифметики)
    let air = |k: usize, j: usize, i: usize| pp.cell_type(k, j, i) == 1;
    let (mut nf, mut nu, mut nv, mut nw) = (0u64, 0u64, 0u64, 0u64);
    for k in 1..nz_h - 1 {
        for j in 1..ny_h - 1 {
            for i in 1..nx_h - 1 {
                if !air(k, j, i) {
                    continue;
                }
                nf += 1;
                if i >= 2 && air(k, j, i - 1) {
                    nu += 1;
                }
                if j >= 2 && air(k, j - 1, i) {
                    nv += 1;
                }
                if k >= 2 && air(k - 1, j, i) {
                    nw += 1;
                }
            }
        }
    }
    assert_eq!(pp.n_unk, [nu, nv, nw, nf], "{tag}: unknowns by cell types");
    // фон: непротекание у земли — нормальная скорость фона на гранях между землёй и чем угодно (и
    // у нижней границы) равна нулю; вертикальной скорости фона нет (w = 0 на нижней грани)
    let hp = pp.col_plane(0);
    for k in 0..nz_h {
        for j in 0..ny_h {
            for i in 0..nx_h {
                let c = pp.cell_type(k, j, i);
                if i > 0 && (c == 0 || pp.cell_type(k, j, i - 1) == 0) {
                    assert_eq!(
                        pp.bg_u(k, j, i),
                        0.0,
                        "{tag}: u through ground ({k},{j},{i})"
                    );
                }
                if j > 0 && (c == 0 || pp.cell_type(k, j - 1, i) == 0) {
                    assert_eq!(
                        pp.bg_v(k, j, i),
                        0.0,
                        "{tag}: v through ground ({k},{j},{i})"
                    );
                }
            }
        }
    }
    // баланс потоков по граням типа 2: приток = выход × fixed_scale, т.е. сумма нормальных потоков 0
    let (mut net, mut fin) = (0.0f64, 0.0f64);
    for k in 1..nz_h - 1 {
        for j in 1..ny_h - 1 {
            for (i, s) in [(1usize, -1.0f64), (nx_h - 1, 1.0)] {
                let u = pp.bg_u(k, j, i);
                net += s * u;
                fin += (-(s * u)).max(0.0);
            }
        }
        for i in 1..nx_h - 1 {
            for (j, s) in [(1usize, -1.0f64), (ny_h - 1, 1.0)] {
                let v = pp.bg_v(k, j, i);
                net += s * v;
                fin += (-(s * v)).max(0.0);
            }
        }
    }
    let _ = hp;
    assert!(
        net.abs() <= 1e-6 * fin.max(1e-30),
        "{tag}: boundary flux not balanced: net {net}, in {fin}"
    );
    if pp.prm[17] > 0.0 {
        assert!(fin > 0.0, "{tag}: windy case without inflow");
    }
}

fn domain_of(dump: &Dump) -> Domain {
    Domain {
        x0: dump.num("x0"),
        y0: dump.num("y0"),
        nx: dump.num("nx") as usize,
        ny: dump.num("ny") as usize,
        dx: dump.num("dx"),
    }
}

fn mode_opts(s: &Value) -> CaseOpts {
    CaseOpts {
        heat: s["mode"] == "heat",
    }
}

fn check(place_name: &str, dx: u32) {
    let name = format!("{place_name}_{dx}");
    let dump = Dump::load(&name);
    let place: Place = read_place(&root().join(format!(
        "../../tests/fixtures/wind/places/{place_name}.json"
    )))
    .unwrap();
    let configs = real_configs();
    let wc = WeatherConfigs::from_configs(&configs).unwrap();
    let zi = ZiCfg::from_configs(&configs).unwrap();
    let dom = domain_of(&dump);
    let hc = dump.f64s("hc");
    let z0_map = dump.f64s("z0_map");
    let mut report = String::new();
    let mut a_sets = 0;
    let mut b_sets = 0;
    for sc in dump.meta["scenarios"].as_array().unwrap() {
        let stag = sc["tag"].as_str().unwrap();
        let gam = dump.f64s(&format!("gam_{stag}"));
        let z_i_col = dump.f32s(&format!("z_i_col_{stag}"));
        let heat = dump.f64s(&format!("heat_{stag}"));
        let inp = DomainInput {
            dom,
            nz: dump.num("nz") as usize,
            dz: dump.num("dz"),
            z_bot: dump.num("z_bot"),
            hc: hc.clone(),
            gam,
            z_i: sc["z_i"].as_f64().unwrap(),
            z_i_col,
            z0_map: z0_map.clone(),
            cells: Cells {
                fr: Vec::new(),
                m: Vec::new(),
            },
        };
        let wind = CaseProfile {
            sun_elev_deg: 0.0,
            class: 0,
            alpha: sc["alpha"].as_f64().unwrap(),
            z_sat: 0.0,
            max_profile: sc["max_profile"].as_f64().unwrap(),
        };
        let (u10, wdir) = (sc["u10"].as_f64().unwrap(), sc["wdir"].as_f64().unwrap());
        // режим B: цепочка погоды и входа
        let cond = Conditions::from_json(&sc["conditions"].to_string()).unwrap();
        let clim = climate(&sc["climate"]);
        let hour = hour_at(&cond, 0.0);
        let fw = field_weather(&cond, &place, &wc, &configs, &clim, hour, &dom).unwrap();
        let inp_b = build_domain_input(&place, &wc.sh, &zi, &dom, &fw.day).unwrap();
        for s in sc["sets"].as_array().unwrap() {
            // дамп снят и с приточным множителем k < 1 (подбор по ветру у старта, снят в WF-2):
            // такие наборы не проверяются — ветер условий теперь всегда набегающий поток (k = 1)
            if s["k"].as_f64().unwrap() != 1.0 {
                continue;
            }
            let opts = mode_opts(s);
            let tag = format!("{name} {stag} {}", s["mode"].as_str().unwrap());
            // A
            let case =
                build_case_with(&inp, &wind, u10, wdir, opts.heat.then_some(heat.as_slice()))
                    .unwrap();
            let pp = case.prepare().unwrap();
            check_scalars(&tag, &pp, s, 1e-12);
            check_properties(&tag, &pp);
            let da = check_planes(&dump, &tag, &pp, s, 1e-6, true);
            a_sets += 1;
            // mech = without_heat тем же случаем
            if opts.heat {
                let m = case.without_heat().prepare().unwrap();
                assert!(m.col_plane(8).iter().all(|&q| q == 0.0), "{tag}: mech Q");
                assert!(m.heat_used.iter().all(|&q| q == 0.0));
            }
            // B: только где дамп хранит плоскости целиком
            if let Some((n, bits, mx)) = da {
                let cb = build_case(&inp_b, &fw, &opts).unwrap();
                let pb = cb.prepare().unwrap();
                check_properties(&format!("{tag} [chain]"), &pb);
                assert_eq!(pb.n_unk, pp.n_unk, "{tag}: chain n_unk");
                let key = s["key"].as_str().unwrap();
                let want = dump.f32s(&format!("col_{key}"));
                let d = diff(&pb.col, &want);
                b_sets += 1;
                report += &format!(
                    "\n  {tag}: A {bits}/{n} words differ (max rel {mx:.1e}); chain col {}/{} differ, max rel {:.1e}",
                    d.bits, d.n, d.max_rel
                );
                assert!(d.max_rel <= 1e-2, "{tag}: chain col rel {}", d.max_rel);
            }
        }
    }
    assert!(a_sets >= 1, "{name}: после фильтра k = 1 не осталось наборов дампа");
    println!("{name}: A {a_sets} sets, chain {b_sets} sets{report}");
}

#[test]
fn synthetic_400() {
    check("synthetic", 400);
}
#[test]
fn synthetic_1200() {
    check("synthetic", 1200);
}
#[test]
fn ongudai_400() {
    check("ongudai", 400);
}
#[test]
fn ongudai_1200() {
    check("ongudai", 1200);
}

#[test]
fn bad_sizes_are_bad_input() {
    let dump = Dump::load("synthetic_1200");
    let dom = domain_of(&dump);
    let sc = &dump.meta["scenarios"][0];
    let inp = DomainInput {
        dom,
        nz: dump.num("nz") as usize,
        dz: dump.num("dz"),
        z_bot: dump.num("z_bot"),
        hc: dump.f64s("hc"),
        gam: Vec::new(),
        z_i: sc["z_i"].as_f64().unwrap(),
        z_i_col: Vec::new(),
        z0_map: Vec::new(),
        cells: Cells {
            fr: Vec::new(),
            m: Vec::new(),
        },
    };
    let wind = CaseProfile {
        sun_elev_deg: 0.0,
        class: 0,
        alpha: 0.24,
        z_sat: 0.0,
        max_profile: 1.0,
    };
    let e = build_case_with(&inp, &wind, 3.0, 150.0, None).unwrap_err();
    assert_eq!(e.code, dp_air::Code::BadInput);
}
