//! Шаблон пузыря в `dp-air` по умолчанию (контракт TB4 v3, TB-15): флага нет.
//!
//! `port_vs_python` — порт и таблицы констант против Python v5; `table_accuracy`, `bubble_cache_budget` — точность и
//! цена; `bubble_sum` — знаки притока/растекания и сумма; `no_table_profile` — профиль Гедеона там, где таблицы нет;
//! `cloud_suck` — облачный подсос выше `top`; `between_q_used`, `between_kbar` — «между» (q(ξ) и K̄ шаблона).
#![allow(clippy::needless_range_loop)]
use dp_air::field::field_set::FieldSet;
use dp_air::field::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use dp_air::terms::thermal::bubble::{self, BState, Bubble, BubbleTable, Source};
use dp_air::terms::thermal::bubble_kbar;
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds};
use dp_air::terms::thermal_air::{AirThermals, AirThermalsCfg, BuildIn, K_ALLEN, ZI_MIN};
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

/// Набор термиков с таблицами пузырей на момент ≥ `tm`: `start_at` (синхронный, без таблиц — профиль) и следующее
/// обновление набора (в игре — фоновое; здесь `thermal_async = false`, оно считает таблицы). Возвращает момент набора.
fn with_tables(t: &mut Terms, tm: f64) -> f64 {
    t.start_at(tm);
    let tm = tm + 1.0;
    t.advance(tm);
    tm
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
    scene: usize,
    t: f64,
    zi: f64,
    states: Vec<St>,
    points: Vec<[f64; 3]>,
    v: Vec<[f64; 3]>,
}

/// Источник сцены фикстуры (`from_game_strength` Python).
#[derive(serde::Deserialize)]
struct SceneSrc {
    w0: f64,
    zl: f64,
    tau: f64,
    #[serde(rename = "F0")]
    f0: f64,
    b0: f64,
    t_decay: f64,
    zh: f64,
    t_end: f64,
}

impl SceneSrc {
    fn source(&self) -> Source {
        Source {
            t0: 0.0,
            f0: self.f0,
            tau: self.tau,
            b0: self.b0,
            t_decay: self.t_decay,
            zh: self.zh,
        }
    }
}

#[derive(serde::Deserialize)]
struct KbarNode {
    zl: f64,
    wstar: f64,
    kbar: f64,
}

#[derive(serde::Deserialize)]
struct Fixture {
    sources: Vec<SceneSrc>,
    cases: Vec<Case>,
    between_q: Vec<f64>,
    kbar: Vec<KbarNode>,
}

fn fixture() -> Fixture {
    let p = repo().join("tools/research/thermal_bubble/out/embed_fixture.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

fn norm(v: [f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

/// Порт шаблона v5 против Python (фикстура `embed_fixture.json`): `velocity` (сумма пузырей, голова с оболочкой,
/// шлейф, образы) отн. <= 1e-5; `state` и `t_end` по `Source` фикстуры отн. <= 1e-5; `from_game_strength` — F0 отн. <= 1e-3
/// (K_ALLEN Rust = e·0,4575, Python 1,2436: разница 7e-6), `b0`, `t_decay`, `zh` — как у `from_game`; таблица `between_q`
/// (`bubble_q`) — узлы отн. 1e-9, среднее 1 (1e-6); K̄ (`bubble_kbar`) в узлах сетки (точки фикстуры — узлы) — отн. 5e-3 (таблица
/// хранит f32 с двумя знаками).
#[test]
fn port_vs_python() {
    let fx = fixture();
    let mut worst: f64 = 0.0;
    for c in &fx.cases {
        let bubbles: Vec<Bubble> = c.states.iter().map(|s| Bubble::new(s.b())).collect();
        let peak = c.v.iter().map(|v| norm(*v)).fold(0.0, f64::max);
        let mut err: f64 = 0.0;
        for (p, want) in c.points.iter().zip(&c.v) {
            let mut got = [0.0; 3];
            for (b, s) in bubbles.iter().zip(&c.states) {
                let v = b.velocity(p[0] - s.xc, p[1] - s.yc, p[2], c.zi);
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
    // состояния по Source фикстуры
    let mut worst_s: f64 = 0.0;
    for (si, sc) in fx.sources.iter().enumerate() {
        let src = sc.source();
        let tr = bubble::Traj::new(&src, sc.zl);
        assert!(
            (tr.t_end - sc.t_end).abs() < 1e-9,
            "сцена {si}: t_end {} против {}",
            tr.t_end,
            sc.t_end
        );
        for c in fx
            .cases
            .iter()
            .filter(|c| c.scene == si && c.states.len() == 1)
        {
            let want = c.states[0];
            let got = tr.state(&src, sc.zl, c.t).expect("состояние есть");
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
    }
    println!("state_max_rel={worst_s:e}");
    // from_game_strength
    let mut worst_f: f64 = 0.0;
    for sc in &fx.sources {
        let t0 = std::time::Instant::now();
        let got = Source::from_game_strength(0.0, sc.w0, sc.zl, sc.tau);
        let ms = t0.elapsed().as_secs_f64() * 1e3;
        let rel = (got.f0 - sc.f0).abs() / sc.f0;
        println!(
            "from_game_strength w0={} zl={} tau={}: F0 rust {:.6e} python {:.6e} rel={rel:.2e} ({ms:.0} мс)",
            sc.w0, sc.zl, sc.tau, got.f0, sc.f0
        );
        for (n, g, w, tol) in [
            ("b0", got.b0, sc.b0, 1e-9),
            ("zh", got.zh, sc.zh, 1e-9),
            // t_decay = z_l/w*, w* = strength/K_ALLEN: K_ALLEN Rust e·0,4575 против 1,2436 Python — 7e-6
            ("t_decay", got.t_decay, sc.t_decay, 5e-5),
        ] {
            assert!((g - w).abs() <= tol * w.abs(), "{n}: {g} против {w}");
        }
        worst_f = worst_f.max(rel);
    }
    println!("from_strength_max_rel={worst_f:e}");
    assert!(worst_f <= 1e-3, "from_game_strength F0: {worst_f:e}");
    // between_q: узлы и среднее
    let nodes = dp_air::terms::thermal::bubble_q::nodes();
    assert_eq!(nodes.len(), fx.between_q.len());
    for (i, (a, b)) in nodes.iter().zip(&fx.between_q).enumerate() {
        assert!((a - b).abs() <= 1e-9 * b.abs().max(1.0), "between_q[{i}]: {a} против {b}");
    }
    let mean = dp_air::terms::thermal::bubble_q::mean();
    assert!((mean - 1.0).abs() <= 1e-6, "среднее between_q {mean}");
    // K̄ шаблона: таблица Rust (сгенерирована из bubble.kbar) против точного bubble.kbar Python в точках фикстуры
        let mut worst_k: f64 = 0.0;
    for k in &fx.kbar {
        let tab = bubble_kbar::kbar(k.zl, k.wstar);
        let rel = (tab - k.kbar).abs() / k.kbar;
        println!("kbar zl={} w*={}: таблица {tab:.1}, Python {:.1}, отн. {rel:.2e}", k.zl, k.wstar, k.kbar);
        worst_k = worst_k.max(rel);
    }
    println!("kbar_fixture_max_rel={worst_k:e}");
    assert!(worst_k <= 5e-3, "K̄ таблицы против Python: {worst_k:e}");
}

/// Быстрый `axis_wmax` (грубая сетка + мелкий перебор у лучших пиков) даёт тот же максимум, что полный перебор
/// сетки (как у Python): сцены фикстуры и их F0 × 0,5…2.
#[test]
fn axis_wmax_fast() {
    let fx = fixture();
    let (mut worst, mut t_fast, mut t_full) = (0.0f64, 0.0f64, 0.0f64);
    for sc in &fx.sources {
        for k in [0.5, 1.0, 2.0] {
            let src = Source {
                f0: sc.f0 * k,
                ..sc.source()
            };
            let t0 = std::time::Instant::now();
            let a = bubble::axis_wmax(&src, sc.zl);
            t_fast += t0.elapsed().as_secs_f64();
            let t0 = std::time::Instant::now();
            let b = bubble::axis_wmax_full(&src, sc.zl);
            t_full += t0.elapsed().as_secs_f64();
            let rel = (a - b).abs() / b;
            worst = worst.max(rel);
            assert!(
                rel <= 1e-9,
                "w0={} zl={} F0×{k}: быстрый {a}, полный {b}",
                sc.w0,
                sc.zl
            );
        }
    }
    println!(
        "axis_wmax_fast: max отн. разница {worst:e}, время быстрый {t_fast:.2} с, полный {t_full:.2} с"
    );
}

// ---------------------------------------------------------------- точность таблицы

/// Таблица против аналитики: сетка разрезов через ось (шаги вне узлов таблицы) и случайные точки в радиусе
/// влияния на стадиях жизни четырёх сцен (разные w0, zl, tau), плюс точки фикстуры. Печатает
/// `table_max_rel=<x>` = max|v_table − v_analytic| / max|v_analytic| (пик по сцене), `table_rms_ms`,
/// `bytes_per_bubble`, `build_ms_per_bubble`. В ошибку входит **устаревание**: та же таблица спрашивается через
/// возраст, пока правило пересборки ([`BubbleTable::stale`]) её не заменит (последняя секунда перед пересборкой и
/// её половина), против аналитики на момент опроса.
#[test]
fn table_accuracy() {
    let fx = fixture();
    let mut rng = Rng(7);
    // ошибки: свежая таблица и устаревшая — отдельно (максимум, сумма квадратов, число точек)
    let (mut max_fresh, mut max_stale, mut sum2, mut n_all) = (0.0f64, 0.0f64, 0.0f64, 0usize);
    let mut scene_peak: f64 = 0.0;
    let (mut bytes, mut build_ms) = (0usize, 0.0f64);
    let mut per_state = Vec::new();
    let single: Vec<&Case> = fx.cases.iter().filter(|c| c.states.len() == 1).collect();
    for c in &single {
        let sc = &fx.sources[c.scene];
        let src = sc.source();
        let (zi, cut) = (c.zi, bubble::INFLUENCE_FRAC * sc.w0);
        let s = c.states[0];
        let b = Bubble::new(s.b());
        let bt = Bubble::for_table(s.b());
        let (r_max, _) = bubble::influence_radius(&bt, zi, cut);
        assert!(
            r_max <= bubble::R_GUESS_FRAC * zi,
            "{}: радиус таблицы {r_max} больше оценки предотбора {}·z_l",
            c.name,
            bubble::R_GUESS_FRAC
        );
        let t0 = std::time::Instant::now();
        let tb = std::sync::Arc::new(BubbleTable::build(&bt, zi, r_max, c.t));
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
        // между ключевыми кадрами: кадр A — эта таблица (момент c.t), B — таблица кадра c.t + keyframe_dt; опрос на
        // четверти, половине и трёх четвертях шага против аналитики на момент опроса
        let tr = bubble::Traj::new(&src, zi);
        let dt = bubble::keyframe_dt(c.t, sc.tau);
        let tb_b = tr.state(&src, zi, c.t + dt).and_then(|sb| {
            let bb = Bubble::for_table(sb);
            let (rb, _) = bubble::influence_radius(&bb, zi, cut);
            (rb > 0.0).then(|| std::sync::Arc::new(BubbleTable::build(&bb, zi, rb, c.t + dt)))
        });
        let mut st_max: f64 = 0.0;
        for q in [0.25, 0.5, 0.75] {
            let a = q * dt;
            let Some(sn) = tr.state(&src, zi, c.t + a) else {
                continue;
            };
            let bn = Bubble::new(sn);
            let bl = bubble::Blend {
                a: Some(tb.clone()),
                b: tb_b.clone(),
                t_a: c.t,
                t_b: c.t + dt,
                t0: c.t + a,
                f0: bubble::Frame::of(&sn),
                rate: bubble::Frame { zb: 0.0, zc: 0.0 },
            };
            let (mut e, mut at) = (0.0f64, [0.0; 3]);
            for p in &pts {
                let v = bn.velocity(p[0], p[1], p[2], zi);
                let rho = p[0].hypot(p[1]);
                let (w, h) = bl.eval(p[2], rho, 0.0, c.t + a);
                let k = if rho > 1e-9 { h[0] / rho } else { 0.0 };
                let d = norm([k * p[0] - v[0], k * p[1] - v[1], w - v[2]]);
                if d > e {
                    e = d;
                    at = [rho, p[2], w - v[2]];
                }
                p_max = p_max.max(norm(v));
            }
            if std::env::var("TB_VERBOSE").is_ok() {
                println!(
                    "    {} q={q}: err {:.3} at rho={:.0} z={:.0} dw={:.2}; zb {:.0}->{:.0} zc {:.0}->{:.0}",
                    c.name, e, at[0], at[1], at[2], s.zb, sn.zb, s.zc, sn.zc
                );
            }
            st_max = st_max.max(e);
        }
        let last = dt;
        scene_peak = scene_peak.max(p_max);
        max_fresh = max_fresh.max(e_max);
        max_stale = max_stale.max(st_max);
        per_state.push((
            c.name.clone(),
            e_max,
            st_max,
            last,
            p_max,
            r_max,
            tb.bytes(),
        ));
    }
    for (n, e, es, last, p, r, b) in &per_state {
        println!(
            "  {n}: свежая {:.4} устаревшая {:.4} (кадр B через {last} с) пик={p:.3} r_max={r} байт={b}",
            e / p,
            es / p,
        );
    }
    let rel = max_fresh.max(max_stale) / scene_peak;
    let nb = single.len() as f64;
    println!("table_fresh_rel={:.5}", max_fresh / scene_peak);
    println!("table_stale_rel={:.5}", max_stale / scene_peak);
    println!("table_max_rel={rel:.5}");
    println!("table_rms_ms={:.5}", (sum2 / n_all as f64).sqrt());
    println!("bytes_per_bubble={:.0}", bytes as f64 / nb);
    println!("build_ms_per_bubble={:.1}", build_ms / nb);
    assert!(rel <= 0.05, "точность таблицы {rel}");
}

// ---------------------------------------------------------------- сумма ветра

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

/// (1) у одного термика приток к оси у земли (пока источник включён) и растекание под крышкой
/// (оторвавшаяся голова у крышки) — знаки `uh` (среднее по кольцу), далеко за радиусом таблицы `w = uh = 0`;
/// (2) в сцене сумма конечна, а горизонталь слагаемого `thermal` суммы равна `uh` опроса набора (TB4 v4: без `fade` у земли).
#[test]
fn bubble_sum() {
    let place = flat_place();
    let fs = FieldSet::default();
    // источники только в круге 800 м: термиков немного (сборка таблиц на -O0 дорогая)
    let mut on = scene_with(
        |v| {
            v["thermal"]["physics_radius_m"] = json!(300.0);
        },
        Arc::new(Spot),
    );
    let t0 = std::time::Instant::now();
    let t_on = with_tables(&mut on, 1200.0);
    println!(
        "bubble_sum: набор с таблицами {:.1} с, активных {}",
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
    let n_tab = slot.state().unwrap().bubble_count();
    assert!(n_tab > 0, "таблиц пузырей нет");

    // (1) один термик: «земля» — столб 1400 м, пока источник включён; «крышка» — мелкий столб 450 м (голова подходит
    // к крышке за время жизни термика; на столбе 1400 м с радиусом ядра по измерениям она за ним не успевает)
    let mut shallow = lone_thermal();
    shallow.top = 450.0;
    shallow.t_mature = 700.0;
    let (h_ground, h_lid) = (Arc::new(lone_thermal()), Arc::new(shallow));
    let (src_l, zi_l) = bubble::source_of(&h_lid).unwrap();
    let tm_lid = (0..300)
        .map(|k| 100.0 + 10.0 * f64::from(k))
        .find(|&tm| bubble::state(&src_l, zi_l, tm).is_some_and(|b| b.zc + b.r >= 0.9 * zi_l))
        .expect("голова подходит к крышке");
    assert!(
        tm_lid < h_lid.t_end(),
        "голова подошла к крышке {tm_lid} после конца термика {}",
        h_lid.t_end()
    );
    for (tm, name) in [(200.0, "земля"), (tm_lid, "крышка")] {
        let h = if name == "земля" {
            h_ground.clone()
        } else {
            h_lid.clone()
        };
        let (src, zi) = bubble::source_of(&h).unwrap();
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
            "bubble_sum {name}: tp={tm} R={:.0} zb={:.0} радиальная uh={r:.3}",
            b.r, b.zb
        );
        if name == "земля" {
            assert!(b.zb == 0.0 && r < -0.1, "приток к оси у земли: {r}");
        } else {
            assert!(r > 0.05, "растекание от оси под крышкой: {r}");
        }
        let far = [(c[0] + 5000.0) as f32, high as f32, c[1] as f32];
        let (o, uh) = st.sample_bubble(&setup, &NoClouds, far, tm);
        assert!(
            o[0] == 0.0 && uh == [0.0; 2],
            "за радиусом таблицы: {o:?} {uh:?}"
        );
        // на оси горизонтали нет, подъём есть
        let on_axis = [c[0] as f32, (0.6 * b.zc) as f32, c[1] as f32];
        let (o, uh) = st.sample_bubble(&setup, &NoClouds, on_axis, tm);
        assert!(uh == [0.0; 2], "на оси uh = {uh:?}");
        if name == "земля" {
            assert!(o[0] > 0.5, "на оси подъём {}", o[0]);
        }
    }

    // (2) сцена: сумма конечна; горизонталь thermal в разложении = uh набора (без fade)
    let mut rng = Rng(5);
    let (mut n_h, mut n_pts) = (0, 0);
    for tm0 in [t_on, 2000.0] {
        let tm = if tm0 == t_on { tm0 } else { with_tables(&mut on, tm0) };
        let ths = live(&on, tm, 6);
        let st = on.slots.thermal.as_slot().unwrap().state().unwrap();
        for th in &ths {
            for p in points_around(th, tm, &mut rng, 60) {
                let s = terms::sum(&on, &fs, Some(&place), p, SampleMode::Mean, tm, None);
                assert!(s.iter().all(|x| x.is_finite()), "сумма не конечна {p:?}");
                let d = terms::decompose(&on, &fs, Some(&place), p, tm);
                let (_, uh) = st.sample_bubble(&setup, &NoClouds, p, tm);
                assert!(st.bubble_count() > 0);
                for (got, want) in [(d.vel[3][0], uh[0]), (d.vel[3][2], uh[1])] {
                    assert!(
                        (f64::from(got) - want).abs() <= 1e-4 + 1e-5 * want.abs(),
                        "{p:?}: thermal.vel {got} против uh {want}"
                    );
                }
                n_pts += 1;
                if uh[0] != 0.0 || uh[1] != 0.0 {
                    n_h += 1;
                }
            }
        }
    }
    println!("bubble_sum: точек {n_pts}, с горизонталью {n_h}");
    assert!(
        n_pts >= 150 && n_h > n_pts / 4,
        "горизонталь есть не везде: {n_h} из {n_pts}"
    );
}

// ---------------------------------------------------------------- кеш, радиус пузырей, цена (TB4 v2)

/// Setup игры (радиусы и интервалы — по умолчанию: `bubble_radius_m` 2000 м).
fn setup_on() -> Arc<dp_air::terms::thermal::Setup> {
    let mut on = scene_with(|_| {}, Arc::new(Spot));
    on.start_at(1200.0);
    on.slots.thermal.as_slot().unwrap().setup().unwrap().clone()
}

/// Динамический термик игры для проверок: источник `(x, z)`, столб `zl`, сила `w0`, рождён в `t_birth`.
fn thermal_at(id: i64, x: f32, z: f32, zl: f64, w0: f64, t_birth: f64) -> AtmoThermal {
    let mut h = AtmoThermal::blank(id);
    h.src = [x, 0.0, z];
    h.top = zl;
    h.strength = w0;
    h.radius = 100.0;
    h.drift_vel = [4.0, 0.0];
    h.drift_delay = 60.0;
    h.t_birth = t_birth;
    h.t_grow = 180.0;
    h.t_mature = 510.0;
    h.t_decay = 300.0;
    h
}

/// Цена кеша: сцена плотности Аллена n_A = 8,5/z_l² (z_l 1400 м), термики со случайными стадиями жизни и силой
/// 1,5…4 м/с, фокус летит 15 м/с 120 с игры с обновлением раз в `refresh_interval_s` (1 с). Один поток (пул rayon
/// на 1 поток) — время равно ЦП-времени. Печатает `build_ms_per_s=` (источники `from_game_strength` + таблицы на 1 с игры
/// после прогрева первого обновления), `warm_ms`, `tables_alive=`, `rebuilds_per_s=`, `sources_per_s=`,
/// `state_build_ms_per_s=` (всё `State::build_cached`, вместе с профилем и сеткой поиска). Порог 100 мс/с.
#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "цена меряется в release: cargo test --release … bubble_cache_budget"
)]
fn bubble_cache_budget() {
    let ms = run_budget(1);
    println!("build_ms_per_s={ms:.1}");
    assert!(ms <= 100.0, "цена сборки {ms} мс/с");
}

/// То же при четырёх фокусах (сетевая игра): фокусы летят 15 м/с из точек, разнесённых на 2500 м по сторонам света.
/// Печатает `build_ms_per_s_4f=`; порог 4 × 100 мс/с.
#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "цена меряется в release: cargo test --release … cache_budget_4f"
)]
fn cache_budget_4f() {
    let ms = run_budget(4);
    println!("build_ms_per_s_4f={ms:.1}");
    assert!(ms <= 400.0, "цена сборки при 4 фокусах {ms} мс/с");
}

/// Сцена плотности Аллена n_A = 8,5/z_l² (z_l 1400 м): термики со случайными стадиями жизни и силой 1,5…4 м/с в области
/// вокруг одного (1) или четырёх разнесённых фокусов; `t0` — момент сцены.
fn allen_scene(n_foc: usize, t0: f64) -> Vec<Arc<AtmoThermal>> {
    let zl = 1400.0;
    let n_a = 8.5 / (zl * zl);
    let (x_lo, x_hi, z_half) = if n_foc == 1 {
        (-3600.0, 5400.0, 3600.0)
    } else {
        (-6600.0, 8400.0, 6100.0) // область вокруг четырёх разнесённых фокусов
    };
    let mut rng = Rng(2026);
    let n = (n_a * (x_hi - x_lo) * 2.0 * z_half) as usize;
    (0..n)
        .map(|i| {
            let x = x_lo + rng.next() * (x_hi - x_lo);
            let z = (rng.next() * 2.0 - 1.0) * z_half;
            let w0 = 1.5 + 2.5 * rng.next();
            let life = 180.0 + 510.0 + 300.0;
            let mut h = thermal_at(
                i as i64 + 1,
                x as f32,
                z as f32,
                zl,
                w0,
                t0 - rng.next() * life,
            );
            h.t_grow = 120.0 + 120.0 * rng.next();
            h.t_mature = 300.0 + 420.0 * rng.next();
            h.t_decay = 150.0 + 150.0 * rng.next();
            Arc::new(h)
        })
        .collect()
}

/// Прогон цены кеша на `n_foc` фокусах (1 — как в [`bubble_cache_budget`]); возвращает `build_ms_per_s`.
fn run_budget(n_foc: usize) -> f64 {
    use dp_air::terms::thermal::bubble::BubbleCache;
    let setup = setup_on();
    let t0 = 1000.0;
    let all = allen_scene(n_foc, t0);
    let n = all.len();
    let cache = BubbleCache::default();
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .unwrap();
    let steps = 120usize;
    let (mut warm_ms, mut total_ms, mut alive) = (0.0f64, 0.0f64, 0usize);
    let (mut b0, mut s0, mut r0, mut n0) = (0u64, 0u64, 0u64, 0u64);
    pool.install(|| {
        for k in 0..=steps {
            let tm = t0 + k as f64;
            let foc: Vec<[f64; 2]> = (0..n_foc)
                .map(|i| {
                    let a = std::f64::consts::FRAC_PI_2 * i as f64;
                    let o = if n_foc == 1 { 0.0 } else { 2500.0 };
                    [15.0 * k as f64 + o * a.cos(), o * a.sin()]
                })
                .collect();
            let t_start = std::time::Instant::now();
            let st = dp_air::terms::thermal::State::build_cached(
                &setup,
                all.clone(),
                tm,
                &foc,
                1.0,
                k as i64,
                &cache,
                true,
            );
            let ms = t_start.elapsed().as_secs_f64() * 1e3;
            if k == 0 {
                warm_ms = ms;
                use std::sync::atomic::Ordering::Relaxed;
                b0 = cache.stats.build_ns.load(Relaxed);
                s0 = cache.stats.source_ns.load(Relaxed);
                r0 = cache.stats.rebuilds.load(Relaxed);
                n0 = cache.stats.sources.load(Relaxed);
            } else {
                total_ms += ms;
            }
            alive = st.bubble_count();
        }
    });
    use std::sync::atomic::Ordering::Relaxed;
    let sec = steps as f64;
    let build = (cache.stats.build_ns.load(Relaxed) - b0) as f64 / 1e6;
    let src = (cache.stats.source_ns.load(Relaxed) - s0) as f64 / 1e6;
    let reb = (cache.stats.rebuilds.load(Relaxed) - r0) as f64;
    let nsrc = (cache.stats.sources.load(Relaxed) - n0) as f64;
    println!("термиков в сцене {n}, warm_ms={warm_ms:.0}");
    println!("tables_alive={alive}");
    println!("rebuilds_per_s={:.3}", reb / sec);
    println!("sources_per_s={:.3}", nsrc / sec);
    println!(
        "tables_ms_per_s={:.1} sources_ms_per_s={:.1}",
        build / sec,
        src / sec
    );
    println!("state_build_ms_per_s={:.1}", total_ms / sec);
    (build + src) / sec
}

/// Нет таблицы — профиль Гедеона (TB4 v3): динамический термик внутри `bubble_radius_m`, для которого шаблон не
/// определён (столб ниже 100 м), и тот, чьи таблицы ещё не собраны (`tables = false`: первая сборка идёт в фоне),
/// дают `w` профиля и `uh = 0` побитно как `State::sample`; статичный и динамический дальше `bubble_radius_m` —
/// тоже; `mask` и `σ` — всегда из профиля.
#[test]
fn no_table_profile() {
    use dp_air::terms::thermal::bubble::BubbleCache;
    let setup = setup_on();
    let tm = 400.0;
    let same = |st: &dp_air::terms::thermal::State, pts: &[[f32; 3]], what: &str| -> usize {
        let mut n_nonzero = 0;
        for &q in pts {
            let a = st.sample(&setup, &NoClouds, q, tm);
            let (b, uh) = st.sample_bubble(&setup, &NoClouds, q, tm);
            assert!(
                a.iter().zip(&b).all(|(x, y)| x.to_bits() == y.to_bits()),
                "{what}: {a:?} против {b:?}"
            );
            assert_eq!(uh, [0.0; 2], "{what}: uh");
            n_nonzero += usize::from(a[0] != 0.0);
        }
        n_nonzero
    };
    // (1) внутри радиуса, столб 60 м: шаблона нет — профиль
    let mut thin = thermal_at(1, 0.0, 0.0, 60.0, 2.5, 0.0);
    thin.drift_vel = [0.0; 2];
    let thin = Arc::new(thin);
    let st =
        dp_air::terms::thermal::State::build(&setup, vec![thin.clone()], tm, &[[0.0, 0.0]], 1.0, 0);
    assert_eq!(st.bubble_count(), 0, "столб 60 м получил таблицу");
    let n = same(&st, &[[20.0, 30.0, 0.0], [5.0, 20.0, 10.0]], "столб 60 м");
    assert!(n > 0, "профиль низкого столба должен давать подъём");
    // (2) статичный: профиль
    let mut stat = thermal_at(2, 0.0, 0.0, 1400.0, 2.5, 0.0);
    stat.is_static = true;
    let st = dp_air::terms::thermal::State::build(
        &setup,
        vec![Arc::new(stat)],
        tm,
        &[[0.0, 0.0]],
        1.0,
        0,
    );
    assert_eq!(st.bubble_count(), 0);
    let n = same(
        &st,
        &[[10.0, 300.0, 5.0], [60.0, 700.0, -20.0], [0.0, 1000.0, 0.0]],
        "статичный",
    );
    assert!(n > 0);
    // (3) динамический дальше bubble_radius_m + радиус таблицы от фокуса: профиль
    let far = Arc::new(thermal_at(3, 4800.0, 0.0, 1400.0, 2.5, 0.0));
    let st =
        dp_air::terms::thermal::State::build(&setup, vec![far.clone()], tm, &[[0.0, 0.0]], 1.0, 0);
    assert_eq!(st.bubble_count(), 0);
    let c = axis_xz(&far, tm);
    let pts: Vec<[f32; 3]> = [[0.0, 300.0, 5.0], [30.0, 700.0, -20.0], [-60.0, 1000.0, 40.0]]
        .iter()
        .map(|p| {
            [
                (c[0] + f64::from(p[0])) as f32,
                p[1],
                (c[1] + f64::from(p[2])) as f32,
            ]
        })
        .collect();
    assert!(same(&st, &pts, "далеко") > 0);
    // (4) таблицы ещё нет (синхронная сборка без таблиц): профиль, потом, со сборкой, — шаблон
    let near = Arc::new(thermal_at(4, 0.0, 0.0, 1400.0, 2.5, 0.0));
    let c = axis_xz(&near, tm);
    let p = [(c[0] + 30.0) as f32, 300.0, c[1] as f32];
    let cache = BubbleCache::default();
    let st = dp_air::terms::thermal::State::build_cached(
        &setup,
        vec![near.clone()],
        tm,
        &[c],
        1.0,
        0,
        &cache,
        false,
    );
    assert_eq!(st.bubble_count(), 0);
    assert!(same(&st, &[p], "таблицы нет") > 0);
    let st = dp_air::terms::thermal::State::build_cached(
        &setup,
        vec![near.clone()],
        tm,
        &[c],
        1.0,
        0,
        &cache,
        true,
    );
    assert_eq!(st.bubble_count(), 1);
    let a = st.sample(&setup, &NoClouds, p, tm);
    let (b, _) = st.sample_bubble(&setup, &NoClouds, p, tm);
    assert!(
        (a[0] - b[0]).abs() > 1e-6 && (a[1], a[2]) == (b[1], b[2]),
        "с таблицей w шаблона {} должен отличаться от профиля {}; mask, σ — те же",
        b[0],
        a[0]
    );
}

/// Облачный подсос сохранён (TB4 v3): у термика с таблицей от `top` до `top + cloud_depth` (поток продолжается в
/// облако) `w` равен профилю Гедеона с теми же зацепками (> 0), `uh = 0`; ниже `top` — таблица (не профиль).
#[test]
fn cloud_suck() {
    struct Cloudy;
    impl dp_air::terms::thermal::CloudHooks for Cloudy {
        fn suck(&self, _th: &AtmoThermal, _t: f64) -> [f64; 2] {
            [0.5, 300.0]
        }
    }
    let setup = setup_on();
    let tm = 400.0;
    let mut h = thermal_at(1, 0.0, 0.0, 1400.0, 2.5, 0.0);
    h.cloud_depth = 300.0;
    let h = Arc::new(h);
    let c = axis_xz(&h, tm);
    let st = dp_air::terms::thermal::State::build(&setup, vec![h.clone()], tm, &[c], 1.0, 0);
    assert_eq!(st.bubble_count(), 1, "таблицы нет");
    let mut n_pos = 0;
    for (dy, dr) in [(60.0, 0.0), (150.0, 30.0), (250.0, -40.0)] {
        let p = [(c[0] + dr) as f32, (1400.0 + dy) as f32, c[1] as f32];
        let prof = st.sample(&setup, &Cloudy, p, tm);
        let (o, uh) = st.sample_bubble(&setup, &Cloudy, p, tm);
        println!("cloud_suck: +{dy} м над top, профиль w={:.3}, шаблон w={:.3}", prof[0], o[0]);
        assert!(o[0] > 0.0, "в облаке нет подсоса: {o:?}");
        assert_eq!(o[0].to_bits(), prof[0].to_bits(), "выше top w — профиль");
        assert_eq!(uh, [0.0; 2]);
        n_pos += 1;
    }
    assert_eq!(n_pos, 3);
    // ниже top — таблица: w отличается от профиля
    let p = [(c[0] + 20.0) as f32, 1000.0, c[1] as f32];
    let prof = st.sample(&setup, &Cloudy, p, tm);
    let (o, _) = st.sample_bubble(&setup, &Cloudy, p, tm);
    assert!((prof[0] - o[0]).abs() > 1e-6, "ниже top должна быть таблица");
}

// ---------------------------------------------------------------- «между»: K̄ шаблона

/// Таблица K̄ (`bubble_kbar`, сгенерирована из `bubble.kbar` Python) против точного счёта порта в узлах сетки и
/// между ними (билинейная интерполяция): тот же интеграл `mean_up_flux`, что у Python, но на порте Rust.
#[test]
fn kbar_table_vs_exact() {
    let mut worst_node: f64 = 0.0;
    for (zl, ws) in [(1400.0, 2.5), (700.0, 1.5)] {
        let w0 = K_ALLEN * ws;
        let exact = bubble::mean_up_flux(w0, zl, bubble_kbar::TAU_S) / w0;
        let tab = bubble_kbar::kbar(zl, ws);
        let rel = (tab - exact).abs() / exact;
        println!("kbar zl={zl} w*={ws}: таблица {tab:.1}, порт {exact:.1}, отн. {rel:.2e}");
        worst_node = worst_node.max(rel);
    }
    // между узлами: билинейная интерполяция
    let (zl, ws) = (1450.0, 2.6);
    let w0 = K_ALLEN * ws;
    let exact = bubble::mean_up_flux(w0, zl, bubble_kbar::TAU_S) / w0;
    let tab = bubble_kbar::kbar(zl, ws);
    let mid = (tab - exact).abs() / exact;
    println!(
        "kbar между узлами zl={zl} w*={ws}: таблица {tab:.1}, порт {exact:.1}, отн. {mid:.2e}"
    );
    println!("kbar_node_max_rel={worst_node:e} kbar_between_rel={mid:e}");
    assert!(worst_node <= 2e-3, "узлы таблицы K̄: {worst_node:e}");
    assert!(mid <= 0.08, "интерполяция K̄ между узлами: {mid:e}");
}

/// Синтетическое поле: ровная земля 1000 м, сетка 40 × 40 × 60, нагрев 250 Вт/м², z_i 1500 м.
fn flat_field() -> Field {
    const N: usize = 40;
    const NZ: usize = 60;
    let grid = FieldGrid {
        dx: 100.0,
        dz: 50.0,
        x0: -2000.0,
        y0: -2000.0,
        z_bot: 950.0,
        nx: N,
        ny: N,
        nz: NZ,
    };
    let n = N * N * NZ;
    let meta = FieldMeta {
        z0: Z0::Uniform(0.1),
        gam: (0..NZ)
            .map(|k| {
                if 950.0 + (k as f64 + 0.5) * 50.0 < 1500.0 {
                    0.0
                } else {
                    0.004
                }
            })
            .collect(),
        heat: vec![250.0; N * N],
        z_i: 1500.0,
        z_i_col: Vec::new(),
    };
    Field::from_arrays(
        &grid,
        vec![2.0; n],
        vec![0.0; n],
        vec![0.0; n],
        vec![0.4; n],
        vec![0.0; n],
        vec![1000.0; N * N],
        meta,
        Limits::default(),
    )
    .unwrap()
}

/// K̄ источника — из таблицы шаблона (`carried = w0·kbar(z_l, w*)`, TB4 v3); сравнение с K̄ профиля Гедеона
/// (`CORE_FLUX·π·r²·shape.mean·life_mean`, прежний расчёт) в печати.
#[test]
fn between_kbar() {
    let f = flat_field();
    let thermal: Value = {
        let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
        serde_json::from_str::<Value>(&t).unwrap()["thermal"].clone()
    };
    let cfg = AirThermalsCfg::from_thermal(&thermal, 0.6, 1.0e9);
    let on = AirThermals::build(&f, &BuildIn::new(&cfg, 5.0)).expect("build");
    assert!(on.count() > 3, "источников {}", on.count());
    let mut kb = Vec::new();
    for s in 0..on.count() {
        let a = on.source(s);
        let zl = (f64::from(a.top) - 1000.0).max(ZI_MIN);
        let want = f64::from(a.w0) * bubble_kbar::kbar(zl, f64::from(a.wstar));
        assert!(
            (f64::from(a.carried) - want).abs() <= 1e-4 * want,
            "источник {s}: carried {} против w0·K̄ {want}",
            a.carried
        );
        kb.push(bubble_kbar::kbar(zl, f64::from(a.wstar)));
    }
    kb.sort_by(f64::total_cmp);
    println!(
        "between_kbar: источников {}, K̄ шаблона, м²: мин {:.0}, медиана {:.0}, макс {:.0}",
        kb.len(),
        kb[0],
        kb[kb.len() / 2],
        kb[kb.len() - 1]
    );
}

/// q(ξ) «между» в `Shape` — таблица `between_q` шаблона (TB4 v3): `expected_net(p)` на одном источнике по высоте
/// пропорционален `bubble_q::between_q(ξ)` (отн. 1e-6), а среднее q по ξ равно 1.
#[test]
fn between_q_used() {
    use dp_air::terms::thermal::bubble_q;
    let f = flat_field();
    let thermal: Value = {
        let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
        serde_json::from_str::<Value>(&t).unwrap()["thermal"].clone()
    };
    let cfg = AirThermalsCfg::from_thermal(&thermal, 0.6, 1.0e9);
    let air = AirThermals::build(&f, &BuildIn::new(&cfg, 5.0)).expect("build");
    assert!((bubble_q::mean() - 1.0).abs() <= 1e-6);
    // Shape (q в «между») = таблица шаблона, отн. 1e-6
    let shape = dp_air::terms::thermal_air::Shape::new(&cfg);
    assert!((shape.q_mean - 1.0).abs() <= 1e-6);
    for k in 1..100 {
        let xi = f64::from(k) / 100.0;
        let (a, b) = (shape.q_at_profile(xi), bubble_q::between_q(xi));
        assert!((a - b).abs() <= 1e-6 * b.abs().max(1e-3), "ξ={xi}: Shape {a}, between_q {b}");
    }
    // найти столбец с ожиданием: точка над источником, ξ в (0,1)
    let s0 = air.source(0);
    let (x, z) = (s0.pos[0], s0.pos[2]);
    let hc = 1000.0; // ровная земля flat_field
    let depth = f64::from(s0.depth);
    let mut ratios = Vec::new();
    for k in 1..20 {
        let xi = f64::from(k) / 20.0;
        let p = [x, (hc + xi * depth) as f32, z];
        let e = air.expected_net(p);
        if e > 0.0 {
            ratios.push((xi, e / bubble_q::between_q(xi)));
        }
    }
    assert!(ratios.len() >= 10, "точек с ожиданием {}", ratios.len());
    let r0 = ratios[0].1;
    for (xi, r) in &ratios {
        // ξ из f32-координат и f32-глубины столба: 1e-4 отн. (сам q — точно, см. выше)
        assert!(
            (r - r0).abs() <= 1e-4 * r0.abs(),
            "ξ={xi}: expected_net/q = {r} против {r0}"
        );
    }
    println!("between_q_used: {} точек, expected_net/q = {r0:.6} (постоянно)", ratios.len());
}

/// Огибающая игры на вкладе пузыря: от начала распада до конца термика шаг 1 с, скачок |Δv| за 1 с не больше 5 % пика
/// (w и горизонталь uh), в момент конца жизни вклад равен 0; до распада вклад — таблица без множителя.
#[test]
fn life_fade() {
    use dp_air::terms::thermal::bubble::BubbleCache;
    let setup = setup_on();
    let h = Arc::new(lone_thermal());
    let cache = BubbleCache::default();
    let (t_a, t_e) = (h.t_decay_start(), h.t_end());
    let probes = [(0.0, 250.0, 0.0), (60.0, 400.0, 30.0)];
    let mut series: Vec<Vec<[f64; 3]>> = vec![Vec::new(); probes.len()];
    let mut tm = t_a - 10.0;
    while tm <= t_e + 1e-9 {
        let c = axis_xz(&h, tm);
        let st = dp_air::terms::thermal::State::build_cached(
            &setup,
            vec![h.clone()],
            tm,
            &[c],
            1.0,
            0,
            &cache,
            true,
        );
        for (k, p) in probes.iter().enumerate() {
            let q = [(c[0] + p.0) as f32, p.1 as f32, (c[1] + p.2) as f32];
            let (o, uh) = st.sample_bubble(&setup, &NoClouds, q, tm);
            series[k].push([o[0], uh[0], uh[1]]);
        }
        tm += 1.0;
    }
    for (k, s) in series.iter().enumerate() {
        let peak = s
            .iter()
            .map(|v| v.iter().fold(0.0f64, |m, x| m.max(x.abs())))
            .fold(0.0, f64::max);
        let jump = s
            .windows(2)
            .map(|w| {
                (0..3)
                    .map(|i| (w[1][i] - w[0][i]).abs())
                    .fold(0.0, f64::max)
            })
            .fold(0.0, f64::max);
        let last = s[s.len() - 1];
        println!(
            "life_fade точка {k}: пик {peak:.3}, макс. скачок за 1 с {jump:.4} ({:.3} пика), v(t_end) = {last:?}",
            jump / peak
        );
        assert!(peak > 0.3, "точка {k}: вклада нет (пик {peak})");
        assert!(
            jump <= 0.05 * peak,
            "точка {k}: скачок {jump} > 5 % пика {peak}"
        );
        assert!(
            last.iter().all(|x| *x == 0.0),
            "точка {k}: v(t_end) = {last:?}"
        );
    }
}

/// Цена опроса: ns на точку профиля (`State::sample`, прежний путь) и шаблона (`State::sample_bubble`, с таблицами) на
/// одних и тех же 20000 случайных точках в круге 1500 м вокруг фокуса, высота 10…1400 м, сцена плотности Аллена, один
/// поток. Печатает `sample_ns_old=` и `sample_ns_new=`.
#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "цена меряется в release: cargo test --release … sample_cost"
)]
fn sample_cost() {
    use dp_air::terms::thermal::bubble::BubbleCache;
    let setup = setup_on();
    let t0 = 1000.0;
    let all = allen_scene(1, t0);
    let cache = BubbleCache::default();
    let f = [0.0, 0.0];
    let st = dp_air::terms::thermal::State::build_cached(
        &setup, all, t0, &[f], 1.0, 0, &cache, true,
    );
    assert!(st.bubble_count() > 10);
    let mut rng = Rng(77);
    let pts: Vec<[f32; 3]> = (0..20000)
        .map(|_| {
            let r = 1500.0 * rng.next().sqrt();
            let a = std::f64::consts::TAU * rng.next();
            [
                (f[0] + r * a.cos()) as f32,
                (10.0 + 1390.0 * rng.next()) as f32,
                (r * a.sin()) as f32,
            ]
        })
        .collect();
    let time = |old: bool| -> (f64, f64) {
        let (mut best, mut acc) = (f64::INFINITY, 0.0);
        for _ in 0..5 {
            let ts = std::time::Instant::now();
            for p in &pts {
                acc += if old {
                    st.sample(&setup, &NoClouds, *p, t0)[0]
                } else {
                    st.sample_bubble(&setup, &NoClouds, *p, t0).0[0]
                };
            }
            best = best.min(ts.elapsed().as_secs_f64() * 1e9 / pts.len() as f64);
        }
        (best, acc)
    };
    let (old, a) = time(true);
    let (new, b) = time(false);
    println!("sample_ns_old={old:.0}");
    println!("sample_ns_new={new:.0}");
    println!("sample_check {a:.3} {b:.3}");
}

/// TB4 v4: центр пузыря — ось термика игры на высоте головы (`axis_at(zc, drift)`, с наклоном `lean`, как у `cores`).
/// Сцена бюджета (плотность Аллена) с наклоном: у термиков с таблицей на высоте головы находим максимум |w| в круге 2R
/// вокруг оси `cores`; медиана расстояния до оси / R не больше 0,25. Печатает `core_axis_dx_over_r=`.
#[test]
fn bubble_on_core_axis() {
    use dp_air::terms::thermal::bubble::BubbleCache;
    let setup = setup_on();
    let t0 = 1000.0;
    let mut rng = Rng(515);
    let all: Vec<Arc<AtmoThermal>> = allen_scene(1, t0)
        .into_iter()
        .map(|h| {
            let mut h = (*h).clone();
            // наклон до ~35°: lean = tan·(направление), как у термиков игры в ветре
            let a = std::f64::consts::TAU * rng.next();
            let l = 0.7 * rng.next();
            h.lean = [(l * a.cos()) as f32, (l * a.sin()) as f32];
            Arc::new(h)
        })
        .collect();
    let cache = BubbleCache::default();
    let f = [0.0, 0.0];
    let mut ratios = Vec::new();
    for th in &all {
        let Some((src, zi)) = bubble::source_of(th) else { continue };
        let Some(b) = bubble::state(&src, zi, t0) else { continue };
        let ph = th.phase(t0);
        if b.r < 20.0 || ph.env < 0.5 || b.zc < 100.0 {
            continue;
        }
        let ax = th.axis_at(f64::from(th.src[1]) + b.zc, ph.drift);
        if (ax[0] - f[0]).hypot(ax[1] - f[1]) > 1500.0 {
            continue;
        }
        let y = (f64::from(th.src[1]) + b.zc) as f32;
        // набор из одного термика (только его вклад)
        let st1 = dp_air::terms::thermal::State::build_cached(
            &setup, vec![th.clone()], t0, &[f], 1.0, 0, &cache, true,
        );
        let (mut best, mut at) = (0.0f64, [0.0f64; 2]);
        let n = 31;
        for i in 0..n {
            for j in 0..n {
                let (ox, oz) = (
                    (f64::from(i) / f64::from(n - 1) * 2.0 - 1.0) * 2.0 * b.r,
                    (f64::from(j) / f64::from(n - 1) * 2.0 - 1.0) * 2.0 * b.r,
                );
                if ox.hypot(oz) > 2.0 * b.r {
                    continue;
                }
                let p = [(ax[0] + ox) as f32, y, (ax[1] + oz) as f32];
                let w = st1.sample_bubble(&setup, &NoClouds, p, t0).0[0];
                if w.abs() > best {
                    best = w.abs();
                    at = [ox, oz];
                }
            }
        }
        if best > 0.2 {
            ratios.push(at[0].hypot(at[1]) / b.r);
        }
    }
    assert!(ratios.len() >= 5, "термиков с таблицей и подъёмом: {}", ratios.len());
    ratios.sort_by(f64::total_cmp);
    let med = ratios[ratios.len() / 2];
    println!("core_axis_dx_over_r={med:.3} (термиков {})", ratios.len());
    assert!(med <= 0.25, "максимум w от оси cores: медиана {med} R");
}
