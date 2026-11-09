//! TB-7: шаблон пузыря в `dp-air` за флагом `thermal.bubble_template` (контракт TB4 v1).
//!
//! `flag_off_bitwise` — флаг выкл: `State::sample` и `terms::sum` побитно как до модуля (фикстура
//! `tests/data/thermal_bubble_off.json`, записана на нетронутом коде: `TB_RECORD=1`).
#![allow(clippy::needless_range_loop)]
use dp_air::field::field_set::FieldSet;
use dp_air::terms::thermal::bubble::{self, BState, Bubble, BubbleTable, Source};
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds};
use dp_air::terms::{self, Terms};
use dp_air::{Conditions, Configs, Focus, Place, PlaceHeader, SampleMode};
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

/// Конфиги игры; `patch` правит `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            patch(&mut v);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Arc::new(Configs::new(files))
}

struct Sunny;
impl GroundSource for Sunny {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, _x: f64, _z: f64, _t: f64) -> f64 {
        1.0
    }
}

fn flat_place() -> Place {
    let h = PlaceHeader::from_json(
        r#"{"version":1,"loc":{"id":"flat","center_lat":50.0,"center_lon":86.0,"utc_offset_h":6.0,
"month":7,"day":15},"grid":{"origin_x":-40000,"origin_z":-40000,"spacing":20000,"width":5,"height":5},
"surface_classes":{"grass":1},"start_sites":[]}"#,
    )
    .unwrap();
    Place::new(h, vec![0.0; 25], vec![0; 25], vec![1; 25], vec![0.5; 25]).unwrap()
}

/// Источники только в круге радиуса 800 м вокруг начала: термиков мало и они разнесены (проверка знаков).
struct Spot;
impl GroundSource for Spot {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        if x.hypot(z) < 800.0 { 1.0 } else { 0.0 }
    }
}

/// Сильный день на ровной земле со сносом (ветер 18 км/ч), динамические термики, круг генерации 8 км.
fn scene_terms(patch: impl Fn(&mut Value)) -> Terms {
    scene_with(patch, Arc::new(Sunny))
}

fn scene_with(patch: impl Fn(&mut Value), ground: Arc<dyn GroundSource>) -> Terms {
    let text = std::fs::read_to_string(repo().join("configs/weather/strong.json")).unwrap();
    let mut w: Value = serde_json::from_str(&text).unwrap();
    w["wind_speed_kmh"] = json!(18.0);
    w["wind_from_deg"] = json!(270.0);
    let c = Conditions::from_json(
        &json!({"preset": w, "start_hour": 12.0, "speed": 1.0, "blend_s": null, "rebuild": false})
            .to_string(),
    )
    .unwrap();
    let cfg = configs_with(|v| {
        v["thermal"]["generation_radius_m"] = json!(8000.0);
        patch(v);
    });
    let mut t = Terms::default();
    t.configure(&cfg, 4242);
    t.thermal_async = false;
    t.set_conditions(&c);
    t.focuses = vec![Focus {
        pos: [0.0, 0.0, 0.0],
        weight: 1.0,
    }];
    t.set_thermal_ground(ground);
    t
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Живые активные термики набора (по возрастанию id), у которых на момент `t` есть подъём.
fn live(t: &Terms, tm: f64, n: usize) -> Vec<Arc<AtmoThermal>> {
    let st = t.slots.thermal.as_slot().unwrap().state().unwrap();
    let mut v: Vec<Arc<AtmoThermal>> = st
        .active
        .iter()
        .filter(|h| !h.is_static && h.phase(tm).env > 0.3 && h.strength > 1.5)
        .cloned()
        .collect();
    v.sort_by_key(|h| h.id);
    v.truncate(n);
    v
}

/// Точки вокруг термика: цилиндр радиусом 3 радиуса ядра, от земли источника до верха.
fn points_around(h: &AtmoThermal, tm: f64, rng: &mut Rng, n: usize) -> Vec<[f32; 3]> {
    let ph = h.phase(tm);
    let y0 = f64::from(h.src[1]);
    (0..n)
        .map(|_| {
            let y = y0 + 20.0 + rng.next() * (h.top - y0 + 80.0);
            let ax = h.axis_at(y, ph.drift);
            let r = 3.0 * h.radius * rng.next().sqrt();
            let a = std::f64::consts::TAU * rng.next();
            [
                (ax[0] + r * a.cos()) as f32,
                y as f32,
                (ax[1] + r * a.sin()) as f32,
            ]
        })
        .collect()
}

const MOMENTS: [f64; 3] = [700.0, 1600.0, 2600.0];
const PER_THERMAL: usize = 170;

/// Побитовая запись `State::sample` (u64) и `sum` (u32) на сцене флага выкл.
fn record(t: &mut Terms, place: &Place) -> Value {
    let fs = FieldSet::default();
    let mut moments = Vec::new();
    for (mi, &tm) in MOMENTS.iter().enumerate() {
        t.start_at(tm);
        let ths = live(t, tm, 6);
        assert!(ths.len() >= 5, "живых термиков {} в момент {tm}", ths.len());
        let slot = t.slots.thermal.as_slot().unwrap();
        let (st, setup) = (slot.state().unwrap(), slot.setup().unwrap());
        let mut rng = Rng(100 + mi as u64);
        let (mut pts, mut samp, mut sums) = (Vec::new(), Vec::new(), Vec::new());
        for h in &ths {
            for p in points_around(h, tm, &mut rng, PER_THERMAL) {
                let o = st.sample(setup, &NoClouds, p, tm);
                let s = terms::sum(t, &fs, Some(place), p, SampleMode::Mean, tm, None);
                pts.push(json!([p[0].to_bits(), p[1].to_bits(), p[2].to_bits()]));
                samp.push(json!([o[0].to_bits(), o[1].to_bits(), o[2].to_bits()]));
                sums.push(json!([
                    s[0].to_bits(),
                    s[1].to_bits(),
                    s[2].to_bits(),
                    s[3].to_bits()
                ]));
            }
        }
        moments.push(json!({
            "t": tm,
            "ids": ths.iter().map(|h| h.id).collect::<Vec<_>>(),
            "points": pts, "sample": samp, "sum": sums,
        }));
    }
    json!({"per_thermal": PER_THERMAL, "moments": moments})
}

fn fixture_path() -> PathBuf {
    repo().join("rust/dp-air/tests/data/thermal_bubble_off.json")
}

/// Флаг выкл: те же биты, что до модуля. `TB_RECORD=1` — переписать фикстуру (только на нетронутом коде).
#[test]
fn flag_off_bitwise() {
    let place = flat_place();
    let mut t = scene_terms(|_| {});
    let now = record(&mut t, &place);
    if std::env::var("TB_RECORD").is_ok() {
        std::fs::write(fixture_path(), serde_json::to_string(&now).unwrap()).unwrap();
        return;
    }
    let want: Value =
        serde_json::from_str(&std::fs::read_to_string(fixture_path()).unwrap()).unwrap();
    let (a, b) = (
        now["moments"].as_array().unwrap(),
        want["moments"].as_array().unwrap(),
    );
    assert_eq!(a.len(), b.len());
    let mut n = 0;
    for (m, (x, y)) in a.iter().zip(b).enumerate() {
        assert_eq!(x["ids"], y["ids"], "момент {m}: набор термиков");
        assert_eq!(x["points"], y["points"], "момент {m}: точки");
        for key in ["sample", "sum"] {
            let (xs, ys) = (x[key].as_array().unwrap(), y[key].as_array().unwrap());
            for (i, (p, q)) in xs.iter().zip(ys).enumerate() {
                assert_eq!(p, q, "момент {m} {key} #{i}: биты");
                n += 1;
            }
        }
    }
    assert!(n >= 2 * 1000 * MOMENTS.len(), "сверено {n}");
}

// ---------------------------------------------------------------- порт против Python

#[derive(serde::Deserialize, Clone, Copy)]
struct St {
    xc: f64,
    yc: f64,
    zc: f64,
    #[serde(rename = "R")]
    r: f64,
    #[serde(rename = "U")]
    u: f64,
    #[serde(rename = "Q")]
    q: f64,
    #[serde(rename = "F0")]
    f0: f64,
    zb: f64,
    #[serde(rename = "Uh")]
    uh: f64,
    b0: f64,
}

impl St {
    fn b(&self) -> BState {
        BState {
            zc: self.zc,
            r: self.r,
            u: self.u,
            q: self.q,
            f0: self.f0,
            zb: self.zb,
            uh: self.uh,
            b0: self.b0,
        }
    }
}

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    t: f64,
    states: Vec<St>,
    points: Vec<[f64; 3]>,
    v: Vec<[f64; 3]>,
}

#[derive(serde::Deserialize)]
struct Fixture {
    env: Env,
    game: Game,
    cases: Vec<Case>,
}

#[derive(serde::Deserialize)]
struct Env {
    zi: f64,
}

#[derive(serde::Deserialize)]
struct Game {
    wstar: f64,
    zl: f64,
}

fn fixture() -> Fixture {
    let p = repo().join("tools/research/thermal_bubble/out/bench_fixture.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn norm(v: [f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

/// Аналитика порта против `bubble.velocity` Python (фикстура `bench_fixture.json`, v2) и `state` против
/// состояний фикстуры: отн. ≤ 1e-5.
#[test]
fn port_vs_python() {
    let fx = fixture();
    let zi = fx.env.zi;
    let mut worst: f64 = 0.0;
    for c in &fx.cases {
        let bubbles: Vec<Bubble> = c.states.iter().map(|s| Bubble::new(s.b())).collect();
        let peak = c.v.iter().map(|v| norm(*v)).fold(0.0, f64::max);
        let mut err: f64 = 0.0;
        for (p, want) in c.points.iter().zip(&c.v) {
            let mut got = [0.0; 3];
            for (b, s) in bubbles.iter().zip(&c.states) {
                let v = b.velocity(p[0] - s.xc, p[1] - s.yc, p[2], zi);
                for k in 0..3 {
                    got[k] += v[k];
                }
            }
            err = err.max(norm([got[0] - want[0], got[1] - want[1], got[2] - want[2]]));
        }
        let rel = err / peak;
        println!("port_vs_python {}: rel={rel:e}", c.name);
        worst = worst.max(rel);
    }
    println!("port_max_rel={worst:e}");
    assert!(worst <= 1e-5, "порт velocity: {worst:e}");
    // состояния
    let src = Source::from_game(0.0, fx.game.wstar, fx.game.zl, 690.0);
    let tr = bubble::Traj::new(&src, zi);
    let mut worst_s: f64 = 0.0;
    for c in fx.cases.iter().filter(|c| c.states.len() == 1) {
        let want = c.states[0];
        let got = tr.state(&src, zi, c.t).expect("состояние есть");
        for (n, g, w) in [
            ("zc", got.zc, want.zc),
            ("R", got.r, want.r),
            ("U", got.u, want.u),
            ("Q", got.q, want.q),
            ("F0", got.f0, want.f0),
            ("zb", got.zb, want.zb),
            ("Uh", got.uh, want.uh),
            ("b0", got.b0, want.b0),
        ] {
            let rel = (g - w).abs() / w.abs().max(1.0);
            assert!(rel <= 1e-5, "{} {n}: rust {g}, python {w}", c.name);
            worst_s = worst_s.max(rel);
        }
    }
    println!("state_max_rel={worst_s:e}");
}

// ---------------------------------------------------------------- точность таблицы

/// Таблица против аналитики: сетка разрезов через ось (шаги вне узлов таблицы) и случайные точки в радиусе
/// влияния на 7 стадиях жизни (рост, зрелость, отрыв, распад), плюс точки фикстуры. Печатает
/// `table_max_rel=<x>` = max|v_table − v_analytic| / max|v_analytic| (пик по сцене), `table_rms_ms`,
/// `bytes_per_bubble`, `build_ms_per_bubble`.
#[test]
fn table_accuracy() {
    let fx = fixture();
    let zi = fx.env.zi;
    let cut = bubble::INFLUENCE_FRAC * fx.game.wstar;
    let mut rng = Rng(7);
    // (имя, максимум ошибки, сумма квадратов, число точек)
    let (mut max_err, mut sum2, mut n_all) = (0.0f64, 0.0f64, 0usize);
    let mut scene_peak: f64 = 0.0;
    let (mut bytes, mut build_ms) = (0usize, 0.0f64);
    let mut per_state = Vec::new();
    let single: Vec<&Case> = fx.cases.iter().filter(|c| c.states.len() == 1).collect();
    for c in &single {
        let s = c.states[0];
        let b = Bubble::new(s.b());
        let (r_max, _) = bubble::influence_radius(&b, zi, cut);
        let t0 = std::time::Instant::now();
        let tb = BubbleTable::build(&b, zi, r_max, c.t);
        build_ms += t0.elapsed().as_secs_f64() * 1e3;
        bytes += tb.bytes();
        let mut pts: Vec<[f64; 3]> = Vec::new();
        // разрезы через ось: ρ и z вне узлов таблицы
        let mut rho = 0.37;
        while rho < r_max {
            let mut z = 0.61;
            while z < zi {
                pts.push([rho, 0.0, z]);
                z += 13.1;
            }
            rho += 7.37;
        }
        // случайные точки в радиусе влияния
        for _ in 0..2000 {
            let r = r_max * rng.next().sqrt();
            let a = std::f64::consts::TAU * rng.next();
            pts.push([r * a.cos(), r * a.sin(), 1.0 + rng.next() * (zi - 2.0)]);
        }
        // точки фикстуры (в том числе вне радиуса таблицы: там таблица даёт 0)
        for p in &c.points {
            pts.push([p[0] - s.xc, p[1] - s.yc, p[2]]);
        }
        let (mut e_max, mut p_max) = (0.0f64, 0.0f64);
        for p in &pts {
            let v = b.velocity(p[0], p[1], p[2], zi);
            let rho = p[0].hypot(p[1]);
            let (ur, w) = tb.lookup(rho, p[2]).map_or((0.0, 0.0), |a| (a[0], a[1]));
            let k = if rho > 1e-9 { ur / rho } else { 0.0 };
            let t = [k * p[0], k * p[1], w];
            let e = norm([t[0] - v[0], t[1] - v[1], t[2] - v[2]]);
            e_max = e_max.max(e);
            p_max = p_max.max(norm(v));
            sum2 += e * e;
            n_all += 1;
        }
        scene_peak = scene_peak.max(p_max);
        max_err = max_err.max(e_max);
        per_state.push((c.name.clone(), e_max, p_max, r_max, tb.bytes()));
    }
    for (n, e, p, r, b) in &per_state {
        println!(
            "  {n}: max|dv|={e:.4} пик={p:.3} ({:.3}) r_max={r} байт={b}",
            e / scene_peak
        );
    }
    let rel = max_err / scene_peak;
    let nb = single.len() as f64;
    println!("table_max_rel={rel:.5}");
    println!("table_rms_ms={:.5}", (sum2 / n_all as f64).sqrt());
    println!("bytes_per_bubble={:.0}", bytes as f64 / nb);
    println!("build_ms_per_bubble={:.1}", build_ms / nb);
    assert!(rel <= 0.05, "точность таблицы {rel}");
}

// ---------------------------------------------------------------- флаг вкл: сумма ветра

fn axis_xz(h: &AtmoThermal, tm: f64) -> [f64; 2] {
    let ph = h.phase(tm);
    [
        f64::from(h.src[0]) + f64::from(ph.drift[0]),
        f64::from(h.src[2]) + f64::from(ph.drift[1]),
    ]
}

/// Термик игры, один: источник в начале, столб 1400 м, сила 2,5 м/с, снос 2 м/с по x.
fn lone_thermal() -> AtmoThermal {
    let mut h = AtmoThermal::blank(1);
    h.top = 1400.0;
    h.strength = 2.5;
    h.radius = 100.0;
    h.drift_vel = [2.0, 0.0];
    h.drift_delay = 0.0;
    h.t_grow = 180.0;
    h.t_mature = 510.0;
    h.t_decay = 300.0;
    h
}

/// Флаг вкл: (1) у одного термика приток к оси у земли (пока источник включён) и растекание под крышкой
/// (оторвавшаяся голова у крышки) — знаки `uh` (среднее по кольцу), далеко за радиусом таблицы `w = uh = 0`;
/// (2) в сцене сумма конечна, а горизонталь слагаемого `thermal` суммы равна `fade·uh` опроса набора.
#[test]
fn flag_on_sum() {
    let place = flat_place();
    let fs = FieldSet::default();
    // источники только в круге 800 м: термиков немного (сборка таблиц на -O0 дорогая)
    let mut on = scene_with(
        |v| {
            v["thermal"]["physics_radius_m"] = json!(300.0);
            v["thermal"]["bubble_template"] = json!(true);
        },
        Arc::new(Spot),
    );
    let t0 = std::time::Instant::now();
    on.start_at(1200.0);
    println!(
        "flag_on_sum: start_at {:.1} с, активных {}",
        t0.elapsed().as_secs_f64(),
        on.slots
            .thermal
            .as_slot()
            .unwrap()
            .state()
            .unwrap()
            .active
            .len()
    );
    let slot = on.slots.thermal.as_slot().unwrap();
    let setup = slot.setup().unwrap().clone();
    assert!(setup.cfg.bubble_template, "флаг не прочитан");

    // (1) один термик
    let h = Arc::new(lone_thermal());
    let (src, zi) = bubble::source_of(&h).unwrap();
    for (tm, name) in [(200.0, "земля"), (900.0, "крышка")] {
        let c = axis_xz(&h, tm);
        let st = dp_air::terms::thermal::State::build(&setup, vec![h.clone()], tm, &[c], 1.0, 0);
        let b = bubble::state(&src, zi, tm).expect("пузырь есть");
        let high = if name == "земля" { 30.0 } else { 0.9 * zi };
        let ring = |rho: f64| -> f64 {
            let n = 16;
            let mut sum = 0.0;
            for k in 0..n {
                let a = std::f64::consts::TAU * f64::from(k) / f64::from(n);
                let p = [
                    (c[0] + rho * a.cos()) as f32,
                    high as f32,
                    (c[1] + rho * a.sin()) as f32,
                ];
                let (o, uh) = st.sample_bubble(&setup, &NoClouds, p, tm);
                assert!(o.iter().chain(&uh).all(|x| x.is_finite()));
                sum += uh[0] * a.cos() + uh[1] * a.sin();
            }
            sum / f64::from(n)
        };
        let r = ring(b.r);
        println!(
            "flag_on_sum {name}: tp={tm} R={:.0} zb={:.0} радиальная uh={r:.3}",
            b.r, b.zb
        );
        if name == "земля" {
            assert!(b.zb == 0.0 && r < -0.1, "приток к оси у земли: {r}");
        } else {
            assert!(b.zb > 0.0 && r > 0.05, "растекание от оси под крышкой: {r}");
        }
        let far = [(c[0] + 5000.0) as f32, high as f32, c[1] as f32];
        let (o, uh) = st.sample_bubble(&setup, &NoClouds, far, tm);
        assert!(
            o[0] == 0.0 && uh == [0.0; 2],
            "за радиусом таблицы: {o:?} {uh:?}"
        );
        // на оси горизонтали нет, подъём есть
        let on_axis = [c[0] as f32, (0.3 * zi) as f32, c[1] as f32];
        let (o, uh) = st.sample_bubble(&setup, &NoClouds, on_axis, tm);
        assert!(uh == [0.0; 2], "на оси uh = {uh:?}");
        if name == "земля" {
            assert!(o[0] > 0.5, "на оси подъём {}", o[0]);
        }
    }

    // (2) сцена: сумма конечна; горизонталь thermal в разложении = fade·uh набора
    let mut rng = Rng(5);
    let fade_m = on.cfg.ground_fade_m;
    let (mut n_h, mut n_pts) = (0, 0);
    for tm in [1200.0, 2000.0] {
        on.start_at(tm);
        let ths = live(&on, tm, 6);
        let st = on.slots.thermal.as_slot().unwrap().state().unwrap();
        for th in &ths {
            for p in points_around(th, tm, &mut rng, 60) {
                let s = terms::sum(&on, &fs, Some(&place), p, SampleMode::Mean, tm, None);
                assert!(s.iter().all(|x| x.is_finite()), "сумма не конечна {p:?}");
                let d = terms::decompose(&on, &fs, Some(&place), p, tm);
                let (_, uh) = st.sample_bubble(&setup, &NoClouds, p, tm);
                let fade = (f64::from(p[1]) / fade_m).min(1.0);
                for (got, want) in [(d.vel[3][0], fade * uh[0]), (d.vel[3][2], fade * uh[1])] {
                    assert!(
                        (f64::from(got) - want).abs() <= 1e-4 + 1e-5 * want.abs(),
                        "{p:?}: thermal.vel {got} против fade·uh {want}"
                    );
                }
                n_pts += 1;
                if uh[0] != 0.0 || uh[1] != 0.0 {
                    n_h += 1;
                }
            }
        }
    }
    println!("flag_on_sum: точек {n_pts}, с горизонталью {n_h}");
    assert!(
        n_pts >= 400 && n_h > n_pts / 4,
        "горизонталь есть не везде: {n_h} из {n_pts}"
    );
}
