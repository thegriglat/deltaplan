//! RW-6c: погода и солнце для поля против дампа GDScript (`tools/research/rust_wind/
//! dump_weather_core.sh`, данные — `tests/data/weather_core/`). Допуски: поток тепла ≤ 1 Вт/м²
//! (по ячейке, max), положение солнца ≤ 1e-4 рад, α ≤ 1e-6, класс устойчивости и
//! `max_profile` точно, температура воды, cap, heat ≤ 1e-3 К.
use dp_air::field::sun::solar_position;
use dp_air::field::surface_heat::CLASS_COUNT;
use dp_air::field::weather_core::*;
use dp_air::field::wind_profile::{self, F_COR};
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, Place};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/weather_core")
        .join(name)
}

fn json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path:?}: {e}")))
        .unwrap()
}

fn f32s(path: &Path) -> Vec<f32> {
    std::fs::read(path)
        .unwrap_or_else(|e| panic!("{path:?}: {e}"))
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

fn configs() -> &'static (Configs, WeatherConfigs) {
    static C: OnceLock<(Configs, WeatherConfigs)> = OnceLock::new();
    C.get_or_init(|| {
        let r = root().join("configs");
        let mut files = Vec::new();
        for n in ["atmosphere", "weather_model", "surface_heat"] {
            files.push((
                n.to_string(),
                std::fs::read_to_string(r.join(format!("{n}.json"))).unwrap(),
            ));
        }
        for n in ["medium", "weak"] {
            files.push((
                format!("weather/{n}"),
                std::fs::read_to_string(r.join(format!("weather/{n}.json"))).unwrap(),
            ));
        }
        let c = Configs::new(files);
        let w = WeatherConfigs::from_configs(&c).unwrap();
        (c, w)
    })
}

fn place(name: &str) -> Place {
    static P: OnceLock<Mutex<HashMap<String, Place>>> = OnceLock::new();
    let m = P.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = m.lock().unwrap();
    g.entry(name.to_string())
        .or_insert_with(|| {
            read_place(&root().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
        })
        .clone()
}

/// Число из json; `null` (NaN или бесконечность в GD) — NaN.
fn n(v: &Value) -> f64 {
    v.as_f64().unwrap_or(f64::NAN)
}

fn close(what: &str, got: f64, want: f64, tol: f64) {
    if want.is_nan() {
        assert!(!got.is_finite(), "{what}: got {got}, want non-finite");
        return;
    }
    assert!(
        (got - want).abs() <= tol,
        "{what}: got {got}, want {want}, tol {tol}"
    );
}

fn rel(what: &str, got: f64, want: f64, tol: f64) {
    close(what, got, want, tol * want.abs().max(1e-300));
}

fn domain(v: &Value) -> Domain {
    Domain {
        x0: n(&v["x0"]),
        y0: n(&v["y0"]),
        nx: n(&v["nx"]) as usize,
        ny: n(&v["ny"]) as usize,
        dx: n(&v["dx"]),
    }
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

fn ang_diff_deg(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

#[test]
fn sun_position_grid() {
    let misc = json(&data("misc.json"));
    let rows = misc["sun"].as_array().unwrap();
    assert!(rows.len() > 100);
    let mut worst: f64 = 0.0;
    for r in rows {
        let utc = n(&r["utc"]);
        let (az, el) = solar_position(
            n(&r["lat"]),
            n(&r["lon"]),
            n(&r["doy"]) as i64,
            n(&r["hour"]),
            utc,
        );
        let de = (el - n(&r["el"])).to_radians().abs();
        // азимут в зените неопределён; сравнивать, пока солнце не у зенита
        let da = if n(&r["el"]).abs() < 89.0 {
            ang_diff_deg(az, n(&r["az"])).to_radians()
        } else {
            0.0
        };
        worst = worst.max(de).max(da);
        assert!(de <= 1e-4 && da <= 1e-4, "sun {r}: az {az} el {el}");
    }
    println!("sun_position_grid: max {worst:e} rad");
}

#[test]
fn wind_profile_grid() {
    let misc = json(&data("misc.json"));
    let cfg = configs().1.wind;
    let rows = misc["profile"].as_array().unwrap();
    assert!(rows.len() > 500);
    for r in rows {
        let (u10, el, cover, z0) = (n(&r["u10"]), n(&r["el"]), n(&r["cover"]), n(&r["z0"]));
        let k = wind_profile::stability_class(u10, el, cover);
        assert_eq!(k as f64, n(&r["cls"]), "class {r}");
        let a = wind_profile::alpha(&cfg, u10, el, cover);
        close("alpha", a, n(&r["alpha"]), 1e-6);
        rel(
            "z_sat",
            wind_profile::z_sat(&cfg, u10, z0, F_COR, k),
            n(&r["z_sat"]),
            1e-9,
        );
        rel(
            "max_profile",
            wind_profile::max_profile(&cfg, a, u10, z0, F_COR, k),
            n(&r["max_profile"]),
            1e-9,
        );
    }
}

fn check_place(name: &str) {
    let (_, cfg) = configs();
    let meta = json(&data(&format!("{name}.json")));
    let bin = f32s(&data(&format!("{name}.bin")));
    let dom = domain(&meta["domain"]);
    let pl = place(name);
    let arr = |k: &str| {
        let o = &meta["arrays"][k];
        let (off, len) = (n(&o[0]) as usize, n(&o[1]) as usize);
        &bin[off..off + len]
    };
    let ctx = context(&pl);
    close(
        "valley",
        ctx.valley_msl_m,
        n(&meta["ctx"]["valley_msl_m"]),
        1e-3,
    );
    close("mean", ctx.mean_msl_m, n(&meta["ctx"]["mean_msl_m"]), 1e-3);
    let hc = block_mean(&pl, &dom).unwrap();
    let worst = hc
        .iter()
        .zip(arr("hc"))
        .map(|(a, b)| (a - *b as f64).abs())
        .fold(0.0, f64::max);
    println!("{name}: hc max diff {worst:e} m");
    assert!(worst <= 1e-3, "hc diff {worst}");
    let cells = cell_surface(&pl, &dom, &cfg.sh).unwrap();
    assert_eq!(cells.fr.len(), arr("fr").len());
    assert!(
        cells.fr.iter().zip(arr("fr")).all(|(a, b)| a == b),
        "fr differs"
    );
    assert!(
        cells
            .m
            .iter()
            .zip(arr("m"))
            .all(|(a, b)| (a - b).abs() <= 1e-6),
        "m differs"
    );
    let z0 = cell_z0(&cells, &cfg.sh);
    for (a, b) in z0.iter().zip(arr("z0")) {
        rel("z0", *a, *b as f64, 1e-6);
    }
    rel("z0_eff", log_mean(&z0), n(&meta["z0_eff"]), 1e-9);
}

#[test]
fn place_rasters_synthetic() {
    check_place("synthetic");
}

#[test]
fn place_rasters_ongudai() {
    check_place("ongudai");
}

fn scenario(file: &str) {
    let (cfgs, cfg) = configs();
    let v = json(&data(&format!("{file}.json")));
    let name = v["place"].as_str().unwrap();
    let meta = json(&data(&format!("{name}.json")));
    let dom = domain(&meta["domain"]);
    let mut pl = place(name);
    // месяц и день сценария могут отличаться от места
    let mut head = pl.header().clone();
    head.loc.month = n(&v["loc"]["month"]) as u32;
    head.loc.day = n(&v["loc"]["day"]) as u32;
    pl = Place::new(
        head,
        pl.heights().to_vec(),
        pl.water().to_vec(),
        pl.cls().to_vec(),
        pl.moist().to_vec(),
    )
    .unwrap();
    let cond = Conditions::from_json(&v["conditions"].to_string()).unwrap();
    let hour = hour_at(&cond, 0.0);
    close("hour", hour, n(&v["hour"]), 1e-12);
    let clim = climate(&v["climate"]);
    let fw = field_weather(&cond, &pl, cfg, cfgs, &clim, hour, &dom).unwrap();
    let tag = |s: &str| format!("{file}: {s}");

    // входы и контекст
    close(&tag("t_max"), fw.t_max, n(&v["t_max"]), 1e-9);
    close(&tag("u10"), fw.inputs.u10, n(&v["u10"]), 1e-9);
    let c = &v["ctx"];
    close(
        &tag("valley"),
        fw.ctx.valley_msl_m,
        n(&c["valley_msl_m"]),
        1e-3,
    );
    close(&tag("mean"), fw.ctx.mean_msl_m, n(&c["mean_msl_m"]), 1e-3);
    assert_eq!(fw.ctx.month as f64, n(&c["month"]));
    assert_eq!(fw.ctx.day as f64, n(&c["day"]));

    // суточный ход и день
    let s = &v["diurnal"];
    let st = &fw.diurnal;
    close(
        &tag("temperature"),
        st.temperature_c,
        n(&s["temperature_c"]),
        1e-6,
    );
    close(&tag("cap"), st.cap_agl_m, n(&s["cap_agl_m"]), 1e-3);
    close(&tag("break"), st.brk, n(&s["break"]), 1e-6);
    close(&tag("heat"), st.heat, n(&s["heat"]), 1e-6);
    close(&tag("soft"), st.soft, n(&s["soft"]), 1e-6);
    close(&tag("mech_k"), st.mech_k, n(&s["mech_k"]), 1e-6);
    close(&tag("sunrise"), st.sunrise_h, n(&s["sunrise_h"]), 1e-9);
    close(&tag("sunset"), st.sunset_h, n(&s["sunset_h"]), 1e-9);
    close(&tag("peak"), st.peak_h, n(&s["peak_h"]), 1e-9);
    close(
        &tag("amp"),
        cfg.wm.diurnal_range_k(&fw.ctx, &clim),
        n(&v["amp"]),
        1e-9,
    );
    let d = &v["day"];
    let day = &fw.day;
    for (k, got) in [
        ("t", day.t),
        ("cap", day.cap),
        ("h_v", day.h_v),
        ("t_u", day.t_u),
        ("z_u", day.z_u),
        ("gam", day.gam),
        ("t_min", day.t_min),
        ("t_res", day.t_res),
        ("t_full", day.t_full),
        ("dep", day.dep),
        ("sky_heat", day.sky_heat),
        ("cover", day.cover),
        ("heat", day.heat),
        ("theta_s", day.theta_s),
    ] {
        close(&tag(k), got, n(&d[k]), 1e-3);
    }
    close(&tag("z_i"), day.z_i, n(&d["z_i"]), 1e-6);
    for t in v["theta"].as_array().unwrap() {
        let z = n(&t["z"]);
        close(&tag("theta"), day.theta(z), n(&t["theta"]), 1e-6);
        close(&tag("gamma"), day.gamma(z), n(&t["gamma"]), 1e-9);
    }

    // солнце и классы
    close(
        &tag("sun el"),
        fw.sun.1.to_radians(),
        n(&v["sun"]["el"]).to_radians(),
        1e-4,
    );
    close(
        &tag("sun az"),
        ang_diff_deg(fw.sun.0, n(&v["sun"]["az"])).to_radians(),
        0.0,
        1e-4,
    );
    let heating = cfg.wm.surface_heating(&fw.ctx);
    let dirs = heating.directions(hour).expect("heating enabled");
    let want = v["class_sun"].as_array().unwrap();
    assert_eq!(want.len(), CLASS_COUNT);
    for (k, w) in want.iter().enumerate() {
        for a in 0..3 {
            close(&tag("class_sun"), dirs[k][a], n(&w[a]), 1e-6);
        }
    }
    close(&tag("sunset_h"), heating.sunset_h, n(&v["sunset_h"]), 1e-9);
    let bn_empty = v["built_night"].as_object().is_none_or(|o| o.is_empty());
    match (heating.built_night(hour), &v["built_night"]) {
        (None, _) if bn_empty => {}
        (Some(b), bn) if !bn_empty => {
            close(&tag("night sin_s"), b.sin_s, n(&bn["sin_s"]), 1e-6);
            close(&tag("night dt_h"), b.dt_h, n(&bn["dt_h"]), 1e-9);
        }
        (got, want) => panic!("{}: built_night {got:?} vs {want}", tag("")),
    }

    // вода
    let w = &v["water"];
    let zv = fw.ctx.valley_msl_m;
    let sh = &cfg.sh;
    close(
        &tag("water valley"),
        water_temp_c(fw.water_mean_air_c, zv, &fw.ctx, sh),
        n(&w["t_valley"]),
        1e-3,
    );
    close(
        &tag("water up"),
        water_temp_c(fw.water_mean_air_c, zv + 300.0, &fw.ctx, sh),
        n(&w["t_up"]),
        1e-3,
    );
    close(
        &tag("water down"),
        water_temp_c(fw.water_mean_air_c, zv - 100.0, &fw.ctx, sh),
        n(&w["t_down"]),
        1e-3,
    );
    close(&tag("air valley"), day.t, n(&w["air_valley"]), 1e-3);

    // ветер случая
    let wp = &v["wind"];
    rel(&tag("z0_eff"), fw.z0_eff, n(&v["z0_eff"]), 1e-9);
    close(
        &tag("sun_elev"),
        fw.wind.sun_elev_deg.to_radians(),
        n(&wp["sun_elev"]).to_radians(),
        1e-4,
    );
    assert_eq!(fw.wind.class as f64, n(&wp["cls"]), "{}", tag("class"));
    close(&tag("alpha"), fw.wind.alpha, n(&wp["alpha"]), 1e-6);
    rel(&tag("z_sat"), fw.wind.z_sat, n(&wp["z_sat"]), 1e-9);
    rel(
        &tag("max_profile"),
        fw.wind.max_profile,
        n(&wp["max_profile"]),
        1e-9,
    );

    // поток тепла
    let want = f32s(&data(&format!("{file}.bin")));
    assert_eq!(fw.heat.len(), want.len());
    let (mut worst, mut at) = (0.0f64, 0usize);
    for (q, (a, b)) in fw.heat.iter().zip(&want).enumerate() {
        let dd = (a - *b as f64).abs();
        if dd > worst {
            (worst, at) = (dd, q);
        }
    }
    let (mx, mean) = (
        fw.heat.iter().cloned().fold(f64::MIN, f64::max),
        fw.heat.iter().sum::<f64>() / fw.heat.len() as f64,
    );
    println!("{file}: H max diff {worst:e} W/m2 (cell {at}), H max {mx:.1}, mean {mean:.1}");
    assert!(worst <= 1.0, "{file}: H differs by {worst} at cell {at}");
}

macro_rules! scenarios {
    ($($fname:ident => $file:expr),* $(,)?) => { $( #[test] fn $fname() { scenario($file); } )* };
}

scenarios! {
    sc_synthetic_h09_clear => "synthetic_m07_h09_clear",
    sc_synthetic_h13_clear => "synthetic_m07_h13_clear",
    sc_synthetic_h09_overcast => "synthetic_m07_h09_overcast",
    sc_synthetic_h13_overcast => "synthetic_m07_h13_overcast",
    sc_ongudai_h09_clear => "ongudai_m07_h09_clear",
    sc_ongudai_h13_clear => "ongudai_m07_h13_clear",
    sc_ongudai_h09_overcast => "ongudai_m07_h09_overcast",
    sc_ongudai_h13_overcast => "ongudai_m07_h13_overcast",
    sc_ongudai_h21_partly => "ongudai_m07_h21_partly",
    sc_ongudai_jan_h12_clear => "ongudai_m01_h12_clear",
    sc_ongudai_aug_h14_partly => "ongudai_m08_h14_partly",
}
