//! RW-14c: `dp_air::weather::Weather` против эталонов GD E1–E5, E7–E10 (`tests/data/RW-14b/`).
//! Допуск W8: `1e-6 + 1e-5·|ref|`; `null` эталона (NaN/inf GD) — нечисло или бесконечность в Rust.
//! E6 (`ground_context` по растру места) — только замер, жёсткого допуска нет (`e6_ground_context`).
//!
//! Сетки климата в репозитории сжаты brotli, а крейт берёт распакованные байты — распаковка
//! здесь, как её делает игра: 64 байта заголовка + тело. Вариант «битый файл» (усечён, лишний
//! байт, размеры, мусор вместо тела) игра отдаёт крейту как заголовок без тела.
mod common;

use dp_air::Forecast;
use dp_air::field::sun::day_of_year;
use dp_air::field::surface_heat::{
    self as sh, CLASS_COUNT, Night, Sky, SurfaceHeatCfg, SurfaceHeating, WaterIn,
};
use dp_air::field::weather_core::{belt_gradient, season_index, sun_elevation_deg};
use dp_air::weather::{
    ClimatePlace, ClimateSrc, GRID_NAMES, PlaceCtx, Weather, WorldTime, band_index,
    cirrus_base_cover, hour_at, interp_rows, lerp_table, monthly, sun_block_cover, td_noise,
};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

const REL: f64 = 1e-5;
const ABS: f64 = 1e-6;
use common::HEADER;

fn data(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/RW-14b")
        .join(name)
}

fn rows(set: &str) -> Vec<Value> {
    let p = data(&format!("{set}.jsonl.zst"));
    let raw =
        zstd::decode_all(&std::fs::read(&p).unwrap_or_else(|e| panic!("{p:?}: {e}"))[..]).unwrap();
    String::from_utf8(raw)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

// ---------------------------------------------------------------- сравнение

#[derive(Default)]
struct Diff {
    n: usize,
    bad: Vec<String>,
}

impl Diff {
    fn num(&mut self, what: &str, got: f64, want: &Value) {
        self.n += 1;
        let ok = match want.as_f64() {
            None => !got.is_finite(),
            Some(w) => got.is_finite() && (got - w).abs() <= ABS + REL * w.abs(),
        };
        if !ok {
            self.bad.push(format!("{what}: got {got}, want {want}"));
        }
    }

    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, what: &str, got: T, want: T) {
        self.n += 1;
        if got != want {
            self.bad.push(format!("{what}: got {got:?}, want {want:?}"));
        }
    }

    fn finish(self, set: &str) {
        eprintln!("{set}: {} проверок, расхождений {}", self.n, self.bad.len());
        assert!(
            self.bad.is_empty(),
            "{set}: {} расхождений из {}; первые:\n{}",
            self.bad.len(),
            self.n,
            self.bad
                .iter()
                .take(12)
                .cloned()
                .collect::<Vec<_>>()
                .join("\n")
        );
        assert!(self.n > 0, "{set}: пусто");
    }
}

fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or(f64::NAN)
}

/// Контекст GD-словаря: нет ключа — NaN (месяц/день — 7/15 как в GD).
fn ctx_of(v: &Value) -> PlaceCtx {
    let g = |k: &str| v.get(k).map_or(f64::NAN, f);
    PlaceCtx {
        month: v.get("month").map_or(7, |m| f(m) as i64),
        day: v.get("day").map_or(15, |m| f(m) as i64),
        lat: g("lat"),
        lon: g("lon"),
        utc_offset_h: g("utc_offset_h"),
        valley_msl_m: g("valley_msl_m"),
        mean_msl_m: g("mean_msl_m"),
        start_msl_m: g("start_msl_m"),
    }
}

// ---------------------------------------------------------------- сетки

use common::{REAL_FILES, cfg_files, real_file, real_grids, unpack, weather_of};

fn synth_file(g: &str) -> Vec<u8> {
    let name = REAL_FILES.iter().find(|(k, _)| *k == g).unwrap().1;
    std::fs::read(data(&format!("grids/{name}_nodata.bin"))).unwrap()
}

/// Правка файла сетки по описанию строки E1 (порядок GD: усечение, хвост, добавка, мусор, патчи).
fn variant_file(row: &Value) -> Vec<u8> {
    let mut b = real_file(row["grid"].as_str().unwrap());
    let tr = row["truncate"].as_i64().unwrap_or(-1);
    if tr >= 0 {
        b.truncate(tr as usize);
    }
    let tt = row["truncate_tail"].as_u64().unwrap_or(0) as usize;
    b.truncate(b.len().saturating_sub(tt));
    b.extend(std::iter::repeat_n(
        0u8,
        row["append"].as_u64().unwrap_or(0) as usize,
    ));
    if row["garbage_body"].as_bool() == Some(true) {
        for k in HEADER..b.len().min(HEADER + 4096) {
            b[k] = ((k * 131 + 7) & 0xFF) as u8;
        }
    }
    for p in row["patch"].as_array().into_iter().flatten() {
        let (off, size, val) = (
            p["off"].as_u64().unwrap() as usize,
            p["size"].as_u64().unwrap() as usize,
            p["value"].as_u64().unwrap(),
        );
        let le = val.to_le_bytes();
        b[off..off + size].copy_from_slice(&le[..size]);
    }
    b
}

fn real() -> &'static Weather {
    static W: OnceLock<Weather> = OnceLock::new();
    W.get_or_init(|| weather_of(&real_grids(&[])))
}

// ---------------------------------------------------------------- E1

fn check_cell(d: &mut Diff, tag: &str, w: &Weather, row: &Value) {
    let c = w.climate_at(
        f(&row["lat"]),
        f(&row["lon"]),
        f(&row["month"]) as i64,
        f(&row["day"]) as i64,
    );
    let at = &row["at"];
    for (k, got) in [
        ("td_c", c.td_c),
        ("td_sd_k", c.td_sd_k),
        ("z_cell_m", c.z_cell_m),
        ("t700_c", c.t700_c),
        ("z700_m", c.z700_m),
        ("tx_c", c.tx_c),
        ("dtr_k", c.dtr_k),
        ("wr", c.wr),
        ("trop_m", c.trop_m),
        ("hcc", c.hcc),
    ] {
        d.num(
            &format!("{tag} {k} @{} {}", row["lat"], row["lon"]),
            got,
            &at[k],
        );
    }
    let s = &at["src"];
    let src = ClimateSrc {
        hh1: s["hh1"].as_str().unwrap().into(),
        hh2: s["hh2"].as_str().unwrap().into(),
        hh5: s["hh5"].as_str().unwrap().into(),
        hh6: s["hh6"].as_str().unwrap().into(),
    };
    d.eq(
        &format!("{tag} src @{} {}", row["lat"], row["lon"]),
        c.src,
        src,
    );
}

#[test]
fn e1_climate_at() {
    let mut d = Diff::default();
    let cache: Mutex<HashMap<String, Arc<Weather>>> = Mutex::new(HashMap::new());
    let get = |key: String, make: &dyn Fn() -> Weather| -> Arc<Weather> {
        cache
            .lock()
            .unwrap()
            .entry(key)
            .or_insert_with(|| Arc::new(make()))
            .clone()
    };
    for row in rows("e1_climate_at") {
        let variant = row["variant"].as_str().unwrap();
        let w: Arc<Weather> = match variant {
            "real" => get("real".into(), &|| weather_of(&real_grids(&[]))),
            "synth_nodata_all" => get(variant.into(), &|| {
                let items: Vec<_> = GRID_NAMES
                    .iter()
                    .map(|g| (*g, unpack(&synth_file(g))))
                    .collect();
                weather_of(&items)
            }),
            v if v.starts_with("synth_nodata_") => {
                let g = v.trim_start_matches("synth_nodata_").to_string();
                get(variant.into(), &|| {
                    let mut items = real_grids(&[g.as_str()]);
                    let name = GRID_NAMES.iter().find(|n| **n == g).unwrap();
                    items.push((*name, unpack(&synth_file(&g))));
                    weather_of(&items)
                })
            }
            _ => {
                let g = row["grid"].as_str().unwrap().to_string();
                let key = format!("{variant}/{g}/{}", row["patch"]);
                get(key, &|| {
                    let mut items = real_grids(&[g.as_str()]);
                    if row["missing"].as_bool() != Some(true) {
                        let name = GRID_NAMES.iter().find(|n| **n == g).unwrap();
                        items.push((*name, unpack(&variant_file(&row))));
                    }
                    weather_of(&items)
                })
            }
        };
        check_cell(&mut d, variant, &w, &row);
    }
    d.finish("E1");
}

// ---------------------------------------------------------------- E2

fn check_place(d: &mut Diff, tag: &str, w: &Weather, row: &Value) {
    let ctx = ctx_of(&row["ctx"]);
    let p = w.climate_place(&ctx);
    let want = &row["place"];
    for (k, got) in [
        ("td_c", p.td_c),
        ("td_sd_k", p.td_sd_k),
        ("z_cell_m", p.z_cell_m),
        ("t700_c", p.t700_c),
        ("z700_m", p.z700_m),
        ("tx_c", p.tx_c),
        ("dtr_k", p.dtr_k),
        ("wr", p.wr),
        ("trop_m", p.trop_m),
        ("hcc", p.hcc),
        ("gain_per_km", p.gain_per_km),
    ] {
        d.num(&format!("{tag} {k} {}", row["ctx"]), got, &want[k]);
    }
    d.eq(
        &format!("{tag} hh6 {}", row["ctx"]),
        p.src.hh6,
        want["src"]["hh6"].as_str().unwrap().to_string(),
    );
    d.eq(
        &format!("{tag} hh1 {}", row["ctx"]),
        p.src.hh1,
        want["src"]["hh1"].as_str().unwrap().to_string(),
    );
}

#[test]
fn e2_climate_place() {
    let mut d = Diff::default();
    let cfg = real().configs().wm.raw.clone();
    let cache: Mutex<HashMap<String, Arc<Weather>>> = Mutex::new(HashMap::new());
    for row in rows("e2_climate_place") {
        match row["kind"].as_str().unwrap() {
            "place" | "place_edge" => check_place(&mut d, "place", real(), &row),
            "place_off" => {
                let off: Vec<String> = row["off"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().into())
                    .collect();
                let key = off.join(",");
                let w = cache
                    .lock()
                    .unwrap()
                    .entry(key)
                    .or_insert_with(|| {
                        let skip: Vec<&str> = off.iter().map(String::as_str).collect();
                        Arc::new(weather_of(&real_grids(&skip)))
                    })
                    .clone();
                check_place(&mut d, "place_off", &w, &row);
            }
            "season_index" => {
                let got = season_index(f(&row["month"]) as i64, f(&row["lat"])) as i64;
                d.eq("season_index", got, row["out"].as_i64().unwrap());
            }
            "gradients" => {
                let (lat, s) = (f(&row["lat"]), row["season"].as_u64().unwrap() as usize);
                let cl = cfg.get("climate");
                let g = |k: &str, def: f64| belt_gradient(lat, s, cl.and_then(|c| c.get(k)), def);
                d.num(
                    "td_gradient",
                    g("td_gradient_k_per_km", -4.0),
                    &row["td_gradient"],
                );
                d.num("belt_tx", g("tx_gradient_k_per_km", -6.31), &row["belt_tx"]);
                d.num(
                    "belt_dtr",
                    g("dtr_gradient_k_per_km", -0.48),
                    &row["belt_dtr"],
                );
            }
            "band_index" => {
                let b: Vec<f64> = row["bounds"].as_array().unwrap().iter().map(f).collect();
                d.eq(
                    "band_index",
                    band_index(f(&row["lat"]), &b) as i64,
                    row["out"].as_i64().unwrap(),
                );
            }
            k => panic!("E2: вид {k}"),
        }
    }
    d.finish("E2");
}

// ---------------------------------------------------------------- E3

#[test]
fn e3_surface_temp() {
    let w = real();
    let mut d = Diff::default();
    for row in rows("e3_surface_temp") {
        let ctx = ctx_of(&row["ctx"]);
        let z = f(&row["z"]);
        let got = match row["kind"].as_str().unwrap() {
            "air" => w.air_temp_c(f(&row["hour"]), f(&row["t_max"]), z, &ctx),
            "water" | "water_edge" => {
                w.water_temp_c(f(&row["month"]) as i64, f(&row["day"]) as i64, z, &ctx)
            }
            k => panic!("E3: вид {k}"),
        };
        d.num(
            &format!("{} {} {}", row["kind"], row["place"], row["ctx"]),
            got,
            &row["out"],
        );
    }
    d.finish("E3");
}

// ---------------------------------------------------------------- E4

fn state_check(d: &mut Diff, tag: &str, w: &Weather, row: &Value) {
    let ctx = ctx_of(&row["ctx"]);
    let (t_max, hour) = (f(&row["t_max"]), f(&row["hour"]));
    let s = w.diurnal_state(t_max, hour, &ctx);
    let o = &row["out"];
    let id = format!("{tag} {} t_max={t_max} h={hour}", row["ctx"]);
    d.num(
        &format!("{id} temperature_c"),
        s.temperature_c,
        &o["temperature_c"],
    );
    d.num(&format!("{id} cap_agl_m"), s.cap_agl_m, &o["cap_agl_m"]);
    d.num(&format!("{id} break"), s.brk, &o["break"]);
    d.num(&format!("{id} heat"), s.heat, &o["heat"]);
    d.num(&format!("{id} soft"), s.soft, &o["soft"]);
    d.num(&format!("{id} mech_k"), s.mech_k, &o["mech_k"]);
    d.num(&format!("{id} sunrise_h"), s.sunrise_h, &o["sunrise_h"]);
    d.num(&format!("{id} sunset_h"), s.sunset_h, &o["sunset_h"]);
    d.num(&format!("{id} peak_h"), s.peak_h, &o["peak_h"]);
    d.num(
        &format!("{id} sunrise_h()"),
        w.sunrise_h(t_max, &ctx),
        &o["sunrise_h"],
    );
    d.num(
        &format!("{id} sunset_h()"),
        w.sunset_h(t_max, &ctx),
        &o["sunset_h"],
    );
}

#[test]
fn e4_weather_diurnal() {
    let w = real();
    let mut d = Diff::default();
    for row in rows("e4_weather_diurnal") {
        let kind = row["kind"].as_str().unwrap();
        let ctx = ctx_of(&row["ctx"]);
        match kind {
            "typical_max"
            | "typical_max_no_valley"
            | "typical_max_no_ctx"
            | "typical_max_clamp" => {
                let got = w.typical_max_c(
                    f(&row["month"]) as i64,
                    f(&row["day"]) as i64,
                    ctx.lat,
                    ctx.lon,
                    ctx.valley_msl_m,
                );
                d.num(
                    &format!("{kind} {} m{} d{}", row["ctx"], row["month"], row["day"]),
                    got,
                    &row["out"],
                );
            }
            "range" | "range_cp" | "range_table" => {
                d.num(
                    &format!("{kind} {}", row["ctx"]),
                    w.diurnal_range_k(&ctx),
                    &row["out"],
                );
            }
            "state" | "state_cp" => state_check(&mut d, kind, w, &row),
            k => panic!("E4: вид {k}"),
        }
    }
    d.finish("E4");
}

// ---------------------------------------------------------------- E5

fn place_of(v: &Value) -> ClimatePlace {
    let g = |k: &str| f(&v[k]);
    let s = |k: &str| v["src"][k].as_str().unwrap().to_string();
    ClimatePlace {
        td_c: g("td_c"),
        td_sd_k: g("td_sd_k"),
        z_cell_m: g("z_cell_m"),
        t700_c: g("t700_c"),
        z700_m: g("z700_m"),
        tx_c: g("tx_c"),
        dtr_k: g("dtr_k"),
        wr: g("wr"),
        trop_m: g("trop_m"),
        hcc: g("hcc"),
        gain_per_km: g("gain_per_km"),
        src: ClimateSrc {
            hh1: s("hh1"),
            hh2: s("hh2"),
            hh5: s("hh5"),
            hh6: s("hh6"),
        },
    }
}

#[test]
fn e5_weather_small() {
    let w = real();
    let wm = &w.configs().wm;
    let mut d = Diff::default();
    for row in rows("e5_weather_small") {
        let kind = row["kind"].as_str().unwrap();
        match kind {
            "reference_context" | "reference_context_cfg" => {
                let c = w.reference_context();
                let o = &row["out"];
                d.num("rc.month", c.month as f64, &o["month"]);
                d.num("rc.day", c.day as f64, &o["day"]);
                d.num("rc.lat", c.lat, &o["lat"]);
                d.num("rc.lon", c.lon, &o["lon"]);
                d.num("rc.valley", c.valley_msl_m, &o["valley_msl_m"]);
                d.num("rc.mean", c.mean_msl_m, &o["mean_msl_m"]);
                d.num("rc.utc", c.utc_offset_h, &o["utc_offset_h"]);
            }
            "sky_params" => {
                let (cover, heat) = w.sky_params(row["sky"].as_str().unwrap());
                d.num(
                    &format!("sky {} cover", row["sky"]),
                    cover,
                    &row["out"]["cover"],
                );
                d.num(
                    &format!("sky {} heat", row["sky"]),
                    heat,
                    &row["out"]["heat"],
                );
            }
            "haze" | "haze_zero" => {
                d.num(
                    &format!("haze {} {}", row["t_c"], row["td_c"]),
                    w.haze_k_rh(f(&row["t_c"]), f(&row["td_c"])),
                    &row["out"],
                );
            }
            "sun_block" => {
                let m = row["w"].as_object().unwrap().clone();
                d.num("sun_block", sun_block_cover(&m), &row["out"]);
            }
            "monthly" | "monthly_default_day" => {
                let arr: Vec<f64> = row["arr"].as_array().unwrap().iter().map(f).collect();
                let day = row.get("day").map_or(15, |v| f(v) as i64);
                d.num(
                    &format!("monthly {} {day}", row["month"]),
                    monthly(&arr, f(&row["month"]) as i64, day),
                    &row["out"],
                );
            }
            "lerp_table" => {
                let xs: Vec<f64> = row["xs"].as_array().unwrap().iter().map(f).collect();
                let ys: Vec<f64> = row["ys"].as_array().unwrap().iter().map(f).collect();
                d.num(
                    "lerp_table",
                    lerp_table(&xs, &ys, f(&row["x"])),
                    &row["out"],
                );
            }
            "interp_rows" => {
                let tab = wm.raw[row["rows_key"].as_str().unwrap()]
                    .as_array()
                    .unwrap()
                    .clone();
                let got = interp_rows(&tab, row["key"].as_str().unwrap(), f(&row["x"]));
                let mut g2 = Map::new();
                for (k, v) in got {
                    g2.insert(k, v);
                }
                let want = row["out"].as_object().unwrap();
                for (k, wv) in want {
                    match (g2.get(k), wv) {
                        (Some(Value::Array(a)), Value::Array(b)) => {
                            for (x, y) in a.iter().zip(b) {
                                d.num(&format!("interp.{k}"), f(x), y);
                            }
                        }
                        (Some(g), wv) => d.num(&format!("interp.{k}"), f(g), wv),
                        (None, _) => d.eq(&format!("interp.{k}"), false, true),
                    }
                }
            }
            "interp_rows_empty" => d.eq("interp_empty", interp_rows(&[], "k", 0.0).len(), 0),
            "noon_elevation" => {
                let doy = day_of_year(f(&row["month"]) as i64, f(&row["day"]) as i64);
                d.num(
                    "noon_elevation",
                    sun_elevation_deg(f(&row["lat"]), 0.0, doy, 12.0, f64::NAN),
                    &row["out"],
                );
            }
            "td_noise" => {
                let got = td_noise(
                    f(&row["month"]) as i64,
                    f(&row["day"]) as i64,
                    f(&row["lat"]),
                    f(&row["lon"]),
                );
                d.num("td_noise", got, &row["out"]);
            }
            "cirrus_base" | "cirrus_base_hh6_none" => {
                let cp = place_of(&row["cp"]);
                let ctx = ctx_of(&row["ctx"]);
                let got = cirrus_base_cover(&cp, row["sky"].as_str().unwrap(), &ctx, wm);
                d.num(&format!("{kind} {}", row["ctx"]), got, &row["out"]);
            }
            k => panic!("E5: вид {k}"),
        }
    }
    d.finish("E5");
}

// ---------------------------------------------------------------- E7

#[test]
fn e7_temp_at_altitude() {
    let w = real();
    let mut d = Diff::default();
    for row in rows("e7_temp_at_altitude") {
        let mut m = Map::new();
        m.insert(
            "_derived".into(),
            if row["derived"].is_null() {
                Value::Object(Map::new())
            } else {
                row["derived"].clone()
            },
        );
        let got = w.temp_at_altitude(
            &m,
            f(&row["alt_msl"]),
            f(&row["month"]) as i64,
            f(&row["day"]) as i64,
        );
        d.num(
            &format!("{} alt={} m={}", row["place"], row["alt_msl"], row["month"]),
            got,
            &row["out"],
        );
    }
    d.finish("E7");
}

// ---------------------------------------------------------------- E8

#[test]
fn e8_goal_weather() {
    let w = real();
    let max_hour = {
        let v: Value =
            serde_json::from_str(&cfg_files().iter().find(|(n, _)| n == "world").unwrap().1)
                .unwrap();
        v.pointer("/time/max_hour").map_or(24.0, f)
    };
    let mut d = Diff::default();
    for row in rows("e8_goal_weather") {
        let s = &row["settings"];
        let ctx = ctx_of(&row["ctx"]);
        let fc: Forecast = serde_json::from_value(row["forecast"].clone()).unwrap();
        let hour = f(&s["hour"]);
        let wx = w.derive(&fc, &ctx, hour);
        let id = format!("{}", s["loc"]);
        let o = &row["out"];
        d.num(
            &format!("{id} cloudbase"),
            f(&wx["cloudbase_agl_m"]),
            &o["cloudbase_agl_m"],
        );
        let ts = wx["thermal_strength_ms"].as_array().unwrap();
        d.num(
            &format!("{id} thermal"),
            0.5 * (f(&ts[0]) + f(&ts[1])),
            &o["thermal_ms"],
        );
        d.num(
            &format!("{id} wind"),
            f(&wx["wind_speed_kmh"]) / 3.6,
            &o["wind_ms"],
        );
        d.num(
            &format!("{id} from"),
            f(&wx["wind_from_deg"]),
            &o["wind_from_deg"],
        );
        let day = w.diurnal_state(fc.temperature_c, hour, &ctx);
        let left = (day.sunset_h.min(max_hour) - hour).max(0.0);
        d.num(&format!("{id} hours_left"), left, &o["hours_left"]);
    }
    d.finish("E8");
}

// ---------------------------------------------------------------- E9

#[test]
fn e9_atmo_day() {
    let w = real();
    let mut d = Diff::default();
    for row in rows("e9_atmo_day") {
        match row["kind"].as_str().unwrap() {
            "sun" | "sun_pole" => {
                let v = w.sun_direction(
                    f(&row["lat"]),
                    f(&row["lon"]),
                    f(&row["month"]) as i64,
                    f(&row["day"]) as i64,
                    f(&row["hour"]),
                    f(&row["utc_offset_h"]),
                );
                for (k, got) in v.iter().enumerate() {
                    d.num(&format!("sun[{k}] {row}"), *got as f64, &row["out"][k]);
                }
            }
            "hour_at" => {
                let wt = WorldTime {
                    min_hour: f(&row["min_hour"]),
                    max_hour: f(&row["max_hour"]),
                    min_light_elevation_deg: 2.0,
                };
                let got = hour_at(
                    f(&row["start_hour"]),
                    f(&row["speed"]),
                    f(&row["t"]) - f(&row["t0"]),
                    &wt,
                );
                d.num(&format!("hour_at {row}"), got, &row["out"]);
            }
            k => panic!("E9: вид {k}"),
        }
    }
    d.finish("E9");
}

// ---------------------------------------------------------------- E10

fn heat_cfg() -> (SurfaceHeatCfg, Value) {
    let w = real();
    (w.configs().sh.clone(), w.configs().wm.raw.clone())
}

fn v3(v: &Value) -> [f64; 3] {
    [f(&v[0]), f(&v[1]), f(&v[2])]
}

#[test]
fn e10_heat_flux() {
    let (cfg, wm) = heat_cfg();
    let mut d = Diff::default();
    for row in rows("e10_heat_flux") {
        let kind = row["kind"].as_str().unwrap();
        let o = &row["out"];
        match kind {
            "shortwave" => d.num(
                kind,
                sh::shortwave(
                    f(&row["cos_inc"]),
                    f(&row["sin_el"]),
                    f(&row["cover"]),
                    &cfg,
                ),
                o,
            ),
            "diffuse_fraction" => d.num(kind, sh::diffuse_fraction(f(&row["k_t"]), 0.165), o),
            "long_wave" => d.num(kind, sh::long_wave(f(&row["cover"]), &cfg), o),
            "bowen" => d.num(
                kind,
                sh::bowen(row["cls"].as_u64().unwrap() as usize, f(&row["m"]), &cfg),
                o,
            ),
            "land_flux" => d.num(
                &format!("{kind} {row}"),
                sh::land_flux(
                    row["cls"].as_u64().unwrap() as usize,
                    f(&row["k_down"]),
                    f(&row["cover"]),
                    f(&row["m"]),
                    &cfg,
                ),
                o,
            ),
            "air_density" => d.num(kind, sh::air_density_factor(f(&row["z"]), &cfg), o),
            "water_flux" => d.num(
                &format!("{kind} {row}"),
                sh::water_flux(
                    f(&row["t_water_c"]),
                    f(&row["t_air_c"]),
                    f(&row["u_ms"]),
                    &cfg,
                    f(&row["z_m"]),
                ),
                o,
            ),
            "built_night_flux" => {
                let n = Night {
                    sin_s: f(&row["night"]["sin_s"]),
                    dt_h: f(&row["night"]["dt_h"]),
                };
                d.num(
                    kind,
                    sh::built_night_flux(&n, f(&row["cover"]), f(&row["m"]), &cfg),
                    o,
                );
            }
            "mix_flux" | "mix_flux_off" => {
                let off = row.get("off").map_or(0, |v| v.as_u64().unwrap() as usize);
                let fr: Vec<f32> = row["fracs"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .skip(off)
                    .take(CLASS_COUNT)
                    .map(|v| f(v) as f32)
                    .collect();
                let sun: Vec<[f64; 3]> = row["class_sun"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(v3)
                    .collect();
                let sky_v = &row["sky"];
                let night = sky_v
                    .get("night")
                    .filter(|n| n.as_object().is_some_and(|o| !o.is_empty()));
                let sky = Sky {
                    cover: sky_v.get("cover").map_or(0.0, f),
                    sky_heat: sky_v.get("sky_heat").map_or(1.0, f),
                    night: night.map(|n| Night {
                        sin_s: f(&n["sin_s"]),
                        dt_h: f(&n["dt_h"]),
                    }),
                };
                let wv = &row["water"];
                let water = wv.as_object().filter(|o| !o.is_empty()).map(|_| {
                    let tw = wv.get("t_water_c").map_or(0.0, f);
                    WaterIn {
                        t_water_c: tw,
                        t_air_c: wv.get("t_air_c").map_or(tw, f),
                        u_ms: wv.get("u_ms").map_or(0.0, f),
                        z_m: wv.get("z_m").map_or(0.0, f),
                    }
                });
                let got = sh::mix_flux(
                    &fr,
                    v3(&row["normal"]),
                    &sun,
                    f(&row["m"]),
                    &sky,
                    water.as_ref(),
                    &cfg,
                );
                d.num(&format!("{kind} {} {}", row["name"], row["m"]), got, o);
            }
            "heating_setup" | "heating" => {
                let sp = &row["spot"];
                let mut heating = wm["heating"].clone();
                if row["enabled"].as_bool() == Some(false) {
                    heating["enabled"] = Value::Bool(false);
                }
                let hs = SurfaceHeating::new(
                    f(&sp["lat"]),
                    f(&sp["lon"]),
                    f(&sp["month"]) as i64,
                    f(&sp["day"]) as i64,
                    f(&sp["utc"]),
                    &heating,
                );
                if kind == "heating_setup" {
                    d.eq("doy", hs.doy, row["doy"].as_i64().unwrap());
                    d.num("sunset_h", hs.sunset_h, &row["sunset_h"]);
                    for (k, l) in row["lags_h"].as_array().unwrap().iter().enumerate() {
                        d.num("lag", hs.lags_h[k], l);
                    }
                } else {
                    let hour = f(&row["hour"]);
                    let sun = hs.sun_at(hour);
                    for k in 0..3 {
                        d.num(&format!("sun {}", sp["name"]), sun[k], &row["sun"][k]);
                    }
                    match (hs.directions(hour), row["directions"].as_array()) {
                        (Some(dirs), Some(want)) => {
                            for (c, w) in want.iter().enumerate() {
                                for k in 0..3 {
                                    d.num(
                                        &format!("dir {} h{hour}", sp["name"]),
                                        dirs[c][k],
                                        &w[k],
                                    );
                                }
                            }
                        }
                        (None, Some(want)) => {
                            // выключено: всем классам текущее солнце
                            for w in want {
                                for k in 0..3 {
                                    d.num(
                                        &format!("dir_off {} h{hour}", sp["name"]),
                                        sun[k],
                                        &w[k],
                                    );
                                }
                            }
                        }
                        (g, w) => d.eq("directions", g.is_some(), w.is_some()),
                    }
                    let bn = row["built_night"].as_object().filter(|o| !o.is_empty());
                    match (hs.built_night(hour), bn) {
                        (Some(n), Some(w)) => {
                            d.num("night.sin_s", n.sin_s, &w["sin_s"]);
                            d.num("night.dt_h", n.dt_h, &w["dt_h"]);
                        }
                        (None, None) => d.n += 1,
                        (g, w) => d.eq("built_night", g.is_some(), w.is_some()),
                    }
                }
            }
            k => panic!("E10: вид {k}"),
        }
    }
    d.finish("E10");
}

// ---------------------------------------------------------------- E6

/// E6: `ground_context` по растру места (долина и средняя высота в круге) - считается и конечна
/// на местах эталона; разность с растром GD (`raster`) только измеряется: решение 2026-10-30,
/// Δ = 0,0 м, поэтому допуск здесь широкий (0,5 м) и ловит лишь поломку, не сверяет формулу.
#[test]
fn e6_ground_context() {
    use dp_air::field::weather_core::ground_context;
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/wind/places");
    let mut places: HashMap<String, dp_air::Place> = HashMap::new();
    let (mut n, mut worst) = (0usize, 0.0f64);
    for row in rows("e6_ground_context") {
        if row["kind"].as_str() != Some("ground") {
            continue;
        }
        let name = row["place"].as_str().unwrap().to_string();
        let place = places.entry(name.clone()).or_insert_with(|| {
            dp_air::fixtures::read_place(&dir.join(format!("{name}.json"))).unwrap()
        });
        let (valley, mean) = ground_context(
            place,
            f(&row["radius_m"]),
            f(&row["samples"]) as usize,
            f(&row["percentile"]),
        );
        assert!(
            valley.is_finite() && mean.is_finite(),
            "{name}: {valley} {mean}"
        );
        assert!(
            valley <= mean + 1e-6 || row["percentile"].as_f64().unwrap() > 0.5,
            "{name}"
        );
        let (want_v, want_m) = (
            f(&row["raster"]["valley_msl_m"]),
            f(&row["raster"]["mean_msl_m"]),
        );
        worst = worst
            .max((valley - want_v).abs())
            .max((mean - want_m).abs());
        n += 1;
    }
    eprintln!("E6: {n} строк, наибольшая разность с растром GD {worst:.4} м");
    assert!(n >= 40, "E6: строк {n}");
    assert!(worst <= 0.5, "E6: разность с растром GD {worst} м");
}
