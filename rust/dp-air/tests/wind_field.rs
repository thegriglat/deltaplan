//! RW-6i: поле воздуха (`Field`, `FieldSet`) против дампа GDScript
//! (`tools/research/rust_wind/dump_wind_field.sh`, данные — `tests/data/wind_field/`) и свойства
//! T2: непрерывность на краю и в полосе `edge_weight`, подмена за `blend_s`, ограничители.
//!
//! Допуски против GDScript: скорость ≤ 1e-4 м/с + 1e-5 отн. по компоненте, θ′ и `w_conv` ≤ 1e-4,
//! `u*`, `w*`, `hmix` ≤ 1e-5 отн.
use dp_air::field::field_set::{FieldSet, Vel};
use dp_air::field::wind_field::{
    Channel, Field, FieldGrid, FieldMeta, Limits, T_HMIX, T_N2, T_SIZE, T_USTAR, T_WSTAR, Z0,
};
use picard_rs::state::State;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn data_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/wind_field")
}

struct Dump {
    json: Value,
    blob: Vec<f32>,
    arrays: HashMap<String, (usize, usize)>,
}

impl Dump {
    fn arr(&self, name: &str) -> &[f32] {
        let (o, l) = *self
            .arrays
            .get(name)
            .unwrap_or_else(|| panic!("в дампе нет массива '{name}'"));
        &self.blob[o..o + l]
    }
    fn num(&self, path: &[&str]) -> f64 {
        let mut v = &self.json;
        for p in path {
            v = &v[*p];
        }
        v.as_f64()
            .unwrap_or_else(|| panic!("в дампе нет числа {path:?}"))
    }
}

fn dump() -> &'static Dump {
    static D: OnceLock<Dump> = OnceLock::new();
    D.get_or_init(|| {
        let (js, bin) = (data_dir().join("field.json"), data_dir().join("field.bin"));
        let text = std::fs::read_to_string(&js).unwrap_or_else(|e| {
            panic!(
                "нет дампа {js:?} ({e}): снимите его tools/research/rust_wind/dump_wind_field.sh \
                 (под замком cpu); тест без дампа не пропускается"
            )
        });
        let json: Value = serde_json::from_str(&text).unwrap();
        let raw = std::fs::read(&bin).unwrap_or_else(|e| panic!("нет {bin:?}: {e}"));
        let blob: Vec<f32> = raw
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect();
        let arrays = json["arrays"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| {
                (
                    k.clone(),
                    (
                        v[0].as_u64().unwrap() as usize,
                        v[1].as_u64().unwrap() as usize,
                    ),
                )
            })
            .collect();
        Dump { json, blob, arrays }
    })
}

/// Сравнение массивов: |a − b| ≤ abs + rel·|b|; NaN равен NaN. Паника с худшим индексом.
fn cmp(name: &str, got: &[f32], want: &[f32], abs: f64, rel: f64) {
    assert_eq!(got.len(), want.len(), "{name}: длина");
    let mut worst = (0.0f64, 0usize);
    for (q, (&a, &b)) in got.iter().zip(want).enumerate() {
        if a.is_nan() && b.is_nan() {
            continue;
        }
        let (a, b) = (a as f64, b as f64);
        let e = ((a - b).abs() - rel * b.abs()).max(0.0);
        if e.is_nan() || e > worst.0 {
            worst = (if e.is_nan() { f64::INFINITY } else { e }, q);
        }
    }
    eprintln!("{name}: худший избыток {:.2e} (допуск {abs:e})", worst.0);
    assert!(
        worst.0 <= abs,
        "{name}: индекс {} Rust {} GD {}, избыток {:.3e} > {abs:e} (rel {rel:e})",
        worst.1,
        got[worst.1],
        want[worst.1],
        worst.0
    );
}

fn grid() -> FieldGrid {
    let d = dump();
    let g = &d.json["grid"];
    let f = |k: &str| g[k].as_f64().unwrap();
    FieldGrid {
        dx: f("dx"),
        dz: f("dz"),
        x0: f("x0"),
        y0: f("y0"),
        z_bot: f("z_bot"),
        nx: f("nx") as usize,
        ny: f("ny") as usize,
        nz: f("nz") as usize,
    }
}

fn state(u: &[f32], v: &[f32], w: &[f32], th: &[f32], g: &FieldGrid) -> State {
    State {
        case: String::new(),
        input: String::new(),
        it: 0,
        dims: [g.nx + 2, g.ny + 2, g.nz + 2],
        halo: 1,
        n: [g.nx, g.ny, g.nz],
        u: u.to_vec(),
        v: v.to_vec(),
        w: w.to_vec(),
        th: th.to_vec(),
        thd: Vec::new(),
        p: Vec::new(),
        nu: None,
        nuh: None,
        residuals: None,
    }
}

fn full_meta() -> FieldMeta {
    let d = dump();
    FieldMeta {
        z0: Z0::Map(d.arr("z0").iter().map(|&x| x as f64).collect()),
        gam: d.arr("gam").to_vec(),
        heat: d.arr("heat").to_vec(),
        z_i: d.num(&["z_i"]),
        z_i_col: d.arr("z_i_col").to_vec(),
    }
}

fn limits() -> Limits {
    let l = &dump().json["limits"];
    Limits {
        max_speed: l[0].as_f64().unwrap(),
        max_w: l[1].as_f64().unwrap(),
    }
}

fn build(meta: FieldMeta) -> Field {
    let d = dump();
    let g = grid();
    let heat = state(
        d.arr("heat_u"),
        d.arr("heat_v"),
        d.arr("heat_w"),
        d.arr("heat_th"),
        &g,
    );
    let mech = state(
        d.arr("heat_u"),
        d.arr("heat_v"),
        d.arr("mech_w"),
        d.arr("heat_th"),
        &g,
    );
    Field::from_mac(&heat, &mech, &g, d.arr("cell"), d.arr("hc"), meta, limits()).unwrap()
}

struct Fx {
    a: Field,
    b: Field,
    c: Field,
}

/// Уровень B — вырез из A (как `_crop_level` дампера).
fn crop_level(a: &Field, off: usize, n: usize) -> Field {
    let d = dump();
    let ga = *a.grid();
    let na = ga.nx;
    let pick = |src: &[f32]| -> Vec<f32> {
        let mut out = Vec::with_capacity(n * n * ga.nz);
        for k in 0..ga.nz {
            for j in 0..n {
                for i in 0..n {
                    out.push(src[(k * na + off + j) * na + off + i]);
                }
            }
        }
        out
    };
    let col = |src: &[f32]| -> Vec<f32> {
        let mut out = Vec::with_capacity(n * n);
        for j in 0..n {
            for i in 0..n {
                out.push(src[(off + j) * na + off + i]);
            }
        }
        out
    };
    let gb = FieldGrid {
        x0: ga.x0 + off as f64 * ga.dx,
        y0: ga.y0 + off as f64 * ga.dx,
        nx: n,
        ny: n,
        ..ga
    };
    let meta = FieldMeta {
        z0: Z0::Map(col(d.arr("z0")).iter().map(|&x| x as f64).collect()),
        gam: d.arr("gam").to_vec(),
        heat: col(d.arr("heat")),
        z_i: d.num(&["z_i"]),
        z_i_col: col(d.arr("z_i_col")),
    };
    Field::from_arrays(
        &gb,
        pick(a.raw_u()),
        pick(a.raw_v()),
        pick(a.raw_w_mech()),
        pick(a.raw_w_conv()),
        pick(a.raw_theta()),
        col(a.raw_hc()),
        meta,
        limits(),
    )
    .unwrap()
}

fn fixture() -> &'static Fx {
    static F: OnceLock<Fx> = OnceLock::new();
    F.get_or_init(|| {
        let a = build(full_meta());
        let off = dump().num(&["b", "off"]) as usize;
        let n = dump().num(&["b", "n"]) as usize;
        let b = crop_level(&a, off, n);
        let c = build(FieldMeta::default());
        Fx { a, b, c }
    })
}

fn pts_of(flat: &[f32]) -> Vec<[f32; 3]> {
    flat.chunks_exact(3).map(|p| [p[0], p[1], p[2]]).collect()
}

/// Опрос уровня тем же набором, что дампер: vel (3), theta, wconv, edge, inside, turb.
fn check_level(f: &Field, prefix: &str, pos: &str, ground: &str) {
    let d = dump();
    let pts = pts_of(d.arr(pos));
    let gh = d.arr(ground);
    let mut vel = Vec::new();
    let mut th = Vec::new();
    let mut wc = Vec::new();
    let mut edge = Vec::new();
    let mut inside = Vec::new();
    let mut turb = Vec::new();
    for (p, &g) in pts.iter().zip(gh) {
        vel.extend_from_slice(&f.sample(*p, g));
        th.push(f.sample_theta(*p, g) as f32);
        wc.push(f.sample_w_conv(*p, g) as f32);
        edge.push(f.edge_weight(*p) as f32);
        inside.push(f.contains(*p) as u8 as f32);
        turb.extend_from_slice(&f.turb_at(*p, g));
    }
    cmp(
        &format!("{prefix}vel"),
        &vel,
        d.arr(&format!("{prefix}vel")),
        1e-4,
        1e-5,
    );
    cmp(
        &format!("{prefix}theta"),
        &th,
        d.arr(&format!("{prefix}theta")),
        1e-4,
        0.0,
    );
    cmp(
        &format!("{prefix}wconv"),
        &wc,
        d.arr(&format!("{prefix}wconv")),
        1e-4,
        0.0,
    );
    cmp(
        &format!("{prefix}edge"),
        &edge,
        d.arr(&format!("{prefix}edge")),
        1e-6,
        1e-6,
    );
    assert_eq!(
        inside,
        d.arr(&format!("{prefix}inside")),
        "{prefix}contains"
    );
    check_turb(
        &format!("{prefix}turb"),
        &turb,
        d.arr(&format!("{prefix}turb")),
    );

    // пачка = поточечно
    let mut many = vec![[0f32; 3]; pts.len()];
    f.sample_many(&pts, gh, &mut many);
    let flat: Vec<f32> = many.iter().flatten().copied().collect();
    assert_eq!(flat, vel, "sample_many != sample");
    for (ch, one) in [(Channel::Theta, &th), (Channel::WConv, &wc)] {
        let mut o = vec![0f32; pts.len()];
        f.sample_scalar_many(ch, &pts, gh, &mut o);
        assert_eq!(&o, one, "sample_scalar_many {ch:?}");
    }
}

fn check_turb(name: &str, got: &[f32], want: &[f32]) {
    for q in 0..T_SIZE {
        let g: Vec<f32> = got.iter().skip(q).step_by(T_SIZE).copied().collect();
        let w: Vec<f32> = want.iter().skip(q).step_by(T_SIZE).copied().collect();
        let (abs, rel) = match q {
            T_USTAR | T_WSTAR | T_HMIX => (1e-6, 1e-5),
            T_N2 => (1e-8, 1e-4),
            _ => (1e-5, 1e-4),
        };
        cmp(&format!("{name}[{q}]"), &g, &w, abs, rel);
    }
}

#[test]
fn a_raw_arrays_match_from_mac() {
    let d = dump();
    let f = &fixture().a;
    for (n, got) in [
        ("raw_u", f.raw_u()),
        ("raw_v", f.raw_v()),
        ("raw_w_mech", f.raw_w_mech()),
        ("raw_w_conv", f.raw_w_conv()),
        ("raw_theta", f.raw_theta()),
    ] {
        cmp(n, got, d.arr(n), 1e-6, 1e-6);
    }
    let k1: Vec<f32> = f.raw_k1().iter().map(|&k| k as f32).collect();
    assert_eq!(k1, d.arr("raw_k1"), "raw_k1");
    let cols: [(&str, &[f32]); 6] = [
        ("ustar", f.raw_ustar()),
        ("uout", f.raw_uout()),
        ("aout", f.raw_aout()),
        ("desc", f.raw_desc()),
        ("wstar", f.raw_wstar()),
        ("hmix", f.raw_hmix()),
    ];
    for (n, got) in cols {
        cmp(
            &format!("col_{n}"),
            got,
            d.arr(&format!("col_{n}")),
            1e-6,
            1e-5,
        );
    }
    assert!(f.raw_wstar().iter().any(|&w| w > 0.5), "w* не тривиален");
    assert!(f.raw_hmix().iter().all(|&h| h >= 300.0), "hmix ≥ ZI_MIN");
    // без метаданных: нагрева нет, w* и hmix нулевые
    let c = &fixture().c;
    for (n, got) in [
        ("ustar", c.raw_ustar()),
        ("wstar", c.raw_wstar()),
        ("hmix", c.raw_hmix()),
    ] {
        cmp(
            &format!("c_col_{n}"),
            got,
            d.arr(&format!("c_col_{n}")),
            1e-6,
            1e-5,
        );
    }
    assert!(c.raw_wstar().iter().all(|&w| w == 0.0));
}

#[test]
fn a_points_match_gd() {
    check_level(&fixture().a, "a_", "pts", "pts_ground");
}

#[test]
fn b_level_points_match_gd() {
    check_level(&fixture().b, "b_", "sub_pos", "sub_ground");
}

#[test]
fn plain_field_points_match_gd() {
    check_level(&fixture().c, "c_", "sub_pos", "sub_ground");
}

#[test]
fn field_set_scenario_matches_gd() {
    let d = dump();
    let fx = fixture();
    let g = &fx.a;
    let mut fs = FieldSet::new(limits(), d.num(&["edge_cells"]));
    let sub = pts_of(d.arr("sub_pos"));
    let gh = d.arr("sub_ground");
    let (mut vel, mut th, mut wc, mut tb, mut dxs, mut bl) =
        (vec![], vec![], vec![], vec![], vec![], vec![]);
    for op in d.json["ops"].as_array().unwrap() {
        match op["op"].as_str().unwrap() {
            "set" => {
                let lv: Vec<Field> = op["levels"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| match n.as_str().unwrap() {
                        "A" => fx.a.clone(),
                        "B" => fx.b.clone(),
                        o => panic!("уровень {o}"),
                    })
                    .collect();
                fs.set_field(lv, op["blend"].as_f64().unwrap());
            }
            "adv" => fs.advance(op["dt"].as_f64().unwrap()),
            "sample" => {
                bl.push(fs.blend_fraction() as f32);
                for (p, &h) in sub.iter().zip(gh) {
                    let v = fs.sample(*p, h);
                    vel.extend_from_slice(&[v.v[0] as f32, v.v[1] as f32, v.v[2] as f32]);
                    vel.push(v.share as f32);
                    let t = fs.sample_theta(*p, h);
                    th.extend_from_slice(&[t.0 as f32, t.1 as f32]);
                    let c = fs.sample_w_conv(*p, h);
                    wc.extend_from_slice(&[c.0 as f32, c.1 as f32]);
                    tb.extend_from_slice(&fs.sample_turb(*p, h));
                    dxs.push(fs.sample_dx(*p) as f32);
                }
            }
            o => panic!("op {o}"),
        }
    }
    let _ = g;
    cmp("set_blend", &bl, d.arr("set_blend"), 1e-5, 0.0);
    cmp("set_vel", &vel, d.arr("set_vel"), 1e-4, 1e-5);
    cmp("set_theta", &th, d.arr("set_theta"), 1e-4, 1e-5);
    cmp("set_wconv", &wc, d.arr("set_wconv"), 1e-4, 1e-5);
    cmp("set_dx", &dxs, d.arr("set_dx"), 1e-3, 1e-6);
    // turb: T_SIZE + 1 на точку (последнее — доля)
    for q in 0..=T_SIZE {
        let g: Vec<f32> = tb.iter().skip(q).step_by(T_SIZE + 1).copied().collect();
        let w: Vec<f32> = d
            .arr("set_turb")
            .iter()
            .skip(q)
            .step_by(T_SIZE + 1)
            .copied()
            .collect();
        let (abs, rel) = match q {
            T_USTAR | T_WSTAR | T_HMIX => (1e-6, 1e-5),
            T_N2 => (1e-8, 1e-4),
            _ => (1e-5, 1e-4),
        };
        cmp(&format!("set_turb[{q}]"), &g, &w, abs, rel);
    }
}

// ------------------------------------------------------------------ T2

/// Поперечник: параметр s (метры от начала) → точка.
type Transect = Box<dyn Fn(f64) -> [f32; 3]>;

fn modified(a: &Field, du: f32) -> Field {
    let g = *a.grid();
    let add = |x: &[f32]| x.iter().map(|&v| v + du).collect::<Vec<f32>>();
    Field::from_arrays(
        &g,
        add(a.raw_u()),
        a.raw_v().to_vec(),
        a.raw_w_mech().to_vec(),
        a.raw_w_conv().to_vec(),
        a.raw_theta().to_vec(),
        a.raw_hc().to_vec(),
        full_meta(),
        limits(),
    )
    .unwrap()
}

/// Полоса края: ни одного скачка. Вес `edge_weight` — гладкий (smoothstep), поле — линейное по
/// столбцам; шаг 1 м. Скачок ограничен произведением: |Δ(w·v)| ≤ w·|Δv| + |v|·|Δw|.
#[test]
fn t2_no_jump_at_edge_and_in_band() {
    let fx = fixture();
    let g = *fx.a.grid();
    let mut fs = FieldSet::new(limits(), 5.0);
    fs.set_field(vec![fx.a.clone()], 0.0);
    let band = 5.0 * g.dx;
    // поперечники: с запада к центру, с востока, с юга, с севера; на высотах над землёй сетки
    let mid_z = -(g.y0 + 0.5 * g.ny as f64 * g.dx);
    let mid_x = g.x0 + 0.5 * g.nx as f64 * g.dx;
    let (xe, ye) = (g.x0 + g.nx as f64 * g.dx, g.y0 + g.ny as f64 * g.dx);
    let hmax = fx.a.raw_hc().iter().cloned().fold(0.0f32, f32::max) as f64;
    for agl_y in [hmax + 200.0, hmax + 1500.0] {
        let mut lines: Vec<(&str, Transect)> = Vec::new();
        lines.push((
            "запад",
            Box::new(move |s| [(g.x0 - 20.0 + s) as f32, agl_y as f32, mid_z as f32]),
        ));
        lines.push((
            "восток",
            Box::new(move |s| [(xe + 20.0 - s) as f32, agl_y as f32, mid_z as f32]),
        ));
        lines.push((
            "юг",
            Box::new(move |s| [mid_x as f32, agl_y as f32, -(g.y0 - 20.0 + s) as f32]),
        ));
        lines.push((
            "север",
            Box::new(move |s| [mid_x as f32, agl_y as f32, -(ye + 20.0 - s) as f32]),
        ));
        for (name, p) in &lines {
            let mut prev: Option<(Vel, [f32; 3], f64)> = None;
            let mut s = 0.0;
            while s <= band + 60.0 {
                let pt = p(s);
                let v = fs.sample(pt, f32::NAN);
                let fv = fx.a.sample(pt, f32::NAN);
                let w = fx.a.edge_weight(pt);
                if let Some((pv, pf, pw)) = prev {
                    let vmax = pf.iter().map(|x| x.abs() as f64).fold(0.0, f64::max);
                    for q in 0..3 {
                        let jump = (v.v[q] - pv.v[q]).abs();
                        let dfield = (fv[q] - pf[q]).abs() as f64;
                        let bound = pw.max(w) * dfield + vmax * (w - pw).abs() + 1e-6;
                        assert!(
                            jump <= bound + 1e-9,
                            "{name}, y {agl_y}: скачок {jump:.3e} > {bound:.3e} на s = {s} (w {w})"
                        );
                    }
                    // сам вес: наклон smoothstep ≤ 1.5/(band) за метр
                    assert!(
                        (w - pw).abs() <= 1.5 / band + 1e-9,
                        "{name}: вес скачет на s = {s}"
                    );
                }
                prev = Some((v, fv, w));
                s += 1.0;
            }
        }
    }
    // вне области доля 0, у края поле — значения ближайшего столбца (без разрыва)
    let out = fs.sample([(g.x0 - 5000.0) as f32, 3000.0, mid_z as f32], f32::NAN);
    assert_eq!(out.share, 0.0);
    assert_eq!(out.v, [0.0; 3]);
}

/// Само поле на шаге 1 м без скачка выше 1e-3 + наклон по столбцам (выше слоя лог-профиля):
/// наклон ограничен разностью значений соседних столбцов/клеток, делённой на их шаг.
#[test]
fn t2_field_has_no_jump_at_domain_border() {
    let fx = fixture();
    let g = *fx.a.grid();
    let mid_z = -(g.y0 + 0.5 * g.ny as f64 * g.dx);
    let y = fx.a.raw_hc().iter().cloned().fold(0.0f32, f32::max) as f64 + 1500.0;
    let mut prev: Option<[f32; 3]> = None;
    let mut worst = 0.0f32;
    for s in -50..=50 {
        let p = [(g.x0 + s as f64) as f32, y as f32, mid_z as f32];
        let v = fx.a.sample(p, f32::NAN);
        if let Some(pv) = prev {
            for q in 0..3 {
                worst = worst.max((v[q] - pv[q]).abs());
            }
        }
        prev = Some(v);
    }
    // у границы столбец один: вне поля значение постоянно, внутри первые полклетки — тоже
    assert!(worst <= 1e-3, "скачок поля у границы {worst:.3e} > 1e-3");
}

#[test]
fn t2_blend_is_monotonic_continuous_and_exact_at_end() {
    let fx = fixture();
    let new = modified(&fx.a, 3.0);
    let g = *fx.a.grid();
    let p = [
        (g.x0 + 0.5 * g.nx as f64 * g.dx) as f32,
        (fx.a.raw_hc().iter().cloned().fold(0.0f32, f32::max) as f64 + 800.0) as f32,
        -(g.y0 + 0.5 * g.ny as f64 * g.dx) as f32,
    ];
    let mut fs = FieldSet::new(limits(), 5.0);
    fs.set_field(vec![fx.a.clone()], 0.0);
    let old = fs.sample(p, f32::NAN);
    let mut only_new = FieldSet::new(limits(), 5.0);
    only_new.set_field(vec![new.clone()], 0.0);
    let want = only_new.sample(p, f32::NAN);
    assert!(
        (want.v[0] - old.v[0]).abs() > 1.0,
        "подмена не меняет поле: {} -> {}",
        old.v[0],
        want.v[0]
    );
    fs.set_field(vec![new], 60.0);
    let mut prev = fs.sample(p, f32::NAN);
    assert_eq!(prev, old, "в t = 0 — старое поле");
    let dt = 0.25;
    let mut t = 0.0;
    let mut last_frac = 0.0;
    while t < 60.0 {
        fs.advance(dt);
        t += dt;
        let v = fs.sample(p, f32::NAN);
        // монотонно (u растёт к новому) и непрерывно: наклон smoothstep ≤ 1.5/60 · Δ за секунду
        assert!(v.v[0] >= prev.v[0] - 1e-9, "не монотонно на t = {t}");
        assert!(
            (v.v[0] - prev.v[0]).abs() <= (want.v[0] - old.v[0]).abs() * 1.5 / 60.0 * dt + 1e-9,
            "скачок на t = {t}"
        );
        let fr = fs.blend_fraction();
        assert!(fr >= last_frac);
        last_frac = fr;
        prev = v;
    }
    assert_eq!(fs.blend_fraction(), 1.0);
    assert_eq!(prev, want, "в t = blend_s — ровно новое поле");
    // два опроса на одном t равны
    assert_eq!(fs.sample(p, f32::NAN), fs.sample(p, f32::NAN));
}

#[test]
fn t2_limits_are_enforced() {
    let fx = fixture();
    let g = *fx.a.grid();
    let n = g.nx * g.ny * g.nz;
    let mut u = vec![100.0f32; n];
    u[3] = f32::NAN;
    let v = vec![-100.0f32; n];
    let w = vec![50.0f32; n];
    let mut q = vec![-30.0f32; n];
    q[5] = f32::INFINITY;
    let f = Field::from_arrays(
        &g,
        u,
        v,
        w,
        q,
        vec![0.0; n],
        fx.a.raw_hc().to_vec(),
        FieldMeta::default(),
        Limits::default(),
    )
    .unwrap();
    for c in 0..n {
        let s = (f.raw_u()[c] as f64).hypot(f.raw_v()[c] as f64);
        assert!(s <= 40.0 + 1e-4, "скорость {s}");
        assert!(f.raw_w_mech()[c].abs() <= 10.0 && f.raw_w_conv()[c].abs() <= 10.0);
    }
    assert_eq!(f.raw_u()[3], 0.0, "NaN → 0 до ограничителя");
    assert_eq!(f.raw_w_conv()[5], 0.0, "inf → 0");
    let mut fs = FieldSet::new(
        Limits {
            max_speed: 5.0,
            max_w: 1.0,
        },
        5.0,
    );
    fs.set_field(vec![fx.a.clone()], 0.0);
    let hi = fx.a.raw_hc().iter().cloned().fold(0.0f32, f32::max) as f64 + 1500.0;
    let p = [
        (g.x0 + 0.5 * g.nx as f64 * g.dx) as f32,
        hi as f32,
        -(g.y0 + 0.5 * g.ny as f64 * g.dx) as f32,
    ];
    let v = fs.sample(p, f32::NAN);
    assert!(v.v[0].hypot(v.v[2]) <= 5.0 + 1e-4 && v.v[1].abs() <= 1.0 + 1e-6);
}

#[test]
fn from_mac_rejects_wrong_sizes() {
    let d = dump();
    let g = grid();
    let ok = state(
        d.arr("heat_u"),
        d.arr("heat_v"),
        d.arr("heat_w"),
        d.arr("heat_th"),
        &g,
    );
    let mut bad = ok.clone();
    bad.u.pop();
    assert!(
        Field::from_mac(
            &bad,
            &ok,
            &g,
            d.arr("cell"),
            d.arr("hc"),
            FieldMeta::default(),
            limits()
        )
        .is_err()
    );
    assert!(
        Field::from_mac(
            &ok,
            &ok,
            &g,
            &d.arr("cell")[1..],
            d.arr("hc"),
            FieldMeta::default(),
            limits()
        )
        .is_err()
    );
}
