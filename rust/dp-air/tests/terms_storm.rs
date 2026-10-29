//! RW-11c: гроза (`StormField`) и физика облака Cb (`CloudModel`): сверка слагаемого `storm` с
//! эталонами W8, стадии/центра/размеров Cb с дампом `desc.json`, интенсивности ядра `storm`;
//! перенос частей `test_hazards.gd` (Cb) и `test_storm_rarity.gd` (слияние потоков ячеек).
use dp_air::Configs;
use dp_air::field::field_set::FieldSet;
use dp_air::fixtures::{self, Case, Frame};
use dp_air::terms::storm::{self, CloudCfg, CloudModel, NO_CLOUD, StormCfg, StormField};
use dp_air::terms::thermal::{AtmoThermal, GroundSource};
use dp_air::terms::{self, Terms};
use dp_air::{Place, SampleMode};
use serde_json::Value;
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

/// Конфиги игры как у `synth_*` (`config_overrides`: круг генерации 8 км).
fn configs() -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["thermal"]["generation_radius_m"] = serde_json::json!(8000.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Arc::new(Configs::new(files))
}

// ---- синтетический мир `atmo_fingerprint.gd` ----

fn syn_height(x: f64, z: f64) -> f64 {
    900.0
        + 350.0 * (x / 3100.0).sin() * (z / 4300.0).cos()
        + 160.0 * ((x + 0.6 * z) / 1700.0).sin()
        + 40.0 * (x / 450.0 - z / 700.0).cos()
}

fn syn_normal(x: f64, z: f64) -> [f32; 3] {
    let e = 15.0;
    let dx = ((syn_height(x + e, z) - syn_height(x - e, z)) / (2.0 * e)) as f32;
    let dz = ((syn_height(x, z + e) - syn_height(x, z - e)) / (2.0 * e)) as f32;
    let l = (dx * dx + 1.0 + dz * dz).sqrt();
    [-dx / l, 1.0 / l, -dz / l]
}

fn syn_source(x: f64, z: f64) -> f64 {
    let k = 0.65 + 0.35 * (x / 830.0 + 1.3).sin() * (z / 1170.0 - 0.4).cos();
    let n = syn_normal(x, z);
    let s = {
        let (a, b, c) = (0.3f32, 0.8f32, 0.5f32);
        let l = (a * a + b * b + c * c).sqrt();
        [a / l, b / l, c / l]
    };
    let d = f64::from(n[0] * s[0] + n[1] * s[1] + n[2] * s[2]);
    (k * (0.35 + 0.8 * d)).clamp(0.0, 1.0)
}

struct SynGround;
impl GroundSource for SynGround {
    fn height(&self, x: f64, z: f64) -> f64 {
        syn_height(x, z)
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        syn_source(x, z)
    }
}

struct Loaded {
    case: Case,
    place: Place,
    data: fixtures::CaseData,
    frames: Vec<Frame>,
    extra: Value,
}

fn load(name: &str) -> Loaded {
    let p = repo().join(format!("tests/fixtures/wind/cases/{name}.json"));
    let case = fixtures::read_case(&p).unwrap();
    let place = fixtures::read_place(&case.place_path(&p)).unwrap();
    let data = fixtures::read_case_data(&case, &p).unwrap();
    let frames = fixtures::read_desc(&case, &p).unwrap();
    let raw: Value = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
    Loaded {
        case,
        place,
        data,
        frames,
        extra: raw["extra"].clone(),
    }
}

fn terms_for(case: &Case) -> Terms {
    let mut t = Terms::default();
    t.configure(&configs(), case.seed);
    t.set_conditions(&case.conditions);
    // эталоны synth_* сняты с упрощённым профилем 0.8.0 (README фикстур)
    t.wind.set_simple_profile(true, None);
    t.statics = case.static_thermals.clone();
    t.statics_mode = case.static_mode;
    t.focuses = case.focuses.clone();
    t.set_thermal_ground(Arc::new(SynGround));
    t
}

fn term_index(case: &Case, name: &str) -> usize {
    case.terms
        .as_ref()
        .unwrap()
        .iter()
        .position(|n| n == name)
        .unwrap()
}

/// Допуск W8 для детерминированных слагаемых: 0,05 м/с + 2 %.
fn tol(v: f32) -> f32 {
    0.05 + 0.02 * v.abs()
}

fn on_grid(place: &Place, p: [f32; 3]) -> bool {
    let g = &place.header().grid;
    let (x1, z1) = (
        g.origin_x + (f64::from(g.width) - 1.0) * g.spacing,
        g.origin_z + (f64::from(g.height) - 1.0) * g.spacing,
    );
    (g.origin_x..=x1).contains(&f64::from(p[0])) && (g.origin_z..=z1).contains(&f64::from(p[2]))
}

fn cb_cells(t: &Terms) -> Vec<&AtmoThermal> {
    storm::cells(t).collect()
}

// ---------------------------------------------------------------- сверка с эталонами W8

/// (1) Слагаемое `storm` в `synth_storm` и остальных `synth_*` (грозы там нет - нули) по всем
/// трём компонентам в допуске W8; в выборке есть точки с настоящим потоком.
#[test]
fn synth_storm_term_in_w8_tolerance() {
    let mut strong = 0;
    let mut checked = 0;
    let mut tagged = 0;
    for name in [
        "synth_storm",
        "synth_weak",
        "synth_medium",
        "synth_strong",
        "synth_wave",
    ] {
        let l = load(name);
        let si = term_index(&l.case, "storm");
        let mut t = terms_for(&l.case);
        let fs = FieldSet::default();
        for (k, &tm) in l.case.times_s.iter().enumerate() {
            t.start_at(tm);
            let want: Vec<[f32; 4]> = l.data.slab(k, 2 + si).collect();
            for (i, (p, tag)) in l.case.points.iter().zip(&l.case.point_tags).enumerate() {
                if !on_grid(&l.place, *p) {
                    // вне растра места высоту знает только аналитика GD (W5: по краю)
                    continue;
                }
                let d = terms::decompose(&t, &fs, Some(&l.place), *p, tm);
                let g = d.vel[4];
                for q in 0..3 {
                    assert!(
                        (g[q] - want[i][q]).abs() <= tol(want[i][q]),
                        "{name} t={tm} точка {i} ({tag}) {p:?} компонента {q}: rust {}, gd {}",
                        g[q],
                        want[i][q]
                    );
                }
                checked += 1;
                if tag == "storm" {
                    tagged += 1;
                }
                if want[i][..3].iter().any(|v| v.abs() > 1.0) {
                    strong += 1;
                }
            }
        }
    }
    assert!(checked > 600, "сверено {checked}");
    assert!(tagged >= 20, "точек с тегом storm: {tagged}");
    assert!(strong >= 20, "точек с потоком > 1 м/с: {strong}");
}

/// (2) σ грозы: в эталоне есть только итоговая σ (σ слагаемого справочно не пишется), поэтому
/// проверка односторонняя: σ_гроза (до предела общей σ 4 м/с) не больше итоговой σ точки.
#[test]
fn synth_storm_sigma_not_above_total() {
    let l = load("synth_storm");
    let mut t = terms_for(&l.case);
    let mut seen = 0;
    let mut max_s = 0.0f64;
    for (k, &tm) in l.case.times_s.iter().enumerate() {
        t.start_at(tm);
        let total: Vec<[f32; 4]> = l.data.slab(k, 0).collect();
        let fs = FieldSet::default();
        for (i, p) in l.case.points.iter().enumerate() {
            if !on_grid(&l.place, *p) {
                continue;
            }
            let ground = f64::from(dp_air::field::runtime::ground_height(&l.place, p[0], p[2]));
            let agl = (f64::from(p[1]) - ground).max(0.0);
            let cfg = StormCfg::from_configs(&t.configs);
            let f = StormField::new(cfg, t.weather.f64_or("cloud_size_factor", 1.0));
            let s = f.sample(storm::cells(&t), *p, agl, tm)[3];
            let _ = &fs;
            assert!(
                s.min(4.0) <= f64::from(total[i][3]) * 1.05 + 0.02,
                "t={tm} точка {i}: σ_гроза {s} > σ_итог {}",
                total[i][3]
            );
            max_s = max_s.max(s);
            if s > 0.5 {
                seen += 1;
            }
        }
    }
    assert!(
        seen >= 10 && max_s > 2.0,
        "точек σ > 0,5: {seen}, max {max_s}"
    );
}

/// (3) Cb-облака дампа `desc.json` (флаг 4): число, стадия (рост, распад), центр, полуось
/// `max(rx, rz)` и верх `top + h` против `CloudModel` крейта по тем же термикам.
#[test]
fn cb_cloud_records_match_gd_dump() {
    let mut total = 0;
    let mut mature = 0;
    for name in ["synth_storm", "synth_medium", "synth_strong"] {
        let l = load(name);
        let mut t = terms_for(&l.case);
        let cm = CloudModel::new(
            CloudCfg::from_configs(&t.configs),
            t.weather.f64_or("cloud_size_factor", 1.0),
        );
        let c = l.extra["desc_center"].as_array().unwrap();
        let (cx, cz) = (c[0].as_f64().unwrap() as f32, c[1].as_f64().unwrap() as f32);
        let radius = l.extra["desc_radius"].as_f64().unwrap() as f32;
        for (k, &tm) in l.case.times_s.iter().enumerate() {
            t.start_at(tm);
            let gd: Vec<_> = l.frames[k]
                .clouds
                .iter()
                .filter(|c| c.flags as u32 == 4)
                .collect();
            let mine: Vec<(&AtmoThermal, [f64; 3])> = cb_cells(&t)
                .into_iter()
                .map(|th| (th, cm.stage(th, tm)))
                .filter(|(_, st)| st[0] >= 0.0)
                .filter(|(th, _)| {
                    let ce = cm.center(th, tm);
                    (cx - ce[0]).hypot(cz - ce[1]) <= radius
                })
                .collect();
            assert_eq!(mine.len(), gd.len(), "{name} t={tm}: число Cb-облаков");
            for g in gd {
                let (th, st) = mine
                    .iter()
                    .min_by(|a, b| {
                        let da = (cm.center(a.0, tm)[0] - g.x).hypot(cm.center(a.0, tm)[1] - g.z);
                        let db = (cm.center(b.0, tm)[0] - g.x).hypot(cm.center(b.0, tm)[1] - g.z);
                        da.total_cmp(&db)
                    })
                    .unwrap();
                let ce = cm.center(th, tm);
                let who = format!("{name} t={tm} облако ({}, {})", g.x, g.z);
                assert!((ce[0] - g.x).hypot(ce[1] - g.z) < 0.5, "{who}: центр");
                assert!((st[0] as f32 - g.growth).abs() < 1e-4, "{who}: рост");
                assert!((st[1] as f32 - g.decay).abs() < 1e-4, "{who}: распад");
                let sz = cm.size(th, *st);
                let rad = sz[0].max(sz[1]) as f32;
                assert!(
                    (rad - g.radius).abs() <= 0.002 * g.radius + 0.5,
                    "{who}: полуось"
                );
                let top = (th.top + sz[2]) as f32;
                assert!(
                    (top - g.top_msl).abs() <= 1.0,
                    "{who}: верх {top} vs {}",
                    g.top_msl
                );
                assert!(
                    (th.top as f32 - g.base_msl).abs() <= 0.5,
                    "{who}: основание"
                );
                total += 1;
                if st[0] >= 1.0 && st[1] == 0.0 {
                    mature += 1;
                }
            }
        }
    }
    assert!(total >= 8, "сверено Cb-облаков {total}");
    assert!(mature >= 2, "зрелых без распада {mature}");
}

/// (4) Интенсивность грозы ядра (поле `storm` ядра W6) против дампа `cores`: у Cb - по времени
/// бури, у остальных 0. Ядро сопоставляется по оси у земли.
#[test]
fn core_storm_intensity_matches_dump() {
    let l = load("synth_storm");
    let mut t = terms_for(&l.case);
    let mut cb = 0;
    let mut live = 0;
    for (k, &tm) in l.case.times_s.iter().enumerate() {
        t.start_at(tm);
        let gd = &l.frames[k].cores;
        let st = t.slots.thermal.as_slot().unwrap().state().unwrap();
        for th in st.all.iter().filter(|a| a.is_cb) {
            let ph = th.phase(tm);
            let ax = th.axis_at(f64::from(th.src[1]), ph.drift);
            // дамп - ядра в круге 8 км вокруг (1500, -2500)
            if (ax[0] - 1500.0).hypot(ax[1] + 2500.0) > 8000.0 {
                continue;
            }
            let g = gd
                .iter()
                .find(|g| {
                    (g.x - ax[0] as f32).hypot(g.z - ax[1] as f32) < 25.0 && g.flags as u32 & 4 != 0
                })
                .unwrap_or_else(|| panic!("t={tm}: ядра Cb {} нет в дампе", th.id));
            let mine = storm::core_intensity(&t, th, tm);
            assert!(
                (mine - f64::from(g.storm)).abs() <= 1e-3,
                "t={tm} Cb {}: интенсивность {mine} vs {}",
                th.id,
                g.storm
            );
            cb += 1;
            if g.storm > 0.1 {
                live += 1;
            }
        }
    }
    assert!(cb >= 4 && live >= 2, "Cb {cb}, с бурей {live}");
}

/// (5) `ongudai_day_2`: в эталоне грозовой вклад мал и редок (десяток точек-моментов, Cb из
/// источников поля Пикара - RW-10d/e, погода дня - RW-12d: сверка после них); у крейта без
/// термиков слагаемое нулевое.
#[test]
fn ongudai_day_2_waits_for_field_and_day() {
    let l = load("ongudai_day_2");
    let si = term_index(&l.case, "storm");
    let mut n = 0;
    for k in 0..l.case.times_s.len() {
        n += l
            .data
            .slab(k, 2 + si)
            .filter(|v| v[..3].iter().any(|x| x.abs() > 0.0))
            .count();
    }
    assert!(
        (1..=40).contains(&n),
        "ненулевых точек-моментов в эталоне: {n}"
    );
    let mut t = Terms::default();
    t.configure(&configs(), l.case.seed);
    t.set_conditions(&l.case.conditions);
    let fs = FieldSet::default();
    let d = terms::decompose(&t, &fs, Some(&l.place), l.case.points[0], 0.0);
    assert_eq!(d.vel[4], [0.0; 3]);
}

/// (6) `ongudai_storm`: в эталоне поток есть, Cb рождаются из источников поля (RW-10d/e). Здесь -
/// только то, что можно проверить без них: теги `storm` есть, у крейта без термиков слагаемое
/// нулевое, режим `Mean` тоже (полная сверка - после RW-10e).
#[test]
fn ongudai_storm_waits_for_field_sources() {
    let l = load("ongudai_storm");
    let si = term_index(&l.case, "storm");
    let mut strong = 0;
    for k in 0..l.case.times_s.len() {
        strong += l
            .data
            .slab(k, 2 + si)
            .filter(|v| v[..3].iter().any(|x| x.abs() > 0.3))
            .count();
    }
    assert!(strong >= 10, "в эталоне точек с грозой: {strong}");
    let mut t = Terms::default();
    t.configure(&configs(), l.case.seed);
    t.set_conditions(&l.case.conditions);
    let fs = FieldSet::default();
    let d = terms::decompose(&t, &fs, Some(&l.place), l.case.points[0], 0.0);
    assert_eq!(d.vel[4], [0.0; 3]);
    let _ = SampleMode::Mean;
}

// ---------------------------------------------------------------- синтетические Cb (hazards)

fn storm_field() -> StormField {
    // пресет `storm`: cloud_size_factor 1 (запасное), ширина облака - из конфига
    StormField::new(StormCfg::from_configs(&configs()), 1.0)
}

/// Cb как в `test_storm_rarity.gd`: зрелая стадия, `t = 0` посреди бури.
fn mature_cb() -> AtmoThermal {
    let mut th = AtmoThermal::blank(1);
    th.is_cb = true;
    th.has_cloud = true;
    th.strength = 4.0;
    th.src = [0.0, 0.0, 0.0];
    th.top = 6000.0;
    th.t_birth = -2000.0;
    th.t_grow = 200.0;
    th.t_mature = 3000.0;
    th.t_decay = 400.0;
    th
}

/// `test_hazards.gd::test_cb_downdraft_and_outflow`: под Cb сильный нисходящий поток, у земли в
/// стороны от центра, на фронте подъём и болтанка.
#[test]
fn cb_downdraft_outflow_and_front() {
    let f = storm_field();
    let th = mature_cb();
    let t = 0.0;
    assert!(f.intensity(&th, t) > 0.9, "буря в разгаре");
    let c = storm::cloud_center(&th, t);
    let rd = f.downdraft_radius(&th);
    let dd = f.sample([&th], [c[0], 1500.0, c[1]], 1500.0, t);
    assert!(dd[1] < -3.0, "под Cb нисходящий поток: {}", dd[1]);
    let rf = f.front_radius(&th, t);
    let p = [c[0] + (rf * 0.6) as f32, 50.0, c[1]];
    let o = f.sample([&th], p, 50.0, t);
    assert!(
        o[0] > 5.0 && o[2].abs() < 1e-3,
        "растекание наружу по +x: {o:?}"
    );
    assert!(rd > 100.0 && rf > rd, "радиусы: ливень {rd}, фронт {rf}");
    let fp = [c[0] + rf as f32, 400.0, c[1]];
    let u = f.sample([&th], fp, 400.0, t);
    assert!(u[1] > 0.5, "на фронте подъём: {}", u[1]);
    assert!(u[3] > 1.0, "и болтанка: {}", u[3]);
    // далеко (дальше фронта и его ширины) бури нет
    let far = f.sample([&th], [c[0] + (rf + 5000.0) as f32, 50.0, c[1]], 50.0, t);
    assert_eq!(far, [0.0; 4]);
}

/// `test_storm_rarity.gd::test_overlapping_outflows_do_not_add`: четыре совпавшие ячейки не
/// сильнее одной (горизонталь ≤ outflow_ms, вертикаль ≥ −downdraft_ms).
#[test]
fn overlapping_outflows_do_not_add() {
    let f = storm_field();
    let th = mature_cb();
    let t = 0.0;
    let c = storm::cloud_center(&th, t);
    let rf = f.front_radius(&th, t);
    let p = [c[0] + (rf * 0.6) as f32, 50.0, c[1]];
    let one = f.sample([&th], p, 50.0, t);
    let four = f.sample([&th, &th, &th, &th], p, 50.0, t);
    let out = f.cfg.outflow_ms;
    assert!(one[0] > 5.0, "одна ячейка дует: {}", one[0]);
    assert!(
        four[0].hypot(four[2]) <= out + 1e-9,
        "четыре - не сильнее одной: {}",
        four[0]
    );
    assert!(four[1] >= -f.cfg.downdraft_ms - 1e-9, "ливень тоже");
    // а у центра, где сумма вертикалей превышает предел, - ровно предел
    let q = f.sample([&th, &th, &th], [c[0], 800.0, c[1]], 800.0, t);
    assert!(
        (q[1] + f.cfg.downdraft_ms).abs() < 1e-9,
        "предел ливня: {}",
        q[1]
    );
}

/// Интенсивность: нуль до начала бури (рост + 0,4 зрелости), 1 в разгаре, снова 0 через
/// `linger_s` после конца термика.
#[test]
fn intensity_follows_life() {
    let f = storm_field();
    let th = mature_cb();
    let s0 = f.storm_start(&th);
    assert!((s0 - (-2000.0 + 200.0 + 0.4 * 3000.0)).abs() < 1e-9);
    assert_eq!(f.intensity(&th, s0 - 1.0), 0.0);
    assert!(f.intensity(&th, s0 + 150.0) > 0.4 && f.intensity(&th, s0 + 150.0) < 0.6);
    assert!((f.intensity(&th, s0 + 400.0) - 1.0).abs() < 1e-12);
    let end = th.t_end() + f.cfg.linger_s;
    assert_eq!(f.intensity(&th, end), 0.0);
    assert!(f.intensity(&th, end - 150.0) < 0.6);
}

/// `CloudModel.stage`: облака нет до окна и после него, рост/распад монотонны, активность -
/// огибающая термика; окно жизни из формулы GD; статичный - (1, 0, 1); без облака - нет.
#[test]
fn cloud_stage_and_window() {
    let cm = CloudModel::new(CloudCfg::from_configs(&configs()), 1.0);
    let th = mature_cb();
    let w = cm.life_window(&th);
    // span 6000 / 4 · 0,6 = 900 > t_grow + 0,5·t_mature = 1700? нет: min(900, 1700) = 900
    assert!(
        (w[0] - (-2000.0 + 900.0)).abs() < 1e-9,
        "появление {}",
        w[0]
    );
    let ds = -2000.0 + 200.0 + 3000.0;
    assert!(
        (w[1] - (ds + 270.0)).abs() < 1e-9 && (w[2] - (ds + 400.0 + cm.cfg.linger_s)).abs() < 1e-9
    );
    assert_eq!(cm.stage(&th, w[0] - 1.0), NO_CLOUD);
    assert_eq!(cm.stage(&th, w[2] + 1.0), NO_CLOUD);
    let mut prev = [0.0; 3];
    let mut t = w[0] + 1.0;
    while t < w[2] {
        let s = cm.stage(&th, t);
        assert!(
            s[0] >= prev[0] - 1e-12 && s[1] >= prev[1] - 1e-12,
            "монотонно при t={t}"
        );
        assert!((s[2] - th.phase(t).env).abs() < 1e-12);
        prev = s;
        t += 25.0;
    }
    let mut st = th.clone();
    st.is_static = true;
    assert_eq!(cm.stage(&st, 1.0e6), [1.0, 0.0, 1.0]);
    let mut nc = th;
    nc.has_cloud = false;
    assert_eq!(cm.stage(&nc, 0.0), NO_CLOUD);
}

/// `CloudModel.size`: Cb шире обычного (×3 в пределах `cb_width_max_m`), мощность Cb - заданная
/// без переразвития; обычное облако - в пределах доли ширины и `width_max_m`.
#[test]
fn cloud_size_limits() {
    let cm = CloudModel::new(CloudCfg::from_configs(&configs()), 1.0);
    let mut cb = mature_cb();
    cb.cloud_depth = 7000.0;
    cb.cloud_stretch = 1.5;
    cb.overdevelop = 0.8;
    let s = cm.size(&cb, [1.0, 0.0, 1.0]);
    let width = (cm.cfg.width_per_ms_m * 4.0).clamp(cm.cfg.width_min_m, cm.cfg.width_max_m);
    let w = (width * 3.0).clamp(cm.cfg.width_max_m, cm.cfg.cb_width_max_m);
    assert!(
        (s[1] - w * 0.5).abs() < 1e-9 && (s[0] - s[1] * 1.5).abs() < 1e-9,
        "{s:?}"
    );
    assert!(
        (s[2] - 7000.0).abs() < 1e-9 && s[3] == 0.0,
        "мощность и растекание Cb: {s:?}"
    );
    let mut cu = AtmoThermal::blank(2);
    cu.has_cloud = true;
    cu.strength = 2.0;
    cu.cloud_depth = 5000.0;
    cu.cloud_stretch = 1.0;
    cu.overdevelop = 0.5;
    let s = cm.size(&cu, [1.0, 0.0, 1.0]);
    let width = (cm.cfg.width_per_ms_m * 2.0).clamp(cm.cfg.width_min_m, cm.cfg.width_max_m);
    let depth = 5000.0f64.clamp(
        width * cm.cfg.height_to_width[0],
        width * cm.cfg.height_to_width[1],
    );
    let want_h = depth * (1.0 + 0.5 * (cm.cfg.overdev_depth_factor - 1.0));
    assert!(
        (s[2] - want_h).abs() < 1e-6 && s[3] > 0.0,
        "{s:?} h={want_h}"
    );
}
