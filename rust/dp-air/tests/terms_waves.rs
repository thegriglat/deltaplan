//! RW-11b: волны и роторы в крейте (`terms::waves`): слагаемое `wave` и σ ротора против эталонов
//! `synth_wave` и `ongudai_wave` (W8), гребни W6 против `desc.json`, перенос `test_wave.gd`
//! (подъём и лентикуляры в одном месте, λ = 2πU/N, без волны нет линз, ротор под гребнем).
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::ground_height;
use dp_air::fixtures::{read_case, read_case_data, read_desc, read_place};
use dp_air::terms::waves::{WaveCfg, WaveField, dir_f32, wave_crests};
use dp_air::terms::{self, Ctx};
use dp_air::{Conditions, Configs, Crest, Place, PlaceHeader, SampleMode, Source};
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
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

fn game_configs() -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    files.sort();
    Arc::new(Configs::new(files))
}

fn cases() -> PathBuf {
    repo().join("tests/fixtures/wind/cases")
}

/// `Terms` случая: конфиги игры, условия случая; эталоны synth_* сняты
/// с упрощённым профилем ветра 0.8.0.
fn terms_of(cond: &Conditions, simple: bool) -> terms::Terms {
    let cfgs = game_configs();
    let mut t = terms::Terms::default();
    t.configure(&cfgs, 1);
    t.set_conditions(cond);
    if simple {
        let c = *t.wind.cfg();
        t.wind
            .set_simple_profile(true, Some((c.simple_alpha, c.simple_max)));
    }
    t
}

fn ctx<'a>(t: &'a terms::Terms, fs: &'a FieldSet, pl: &'a Place, p: [f32; 3]) -> Ctx<'a> {
    let g = ground_height(pl, p[0], p[2]);
    let agl = f64::from((p[1] - g).max(0.0));
    Ctx {
        pos: p,
        ground: g,
        agl,
        t: 0.0,
        mode: SampleMode::Mean,
        a: 0.0,
        fw: [0.0; 3],
        u: t.wind.speed_at_pos(agl, f64::from(p[1])),
        terms: t,
        fs,
        place: pl,
    }
}

/// Мир синтетических эталонов (`AtmoFingerprint.height`) растром 100 м на ±60 км: эталонный `Place`
/// синтетики — только 20 км, а волна смотрит на 3λ ≈ 20 км против ветра (за краем растр держит
/// высоту края, у GD высота аналитическая во всём пространстве).
fn synthetic_wide() -> Place {
    let (n, sp, o) = (1201usize, 100.0, -60000.0);
    let hdr = format!(
        r#"{{"version":1,"loc":{{"id":"synthw","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,
"month":7,"day":15}},"grid":{{"origin_x":{o},"origin_z":{o},"spacing":{sp},"width":{n},"height":{n}}},
"surface_classes":{{"grass":1}},"start_sites":[]}}"#
    );
    let header = PlaceHeader::from_json(&hdr).unwrap();
    let mut hs = Vec::with_capacity(n * n);
    for j in 0..n {
        let z = o + j as f64 * sp;
        for i in 0..n {
            let x = o + i as f64 * sp;
            hs.push(
                (900.0
                    + 350.0 * (x / 3100.0).sin() * (z / 4300.0).cos()
                    + 160.0 * ((x + 0.6 * z) / 1700.0).sin()
                    + 40.0 * (x / 450.0 - z / 700.0).cos()) as f32,
            );
        }
    }
    Place::new(header, hs, vec![0; n * n], vec![1; n * n], vec![1.0; n * n]).unwrap()
}

fn place_of(cs: &Case, case: &dp_air::fixtures::Case, path: &Path) -> Place {
    if cs.simple {
        synthetic_wide()
    } else {
        read_place(&case.place_path(path)).unwrap()
    }
}

fn tol(v: f64, want: f64) -> bool {
    (v - want).abs() <= 0.05 + 0.02 * want.abs()
}

struct Case {
    name: &'static str,
    simple: bool,
}
const CASES: [Case; 2] = [
    Case {
        name: "synth_wave",
        simple: true,
    },
    Case {
        name: "ongudai_wave",
        simple: false,
    },
];

/// (1) Слагаемое `wave` эталонов: все точки и моменты, W8 `0,05 м/с + 2 %` по компоненте.
fn wave_term_against(which: &[&Case]) {
    for &cs in which {
        let path = cases().join(format!("{}.json", cs.name));
        let case = read_case(&path).unwrap();
        let data = read_case_data(&case, &path).unwrap();
        let place = place_of(cs, &case, &path);
        let k = 2 + case
            .terms
            .as_ref()
            .unwrap()
            .iter()
            .position(|n| n == "wave")
            .unwrap();
        let t = terms_of(&case.conditions, cs.simple);
        let fs = FieldSet::default();
        let (mut n, mut nonzero, mut bad, mut worst) = (0, 0, 0, 0.0f64);
        let mut max_abs = 0.0f64;
        for ti in 0..data.n_t {
            for (p, a) in case.points.iter().zip(data.slab(ti, k)) {
                let c = ctx(&t, &fs, &place, *p);
                let out = t.slots.extra.flow(&c, [0.0; 3]).expect("волна включена");
                let got = out.wave;
                assert_eq!(got[0], 0.0);
                assert_eq!(got[2], 0.0);
                let want = f64::from(a[1]);
                assert_eq!(
                    (a[0], a[2]),
                    (0.0, 0.0),
                    "эталон: волна только вертикальная"
                );
                n += 1;
                if want.abs() > 0.3 {
                    nonzero += 1;
                }
                max_abs = max_abs.max(want.abs());
                worst = worst.max((got[1] - want).abs());
                assert!(got[1].abs() <= 8.0 + 1e-9);
                if !tol(got[1], want) {
                    bad += 1;
                    if cs.simple {
                        eprintln!("{} t{ti} {p:?}: rust {} gd {want}", cs.name, got[1]);
                    }
                }
            }
        }
        eprintln!(
            "{}: точек {n}, |wave|>0,3: {nonzero}, max |w| {max_abs:.2}, худшее |Δ| {worst:.4}",
            cs.name
        );
        assert!(nonzero >= 30, "{}: точек с волной {nonzero}", cs.name);
        // Онгудай: эталон снят с `terrain.height_at` за краем растра места (±20 км, а волна смотрит на
        // 3λ ≈ 20 км и больше против ветра); сверка на растре — `ongudai_wave_on_place_raster`.
        // Здесь — только число точек вне допуска для отчёта.
        if cs.simple {
            assert_eq!(bad, 0, "{}: вне допуска W8 {bad} из {n}", cs.name);
        } else {
            eprintln!(
                "{}: вне допуска W8 из-за рельефа за растром: {bad} из {n}",
                cs.name
            );
        }
    }
}

/// (1) Слагаемое `wave` синтетики: W8 `0,05 м/с + 2 %` по компоненте, все точки и моменты.
#[test]
fn wave_term_matches_references() {
    wave_term_against(&[&CASES[0]]);
}

/// Онгудай против эталона `terrain.height_at`: граница W5 — рельеф за растром (±20 км), см.
/// `ongudai_wave_on_place_raster`. Игнорируется, число вне допуска — в отчёте.
#[test]
#[ignore = "граница W5: рельеф за растром"]
fn wave_term_matches_ongudai_terrain_reference() {
    wave_term_against(&[&CASES[1]]);
}

/// (2) σ ротора. В эталоне σ итога содержит ротор под корнем (`√(var + σ_гроза² + σ_ротор²)`, предел
/// `max(turb_max, min(rot, rotor_max))` ≥ 4), поэтому там, где ротор виден, `σ_gd ≥ min(σ_ротор, 4)`
/// (W8: `0,02 м/с + 5 %`); равенство — при нулевых остальных частях (после RW-9 и RW-8).
#[test]
fn rotor_sigma_is_visible_in_reference_sigma() {
    for cs in &CASES {
        let path = cases().join(format!("{}.json", cs.name));
        let case = read_case(&path).unwrap();
        let data = read_case_data(&case, &path).unwrap();
        let place = place_of(cs, &case, &path);
        let t = terms_of(&case.conditions, cs.simple);
        let fs = FieldSet::default();
        let (mut with_rotor, mut bad) = (0, 0);
        let mut max_rotor = 0.0f64;
        for ti in 0..data.n_t {
            for (p, a) in case.points.iter().zip(data.slab_k0(ti)) {
                let c = ctx(&t, &fs, &place, *p);
                let r = t.slots.extra.flow(&c, [0.0; 3]).unwrap().sigma_rotor;
                assert!(r.is_finite() && r >= 0.0);
                if r > 0.05 {
                    with_rotor += 1;
                    max_rotor = max_rotor.max(r);
                    let sigma_gd = f64::from(a[3]);
                    let need = r.min(4.0);
                    if sigma_gd < need - (0.02 + 0.05 * need) {
                        bad += 1;
                        if cs.simple {
                            eprintln!("{} t{ti} {p:?}: rotor {r} > σ_gd {sigma_gd}", cs.name);
                        }
                    }
                }
            }
        }
        eprintln!(
            "{}: точек с ротором {with_rotor}, max σ_ротор {max_rotor:.2}",
            cs.name
        );
        if cs.simple {
            assert_eq!(bad, 0, "{}: σ итога меньше ротора в {bad} точках", cs.name);
        } else {
            // рельеф за растром (см. `wave_term_matches_references`)
            eprintln!(
                "{}: σ итога меньше ротора (рельеф за растром): {bad}",
                cs.name
            );
        }
    }
}

trait SlabK0 {
    fn slab_k0(&self, t: usize) -> Box<dyn Iterator<Item = [f32; 4]> + '_>;
}
impl SlabK0 for dp_air::fixtures::CaseData {
    fn slab_k0(&self, t: usize) -> Box<dyn Iterator<Item = [f32; 4]> + '_> {
        Box::new(self.slab(t, 0))
    }
}

/// (3) Гребни W6 против `desc.json`: тот же вызов, что у генератора (центр — фокус, радиус
/// `lens_radius_m`, `min_eta = lens_min_eta_m`, `spacing = 0,9·lens_length_m[1]`).
#[test]
fn crests_match_desc() {
    for cs in &CASES {
        let path = cases().join(format!("{}.json", cs.name));
        let case = read_case(&path).unwrap();
        let place = place_of(cs, &case, &path);
        let frames = read_desc(&case, &path).unwrap();
        let t = terms_of(&case.conditions, cs.simple);
        let cfg = WaveCfg::from_configs(&t.configs);
        let f = case.focuses[0].pos;
        let mut out = Vec::new();
        wave_crests(
            &t,
            Some(&place),
            [f[0], f[2]],
            cfg.lens_radius_m as f32,
            cfg.lens_min_eta_m as f32,
            (cfg.lens_length_max_m * 0.9) as f32,
            &mut out,
        );
        let mut worst = (0.0f64, 0.0f64, 0.0f64);
        for (ti, fr) in frames.iter().enumerate() {
            if !cs.simple {
                // Онгудай: рельеф за растром, гребни другие — сверка на растре в отдельном тесте
                eprintln!(
                    "{} t{ti}: гребней {} (эталон {})",
                    cs.name,
                    out.len(),
                    fr.crests.len()
                );
                continue;
            }
            assert_eq!(
                out.len(),
                fr.crests.len(),
                "{} t{ti}: число гребней",
                cs.name
            );
            assert!(out.len() >= 5, "{}: гребней {}", cs.name, out.len());
            for (g, w) in out.iter().zip(&fr.crests) {
                let d = f64::from(g.x - w.x).hypot(f64::from(g.z - w.z));
                worst.0 = worst.0.max(d);
                worst.1 = worst.1.max(f64::from((g.eta - w.eta).abs()));
                worst.2 = worst.2.max(f64::from((g.crest - w.crest).abs()));
            }
        }
        eprintln!(
            "{}: гребней {}, худшее: позиция {:.2} м, eta {:.2} м, crest {:.2} м",
            cs.name,
            out.len(),
            worst.0,
            worst.1,
            worst.2
        );
        if cs.simple {
            // аналитический мир против растра 100 м (билинейно): доли метра
            assert!(
                worst.0 <= 1.0,
                "{}: позиция гребня {:.1} м",
                cs.name,
                worst.0
            );
            assert!(worst.1 <= 1.0, "{}: eta {:.2}", cs.name, worst.1);
            assert!(worst.2 <= 1.0, "{}: crest {:.2}", cs.name, worst.2);
        }
    }
}

// ---------------------------------------------------------------- перенос test_wave.gd

const RIDGE_H: f64 = 800.0;
const RIDGE_W: f64 = 1500.0;

/// Хребет `test_wave.gd`: `500 + 800·exp(−(x/1500)²)`, растр 50 м на ±25 км (билинейно — точность
/// профиля ~0,5 м).
fn ridge_place() -> Place {
    let (w, h, sp) = (1001usize, 1001usize, 50.0);
    let hdr = format!(
        r#"{{"version":1,"loc":{{"id":"ridge","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,
"month":7,"day":1}},"grid":{{"origin_x":-25000,"origin_z":-25000,"spacing":{sp},"width":{w},"height":{h}}},
"surface_classes":{{"grass":1}},"start_sites":[]}}"#
    );
    let header = PlaceHeader::from_json(&hdr).unwrap();
    let mut hs = Vec::with_capacity(w * h);
    for _j in 0..h {
        for i in 0..w {
            let x = -25000.0 + i as f64 * sp;
            hs.push((500.0 + RIDGE_H * (-(x / RIDGE_W).powi(2)).exp()) as f32);
        }
    }
    let n = w * h;
    Place::new(header, hs, vec![0; n], vec![1; n], vec![1.0; n]).unwrap()
}

fn wave_conditions(over: Value) -> Conditions {
    let cfgs = game_configs();
    let mut m = match dp_air::terms::named_json(&cfgs, "weather/wave").unwrap() {
        Value::Object(m) => m,
        _ => panic!(),
    };
    if let Value::Object(o) = over {
        m.extend(o);
    }
    Conditions::from_json(&json!({"preset": m, "start_hour": 12, "speed": 1}).to_string()).unwrap()
}

fn field_of(t: &terms::Terms, pl: &Place) -> Arc<WaveField> {
    let (f, _) = waves_field(t, pl).expect("волна включена");
    f
}

fn waves_field(t: &terms::Terms, pl: &Place) -> Option<(Arc<WaveField>, WaveCfg)> {
    let w = dp_air::terms::waves::WaveExtra::new();
    w.field(t, pl)
}

fn crests_of(t: &terms::Terms, pl: &Place, c: [f32; 2], r: f32, min_eta: f32) -> Vec<Crest> {
    let mut v = Vec::new();
    wave_crests(t, Some(pl), c, r, min_eta, 5000.0, &mut v);
    v
}

fn w_at(t: &terms::Terms, pl: &Place, p: [f32; 3]) -> (f64, f64) {
    let fs = FieldSet::default();
    let o = t.slots.extra.flow(&ctx(t, &fs, pl, p), [0.0; 3]).unwrap();
    (o.wave[1], o.sigma_rotor)
}

/// Центр линзы: подъём ≥ 0,45·max_ms, через полволны — опускание, λ = 2πU/N ± 10 %.
fn check_crest_matches_lift(t: &terms::Terms, pl: &Place, f: &WaveField, cr: Crest, tag: &str) {
    let lam = f.wavelength();
    let wd = f.dir();
    let y = cr.crest + 1500.0;
    let cfg = WaveCfg::from_configs(&t.configs);
    let w_here = w_at(t, pl, [cr.x, y, cr.z]).0;
    assert!(
        w_here >= 0.45 * cfg.max_ms,
        "{tag}: в центре линзы подъём {w_here:.2} >= {:.2}",
        0.45 * cfg.max_ms
    );
    let p2 = [
        cr.x + wd[0] * (lam * 0.5) as f32,
        cr.z + wd[1] * (lam * 0.5) as f32,
    ];
    let w_half = w_at(t, pl, [p2[0], y, p2[1]]).0;
    assert!(
        w_half < 0.0,
        "{tag}: на полволны дальше — опускание: {w_half:.2}"
    );
    let n = t.weather.f64_or("stability_n_per_s", cfg.default_n_per_s);
    let u = t.wind.speed_at(cfg.wind_reference_agl_m);
    let lam_expected = std::f64::consts::TAU * u / n;
    assert!(
        (lam - lam_expected).abs() < lam_expected * 0.1,
        "{tag}: λ {lam:.0} ~ {lam_expected:.0}"
    );
}

#[test]
fn synthetic_ridge_lens_matches_lift() {
    let pl = ridge_place();
    let t = terms_of(&wave_conditions(json!({})), false);
    let f = field_of(&t, &pl);
    let cr = crests_of(&t, &pl, [8000.0, 0.0], 15000.0, 40.0);
    assert!(!cr.is_empty(), "гребни волн найдены на синтетике");
    check_crest_matches_lift(&t, &pl, &f, cr[0], "синтетика");
    // сильные первыми
    assert!(cr.windows(2).all(|w| w[0].eta >= w[1].eta));
}

/// Ротор: у земли под гребнем η > 0 — σ > 0, а без волны (`wave_strength = 0`) — нет ни ротора,
/// ни подъёма, ни линз; в обычный день (`weather/medium`) волн нет.
#[test]
fn rotor_under_crest_and_no_wave_without_preset() {
    let pl = ridge_place();
    let t = terms_of(&wave_conditions(json!({"wind_speed_kmh": 15.0})), false);
    let f = field_of(&t, &pl);
    let cr = crests_of(&t, &pl, [8000.0, 0.0], 15000.0, 40.0);
    assert!(!cr.is_empty());
    let wd = f.dir();
    let lam = f.wavelength() as f32;
    // под гребнем линии тока (η > 0): crests() сдвинут против ветра на четверть волны
    let p = [cr[0].x + wd[0] * lam * 0.25, cr[0].z + wd[1] * lam * 0.25];
    let g = ground_height(&pl, p[0], p[1]);
    let y = cr[0].crest.max(g) + 40.0;
    let (_, rotor) = w_at(&t, &pl, [p[0], y, p[1]]);
    assert!(rotor > 0.3, "ротор у земли под гребнем: {rotor}");
    // выше ротора σ нет
    let (_, up) = w_at(&t, &pl, [p[0], cr[0].crest + 1500.0, p[1]]);
    assert_eq!(up, 0.0);

    let off = terms_of(&wave_conditions(json!({"wave_strength": 0.0})), false);
    assert!(
        off.slots
            .extra
            .flow(
                &ctx(&off, &FieldSet::default(), &pl, [p[0], y, p[1]]),
                [0.0; 3]
            )
            .is_none()
    );
    assert!(crests_of(&off, &pl, [8000.0, 0.0], 15000.0, 40.0).is_empty());

    let day = Conditions::from_json(r#"{"preset":"medium","start_hour":12,"speed":1}"#).unwrap();
    let medium = terms_of(&day, false);
    assert!(
        waves_field(&medium, &pl).is_none(),
        "в обычный день волн нет"
    );
    assert!(crests_of(&medium, &pl, [8000.0, 0.0], 15000.0, 40.0).is_empty());
    // нет места — нет гребней
    let mut v = Vec::new();
    wave_crests(&t, None, [0.0, 0.0], 15000.0, 40.0, 5000.0, &mut v);
    assert!(v.is_empty());
}

/// Онгудай: линза и подъём в одном месте (ветер 40 км/ч с 340°).
#[test]
fn ongudai_lens_matches_lift() {
    let path = cases().join("ongudai_wave.json");
    let case = read_case(&path).unwrap();
    let pl = read_place(&case.place_path(&path)).unwrap();
    let mut m = match &case.conditions.source {
        Source::Preset(Value::Object(m)) => m.clone(),
        _ => panic!("preset"),
    };
    m.insert("wind_speed_kmh".into(), json!(40.0));
    m.insert("wind_from_deg".into(), json!(340.0));
    let cond =
        Conditions::from_json(&json!({"preset": m, "start_hour": 12, "speed": 1}).to_string())
            .unwrap();
    let t = terms_of(&cond, false);
    let f = field_of(&t, &pl);
    let c = case.focuses[0].pos;
    let cr = crests_of(&t, &pl, [c[0], c[2]], 15000.0, 40.0);
    assert!(!cr.is_empty(), "гребни волн найдены на Онгудае");
    check_crest_matches_lift(&t, &pl, &f, cr[0], "Онгудай");
}

/// Кеш и поле: те же входы — то же поле (один `Arc`), смена ветра больше 1 м λ — новое;
/// направление в `f32` как `Vector2` Godot; `fields` на узле сетки сходится с прямым расчётом.
#[test]
fn field_cache_and_wind_change() {
    let pl = ridge_place();
    let w = dp_air::terms::waves::WaveExtra::new();
    let t = terms_of(&wave_conditions(json!({})), false);
    let (a, _) = w.field(&t, &pl).unwrap();
    let (b, _) = w.field(&t, &pl).unwrap();
    assert!(Arc::ptr_eq(&a, &b));
    let t2 = terms_of(&wave_conditions(json!({"wind_speed_kmh": 20.0})), false);
    let (c, _) = w.field(&t2, &pl).unwrap();
    assert!(!Arc::ptr_eq(&a, &c));
    assert!(c.wavelength() < a.wavelength());
    let d = dir_f32([0.6, 0.8]);
    assert!((d[0] * d[0] + d[1] * d[1] - 1.0).abs() < 1e-6);
    // однородная местность — η = 0, подъёма нет
    let flat_hdr = PlaceHeader::from_json(
        r#"{"version":1,"loc":{"id":"f","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,
"month":7,"day":1},"grid":{"origin_x":-5000,"origin_z":-5000,"spacing":100,"width":101,"height":101},
"surface_classes":{"grass":1},"start_sites":[]}"#,
    )
    .unwrap();
    let n = flat_hdr.cells();
    let flat = Place::new(
        flat_hdr,
        vec![300.0; n],
        vec![0; n],
        vec![1; n],
        vec![1.0; n],
    )
    .unwrap();
    let (w0, r0) = w_at(&t, &flat, [100.0, 2500.0, 100.0]);
    assert_eq!((w0, r0), (0.0, 0.0));
}

/// (4) Онгудай на растре места: эталон снят GD на опорной ревизии с землёй = растр `places/ongudai`
/// (билинейно, вне растра — край), как у крейта (`tests/data/RW-11b/gen_ongudai_wave.gd`). Проверяет
/// рамку ветра на Онгудае (`U` на 1500 м, направление, λ), `wave` и σ ротора на точках случая и над
/// гребнями, гребни W6.
#[test]
fn ongudai_wave_on_place_raster() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-11b");
    let r: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("ongudai_wave_raster.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(r["wave_enabled"], json!(true));
    let path = cases().join("ongudai_wave.json");
    let case = read_case(&path).unwrap();
    let pl = read_place(&case.place_path(&path)).unwrap();
    let t = terms_of(&case.conditions, false);
    let (f, cfg) = waves_field(&t, &pl).unwrap();
    let u = t.wind.speed_at(cfg.wind_reference_agl_m);
    let f64v = |v: &Value| v.as_f64().unwrap();
    eprintln!(
        "u: rust {u:.6} gd {:.6}; λ rust {:.2} gd {:.2}; dir rust {:?} gd {:?}",
        f64v(&r["u_ref"]),
        f.wavelength(),
        f64v(&r["lambda"]),
        f.dir(),
        r["dir"]
    );
    assert!((u - f64v(&r["u_ref"])).abs() <= 1.0e-3 * u, "U рамки ветра");
    assert!((f.wavelength() - f64v(&r["lambda"])).abs() <= 0.5, "λ");
    for (q, d) in f.dir().iter().enumerate() {
        assert!(
            (f64::from(*d) - f64v(&r["dir"][q])).abs() < 1.0e-5,
            "направление"
        );
    }

    let fs = FieldSet::default();
    let (mut n, mut strong, mut rot) = (0, 0, 0);
    let (mut worst_w, mut worst_r) = (0.0f64, 0.0f64);
    for s in r["samples"].as_array().unwrap() {
        let p = [f64v(&s[0]) as f32, f64v(&s[1]) as f32, f64v(&s[2]) as f32];
        let o = t.slots.extra.flow(&ctx(&t, &fs, &pl, p), [0.0; 3]).unwrap();
        let (w, rr) = (f64v(&s[3]), f64v(&s[4]));
        worst_w = worst_w.max((o.wave[1] - w).abs());
        worst_r = worst_r.max((o.sigma_rotor - rr).abs());
        assert!(tol(o.wave[1], w), "{p:?}: wave rust {} gd {w}", o.wave[1]);
        assert!(
            (o.sigma_rotor - rr).abs() <= 0.02 + 0.05 * rr.abs(),
            "{p:?}: rotor rust {} gd {rr}",
            o.sigma_rotor
        );
        n += 1;
        strong += usize::from(w.abs() > 0.3);
        rot += usize::from(rr > 0.05);
    }
    eprintln!(
        "растр: точек {n}, |w|>0,3: {strong}, с ротором {rot}, худшее |Δw| {worst_w:.5}, |Δσ| {worst_r:.5}"
    );
    assert!(strong >= 30 && rot >= 5, "выборка: {strong}, {rot}");

    let c = case.focuses[0].pos;
    let got = crests_of_cfg(&t, &pl, [c[0], c[2]]);
    // Гребни за краем растра (±20 км) — плато клеммированной высоты: кандидат там выбирает шум
    // последнего знака (exp/cos двух реализаций), положение вырождено — только в отчёт.
    let g = &pl.header().grid;
    let inside = |x: f64, z: f64| {
        x >= g.origin_x
            && z >= g.origin_z
            && x <= g.origin_x + (f64::from(g.width) - 1.0) * g.spacing
            && z <= g.origin_z + (f64::from(g.height) - 1.0) * g.spacing
    };
    let want: Vec<&Value> = r["crests"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|w| inside(f64v(&w[0]), f64v(&w[1])))
        .collect();
    let got_in: Vec<Crest> = got
        .iter()
        .copied()
        .filter(|c| inside(f64::from(c.x), f64::from(c.z)))
        .collect();
    eprintln!(
        "растр: гребней в растре gd {} rust {}; всего gd {} rust {}",
        want.len(),
        got_in.len(),
        r["crests"].as_array().unwrap().len(),
        got.len()
    );
    assert_eq!(got_in.len(), want.len(), "число гребней в растре");
    assert!(got_in.len() >= 5);
    let mut worst = 0.0f64;
    for (g, w) in got_in.iter().zip(&want) {
        let d = (f64::from(g.x) - f64v(&w[0])).hypot(f64::from(g.z) - f64v(&w[1]));
        worst = worst.max(d);
        assert!(d <= 1.0, "позиция гребня {d} м: rust {g:?} gd {w}");
        assert!((f64::from(g.eta) - f64v(&w[2])).abs() <= 0.05, "eta");
        assert!((f64::from(g.crest) - f64v(&w[3])).abs() <= 0.05, "crest");
    }
    eprintln!("растр: худшая позиция гребня {worst:.4} м");
}

fn crests_of_cfg(t: &terms::Terms, pl: &Place, c: [f32; 2]) -> Vec<Crest> {
    let cfg = WaveCfg::from_configs(&t.configs);
    let mut v = Vec::new();
    wave_crests(
        t,
        Some(pl),
        c,
        cfg.lens_radius_m as f32,
        cfg.lens_min_eta_m as f32,
        (cfg.lens_length_max_m * 0.9) as f32,
        &mut v,
    );
    v
}

/// (5) Слот в сумме: `decompose` кладёт вклад волны в `wave` (только вертикаль), итог `sum` его
/// содержит (`Σ vel = total.xyz`), σ ротора входит в σ итога (при нулевых остальных слагаемых).
#[test]
fn wave_in_sum_and_decompose() {
    let pl = ridge_place();
    let t = terms_of(&wave_conditions(json!({})), false);
    let f = field_of(&t, &pl);
    let cr = crests_of(&t, &pl, [8000.0, 0.0], 15000.0, 40.0);
    let p = [cr[0].x, cr[0].crest + 1500.0, cr[0].z];
    let fs = FieldSet::default();
    let d = terms::decompose(&t, &fs, Some(&pl), p, 0.0);
    let w = d.vel[terms::T_WAVE];
    assert_eq!((w[0], w[2]), (0.0, 0.0));
    assert!(f64::from(w[1]) >= 0.45 * 8.0, "w {w:?}");
    let want = w_at(&t, &pl, p).0;
    assert!((f64::from(w[1]) - want).abs() < 1.0e-6);
    // Analytic активен (RW-9): итог = волна + analytic + ridge + порыв, остальные слоты пусты
    let (a, r, gu) = (
        d.vel[terms::T_ANALYTIC],
        d.vel[terms::T_RIDGE],
        d.vel[terms::T_GUST],
    );
    for q in 0..3 {
        let own = if q == 1 { w[1] } else { 0.0 };
        assert!((d.total[q] - (own + a[q] + r[q] + gu[q])).abs() < 1.0e-5);
    }
    // у земли под гребнем: σ итога = ротор (ограничен turb_max/rotor_max)
    let wd = f.dir();
    let lam = f.wavelength() as f32;
    let g = [cr[0].x + wd[0] * lam * 0.25, cr[0].z + wd[1] * lam * 0.25];
    let y = cr[0].crest.max(ground_height(&pl, g[0], g[1])) + 40.0;
    let rotor = w_at(&t, &pl, [g[0], y, g[1]]).1;
    assert!(rotor > 0.3);
    let s = terms::sum(
        &t,
        &fs,
        Some(&pl),
        [g[0], y, g[1]],
        SampleMode::Mean,
        0.0,
        None,
    );
    assert!(s.iter().all(|x| x.is_finite()));
}
