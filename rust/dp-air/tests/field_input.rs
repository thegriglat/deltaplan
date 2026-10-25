//! RW-6b: вход области Пикара (Rust) против дампа GDScript `AirPlace` на тех же растрах места.
//! Дамп: `tools/research/rust_wind/dump_field_input.sh` (rust/dp-air/tests/data/field_input).
use dp_air::Configs;
use dp_air::field::place_input::*;
use dp_air::field::surface_heat::{CLASS_COUNT, NONE, WATER};
use dp_air::field::weather_core::{Day, Domain, WeatherConfigs};
use dp_air::fixtures::read_place;
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
        let d = root().join("tests/data/field_input");
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join(format!("{name}.json"))).unwrap())
                .unwrap();
        let bin = std::fs::read(d.join(format!("{name}.bin"))).unwrap();
        Dump { meta, bin }
    }
    fn num(&self, k: &str) -> f64 {
        self.meta[k].as_f64().unwrap()
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        let a = &self.meta["arrays"][k];
        assert_eq!(a["dtype"], "f64", "{k}");
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        self.bin[o..o + 8 * n]
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        let a = &self.meta["arrays"][k];
        assert_eq!(a["dtype"], "f32", "{k}");
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        self.bin[o..o + 4 * n]
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
}

fn max_abs(a: &[f64], b: &[f64]) -> f64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs())
        .fold(0.0, f64::max)
}

fn max_rel(a: &[f64], b: &[f64]) -> f64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs() / y.abs().max(1e-30))
        .fold(0.0, f64::max)
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

fn check(place_name: &str, dx: u32) {
    let name = format!("{place_name}_{dx}");
    let dump = Dump::load(&name);
    let place = read_place(&root().join(format!(
        "../../tests/fixtures/wind/places/{place_name}.json"
    )))
    .unwrap();
    let configs = real_configs();
    let wc = WeatherConfigs::from_configs(&configs).unwrap();
    let zi = ZiCfg::from_configs(&configs).unwrap();
    let l = dump.num("l");
    let n = (l / dx as f64).round() as usize;
    let dom = Domain {
        x0: -l / 2.0,
        y0: -l / 2.0,
        nx: n,
        ny: n,
        dx: dx as f64,
    };
    let scal = dump.f64s("scal");
    let mut report = String::new();
    for v in dump.meta["variants"].as_array().unwrap() {
        let tag = v["tag"].as_str().unwrap();
        let s = &scal[v["scal"].as_u64().unwrap() as usize..][..13];
        let day = Day {
            hour: 0.0,
            t: s[0],
            cap: if v["cap_inf"].as_bool().unwrap() {
                f64::INFINITY
            } else {
                s[1]
            },
            h_v: s[2] / 1000.0,
            t_u: s[3],
            z_u: s[4],
            gam: s[5],
            t_min: s[6],
            t_res: s[7],
            t_full: s[8],
            dep: s[9],
            sky_heat: 0.0,
            cover: 0.0,
            heat: 0.0,
            theta_s: s[11],
            z_i: s[12],
        };
        let inp = build_domain_input(&place, &wc.sh, &zi, &dom, &day).unwrap();
        assert_eq!(inp.dom.nx as f64, dump.num("nx"), "{name}: nx");
        assert_eq!(inp.nz as f64, dump.num("nz"), "{name}: nz");
        assert_eq!(inp.dz, dump.num("dz"));
        assert_eq!(inp.z_bot, dump.num("z_bot"));
        assert_eq!((inp.dom.x0, inp.dom.y0), (dump.num("x0"), dump.num("y0")));
        let e_hc = max_abs(&inp.hc, &dump.f64s("hc"));
        assert!(e_hc <= 1e-3, "{name}: hc {e_hc}");
        let e_gam = max_abs(&inp.gam, &dump.f64s(&format!("gam_{tag}")));
        assert!(e_gam <= 1e-7, "{name} {tag}: gam {e_gam}");
        let zc: Vec<f64> = inp.z_i_col.iter().map(|&x| x as f64).collect();
        let zd: Vec<f64> = dump
            .f32s(&format!("z_i_col_{tag}"))
            .iter()
            .map(|&x| x as f64)
            .collect();
        let e_zc = max_abs(&zc, &zd);
        assert!(e_zc <= 0.5, "{name} {tag}: z_i_col {e_zc}");
        report += &format!(" [{tag}: gam {e_gam:.1e} z_i_col {e_zc:.1e}]");
        if tag.starts_with("13") {
            let e_z0 = max_rel(&inp.z0_map, &dump.f64s("z0_map"));
            assert!(e_z0 <= 1e-6, "{name}: z0 {e_z0}");
            let fr: Vec<f64> = inp.cells.fr.iter().map(|&x| x as f64).collect();
            let frd: Vec<f64> = dump.f32s("cell_fr").iter().map(|&x| x as f64).collect();
            let e_fr = max_abs(&fr, &frd);
            assert!(e_fr <= 1e-6, "{name}: fr {e_fr}");
            let m: Vec<f64> = inp.cells.m.iter().map(|&x| x as f64).collect();
            let md: Vec<f64> = dump.f32s("cell_m").iter().map(|&x| x as f64).collect();
            let e_m = max_abs(&m, &md);
            assert!(e_m <= 1e-6, "{name}: moist {e_m}");
            let wf = water_fraction(&place, &dom).unwrap();
            let e_wf = max_abs(&wf, &dump.f64s("water_fraction"));
            assert!(e_wf <= 1e-12, "{name}: water_fraction {e_wf}");
            report += &format!(" [hc {e_hc:.1e} z0 {e_z0:.1e} fr {e_fr:.1e} m {e_m:.1e}]");
        }
    }
    println!("{name}:{report}");
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
fn synthetic_400() {
    check("synthetic", 400);
}
#[test]
fn synthetic_1200() {
    check("synthetic", 1200);
}

#[test]
fn cfg_matches_dump() {
    let dump = Dump::load("ongudai_400");
    let c = &dump.meta["cfg"];
    let configs = real_configs();
    let zi = ZiCfg::from_configs(&configs).unwrap();
    assert_eq!(zi.alpha, c["zi_alpha"].as_f64().unwrap());
    assert_eq!(zi.smooth_m, c["zi_smooth_m"].as_f64().unwrap());
    assert_eq!(zi.zi_min, c["zi_min"].as_f64().unwrap());
    let wc = WeatherConfigs::from_configs(&configs).unwrap();
    assert_eq!(wc.sh.m_norm_cells, c["m_norm"].as_f64().unwrap());
    for (k, z) in c["z0_m"].as_array().unwrap().iter().enumerate() {
        assert_eq!(wc.sh.classes[k].z0_m, z.as_f64().unwrap());
    }
    assert_eq!(c["z0_m"].as_array().unwrap().len(), CLASS_COUNT);
    let _ = (NONE, WATER);
}

#[test]
fn domain_outside_raster_is_bad_input() {
    let place =
        read_place(&root().join("../../tests/fixtures/wind/places/synthetic.json")).unwrap();
    let e = water_fraction(&place, &Domain::standard(400.0)).unwrap_err();
    assert_eq!(e.code, dp_air::Code::BadInput);
}

#[test]
fn gauss_preserves_constant_and_mean_shape() {
    let a = vec![5.0; 30 * 20];
    let g = gauss2d(&a, 30, 20, 4.0);
    assert!(g.iter().all(|v| (v - 5.0).abs() < 1e-12));
}
