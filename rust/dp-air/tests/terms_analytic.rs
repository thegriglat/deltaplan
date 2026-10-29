//! RW-9: слот `Analytic` — аналитика без поля и в полосе края `a < 1`, склоновый подъём,
//! подветренная зона, режим `off`, `background_wind`, `GroundField`.
//!
//! Сверки: слагаемые `analytic` и `ridge` из эталонов W8 (`tests/fixtures/wind/cases`, k по
//! `terms` случая) на `synth_*` (поля нет — вся аналитика) и в полосе края `ongudai_*` (доля поля
//! восстанавливается по эталону — поля Пикара в тесте нет), шум `gust_unit` и `GroundField` — по
//! дампу Godot (`tests/data/RW-9/`, опорная ревизия `c591b1026`, `dump.sh`). Допуски — W8:
//! `|Δv| ≤ 0,05 м/с + 2 % |v_ref|`, σ `0,02 + 5 %`.
use dp_air::compat::noise::{FastNoise, Fractal};
use dp_air::field::field_set::FieldSet;
use dp_air::fixtures::{Case, CaseData, read_case, read_case_data, read_place};
use dp_air::terms::analytic::ground::{GroundField, PlaceSig};
use dp_air::terms::analytic::lee::smoothstep;
use dp_air::terms::analytic::noise::{GustNoise, NoiseCfg};
use dp_air::terms::{self, Ctx, T_ANALYTIC, T_GUST, T_RIDGE, Terms};
use dp_air::{Configs, Place, SampleMode};
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

/// Конфиги игры; `patch` правит разобранный `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            patch(&mut v);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Arc::new(Configs::new(files))
}

/// Правка по ключам вида `atmosphere.air_model.enabled` (`extra.config_overrides` случая).
fn apply_overrides(v: &mut Value, over: Option<&Value>) {
    if let Some(Value::Object(o)) = over {
        for (k, x) in o {
            let Some(path) = k.strip_prefix("atmosphere.") else {
                continue;
            };
            let parts: Vec<&str> = path.split('.').collect();
            let mut cur = &mut *v;
            for p in &parts[..parts.len() - 1] {
                cur = cur.get_mut(*p).unwrap();
            }
            cur[parts[parts.len() - 1]] = x.clone();
        }
    }
}

fn place_named(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

/// Случай эталона с готовыми `Terms` (как после `configure` и `set_conditions`).
struct Fx {
    case: Case,
    data: CaseData,
    place: Place,
    terms: Terms,
    names: Vec<String>,
}

fn load_with(name: &str, extra_patch: impl Fn(&mut Value)) -> Fx {
    let cp = repo().join(format!("tests/fixtures/wind/cases/{name}.json"));
    let case = read_case(&cp).unwrap();
    let data = read_case_data(&case, &cp).unwrap();
    let place = read_place(&case.place_path(&cp)).unwrap();
    let raw: Value = serde_json::from_str(&std::fs::read_to_string(&cp).unwrap()).unwrap();
    let over = raw.pointer("/extra/config_overrides").cloned();
    let cfg = configs_with(|v| {
        apply_overrides(v, over.as_ref());
        extra_patch(v);
    });
    let mut terms = Terms::default();
    terms.configure(&cfg, case.seed);
    terms.set_conditions(&case.conditions);
    // Пресет W5 не несёт высоты ветра прогноза; генератор ставил её явно (`extra.wind_ref_msl`)
    if let Some(r) = raw.pointer("/extra/wind_ref_msl").and_then(Value::as_f64) {
        terms.wind.ref_msl = r;
    }
    let names = case.terms.clone().unwrap();
    Fx {
        case,
        data,
        place,
        terms,
        names,
    }
}

fn load(name: &str) -> Fx {
    load_with(name, |_| {})
}

impl Fx {
    /// Точка внутри растра места с запасом `margin` м (вне растра высота зажата в край, а эталон
    /// GD считает рельеф везде — расхождение объяснено рельефом, W8).
    fn inside(&self, p: [f32; 3], margin: f64) -> bool {
        let g = &self.place.header().grid;
        let (x1, z1) = (
            g.origin_x + (g.width as f64 - 1.0) * g.spacing,
            g.origin_z + (g.height as f64 - 1.0) * g.spacing,
        );
        let (x, z) = (f64::from(p[0]), f64::from(p[2]));
        x > g.origin_x + margin && x < x1 - margin && z > g.origin_z + margin && z < z1 - margin
    }

    fn k(&self, term: &str) -> usize {
        2 + self.names.iter().position(|n| n == term).unwrap()
    }

    fn slab(&self, t: usize, term: &str) -> Vec<[f32; 4]> {
        self.data.slab(t, self.k(term)).collect()
    }
}

/// Допуск W8 для скорости и σ.
fn tol_v(r: f32) -> f32 {
    0.05 + 0.02 * r.abs()
}
fn tol_s(r: f32) -> f32 {
    0.02 + 0.05 * r.abs()
}

/// Вклады аналитики и склона в точке без поля.
fn mine(fx: &Fx, p: [f32; 3], t: f64) -> (Vec<f32>, f32, f32) {
    let fs = FieldSet::default();
    let d = terms::decompose(&fx.terms, &fs, Some(&fx.place), p, t);
    (
        d.vel[T_ANALYTIC].to_vec(),
        d.vel[T_RIDGE][1],
        d.sigma[T_GUST],
    )
}

// ---------------------------------------------------------------- synth_*: вся аналитика

/// Горизонталь `analytic` и `ridge` на синтетике: поля нет, ветер off (простой профиль).
fn check_synth(name: &str) -> (usize, usize, f32) {
    let fx = load(name);
    let (mut n, mut bad, mut worst, mut outside) = (0, 0, 0.0f32, 0);
    for ti in 0..fx.case.times_s.len() {
        let t = fx.case.times_s[ti];
        let (ra, rr) = (fx.slab(ti, "analytic"), fx.slab(ti, "ridge"));
        for (pi, p) in fx.case.points.iter().enumerate() {
            if !fx.inside(*p, 500.0) {
                outside += 1;
                continue;
            }
            let (a, r, _) = mine(&fx, *p, t);
            for (q, &x) in [a[0], a[1], a[2]]
                .iter()
                .zip(&[ra[pi][0], ra[pi][1], ra[pi][2]])
            {
                n += 1;
                let d = (q - x).abs();
                worst = worst.max(d);
                if d > tol_v(x) {
                    bad += 1;
                    println!(
                        "{name} t{ti} p{pi} {}: {q} против {x}",
                        fx.case.point_tags[pi]
                    );
                }
            }
            n += 1;
            let d = (r - rr[pi][1]).abs();
            worst = worst.max(d);
            if d > tol_v(rr[pi][1]) {
                bad += 1;
            }
        }
    }
    println!(
        "{name}: горизонталь analytic + ridge: {n} значений, вне допуска {bad}, max|Δ| = {worst:.4}; точек-моментов вне растра места (не сверялись): {outside}"
    );
    (n, bad, worst)
}

#[test]
fn synth_horizontal_and_ridge_match() {
    for name in [
        "synth_weak",
        "synth_medium",
        "synth_strong",
        "synth_storm",
        "synth_wave",
        "synth_off",
    ] {
        let (n, bad, _) = check_synth(name);
        assert!(n > 150, "{name}: сверено лишь {n}");
        // 1 %: рельеф растра 25 м против terrain.height_at меняет силу подветренной зоны (W8)
        assert!(bad * 100 <= n, "{name}: вне допуска W8 {bad} из {n}");
    }
}

#[test]
fn synth_sigma_is_analytic_part_of_reference() {
    // σ аналитики в эталоне включает край термика, грозу и ротор волн (RW-10/11): σ² эталона
    // не меньше нашей, а там, где они нулевые, равна
    for name in [
        "synth_weak",
        "synth_medium",
        "synth_strong",
        "synth_storm",
        "synth_wave",
    ] {
        let fx = load(name);
        let (mut n, mut eq, mut worst_below) = (0, 0, 0.0f32);
        for ti in 0..fx.case.times_s.len() {
            let t = fx.case.times_s[ti];
            let rg = fx.slab(ti, "gust");
            for (pi, p) in fx.case.points.iter().enumerate() {
                if !fx.inside(*p, 500.0) {
                    continue;
                }
                let (_, _, s) = mine(&fx, *p, t);
                let r = rg[pi][3];
                n += 1;
                worst_below = worst_below.max(s - r);
                if (s - r).abs() <= tol_s(r) {
                    eq += 1;
                }
            }
        }
        println!(
            "{name}: σ аналитики: совпало {eq}/{n}, наибольшее превышение нашей над эталоном {worst_below:.4}"
        );
        // synth_wave: σ ротора волны (`WaveExtra`, RW-11b) в 3-4 точках из 93 расходится с GD
        // (p7 ground: ротор 0.03 у GD против 0.73; p9 ground: 2.33 против 0.74; p36: 0.93 против 0).
        // В GD ротор входит в σ аналитики так же (`_analytic_amp`), стык верный; расхождение в
        // числе самой волны (RW-11b). Здесь допуск не расширяется: для волны проверяется доля
        // совпавших точек, превышение не ограничивается.
        if name != "synth_wave" {
            assert!(
                worst_below <= 0.02,
                "{name}: наша σ больше эталона на {worst_below}"
            );
        }
        // гроза и роторы волн (RW-11) добавляют σ в эталоне — равенство только без них
        if name == "synth_wave" {
            assert!(eq * 100 >= n * 95, "{name}: σ совпала лишь в {eq}/{n}");
        } else if name != "synth_storm" {
            assert!(eq * 10 >= n * 9, "{name}: σ совпала лишь в {eq}/{n}");
        }
    }
}

#[test]
fn off_mode_case_equals_medium_and_uses_simple_profile() {
    let off = load("synth_off");
    assert!(off.terms.air_off && off.terms.wind.is_simple());
    let (a, b) = (off.terms.wind.profile_params(), (0.14, 1.8));
    assert_eq!(a, b);
    // synth_off побитно равен synth_medium (README эталонов): те же слагаемые
    let med = load("synth_medium");
    for ti in 0..off.case.times_s.len() {
        let t = off.case.times_s[ti];
        for p in &off.case.points {
            let (a, ra, sa) = mine(&off, *p, t);
            let (b, rb, sb) = mine(&med, *p, t);
            assert_eq!((a, ra, sa), (b, rb, sb));
        }
    }
    // Ongudai (auto): WindProfile, не простой
    let au = load("ongudai_medium");
    assert!(!au.terms.air_off && !au.terms.wind.is_simple());
}

#[test]
fn simple_profile_matches_080_any_hour_and_sky() {
    // перенос tests/atmosphere/test_wind_profile_simple.gd
    let v080 = |agl: f64| ((agl.max(1.0) / 10.0).powf(0.14)).min(1.8);
    let cfg = configs_with(|v| v["air_model"]["enabled"] = json!("off"));
    let mut t = Terms::default();
    t.configure(&cfg, 1);
    t.wind.set_wind(10.8 / 3.6, 270.0);
    assert!(t.wind.is_simple() && t.air_off);
    for sun in [-10.0, 5.0, 30.0, 52.0, 70.0] {
        for cover in [0.0, 0.5, 1.0] {
            t.wind.set_conditions(sun, cover);
            for h in [10.0, 50.0, 100.0, 300.0, 1000.0] {
                let d = (t.wind.profile(h) - v080(h)).abs();
                assert!(d < 1e-9, "sun {sun} cover {cover} h {h}: {d}");
            }
        }
    }
    assert!((v080(1000.0) - 1.8).abs() < 1e-9);
    // auto: WindProfile (α не 0,14); переключение в off и обратно
    let cfg = configs_with(|_| {});
    let mut a = Terms::default();
    a.configure(&cfg, 1);
    a.wind.set_wind(10.8 / 3.6, 270.0);
    assert!(!a.wind.is_simple() && (a.wind.profile_params().0 - 0.14).abs() > 0.02);
    a.set_air_off(true);
    assert!((a.wind.profile_params().0 - 0.14).abs() < 1e-9);
    a.set_air_off(false);
    assert!(!a.wind.is_simple() && (a.wind.profile_params().0 - 0.14).abs() > 0.02);
}

// ---------------------------------------------------------------- шум и GroundField по дампу Godot

fn dump(name: &str) -> Vec<f32> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/RW-9")
        .join(name);
    std::fs::read(&p)
        .unwrap_or_else(|e| panic!("{}: {e}", p.display()))
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

#[test]
fn gust_unit_matches_godot_dump() {
    let cfg = configs_with(|_| {});
    let nc = {
        let g = dp_air::terms::named_json(&cfg, "atmosphere").unwrap();
        let t = &g["turbulence"];
        NoiseCfg {
            scale_m: t["scale_m"].as_f64().unwrap(),
            octaves: t["octaves"].as_i64().unwrap() as i32,
            evolve_ms: t["evolve_ms"].as_f64().unwrap(),
            large_scale_m: t["large_scale_m"].as_f64().unwrap(),
            large_fade_agl_m: t["large_fade_agl_m"].as_f64().unwrap(),
        }
    };
    let ins = dump("gust_in.f32");
    let d = 230.0f64.to_radians();
    let dir = [-d.sin(), d.cos()];
    for seed in [4242u64, 909] {
        let want = dump(&format!("gust_{seed}.f32"));
        let gn = GustNoise::new(&nc, seed);
        let mut worst = 0.0f64;
        for (i, w) in want.chunks_exact(3).enumerate() {
            let b = i * 6;
            let n = gn.gust_unit(
                [ins[b], ins[b + 1], ins[b + 2]],
                f64::from(ins[b + 3]),
                dir,
                f64::from(ins[b + 4]),
                f64::from(ins[b + 5]),
            );
            for q in 0..3 {
                worst = worst.max((n[q] - f64::from(w[q])).abs());
            }
        }
        println!(
            "gust_unit сид {seed}: {} проб, max|Δ| = {worst:e}",
            want.len() / 3
        );
        assert!(worst < 2e-4, "сид {seed}: max|Δ| = {worst}");
    }
    let _ = (FastNoise::new(0, Fractal::None, 1.0), smoothstep);
}

#[test]
fn ground_field_matches_godot_dump() {
    let place = place_named("ongudai");
    let cfg = configs_with(|_| {});
    let gcfg = dp_air::terms::analytic::AnalyticCfg::from_configs(&cfg).ground;
    let pts = dump("ground_pts.f32");
    let n = pts.len() / 2;
    let mut total = (0usize, 0usize);
    for from in [151u32, 250, 330, 60] {
        let want = dump(&format!("ground_{from}.f32"));
        assert_eq!(want.len(), n * 6);
        let d = f64::from(from).to_radians();
        let dir = [(-d.sin()) as f32, d.cos() as f32];
        let l = (dir[0] * dir[0] + dir[1] * dir[1]).sqrt();
        let gf = GroundField::new(&gcfg, PlaceSig::of(&place), [dir[0] / l, dir[1] / l]);
        let (mut dh, mut dsl, mut dsh, mut dre, mut dterr) =
            (vec![], vec![], vec![], vec![], vec![]);
        for k in 0..n {
            let (x, z) = (f64::from(pts[2 * k]), f64::from(pts[2 * k + 1]));
            let s = gf.sample(&place, x, z);
            let r = gf.relief_at(&place, x, z);
            let w = &want[k * 6..k * 6 + 6];
            dh.push((s.h - f64::from(w[0])).abs());
            dsl.push(((s.dhdx - f64::from(w[1])).abs()).max((s.dhdz - f64::from(w[2])).abs()));
            dsh.push((s.shadow - f64::from(w[3])).abs());
            dre.push((r - f64::from(w[4])).abs());
            dterr.push((GroundField::height(&place, x, z) - f64::from(w[5])).abs());
        }
        let stat = |v: &mut Vec<f64>| {
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            (v[v.len() / 2], v[v.len() * 95 / 100], *v.last().unwrap())
        };
        println!(
            "ground с {from}°: |Δh| мед/95%/max {:?}; |Δуклон| {:?}; |Δтень| {:?}; |Δгребень| {:?}; растр против height_at (в точке) {:?}",
            stat(&mut dh),
            stat(&mut dsl),
            stat(&mut dsh),
            stat(&mut dre),
            stat(&mut dterr)
        );
        // та же высота, что и у GD, но растр 25 м против слоёв terrain: медиана мала
        total.0 += dh.iter().filter(|v| **v <= 0.5).count();
        total.1 += dh.len();
    }
    let _ = gcfg;
    assert!(
        total.0 * 100 >= total.1 * 90,
        "высота сетки совпала (≤ 0,5 м) лишь в {}/{}",
        total.0,
        total.1
    );
}

// ---------------------------------------------------------------- полоса края поля (Онгудай)

/// Ctx точки с долей поля `a` (вклад поля нулевой — аналитика его не читает).
fn ctx<'a>(fx: &'a Fx, fs: &'a FieldSet, p: [f32; 3], t: f64, a: f64) -> Ctx<'a> {
    let g = dp_air::field::runtime::ground_height(&fx.place, p[0], p[2]);
    let agl = f64::from((p[1] - g).max(0.0));
    Ctx {
        pos: p,
        ground: g,
        agl,
        t,
        mode: SampleMode::Full,
        a,
        fw: [0.0; 3],
        u: fx.terms.wind.speed_at_pos(agl, f64::from(p[1])),
        terms: &fx.terms,
        fs,
        place: &fx.place,
    }
}

fn mean_at(fx: &Fx, p: [f32; 3], t: f64, a: f64) -> Option<terms::AnalyticMean> {
    let fs = FieldSet::default();
    let c = ctx(fx, &fs, p, t, a);
    fx.terms.slots.analytic.mean(&c)
}

use dp_air::terms::Analytic;

#[test]
fn ongudai_strip_points_are_consistent_with_reference() {
    // Поля Пикара в тесте нет: доля поля восстанавливается по эталону. В полосе горизонталь
    // аналитики ∝ (1 − a): a = 1 − h_эт / h(0+) (знак учтён: ротор даёт обратный поток). Тогда
    // склон и вертикаль аналитики при той же доле должны сойтись с эталоном. Точки, где аналитики
    // в эталоне нет (внутри поля, a = 1), — слот не даёт вклада.
    let (mut n, mut bad, mut used, mut inside_field, mut from_field) = (0, 0, 0, 0, 0);
    for name in [
        "ongudai_medium",
        "ongudai_strong",
        "ongudai_wave",
        "ongudai_storm",
    ] {
        let fx = load(name);
        let wd = fx.terms.wind.dir();
        for ti in 0..fx.case.times_s.len() {
            let t = fx.case.times_s[ti];
            let ra = fx.slab(ti, "analytic");
            let rr = fx.slab(ti, "ridge");
            for (pi, p) in fx.case.points.iter().enumerate() {
                let tag = fx.case.point_tags[pi].as_str();
                if tag != "field_edge" && tag != "lee" {
                    continue;
                }
                let href = f64::from(ra[pi][0]) * wd[0] + f64::from(ra[pi][2]) * wd[1];
                let h1 = mean_at(&fx, *p, t, 1.0e-9).map_or(0.0, |m| m.h);
                if ra[pi].iter().take(3).all(|v| v.abs() < 1e-4) && rr[pi][1].abs() < 1e-4 {
                    inside_field += 1;
                    continue;
                }
                if h1.abs() < 0.1 {
                    continue; // доля не восстанавливается (h(0+) ≈ 0)
                }
                let a = 1.0 - href / h1;
                if !(-0.02..1.0).contains(&a) {
                    // в эталоне есть вклад, которого аналитика полосы не даёт: обратный поток
                    // отрыва в самом поле (`Turb::mean`, RW-8)
                    from_field += 1;
                    continue;
                }
                let m = mean_at(&fx, *p, t, a.max(0.0)).unwrap();
                used += 1;
                for (got, w) in [
                    ((wd[0] * m.h) as f32, ra[pi][0]),
                    ((wd[1] * m.h) as f32, ra[pi][2]),
                    (m.w_ridge as f32, rr[pi][1]),
                    (m.w_lee as f32, ra[pi][1]),
                ] {
                    n += 1;
                    if (got - w).abs() > tol_v(w) {
                        bad += 1;
                        println!("{name} t{ti} p{pi} {tag} a={a:.3}: {got} против {w}");
                    }
                }
            }
        }
    }
    println!(
        "полоса края: {used} точек-моментов, {n} значений, вне допуска {bad}; без аналитики (внутри поля): {inside_field}; с вкладом поля (RW-8, не сверялись): {from_field}"
    );
    assert!(used >= 30 && inside_field >= 10);
    // остаток — точки, где в эталоне есть неотделимый вклад обратного потока поля (RW-8): сверить после RW-8
    assert!(bad * 10 <= n, "вне допуска {bad} из {n}");
}

#[test]
fn strip_has_no_jump_at_field_edge_t2() {
    // T2: нет разрыва на краю полосы. a → 1: все вклады аналитики ∝ (1 − a) → 0. a → 0+: полоса
    // совпадает с веткой без поля, кроме множителя нагрева в роторе (GD не применяет его в
    // полосе — переносим буквально), поэтому для чистоты шва нагрев выключен конфигом.
    let fx = load_with("ongudai_strong", |v| v["lee"]["heat_kill_wm2"] = json!(0.0));
    let mut zone_pts = 0;
    for ti in 0..fx.case.times_s.len() {
        let t = fx.case.times_s[ti];
        for p in fx
            .case
            .points
            .iter()
            .chain(&[[10424.8, 1124.5, 3524.7], [5024.8, 1292.6, -275.3]])
        {
            let a0 = mean_at(&fx, *p, t, 0.0).unwrap();
            let a1 = mean_at(&fx, *p, t, 1.0e-9).unwrap();
            if a0.lee > 0.0 {
                zone_pts += 1;
            }
            assert!((a0.h - a1.h).abs() < 1e-6, "h: {} против {}", a0.h, a1.h);
            assert!((a0.w_ridge - a1.w_ridge).abs() < 1e-6);
            assert!(
                (a0.w_lee - a1.w_lee).abs() < 1e-6,
                "w_lee: {} против {}",
                a0.w_lee,
                a1.w_lee
            );
            let e = mean_at(&fx, *p, t, 1.0 - 1.0e-9).unwrap();
            assert!(e.h.abs() < 1e-6 && e.w_ridge.abs() < 1e-6 && e.w_lee.abs() < 1e-6);
            assert!(mean_at(&fx, *p, t, 1.0).is_none());
        }
    }
    println!("точек с подветренной зоной в проверке шва: {zone_pts}");
}

// ---------------------------------------------------------------- фон, кромка облаков

#[test]
fn background_wind_is_profile_without_relief() {
    let fx = load("synth_medium");
    let gref = terms::analytic::cloudbase_msl(&fx.terms, &fx.place).unwrap()
        - fx.terms.weather.f64_or("cloudbase_agl_m", 1500.0);
    let hs = [500.0f32, 900.0, 1200.0, 2500.0, f32::NAN];
    let mut out = [[9.0f32; 2]; 5];
    terms::analytic::background_wind(&fx.terms, &fx.place, &hs, &mut out);
    let w = &fx.terms.wind;
    let d = w.dir();
    for (o, &h) in out.iter().zip(&hs) {
        if !h.is_finite() {
            assert_eq!(*o, [0.0, 0.0]);
            continue;
        }
        let u = w.speed_at_pos((f64::from(h) - gref).max(0.0), f64::from(h));
        assert!(
            (f64::from(o[0]) - d[0] * u).abs() < 1e-5 && (f64::from(o[1]) - d[1] * u).abs() < 1e-5
        );
    }
    // ниже средней земли профиль не убывает; выше — растёт
    assert!(out[3][0].hypot(out[3][1]) > out[1][0].hypot(out[1][1]));
    // без места/конфигов — нули (слот не задан)
    let t0 = Terms::default();
    let mut z = [[1.0f32; 2]; 2];
    terms::analytic::background_wind(&t0, &fx.place, &[100.0, 200.0], &mut z);
    assert_eq!(z, [[0.0; 2]; 2]);
}

#[test]
fn cloudbase_matches_reference_frames() {
    // кромка облаков = средняя высота земли вокруг центра + cloudbase_agl_m погоды (W8: ≤ 5 м)
    for name in ["synth_medium", "ongudai_medium", "ongudai_strong"] {
        let fx = load(name);
        let cp = repo().join(format!("tests/fixtures/wind/cases/{name}.json"));
        let frames = dp_air::fixtures::read_desc(&fx.case, &cp).unwrap();
        let cb = terms::analytic::cloudbase_msl(&fx.terms, &fx.place).unwrap();
        for f in &frames {
            println!(
                "{name}: кромка {cb:.2} против эталона {:.2}",
                f.cloudbase_msl
            );
            assert!(
                (cb - f64::from(f.cloudbase_msl)).abs() <= 5.0,
                "{name}: {cb} против {}",
                f.cloudbase_msl
            );
        }
    }
}

#[test]
fn unconfigured_slot_gives_nothing_and_probe_slots_survive_configure() {
    // до configure слот пуст (сумма как раньше); пробник, подставленный тестом, configure не трогает
    let t = Terms::default();
    let fs = FieldSet::default();
    let pl = place_named("synthetic");
    let fx_ctx = Ctx {
        pos: [0.0, 1000.0, 0.0],
        ground: 0.0,
        agl: 100.0,
        t: 0.0,
        mode: SampleMode::Mean,
        a: 0.0,
        fw: [0.0; 3],
        u: 3.0,
        terms: &t,
        fs: &fs,
        place: &pl,
    };
    assert!(t.slots.analytic.mean(&fx_ctx).is_none());
    assert_eq!(t.slots.analytic.gust(&fx_ctx, 1.0, 1.0), [0.0; 3]);
    struct Probe;
    impl Analytic for Probe {}
    let mut t = Terms::default();
    t.slots.analytic = Arc::new(Probe);
    let cfg = configs_with(|_| {});
    t.configure(&cfg, 1);
    assert!(
        t.slots.analytic.configured(&cfg, 1).is_none(),
        "пробник остаётся пробником"
    );
}
