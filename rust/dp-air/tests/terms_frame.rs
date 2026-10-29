//! RW-8b: ветровая рамка (`terms::frame`) — профиль, `altitude_factor`, `vec2_at`, `dir`, упрощённый
//! профиль против чисел GD (`wind_model.gd`) и против слагаемого `analytic` эталона `synth_medium`;
//! `WeatherView`; условия -> ветер в `Terms`.
use dp_air::field::runtime::ground_height;
use dp_air::fixtures::{read_case, read_case_data, read_place};
use dp_air::terms::{Terms, WeatherView, WindCfg, WindModel};
use dp_air::{Conditions, Configs};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((name, std::fs::read_to_string(&p).unwrap()));
        }
    }
}

fn game_configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    files.sort();
    Configs::new(files)
}

fn rel(a: f64, b: f64, tol: f64, what: &str) {
    assert!(
        (a - b).abs() <= tol * b.abs().max(1.0),
        "{what}: {a} != {b} (tol {tol})"
    );
}

struct Gd {
    speed: f64,
    sun: f64,
    cover: f64,
    params: (f64, f64),
    dir: (f64, f64),
    pr: &'static [(f64, f64, f64, f64, f64)],
    /// `(msl, altitude_factor, speed_at_pos(100, msl))`
    af: &'static [(f64, f64, f64)],
}

const GD: &[Gd] = &[
    Gd {
        speed: 5.0,
        sun: 52.0,
        cover: 0.0,
        params: (0.159999996423721, 1.76291644573212),
        dir: (0.766044437885284, -0.642787635326385),
        pr: &[
            (
                0.0,
                0.691830970918937,
                3.45915485459468,
                2.64986634254456,
                -2.22350192070007,
            ),
            (
                0.5,
                0.691830970918937,
                3.45915485459468,
                2.64986634254456,
                -2.22350192070007,
            ),
            (
                1.0,
                0.691830970918937,
                3.45915485459468,
                2.64986634254456,
                -2.22350192070007,
            ),
            (10.0, 1.0, 5.0, 3.83022212982178, -3.21393823623657),
            (
                50.0,
                1.29370483333399,
                6.46852416666993,
                4.95517683029175,
                -4.15788745880127,
            ),
            (
                100.0,
                1.44543977074593,
                7.22719885372964,
                5.53635549545288,
                -4.64555406570435,
            ),
            (
                300.0,
                1.72321473970575,
                8.61607369852877,
                6.60029554367065,
                -5.53830575942993,
            ),
            (
                1000.0,
                1.76291649106829,
                8.81458245534146,
                6.75236177444458,
                -5.66590452194214,
            ),
            (
                3000.0,
                1.76291649106829,
                8.81458245534146,
                6.75236177444458,
                -5.66590452194214,
            ),
        ],
        af: &[
            (-500.0, 0.5, 3.61359942686482),
            (0.0, 0.5, 3.61359942686482),
            (800.0, 0.88, 6.35993499128208),
            (1000.0, 1.0, 7.22719885372964),
            (1500.0, 1.3, 9.39535850984853),
            (3000.0, 2.0, 14.4543977074593),
            (6000.0, 2.0, 14.4543977074593),
        ],
    },
    Gd {
        speed: 2.0,
        sun: 52.0,
        cover: 0.0,
        params: (0.112000003457069, 1.34212493896484),
        dir: (0.766044437885284, -0.642787635326385),
        pr: &[
            (
                0.0,
                0.772680585095702,
                1.5453611701914,
                1.18381536006927,
                -0.993339061737061,
            ),
            (
                0.5,
                0.772680585095702,
                1.5453611701914,
                1.18381536006927,
                -0.993339061737061,
            ),
            (
                1.0,
                0.772680585095702,
                1.5453611701914,
                1.18381536006927,
                -0.993339061737061,
            ),
            (10.0, 1.0, 2.0, 1.53208887577057, -1.28557527065277),
            (
                50.0,
                1.19752514284185,
                2.39505028568369,
                1.83471500873566,
                -1.53950870037079,
            ),
            (
                100.0,
                1.29419584144999,
                2.58839168289997,
                1.98282301425934,
                -1.66378617286682,
            ),
            (
                300.0,
                1.34212491088563,
                2.68424982177127,
                2.05625462532043,
                -1.72540259361267,
            ),
            (
                1000.0,
                1.34212491088563,
                2.68424982177127,
                2.05625462532043,
                -1.72540259361267,
            ),
            (
                3000.0,
                1.34212491088563,
                2.68424982177127,
                2.05625462532043,
                -1.72540259361267,
            ),
        ],
        af: &[
            (-500.0, 0.5, 1.29419584144999),
            (0.0, 0.5, 1.29419584144999),
            (800.0, 0.88, 2.27778468095198),
            (1000.0, 1.0, 2.58839168289997),
            (1500.0, 1.3, 3.36490918776996),
            (3000.0, 2.0, 5.17678336579994),
            (6000.0, 2.0, 5.17678336579994),
        ],
    },
    Gd {
        speed: 2.0,
        sun: -10.0,
        cover: 0.0,
        params: (0.879999995231628, 1.64931190013885),
        dir: (0.766044437885284, -0.642787635326385),
        pr: &[
            (
                0.0,
                0.131825673855641,
                0.263651347711281,
                0.201968654990196,
                -0.169471830129623,
            ),
            (
                0.5,
                0.131825673855641,
                0.263651347711281,
                0.201968654990196,
                -0.169471830129623,
            ),
            (
                1.0,
                0.131825673855641,
                0.263651347711281,
                0.201968654990196,
                -0.169471830129623,
            ),
            (10.0, 1.0, 2.0, 1.53208887577057, -1.28557527065277),
            (
                50.0,
                1.6493119327753,
                3.2986238655506,
                2.52689242362976,
                -2.1203145980835,
            ),
            (
                100.0,
                1.6493119327753,
                3.2986238655506,
                2.52689242362976,
                -2.1203145980835,
            ),
            (
                300.0,
                1.6493119327753,
                3.2986238655506,
                2.52689242362976,
                -2.1203145980835,
            ),
            (
                1000.0,
                1.6493119327753,
                3.2986238655506,
                2.52689242362976,
                -2.1203145980835,
            ),
            (
                3000.0,
                1.6493119327753,
                3.2986238655506,
                2.52689242362976,
                -2.1203145980835,
            ),
        ],
        af: &[
            (-500.0, 0.5, 1.6493119327753),
            (0.0, 0.5, 1.6493119327753),
            (800.0, 0.88, 2.90278900168453),
            (1000.0, 1.0, 3.2986238655506),
            (1500.0, 1.3, 4.28821102521578),
            (3000.0, 2.0, 6.5972477311012),
            (6000.0, 2.0, 6.5972477311012),
        ],
    },
    Gd {
        speed: 8.0,
        sun: 20.0,
        cover: 0.7,
        params: (0.239999994635582, 2.6202118396759),
        dir: (0.766044437885284, -0.642787635326385),
        pr: &[
            (
                0.0,
                0.575439937337157,
                4.60351949869726,
                3.52650046348572,
                -2.95908546447754,
            ),
            (
                0.5,
                0.575439937337157,
                4.60351949869726,
                3.52650046348572,
                -2.95908546447754,
            ),
            (
                1.0,
                0.575439937337157,
                4.60351949869726,
                3.52650046348572,
                -2.95908546447754,
            ),
            (10.0, 1.0, 8.0, 6.12835550308228, -5.14230108261108),
            (
                50.0,
                1.47147470556325,
                11.771797644506,
                9.01772022247314,
                -7.56676578521729,
            ),
            (
                100.0,
                1.73780082874938,
                13.902406629995,
                10.6498613357544,
                -8.93629550933838,
            ),
            (
                300.0,
                2.26208594384575,
                18.096687550766,
                13.8628664016724,
                -11.6323270797729,
            ),
            (
                1000.0,
                2.62021184974368,
                20.9616947979494,
                16.0575904846191,
                -13.4739179611206,
            ),
            (
                3000.0,
                2.62021184974368,
                20.9616947979494,
                16.0575904846191,
                -13.4739179611206,
            ),
        ],
        af: &[
            (-500.0, 0.5, 6.9512033149975),
            (0.0, 0.5, 6.9512033149975),
            (800.0, 0.88, 12.2341178343956),
            (1000.0, 1.0, 13.902406629995),
            (1500.0, 1.3, 18.0731286189935),
            (3000.0, 2.0, 27.80481325999),
            (6000.0, 2.0, 27.80481325999),
        ],
    },
    Gd {
        speed: 12.0,
        sun: 52.0,
        cover: 0.3,
        params: (0.239999994635582, 2.88800740242004),
        dir: (0.766044437885284, -0.642787635326385),
        pr: &[
            (
                0.0,
                0.575439937337157,
                6.90527924804588,
                5.28975057601929,
                -4.43862819671631,
            ),
            (
                0.5,
                0.575439937337157,
                6.90527924804588,
                5.28975057601929,
                -4.43862819671631,
            ),
            (
                1.0,
                0.575439937337157,
                6.90527924804588,
                5.28975057601929,
                -4.43862819671631,
            ),
            (10.0, 1.0, 12.0, 9.19253349304199, -7.71345138549805),
            (
                50.0,
                1.47147470556325,
                17.657696466759,
                13.5265798568726,
                -11.3501491546631,
            ),
            (
                100.0,
                1.73780082874938,
                20.8536099449925,
                15.9747915267944,
                -13.4044427871704,
            ),
            (
                300.0,
                2.26208594384575,
                27.1450313261489,
                20.7943000793457,
                -17.4484901428223,
            ),
            (
                1000.0,
                2.88800744556324,
                34.6560893467588,
                26.5481052398682,
                -22.2765064239502,
            ),
            (
                3000.0,
                2.88800744556324,
                34.6560893467588,
                26.5481052398682,
                -22.2765064239502,
            ),
        ],
        af: &[
            (-500.0, 0.5, 10.4268049724963),
            (0.0, 0.5, 10.4268049724963),
            (800.0, 0.88, 18.3511767515934),
            (1000.0, 1.0, 20.8536099449925),
            (1500.0, 1.3, 27.1096929284903),
            (3000.0, 2.0, 41.707219889985),
            (6000.0, 2.0, 41.707219889985),
        ],
    },
];

/// Упрощённый профиль: `(speed, dir, params, [(agl, profile, speed_at)])`.
type GdSimple = (f64, (f64, f64), (f64, f64), &'static [(f64, f64, f64)]);
const GD_SIMPLE: &[GdSimple] = &[
    (
        3.0,
        (-1.0, 6.12323426292584e-17),
        (0.140000000596046, 1.79999995231628),
        &[
            (0.0, 0.72443596007499, 2.17330788022497),
            (0.5, 0.72443596007499, 2.17330788022497),
            (10.0, 1.0, 3.0),
            (100.0, 1.38038426460288, 4.14115279380865),
            (1000.0, 1.8, 5.4),
        ],
    ),
    (
        5.0,
        (-1.0, 6.12323426292584e-17),
        (0.140000000596046, 1.79999995231628),
        &[
            (0.0, 0.72443596007499, 3.62217980037495),
            (0.5, 0.72443596007499, 3.62217980037495),
            (10.0, 1.0, 5.0),
            (100.0, 1.38038426460288, 6.90192132301442),
            (1000.0, 1.8, 9.0),
        ],
    ),
    (
        10.0,
        (-1.0, 6.12323426292584e-17),
        (0.140000000596046, 1.79999995231628),
        &[
            (0.0, 0.72443596007499, 7.2443596007499),
            (0.5, 0.72443596007499, 7.2443596007499),
            (10.0, 1.0, 10.0),
            (100.0, 1.38038426460288, 13.8038426460288),
            (1000.0, 1.8, 18.0),
        ],
    ),
];

/// (1) Профиль, предел, `speed_at`, `vec2_at`, `dir`, `altitude_factor`, `speed_at_pos` — против GD
/// в таблице точек: нейтральная и устойчивые атмосферы (класс Тёрнера из ветра, солнца и облаков).
#[test]
fn profile_and_altitude_factor_match_gd() {
    let cfg = WindCfg::from_configs(&game_configs());
    for g in GD {
        let mut w = WindModel::new(cfg);
        w.set_wind(g.speed, 230.0);
        w.set_conditions(g.sun, g.cover);
        let tag = format!("{} м/с, солнце {}, облака {}", g.speed, g.sun, g.cover);
        let (a, m) = w.profile_params();
        // профиль GD отдаёт Vector2 (float32)
        rel(a, g.params.0, 2e-6, &format!("alpha {tag}"));
        rel(m, g.params.1, 2e-6, &format!("max {tag}"));
        rel(w.dir()[0], g.dir.0, 2e-6, "dir.x");
        rel(w.dir()[1], g.dir.1, 2e-6, "dir.z");
        for &(agl, prof, sp, vx, vz) in g.pr {
            rel(w.profile(agl), prof, 1e-9, &format!("profile({agl}) {tag}"));
            rel(w.speed_at(agl), sp, 1e-9, &format!("speed_at({agl}) {tag}"));
            let v = w.vec2_at(agl);
            rel(v[0], vx, 2e-6, &format!("vec2.x({agl}) {tag}"));
            rel(v[1], vz, 2e-6, &format!("vec2.z({agl}) {tag}"));
        }
        // без опорной высоты множитель 1
        assert_eq!(w.altitude_factor(1234.0), 1.0);
        w.ref_msl = 1000.0;
        for &(msl, f, sp) in g.af {
            rel(
                w.altitude_factor(msl),
                f,
                1e-12,
                &format!("altitude_factor({msl})"),
            );
            rel(
                w.speed_at_pos(100.0, msl),
                sp,
                1e-9,
                &format!("speed_at_pos({msl}) {tag}"),
            );
        }
    }
    // пределы множителя из конфига: 0,5 … 2
    let w = WindModel::new(cfg);
    assert_eq!(
        (w.cfg().alt_min, w.cfg().alt_max, w.cfg().alt_gain),
        (0.5, 2.0, 0.6)
    );
}

/// (2) Упрощённый профиль 0.8.0 (`wind_profile_simple`): постоянные α = 0,14 и предел 1,8, без
/// зависимости от солнца и облаков; возврат к профилю Тёрнера.
#[test]
fn simple_profile_matches_gd() {
    let cfg = WindCfg::from_configs(&game_configs());
    assert_eq!((cfg.simple_alpha, cfg.simple_max), (0.14, 1.8));
    for &(sp, dir, params, rows) in GD_SIMPLE {
        let mut w = WindModel::new(cfg);
        w.set_simple_profile(true, Some((cfg.simple_alpha, cfg.simple_max)));
        w.set_wind(sp, 90.0);
        assert!(w.is_simple());
        let (a, m) = w.profile_params();
        rel(a, params.0, 2e-6, "alpha");
        rel(m, params.1, 2e-6, "max");
        rel(w.dir()[0], dir.0, 2e-6, "dir.x");
        rel(w.dir()[1], dir.1, 2e-6, "dir.z");
        for &(agl, prof, s) in rows {
            rel(w.profile(agl), prof, 1e-9, &format!("profile({agl})"));
            rel(w.speed_at(agl), s, 1e-9, &format!("speed_at({agl})"));
        }
        // облачность и солнце профиль не меняют
        w.set_conditions(-10.0, 1.0);
        assert_eq!(w.profile_params(), (a, m));
        w.set_simple_profile(false, None);
        assert!(!w.is_simple());
        assert_ne!(w.profile_params(), (a, m));
    }
}

/// (3) `dir = (−sin d, cos d)` по сторонам света, `vec2_at` вдоль `dir`, `speed_at` не убывает
/// с высотой до предела, `NaN`-высота опорной точки отключает множитель, скорость не отрицательна.
#[test]
fn dir_and_vec2() {
    let mut w = WindModel::new(WindCfg::default());
    for (from, want) in [
        (0.0, [0.0, 1.0]),
        (90.0, [-1.0, 0.0]),
        (180.0, [0.0, -1.0]),
        (270.0, [1.0, 0.0]),
    ] {
        w.set_wind(6.0, from);
        assert!((w.dir()[0] - want[0]).abs() < 1e-12 && (w.dir()[1] - want[1]).abs() < 1e-12);
        let v = w.vec2_at(50.0);
        let s = w.speed_at(50.0);
        assert!((v[0] - want[0] * s).abs() < 1e-12 && (v[1] - want[1] * s).abs() < 1e-12);
    }
    w.set_wind(-3.0, 0.0);
    assert_eq!(w.speed_ref, 0.0);
    assert_eq!(w.speed_at(100.0), 0.0);
    w.set_wind(6.0, 0.0);
    let mut prev = 0.0;
    for agl in [0.0, 1.0, 10.0, 50.0, 200.0, 800.0, 3000.0] {
        let s = w.speed_at(agl);
        assert!(s >= prev - 1e-12);
        prev = s;
    }
    w.ref_msl = 500.0;
    w.set_altitude_gain(f64::NAN); // NaN — оставить прежний
    assert_eq!(w.altitude_factor(500.0), 1.0);
    w.ref_msl = f64::NAN;
    assert_eq!(w.altitude_factor(9999.0), 1.0);
}

/// (4) Слагаемое `analytic` эталона `synth_medium` (режим `off`, упрощённый профиль): горизонталь
/// аналитики над ровным местом = `dir · speed_at_pos(agl, y)` (14 км/ч с 230°, ref_msl 940 м, рост
/// 0,6/км): ровно — в свободном воздухе (agl ≥ 200 м), у земли — до тени гребня (она только ослабляет).
#[test]
fn analytic_term_of_synth_medium_matches_frame() {
    let cases = repo().join("tests/fixtures/wind/cases/synth_medium.json");
    let case = read_case(&cases).unwrap();
    let data = read_case_data(&case, &cases).unwrap();
    let place = read_place(&case.place_path(&cases)).unwrap();
    let terms = case.terms.as_ref().unwrap();
    let k = 2 + terms.iter().position(|n| n == "analytic").unwrap();
    let extra: Value = serde_json::from_str(&std::fs::read_to_string(&cases).unwrap()).unwrap();
    let ref_msl = extra["extra"]["wind_ref_msl"].as_f64().unwrap();
    let cfg = WindCfg::from_configs(&game_configs());
    let mut w = WindModel::new(cfg);
    w.set_simple_profile(true, Some((cfg.simple_alpha, cfg.simple_max)));
    w.ref_msl = ref_msl;
    w.set_wind(14.0 / 3.6, 230.0);
    let mut checked = 0;
    let (mut free, mut flat) = (0, 0);
    for t in 0..data.n_t {
        for (p, a) in case.points.iter().zip(data.slab(t, k)) {
            let g = f64::from(ground_height(&place, p[0], p[2]));
            let agl = (f64::from(p[1]) - g).max(0.0);
            let s = w.speed_at_pos(agl, f64::from(p[1]));
            let want = [w.dir()[0] * s, w.dir()[1] * s];
            let r = f64::from(a[0]).hypot(f64::from(a[2])) / s;
            // подветренная зона (тень гребня) только ослабляет ветер: `h = u·(1 − 0,6·lee)`
            assert!(r <= 1.002, "t {t} {p:?}: gd/frame {r}");
            if agl >= 200.0 {
                // выше слоя сдвига тени (350 м над линией — у синтетики гребни ниже): ровно профиль
                assert!((r - 1.0).abs() < 1e-4, "t {t} {p:?}: gd/frame {r}");
                assert!(
                    (f64::from(a[0]) - want[0]).abs() < 1e-3
                        && (f64::from(a[2]) - want[1]).abs() < 1e-3,
                    "t {t} {p:?}: gd ({}, {}) frame {want:?}",
                    a[0],
                    a[2]
                );
                free += 1;
            }
            if (r - 1.0).abs() < 3e-3 {
                flat += 1;
            }
            checked += 1;
        }
    }
    assert!(checked >= 3 * 39);
    assert!(free >= 3 * 15, "точек в свободном воздухе: {free}");
    assert!(
        flat * 2 >= checked,
        "вне тени профиль сходится: {flat} из {checked}"
    );
}

/// (5) `WeatherView`: геттеры с запасным значением, `_derived`; `Terms::set_conditions` берёт ветер
/// из пресета (имя и словарь) и прогноза (`wind_ref` — опорная высота и рост).
#[test]
fn weather_view_and_conditions_to_wind() {
    let mut m = serde_json::Map::new();
    m.insert("wind_speed_kmh".into(), json!(36.0));
    m.insert("sky".into(), json!("clear"));
    m.insert("_derived".into(), json!({"zi_m": 1500.0}));
    let v = WeatherView::new(m);
    assert_eq!(v.f64_or("wind_speed_kmh", 0.0), 36.0);
    assert_eq!(v.f64_or("nope", 7.5), 7.5);
    assert_eq!(v.f64_or("sky", 7.5), 7.5, "не число — запасное");
    assert_eq!(v.derived_f64_or("zi_m", 0.0), 1500.0);
    assert_eq!(v.derived_f64_or("x", -1.0), -1.0);
    assert_eq!(v.str_or("sky", "?"), "clear");
    assert!(WeatherView::default().is_empty());

    let cfgs = Arc::new(game_configs());
    let mut t = Terms::default();
    t.configure(&cfgs, 5);
    // пресет по имени: configs/weather/medium.json (12 км/ч с 270°)
    t.set_conditions(
        &Conditions::from_json(r#"{"preset":"medium","start_hour":12,"speed":1}"#).unwrap(),
    );
    rel(t.wind.speed_ref, 12.0 / 3.6, 1e-12, "speed medium");
    rel(t.wind.dir()[0], 1.0, 1e-12, "dir.x 270");
    assert!(t.wind.ref_msl.is_nan());
    assert_eq!(t.weather.f64_or("background_sink_ms", 0.0), -0.5);
    // пресет словарём
    t.set_conditions(
        &Conditions::from_json(
            r#"{"preset":{"wind_speed_kmh":18,"wind_from_deg":0},"start_hour":12,"speed":1}"#,
        )
        .unwrap(),
    );
    rel(t.wind.speed_ref, 5.0, 1e-12, "speed dict");
    rel(t.wind.dir()[1], 1.0, 1e-12, "dir.z 0");
    // прогноз с опорной высотой старта
    t.set_conditions(
        &Conditions::from_json(
            r#"{"forecast":{"temperature_c":20,"wind_speed_kmh":10,"wind_from_deg":90,"sky":"clear"},
"quantum_h":1,"start_hour":12,"speed":1,"wind_ref":{"ref_msl":900,"gain_per_km":0.3}}"#,
        )
        .unwrap(),
    );
    rel(t.wind.speed_ref, 10.0 / 3.6, 1e-12, "speed forecast");
    assert_eq!(t.wind.ref_msl, 900.0);
    rel(t.wind.altitude_factor(1900.0), 1.3, 1e-12, "gain 0,3/км");
}
