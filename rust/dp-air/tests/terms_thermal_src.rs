//! RW-10c: сила источников термиков из растров места (`terms::thermal_src`).
//!
//! Эталон GD — опорная ревизия c591b1026 (`tests/data/RW-10c/`, снят `dump_source.gd`):
//! `AirPlaceData.source_at` (растровый путь, допуск 1e-4) и `Terrain.thermal_source_strength_water`
//! на рельефе игры (слои 10 м; доля точек с |Δ| > 0,05 печатается — это мера границы модели, не
//! допуск). Остальное — свойства на малых местах: вода (день/ночь/лёд), ночь, скалы, край.
use dp_air::field::surface_heat::{Night, SurfaceHeatCfg, WaterIn};
use dp_air::fixtures::read_place;
use dp_air::terms::thermal_src::{
    SourceCfg, SourceHour, class_at, edge_at, raster_source, source_grid, source_strength,
};
use dp_air::{Configs, Place, PlaceHeader};
use serde_json::Value;
use std::path::{Path, PathBuf};

const FOREST: usize = 1;
const GRASS: usize = 2;
const CROP: usize = 3;
const BARE: usize = 5;
const WATER: usize = 6;
const BUILT: usize = 7;
const SNOW: usize = 8;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data() -> PathBuf {
    repo().join("rust/dp-air/tests/data/RW-10c")
}

fn configs() -> Configs {
    let read = |n: &str| std::fs::read_to_string(repo().join("configs").join(n)).unwrap();
    Configs::new(vec![
        ("surface_heat".into(), read("surface_heat.json")),
        ("world".into(), read("world.json")),
    ])
}

fn cfg() -> SourceCfg {
    SourceCfg::from_configs(&configs()).unwrap()
}

fn fixture(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

fn f32s(path: &Path) -> Vec<f32> {
    std::fs::read(path)
        .unwrap()
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

fn manifest() -> Value {
    serde_json::from_str(&std::fs::read_to_string(data().join("manifest.json")).unwrap()).unwrap()
}

fn v3(v: &Value) -> [f64; 3] {
    let a = v.as_array().unwrap();
    [
        a[0].as_f64().unwrap(),
        a[1].as_f64().unwrap(),
        a[2].as_f64().unwrap(),
    ]
}

/// Вход часа из дампа GD (`manifest.json`, `places[].hours[]`).
fn hour_of(h: &Value) -> SourceHour {
    let to_sun = v3(&h["to_sun"]);
    let dirs = h["class_sun"].as_array().unwrap();
    let mut hr = SourceHour::uniform(to_sun);
    if dirs.len() == 9 {
        for (k, d) in dirs.iter().enumerate() {
            hr.class_sun[k] = v3(d);
        }
    }
    let w = &h["water"];
    if w.as_object().is_some_and(|o| !o.is_empty()) {
        hr.water = Some(WaterIn {
            t_water_c: w["t_water_c"].as_f64().unwrap(),
            t_air_c: w["t_air_c"].as_f64().unwrap(),
            u_ms: w["u_ms"].as_f64().unwrap(),
            z_m: w["z_m"].as_f64().unwrap(),
        });
    }
    let n = &h["night"];
    if n.as_object().is_some_and(|o| !o.is_empty()) {
        hr.night = Some(Night {
            sin_s: n["sin_s"].as_f64().unwrap(),
            dt_h: n["dt_h"].as_f64().unwrap(),
        });
    }
    hr
}

struct Pts {
    x0: f64,
    z0: f64,
    nx: usize,
    nz: usize,
}

impl Pts {
    fn of(p: &Value) -> Self {
        Pts {
            x0: p["x0"].as_f64().unwrap(),
            z0: p["z0"].as_f64().unwrap(),
            nx: p["nx"].as_u64().unwrap() as usize,
            nz: p["nz"].as_u64().unwrap() as usize,
        }
    }
    fn xz(&self, k: usize) -> (f64, f64) {
        (
            self.x0 + (k % self.nx) as f64 * 50.0,
            self.z0 + (k / self.nx) as f64 * 50.0,
        )
    }
    fn n(&self) -> usize {
        self.nx * self.nz
    }
}

// ------------------------------------------------------------ малые места

/// Место `w × h`, шаг 25 м, начало (0, 0); высота, класс, вода и влажность — функциями узла.
fn mini(
    w: u32,
    h: u32,
    height: impl Fn(f64, f64) -> f64,
    cls: impl Fn(u32, u32) -> u8,
    water: impl Fn(u32, u32) -> u8,
    moist: f32,
) -> Place {
    let head = format!(
        r#"{{"version":1,"loc":{{"id":"t","center_lat":50.0,"center_lon":85.0,"utc_offset_h":6.0,
        "month":7,"day":15}},"grid":{{"origin_x":0.0,"origin_z":0.0,"spacing":25.0,"width":{w},"height":{h}}},
        "surface_classes":{{}},"start_sites":[]}}"#
    );
    let header = PlaceHeader::from_json(&head).unwrap();
    let (mut hs, mut cs, mut ws) = (Vec::new(), Vec::new(), Vec::new());
    for j in 0..h {
        for i in 0..w {
            hs.push(height(i as f64 * 25.0, j as f64 * 25.0) as f32);
            cs.push(cls(i, j));
            ws.push(water(i, j));
        }
    }
    let n = (w * h) as usize;
    Place::new(header, hs, ws, cs, vec![moist; n]).unwrap()
}

/// Солнце под 30° над горизонтом с юга-запада; всем классам одно.
fn sun30() -> SourceHour {
    let el = 30f64.to_radians();
    SourceHour::uniform([0.0, el.sin(), -el.cos()])
}

fn flat(cls: impl Fn(u32, u32) -> u8, water: impl Fn(u32, u32) -> u8) -> Place {
    mini(61, 61, |_, _| 500.0, cls, water, 0.5)
}

const MID: f64 = 750.0;

// ------------------------------------------------------------ тесты

#[test]
fn config_matches_game() {
    let c = cfg();
    assert_eq!(c.h_ref, 360.0, "surface_heat.thermal.h_ref_wm2");
    assert_eq!(c.edge_boost, 0.3);
    assert_eq!((c.edge_full_m, c.edge_max_m), (50.0, 150.0));
    assert!((c.rock_cos - 38f64.to_radians().cos()).abs() < 1e-15);
    let pair = |a: usize, b: usize| c.edge_pair[a * 9 + b];
    for (a, b) in [
        (CROP, FOREST),
        (GRASS, FOREST),
        (CROP, GRASS),
        (BARE, FOREST),
        (4, FOREST),
    ] {
        assert!(pair(a, b) && pair(b, a), "пара {a}-{b} симметрична");
    }
    assert!(
        !pair(WATER, FOREST) && !pair(GRASS, GRASS),
        "вода не триггер"
    );
    let heat = SurfaceHeatCfg::from_value(
        &serde_json::from_str(
            &std::fs::read_to_string(repo().join("configs/surface_heat.json")).unwrap(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(c.heat, heat);
    assert!(SourceCfg::from_configs(&Configs::new(vec![])).is_err());
}

/// Растровый путь `AirPlaceData.source_at`: допуск 1e-4 на сетках четырёх мест.
#[test]
fn raster_path_matches_gd_source_at() {
    let m = manifest();
    let mut worst = 0.0f64;
    for p in m["places"].as_array().unwrap() {
        let name = p["name"].as_str().unwrap();
        let place = fixture(name);
        let pts = Pts::of(p);
        let gd = f32s(&data().join(format!("{name}.src.f32")));
        assert_eq!(gd.len(), pts.n());
        let mut mx = 0.0f64;
        for (k, &g) in gd.iter().enumerate() {
            let (x, z) = pts.xz(k);
            mx = mx.max((raster_source(&place, x, z) - g).abs() as f64);
        }
        println!(
            "raster_source {name}: max|Δ| = {mx:.2e} на {} точках",
            gd.len()
        );
        assert!(mx <= 1e-4, "{name}: max|Δ| = {mx}");
        worst = worst.max(mx);
    }
    println!("raster_source: max|Δ| по местам = {worst:.2e}");
}

/// Рельеф игры (слои 10 м) против растра 25 м: доля точек с |Δ| > 0,05 — мера границы модели.
#[test]
fn terrain_path_difference_is_measured() {
    let m = manifest();
    let c = cfg();
    let (mut tot, mut bad_tot) = (0usize, 0usize);
    for p in m["places"].as_array().unwrap() {
        if !p["terrain"].as_bool().unwrap() {
            continue;
        }
        let name = p["name"].as_str().unwrap();
        let place = fixture(name);
        let pts = Pts::of(p);
        // класс точки и близость к границе: по отдельности
        let cls = std::fs::read(data().join(format!("{name}.cls.u8"))).unwrap();
        let edge = f32s(&data().join(format!("{name}.edge.f32")));
        let (mut same, mut edge_bad) = (0usize, 0usize);
        for k in 0..pts.n() {
            let (x, z) = pts.xz(k);
            same += (class_at(&place, &c, x, z) == cls[k] as usize) as usize;
            edge_bad += ((edge_at(&place, &c, x, z) - edge[k] as f64).abs() > 0.05) as usize;
        }
        println!(
            "{name}: класс совпал в {:.1} % точек, близость к границе |Δ| > 0,05 в {:.1} %",
            100.0 * same as f64 / pts.n() as f64,
            100.0 * edge_bad as f64 / pts.n() as f64
        );
        for h in p["hours"].as_array().unwrap() {
            let hour = h["hour"].as_f64().unwrap();
            let hr = hour_of(h);
            let tag = format!("{hour:?}").replace('.', "_");
            let gd = f32s(&data().join(format!("{name}.h{tag}.f32")));
            assert_eq!(gd.len(), pts.n());
            let (mut bad, mut sum, mut mx, mut gd_pos) = (0usize, 0.0f64, 0.0f64, 0usize);
            for (k, &g) in gd.iter().enumerate() {
                let (x, z) = pts.xz(k);
                let s = source_strength(&place, &c, &hr, x, z);
                assert!(s.is_finite() && (0.0..=1.0).contains(&s));
                let d = (s - g).abs() as f64;
                bad += (d > 0.05) as usize;
                sum += d;
                mx = mx.max(d);
                gd_pos += (g > 0.0) as usize;
            }
            println!(
                "{name} {hour:>4} ч: |Δ| > 0,05 в {:5.2} % точек (средн. {:.4}, макс. {:.3}); GD > 0 в {:.1} %",
                100.0 * bad as f64 / pts.n() as f64,
                sum / pts.n() as f64,
                mx,
                100.0 * gd_pos as f64 / pts.n() as f64
            );
            tot += pts.n();
            bad_tot += bad;
        }
    }
    let frac = bad_tot as f64 / tot as f64;
    println!(
        "ВСЕГО: доля точек с |Δ| > 0,05 против GD = {:.2} % ({bad_tot} из {tot})",
        100.0 * frac
    );
    // защита от регрессии, не допуск: измеренная доля (см. «Границы модели» в thermal_src) с запасом
    assert!(frac < 0.03, "доля расхождений {frac}");
}

/// Растр на место совпадает с опросом в узлах.
#[test]
fn grid_equals_pointwise() {
    let place = mini(
        41,
        41,
        |x, z| 500.0 + 0.2 * x + 0.1 * z,
        |i, j| {
            if (i / 8 + j / 8) % 2 == 0 {
                GRASS as u8
            } else {
                FOREST as u8
            }
        },
        |_, _| 0,
        0.45,
    );
    let c = cfg();
    let hr = sun30();
    let g = source_grid(&place, &c, &hr);
    assert_eq!(g.len(), 41 * 41);
    for j in 0..41 {
        for i in 0..41 {
            let s = source_strength(&place, &c, &hr, i as f64 * 25.0, j as f64 * 25.0);
            assert_eq!(g[j * 41 + i], s);
        }
    }
    assert!(g.iter().any(|&v| v > 0.0));
}

/// Вода: без контекста воды сила 0; тёплая вода греет, холодная — нет; лёд — как снег.
#[test]
fn water_day_night_ice() {
    let c = cfg();
    let w_cls = |_, _| WATER as u8;
    let place = flat(w_cls, |_, _| 1);
    let mut hr = sun30();
    assert_eq!(
        source_strength(&place, &c, &hr, MID, MID),
        0.0,
        "нет контекста воды"
    );
    let water = |tw: f64| WaterIn {
        t_water_c: tw,
        t_air_c: 10.0,
        u_ms: 3.0,
        z_m: 0.0,
    };
    hr.water = Some(water(8.0));
    assert_eq!(
        source_strength(&place, &c, &hr, MID, MID),
        0.0,
        "вода холоднее воздуха"
    );
    hr.water = Some(water(20.0));
    let warm = source_strength(&place, &c, &hr, MID, MID);
    // H = ρc_p · C_H · U · ΔT = 1206 · 1,4e-3 · 3 · 10 = 50,7 Вт/м²; /360
    assert!(
        (warm as f64 - 1206.0 * 1.4e-3 * 3.0 * 10.0 / 360.0).abs() < 1e-3,
        "{warm}"
    );
    // вода есть и по `water`-растру при классе луг: река поверх cls
    let river = flat(|_, _| GRASS as u8, |_, _| 1);
    assert_eq!(source_strength(&river, &c, &hr, MID, MID), warm);
    // лёд: T воды ≤ 0 — как снег (то же солнце), а не вода
    hr.water = Some(water(0.0));
    let ice = source_strength(&place, &c, &hr, MID, MID);
    let snow = source_strength(&flat(|_, _| SNOW as u8, |_, _| 0), &c, &hr, MID, MID);
    assert_eq!(ice, snow);
    assert!(ice > 0.0 && ice != warm);
}

/// Ночь: без солнца суша не греет, застройка остывает от закатного потока до ночного предела.
#[test]
fn night_built_decays_to_floor() {
    let c = cfg();
    let mut hr = SourceHour::uniform([0.0; 3]);
    let grass = flat(|_, _| GRASS as u8, |_, _| 0);
    assert_eq!(source_strength(&grass, &c, &hr, MID, MID), 0.0);
    let built = flat(|_, _| BUILT as u8, |_, _| 0);
    assert_eq!(
        source_strength(&built, &c, &hr, MID, MID),
        0.0,
        "без ночи застройки"
    );
    let at = |hr: &mut SourceHour, dt: f64| {
        hr.night = Some(Night {
            sin_s: 0.3,
            dt_h: dt,
        });
        source_strength(&built, &c, hr, MID, MID)
    };
    let (s0, s2, s100) = (at(&mut hr, 0.0), at(&mut hr, 2.0), at(&mut hr, 100.0));
    assert!(s0 > s2 && s2 > s100, "{s0} {s2} {s100}");
    let floor = c.heat.classes[BUILT].night_floor_wm2 / c.h_ref;
    assert!(
        floor > 0.0 && (s100 as f64 - floor).abs() < 1e-4,
        "{s100} против {floor}"
    );
}

/// Скалы: луг на склоне круче `rock_slope_deg` считается голым грунтом; лес и вода — нет.
#[test]
fn rock_slope_makes_bare() {
    let c = cfg();
    let tan = |deg: f64| deg.to_radians().tan();
    let slope = |deg: f64, cls: u8, water: u8| {
        mini(
            61,
            61,
            move |x, _| 500.0 + tan(deg) * x,
            move |_, _| cls,
            move |_, _| water,
            0.5,
        )
    };
    for (deg, want) in [(30.0, GRASS), (37.0, GRASS), (40.0, BARE), (60.0, BARE)] {
        let p = slope(deg, GRASS as u8, 0);
        assert_eq!(class_at(&p, &c, MID, MID), want, "{deg}°");
    }
    for cls in [GRASS, CROP, 4, 0] {
        assert_eq!(
            class_at(&slope(50.0, cls as u8, 0), &c, MID, MID),
            BARE,
            "класс {cls}"
        );
    }
    assert_eq!(
        class_at(&slope(50.0, FOREST as u8, 0), &c, MID, MID),
        FOREST
    );
    assert_eq!(class_at(&slope(50.0, GRASS as u8, 1), &c, MID, MID), WATER);
    // сила луга на крутом склоне = сила голого грунта на той же поверхности
    let hr = sun30();
    let a = source_strength(&slope(50.0, GRASS as u8, 0), &c, &hr, MID, MID);
    let b = source_strength(&slope(50.0, BARE as u8, 0), &c, &hr, MID, MID);
    assert_eq!(a, b);
    assert_ne!(
        source_strength(&slope(10.0, GRASS as u8, 0), &c, &hr, MID, MID),
        source_strength(&slope(10.0, BARE as u8, 0), &c, &hr, MID, MID)
    );
}

/// Край: граница поле-лес усиливает до ×(1 + edge_boost) ближе edge_full_m/2 и линейно сходит на нет
/// к edge_max_m; вода не триггер; без усиления (edge_boost = 0) сила не меняется.
#[test]
fn edge_boost_near_class_boundary() {
    let c = cfg();
    let mut off = c.clone();
    off.edge_boost = 0.0;
    let hr = sun30();
    // лес при x < 750 м, поле при x ≥ 750 м
    let place = flat(
        |i, _| if i < 30 { FOREST as u8 } else { CROP as u8 },
        |_, _| 0,
    );
    let z = MID;
    let mut prev = 2.0;
    let mut seen_mid = false;
    for d in [0.0, 25.0, 50.0, 75.0, 100.0, 125.0, 150.0, 200.0, 400.0] {
        let x = 750.0 + d; // в поле на d от границы
        let e = edge_at(&place, &c, x, z);
        assert!(
            (0.0..=1.0).contains(&e) && e <= prev + 1e-12,
            "d = {d}: e = {e}"
        );
        prev = e;
        seen_mid |= e > 0.05 && e < 0.95;
        let s_on = source_strength(&place, &c, &hr, x, z);
        let s_off = source_strength(&place, &off, &hr, x, z);
        assert!(
            s_off > 0.0 && s_off * 1.3 < 1.0,
            "нужна сила без насыщения: {s_off}"
        );
        assert!(
            ((s_on / s_off) as f64 - (1.0 + c.edge_boost * e)).abs() < 1e-5,
            "d = {d}: ×{}",
            s_on / s_off
        );
    }
    assert!(
        seen_mid,
        "в полосе между edge_full и edge_max есть промежуточные значения"
    );
    assert_eq!(edge_at(&place, &c, 750.0, z), 1.0);
    assert_eq!(edge_at(&place, &c, 750.0 + 400.0, z), 0.0);
    // вода рядом с лесом — не триггер
    let wf = flat(
        |i, _| if i < 30 { FOREST as u8 } else { WATER as u8 },
        |_, _| 0,
    );
    assert_eq!(edge_at(&wf, &c, 770.0, z), 0.0);
    // однородный класс — края нет
    let uni = flat(|_, _| CROP as u8, |_, _| 0);
    assert_eq!(edge_at(&uni, &c, MID, z), 0.0);
}

/// Вне сетки — край сетки; точки с NaN не отдают NaN в сумму не требуется, но числа конечны.
#[test]
fn outside_grid_is_clamped_and_finite() {
    let c = cfg();
    let place = flat(|_, _| GRASS as u8, |_, _| 0);
    let hr = sun30();
    for (x, z) in [(-1e5, -1e5), (1e5, 0.0), (0.0, 1e5), (750.0, 750.0)] {
        let s = source_strength(&place, &c, &hr, x, z);
        assert!(s.is_finite() && (0.0..=1.0).contains(&s));
        assert!(raster_source(&place, x, z).is_finite());
    }
    assert!(source_strength(&place, &c, &hr, -1e5, -1e5) > 0.0);
}
