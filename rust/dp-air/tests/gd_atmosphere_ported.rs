//! RW-P7: физика слагаемых малых тестов `tests/atmosphere/*.gd`, перенесённая из Godot (при поле
//! «всегда» GD-фасад считает поле Пикара на каждый мир, и сумма поля с аналитикой уже не та, что
//! мерили пороги GD). Здесь — слагаемые крейта без поля (`FieldSet::default()`): аналитика, склон,
//! подветренная зона, турбулентность, термики. Пороги — те же, что были в GD (не подгонялись).
//! Эти слагаемые сверены с эталоном GD (W8) в `terms_analytic.rs` (`synth_*`), `terms_turb.rs`,
//! `terms_thermal.rs`; здесь — перенос физических проверок тестов, а не новая сверка.
use dp_air::field::field_set::FieldSet;
use dp_air::terms::thermal::GroundSource;
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

fn configs() -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    files.sort();
    Arc::new(Configs::new(files))
}

/// Место 6 км (шаг 25 м, как малое место GD-тестов) с рельефом `h(x, z)`.
fn place_of(h: impl Fn(f64, f64) -> f64) -> Place {
    let (w, sp) = (241usize, 25.0);
    let hdr = format!(
        r#"{{"version":1,"loc":{{"id":"rig","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,
"month":7,"day":15}},"grid":{{"origin_x":-3000,"origin_z":-3000,"spacing":{sp},"width":{w},"height":{w}}},
"surface_classes":{{"grass":1}},"start_sites":[]}}"#
    );
    let header = PlaceHeader::from_json(&hdr).unwrap();
    let mut hs = Vec::with_capacity(w * w);
    for j in 0..w {
        for i in 0..w {
            hs.push(h(-3000.0 + i as f64 * sp, -3000.0 + j as f64 * sp) as f32);
        }
    }
    let n = w * w;
    Place::new(header, hs, vec![0; n], vec![1; n], vec![1.0; n]).unwrap()
}

/// Пресет `configs/weather/<preset>.json` с правками `over`, в `Terms` с режимом термиков
/// `mode` (0 динамика, 1 только статичные) и фокусом в начале координат.
fn terms_of(preset: &str, over: Value, mode: u8) -> Terms {
    let text =
        std::fs::read_to_string(repo().join(format!("configs/weather/{preset}.json"))).unwrap();
    let mut w: Value = serde_json::from_str(&text).unwrap();
    for (k, v) in over.as_object().unwrap() {
        w[k] = v.clone();
    }
    let c = Conditions::from_json(
        &json!({"preset": w, "start_hour": 12.0, "speed": 1.0, "blend_s": null, "rebuild": false})
            .to_string(),
    )
    .unwrap();
    let mut t = Terms::default();
    t.configure(&configs(), 4242);
    t.set_conditions(&c);
    t.statics_mode = mode;
    t.focuses = vec![Focus {
        pos: [0.0, 0.0, 0.0],
        weight: 1.0,
    }];
    t
}

fn at(t: &Terms, pl: &Place, p: [f32; 3], tm: f64, mode: SampleMode) -> [f32; 4] {
    terms::sum(t, &FieldSet::default(), Some(pl), p, mode, tm, None)
}

fn mean(t: &Terms, pl: &Place, p: [f32; 3], tm: f64) -> [f32; 4] {
    at(t, pl, p, tm, SampleMode::Mean)
}

// ---------------------------------------------------------------- test_atmosphere.gd

fn ridge_300(x: f64, _z: f64) -> f64 {
    300.0 * (-(x / 400.0) * (x / 400.0)).exp()
}

/// `test_ridge_lift_windward_and_lee_sink`: наветренный склон поднимает, подъём затухает с высотой,
/// зона подъёма выдвинута вперёд склона, подветренный склон опускает, ветер в тени ослаблен.
#[test]
fn ridge_lift_windward_and_lee_sink() {
    let pl = place_of(ridge_300);
    let mut t = terms_of(
        "medium",
        json!({"wind_speed_kmh": 25.0, "wind_from_deg": 270.0}),
        1,
    );
    t.wind.set_simple_profile(true, None);
    t.start_at(0.01);
    let bg = t.weather.f64_or("background_sink_ms", 0.0) as f32;
    let g = |x: f64| ridge_300(x, 0.0) as f32;
    let xw = -300.0f32;
    let ww = mean(&t, &pl, [xw, g(-300.0) + 50.0, 0.0], 0.01)[1];
    assert!(ww > 1.0, "наветренный склон поднимает: {ww}");
    let ww_high = mean(&t, &pl, [xw, g(-300.0) + 700.0, 0.0], 0.01)[1];
    assert!(
        ww_high < ww * 0.5,
        "подъём затухает с высотой: {ww_high} < {ww}"
    );
    let front = mean(&t, &pl, [-650.0, 250.0, 0.0], 0.01)[1];
    assert!(front > bg + 0.3, "перед склоном уже поднимает: {front}");
    let xl = 300.0f32;
    let wl = mean(&t, &pl, [xl, g(300.0) + 30.0, 0.0], 0.01)[1];
    assert!(wl < bg - 0.5, "подветренный склон опускает: {wl}");
    let vl = mean(&t, &pl, [xl, g(300.0) + 30.0, 0.0], 0.01)[0];
    let vu = mean(&t, &pl, [-2500.0, 30.0, 0.0], 0.01)[0];
    assert!(vl < vu, "в тени гребня ветер ослаблен: {vl} < {vu}");
}

/// `test_turbulence_deterministic_and_ground_stronger`: одна точка — один ответ; у земли (20 м)
/// пульсации сильнее, чем на 900 м; на высоте они тоже есть. Без конвективной болтанки.
#[test]
fn turbulence_deterministic_and_ground_stronger() {
    let pl = place_of(|_, _| 0.0);
    let mut t = terms_of(
        "medium",
        json!({"wind_speed_kmh": 20.0, "convective_turbulence_ms": 0.0}),
        1,
    );
    t.start_at(0.01);
    let full = |p: [f32; 3]| at(&t, &pl, p, 0.01, SampleMode::Full);
    let p = [123.0, 40.0, -77.0];
    assert_eq!(full(p), full(p), "детерминированно");
    let (mut low, mut high) = (0.0f64, 0.0f64);
    for i in 0..400 {
        let q = [i as f32 * 13.0, 0.0, i as f32 * 7.0];
        let dx = |y: f32| {
            let pp = [q[0], y, q[2]];
            f64::from(full(pp)[0] - mean(&t, &pl, pp, 0.01)[0])
        };
        low += dx(20.0).powi(2);
        high += dx(900.0).powi(2);
    }
    println!(
        "σ² у земли {:.3}, на 900 м {:.3}",
        low / 400.0,
        high / 400.0
    );
    assert!(
        low > high * 1.2,
        "у земли порывистее: {} > {}",
        low / 400.0,
        high / 400.0
    );
    assert!(high > 0.0, "на высоте тоже есть пульсации");
}

// ---------------------------------------------------------------- test_lee_rotor.gd

const LEE_X: [f32; 5] = [150.0, 200.0, 250.0, 300.0, 350.0];
const LEE_AGL: [f32; 4] = [20.0, 40.0, 60.0, 80.0];

fn ridge_lee(x: f64, _z: f64) -> f64 {
    300.0 * (-(x / 400.0) * (x / 400.0)).exp()
}

/// `simple` — упрощённый профиль ветра 0.8.0, на котором сняты эталоны GD (README фикстур) и
/// откалиброваны пороги тестов; в игре его нет (профиль по высоте — `wind.profile`).
fn lee_world(wind_ms: f64, simple: bool) -> (Terms, Place) {
    let kmh = if wind_ms > 0.0 { wind_ms * 3.6 } else { 0.0 };
    let mut t = terms_of(
        "medium",
        json!({"wind_speed_kmh": kmh, "wind_from_deg": 270.0, "background_sink_ms": 0.0,
            "convective_turbulence_ms": 0.0}),
        1,
    );
    if simple {
        t.wind.set_simple_profile(true, None);
    }
    t.start_at(0.01);
    (t, place_of(ridge_lee))
}

/// Среднее по пятну (вдоль гребня и по времени): (w, u, σ, горизонталь вдоль ветра), где u —
/// ветер профиля в тех же точках без влияния склона (`mean_wind_at` эталона GD: `|v|` набегающего
/// потока; пороги `0,35·u` и `0,45·u` откалиброваны на нём. Берёт скорость профиля, а не `|sample|`
/// в тени: там поток замедлен самим склоном и порог превращался бы в ссылку на себя).
fn patch(t: &mut Terms, pl: &Place, xs: &[f32], agls: &[f32]) -> [f64; 4] {
    let (mut sw, mut su, mut ss, mut sh, mut n) = (0.0f64, 0.0f64, 0.0f64, 0.0f64, 0usize);
    for k5 in 0..5 {
        let tm = 10.0 + k5 as f64 * 7.0;
        t.advance(tm);
        for &x in xs {
            for &agl in agls {
                for k in 0..20 {
                    let g = ridge_lee(f64::from(x), 0.0) as f32;
                    let s = mean(t, pl, [x, g + agl, k as f32 * 37.0], tm);
                    sw += f64::from(s[1]);
                    sh += f64::from(s[0]);
                    su += t.wind.speed_at_pos(f64::from(agl), f64::from(g + agl));
                    ss += f64::from(s[3]);
                    n += 1;
                }
            }
        }
    }
    let n = n as f64;
    [sw / n, su / n, ss / n, sh / n]
}

/// `test_lee_sink_and_rotor_scale_with_wind`: за гребнем опускание и ротор растут с ветром, на
/// наветренной стороне поднимает и σ мала (пороги GD, регрессия аналитики `lee.*`).
#[test]
fn lee_sink_and_rotor_scale_with_wind() {
    // игровой профиль ветра: числа в журнал (в отчёт RW-P7), пороги — на профиле эталона
    for wind in [2.0, 5.0, 8.0] {
        let (mut t, pl) = lee_world(wind, false);
        let lee = patch(&mut t, &pl, &LEE_X, &LEE_AGL);
        println!(
            "игровой профиль, {wind:.0} м/с: за гребнем w {:.2} ({:.2}·u), σ {:.2} ({:.2}·u)",
            lee[0],
            lee[0] / lee[1],
            lee[2],
            lee[2] / lee[1]
        );
    }
    for wind in [2.0, 5.0, 8.0] {
        let (mut t, pl) = lee_world(wind, true);
        let lee = patch(&mut t, &pl, &LEE_X, &LEE_AGL);
        let ww = patch(&mut t, &pl, &[-300.0], &LEE_AGL);
        println!(
            "ветер {wind:.0} м/с: за гребнем w {:.2} ({:.2}·u), σ {:.2} ({:.2}·u), u {:.2}; наветренный w {:.2} σ {:.2}",
            lee[0],
            lee[0] / lee[1],
            lee[2],
            lee[2] / lee[1],
            lee[1],
            ww[0],
            ww[2]
        );
        if wind > 4.0 {
            assert!(
                lee[0] < 0.0 && lee[0] >= -0.35 * lee[1],
                "{wind} м/с: опускание {}",
                lee[0]
            );
            assert!(
                lee[2] >= 0.45 * lee[1],
                "{wind} м/с: ротор σ {} против {}",
                lee[2],
                0.45 * lee[1]
            );
            assert!(
                ww[0] > 0.3,
                "{wind} м/с: наветренный склон поднимает {}",
                ww[0]
            );
            assert!(
                ww[2] < 0.35 * ww[1],
                "{wind} м/с: наветренный σ мал {}",
                ww[2]
            );
        } else {
            assert!(lee[0] >= -1.0, "слабый ветер: опускание мягкое {}", lee[0]);
        }
    }
}

/// `test_rotor_reverse_flow_near_slope`: у подветренного склона обратный/нулевой поток, высоко над
/// линией тени ветер прежний.
#[test]
fn rotor_reverse_flow_near_slope() {
    let (t, pl) = lee_world(8.0, true);
    let mut reversed = 0;
    for &x in &LEE_X {
        for agl in [5.0f32, 10.0, 15.0] {
            let g = ridge_lee(f64::from(x), 0.0) as f32;
            if mean(&t, &pl, [x, g + agl, 0.0], 0.01)[0] < 0.5 {
                reversed += 1;
            }
        }
    }
    assert!(
        reversed >= 3,
        "у подветренного склона обратный/нулевой поток: {reversed} клеток"
    );
    let u = mean(&t, &pl, [250.0, 700.0, 0.0], 0.01)[0];
    assert!(u > 4.0, "над тенью ветер прежний: {u}");
}

// ---------------------------------------------------------------- test_hazards.gd

struct Dry(f64);
impl GroundSource for Dry {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, _x: f64, _z: f64, _t: f64) -> f64 {
        self.0
    }
}

/// (средняя сила ядер, число ядер) в круге 8 км вокруг фокуса.
fn core_stats(cirrus: f64) -> (f64, usize) {
    let mut t = terms_of("strong", json!({"cirrus_cover": cirrus}), 0);
    t.set_thermal_ground(Arc::new(Dry(0.8)));
    t.start_at(0.01);
    let mut c = Vec::new();
    t.thermal_cores([0.0, 300.0, 0.0], 8000.0, 0.01, &mut c);
    let n = c.len();
    let s: f64 = c.iter().map(|x| f64::from(x.w)).sum();
    (s / n.max(1) as f64, n)
}

/// `test_cirrus_weakens_thermals`: перистая пелена гасит прогрев — термики слабее и реже.
#[test]
fn cirrus_weakens_thermals() {
    let (sc, nc) = core_stats(0.0);
    let (sv, nv) = core_stats(0.9);
    println!("ясно: {sc:.2} м/с, {nc} ядер; пелена: {sv:.2} м/с, {nv} ядер");
    assert!(nc > 0, "ядра есть");
    assert!(sv < sc * 0.9, "термики под пеленой слабее: {sv} < {sc}");
    assert!(nv < nc, "и реже: {nv} < {nc}");
}

// ---------------------------------------------------------------- test_calibration.gd

/// Средняя сила зрелых динамических ядер (stage 1–2) в круге 6 км на 3600 с, ровная земля,
/// источник 1,0 всюду (поле без границ — в отличие от малого места GD-фасада, где термиков 5).
fn mean_mature_strength(preset: &str) -> (f64, usize) {
    let mut t = terms_of(preset, json!({}), 0);
    t.set_thermal_ground(Arc::new(Dry(1.0)));
    t.start_at(3600.0);
    let mut c = Vec::new();
    t.thermal_cores([0.0, 300.0, 0.0], 6000.0, 3600.0, &mut c);
    let m: Vec<f64> = c
        .iter()
        .filter(|x| x.flags as u32 & 1 == 0 && x.stage >= 1.0 && x.stage <= 2.0)
        .map(|x| f64::from(x.w))
        .collect();
    (m.iter().sum::<f64>() / m.len().max(1) as f64, m.len())
}

/// `test_thermal_strength_by_day` (A07): средний день — ядра ≈ 2,3–2,5 м/с, слабый трудный, сильный
/// сильнее среднего и в рамках FR-11.
#[test]
fn thermal_strength_by_day() {
    let (weak, nw) = mean_mature_strength("weak");
    let (medium, nm) = mean_mature_strength("medium");
    let (strong, ns) = mean_mature_strength("strong");
    println!("weak {weak:.2} ({nw}), medium {medium:.2} ({nm}), strong {strong:.2} ({ns})");
    assert!(nm >= 20, "зрелых ядер medium: {nm}");
    assert!(
        (2.2..=3.2).contains(&medium),
        "medium: средняя сила 2,2–3,2 м/с: {medium}"
    );
    assert!(weak < medium - 0.5, "weak слабее medium: {weak} < {medium}");
    assert!(
        weak >= 0.9,
        "weak: термики держат крыло (>= 0,9 м/с): {weak}"
    );
    assert!(
        strong > medium + 0.3,
        "strong сильнее medium: {strong} > {medium}"
    );
    assert!(strong <= 5.0, "strong в рамках FR-11 (<= 5 м/с): {strong}");
}
