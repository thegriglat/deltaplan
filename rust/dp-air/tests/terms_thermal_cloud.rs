//! RW-10f: петля термики <-> облака в слоте `Thermal` (подсос `CloudPhysics::suck`, тень
//! `CloudField::shade_at`): thermal в точках `above_base` и в 250 м под основанием, сверка с W8.
#![allow(clippy::needless_range_loop)]
use dp_air::Configs;
use dp_air::Core;
use dp_air::Place;
use dp_air::field::baked::parse_baked;
use dp_air::field::field_set::FieldSet;
use dp_air::field::wind_field::Limits;
use dp_air::fixtures::{self, Case, Frame};
use dp_air::terms::clouds::snapshot_thermals;
use dp_air::terms::clouds::{CloudInputs, FieldInputs, Grid};
use dp_air::terms::thermal::{self as dterm, CloudHooks, GroundSource, NoClouds, ThermalSlot};
use dp_air::terms::{self, Terms};
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

/// Конфиги игры; `patch` правит `atmosphere.json`.
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

/// Как `config_overrides` случаев `synth_*`: круг генерации 8 км.
fn configs() -> Arc<Configs> {
    configs_with(|v| v["thermal"]["generation_radius_m"] = serde_json::json!(8000.0))
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

fn syn_surface_k(x: f64, z: f64) -> f64 {
    0.65 + 0.35 * (x / 830.0 + 1.3).sin() * (z / 1170.0 - 0.4).cos()
}

/// `AtmoFingerprint.source_static`.
fn syn_source(x: f64, z: f64) -> f64 {
    let n = syn_normal(x, z);
    let s = {
        let (a, b, c) = (0.3f32, 0.8f32, 0.5f32);
        let l = (a * a + b * b + c * c).sqrt();
        [a / l, b / l, c / l]
    };
    let d = f64::from(n[0] * s[0] + n[1] * s[1] + n[2] * s[2]);
    (syn_surface_k(x, z) * (0.35 + 0.8 * d)).clamp(0.0, 1.0)
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

fn case_path(name: &str) -> PathBuf {
    repo().join(format!("tests/fixtures/wind/cases/{name}.json"))
}

fn terms_for(case: &Case, ground: Arc<dyn GroundSource>) -> Terms {
    let mut t = Terms::default();
    t.configure(&configs(), case.seed);
    t.thermal_async = false;
    t.set_conditions(&case.conditions);
    // синтетика идёт с `air_model.enabled = off`: упрощённый профиль 0.8.0 (README фикстур)
    t.wind.set_simple_profile(true, None);
    t.statics = case.static_thermals.clone();
    t.statics_mode = case.static_mode;
    t.focuses = case.focuses.clone();
    t.set_thermal_ground(ground);
    t
}

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

fn thermal_index(case: &Case) -> usize {
    case.terms
        .as_ref()
        .unwrap()
        .iter()
        .position(|n| n == "thermal")
        .unwrap()
}

// ---------------------------------------------------------------- Онгудай: поле воздуха + AirThermals

/// Входы поля облаков из поля воздуха и `AirThermals` слота `Thermal` (путь GD
/// `CloudFieldSources.prepare` с GPU-полем; в игре его подключит RW-12z).
struct AirInputs;

impl CloudInputs for AirInputs {
    fn key(&self, terms: &Terms) -> Option<u64> {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        serde_json::to_string(terms.weather.map())
            .ok()?
            .hash(&mut h);
        terms
            .slots
            .thermal
            .as_slot()?
            .air()?
            .src
            .count()
            .hash(&mut h);
        Some(h.finish())
    }
    fn inputs(&self, terms: &Terms, t: f64) -> Option<FieldInputs> {
        let slot = terms.slots.thermal.as_slot()?;
        let setup = slot.setup()?;
        let a = slot.air()?;
        let ground_ref = setup.cloudbase_msl - terms.weather.f64_or("cloudbase_agl_m", 0.0);
        let wind = terms.wind.clone();
        Some(FieldInputs {
            grid: Grid::of_field(&a.level),
            wind_field: Some(a.level.clone()),
            air: Some(a.src.clone()),
            thermals: Some(snapshot_thermals(&slot.state()?.all, t)),
            weather: terms.weather.clone(),
            cloudbase_msl: Some(setup.cloudbase_msl),
            ground_ref: Some(ground_ref),
            seed: terms.seed as i64,
            wind_at: Arc::new(move |z| wind.vec2_at((z - ground_ref).max(0.0))),
        })
    }
}

fn le32(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

/// Земля места: сила и вода в точках кандидатов из журнала вызовов GD (RW-10d/RW-10e), как
/// `ongudai_*_on_gd_source_input_*` в `terms_thermal_field.rs`.
struct LogGround {
    inner: Arc<dyn GroundSource>,
    log: std::collections::HashMap<(u32, u32), (f64, bool)>,
}
impl GroundSource for LogGround {
    fn height(&self, x: f64, z: f64) -> f64 {
        self.inner.height(x, z)
    }
    fn is_water(&self, x: f64, z: f64) -> bool {
        self.log
            .get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .map_or_else(|| self.inner.is_water(x, z), |v| v.1)
    }
    fn source(&self, x: f64, z: f64, t: f64) -> f64 {
        self.log
            .get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .map_or_else(|| self.inner.source(x, z, t), |v| v.0.clamp(0.0, 1.0))
    }
}

fn log_ground(o: &Ref, name: &str) -> Arc<dyn GroundSource> {
    let dp = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data");
    let rd = |p: PathBuf| std::fs::read(p).unwrap();
    let (x, z, s, w): (Vec<f32>, Vec<f32>, Vec<f64>, Vec<u8>);
    let d10d = dp.join("RW-10d").join(name);
    if d10d.join("ref.json").exists() {
        let j: Value =
            serde_json::from_str(&std::fs::read_to_string(d10d.join("ref.json")).unwrap()).unwrap();
        let body = zstd::bulk::decompress(
            &rd(d10d.join("ref.bin")),
            j["raw_bytes"].as_u64().unwrap() as usize,
        )
        .unwrap();
        let seg = |n: &str, size: usize| {
            let a = &j["arrays"][n];
            let off = a[0].as_u64().unwrap() as usize;
            let c = a[1].as_u64().unwrap() as usize;
            body[off..off + c * size].to_vec()
        };
        x = le32(&seg("pl_x", 4));
        z = le32(&seg("pl_z", 4));
        s = seg("pl_s", 8)
            .chunks_exact(8)
            .map(|b| f64::from_le_bytes(b.try_into().unwrap()))
            .collect();
        w = seg("pl_w", 1);
    } else {
        let d = dp.join("RW-10e").join(name);
        let j: Value =
            serde_json::from_str(&std::fs::read_to_string(d.join("source_log.json")).unwrap())
                .unwrap();
        let n = j["n"].as_u64().unwrap() as usize;
        let body = zstd::bulk::decompress(&rd(d.join("source_log.bin")), n * 13).unwrap();
        x = le32(&body[..4 * n]);
        z = le32(&body[4 * n..8 * n]);
        s = le32(&body[8 * n..12 * n])
            .into_iter()
            .map(f64::from)
            .collect();
        w = body[12 * n..].to_vec();
    }
    let mut log = std::collections::HashMap::new();
    for q in 0..x.len() {
        log.insert((x[q].to_bits(), z[q].to_bits()), (s[q], w[q] == 1));
    }
    let base = {
        let mut t = Terms::default();
        t.configure(&configs_with(|_| {}), 0);
        t.set_thermal_place(o.place.clone(), None).unwrap();
        t.slots.thermal.as_slot().unwrap().ground().clone()
    };
    Arc::new(LogGround { inner: base, log })
}

// ---------------------------------------------------------------- случаи

#[derive(Clone, Copy, PartialEq)]
enum Src {
    /// `tests/fixtures/wind/cases` (W8, синтетика).
    W8,
    /// `tests/data/RW-10e/cases` (W8, Онгудай на запечённом поле).
    Rw10e,
    /// `tests/data/RW-10f/cases`: те же случаи с добавочными точками в слое облаков у термиков с
    /// подсосом (`gen_cloud_cases.gd`).
    Own,
}

struct Ref {
    case: Case,
    place: Arc<Place>,
    data: fixtures::CaseData,
    frames: Vec<Frame>,
    fs: FieldSet,
    ong: bool,
    name: String,
}

fn ref_load(name: &str, src: Src) -> Ref {
    let dp = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data");
    let ong = name.starts_with("ongudai");
    let p = match src {
        Src::W8 => case_path(name),
        Src::Rw10e | Src::Own => {
            let dir = dp.join(if src == Src::Own {
                "RW-10f/cases"
            } else {
                "RW-10e/cases"
            });
            let tmp =
                std::env::temp_dir().join(format!("rw10f_{}_{}", src as u8, std::process::id()));
            std::fs::create_dir_all(&tmp).unwrap();
            for ext in ["json", "bin"] {
                std::fs::copy(
                    dir.join(format!("{name}.{ext}")),
                    tmp.join(format!("{name}.{ext}")),
                )
                .unwrap();
            }
            let z = std::fs::read(dir.join(format!("{name}.desc.json.zst"))).unwrap();
            std::fs::write(
                tmp.join(format!("{name}.desc.json")),
                zstd::stream::decode_all(&z[..]).unwrap(),
            )
            .unwrap();
            tmp.join(format!("{name}.json"))
        }
    };
    let case = fixtures::read_case(&p).unwrap();
    let pp = repo().join(format!("tests/fixtures/wind/places/{}.json", case.place));
    let place = Arc::new(fixtures::read_place(&pp).unwrap());
    let data = fixtures::read_case_data(&case, &p).unwrap();
    let frames = fixtures::read_desc(&case, &p).unwrap();
    let mut fs = FieldSet::default();
    if ong {
        let own = dp.join("RW-10e").join(name);
        let d = if own.join("field.json").exists() {
            own
        } else {
            dp.join("RW-10d").join(name)
        };
        let hdr = std::fs::read_to_string(d.join("field.json")).unwrap();
        let bin = std::fs::read(d.join("field.bin")).unwrap();
        let b = parse_baked(&hdr, &bin).unwrap();
        fs = FieldSet::new(Limits::default(), 5.0);
        fs.set_field(b.levels, 0.0);
    }
    Ref {
        case,
        place,
        data,
        frames,
        fs,
        ong,
        name: name.to_string(),
    }
}

/// Слагаемые случая: `clouds_on` - подсос и тень облаков `Terms` (по умолчанию), иначе нулевые зацепки.
/// Синтетика - аналитические входы поля облаков (живые термики), Онгудай - поле воздуха и `AirThermals`.
fn ref_terms(r: &Ref, clouds_on: bool) -> Terms {
    if !r.ong {
        let mut t = terms_for(&r.case, Arc::new(SynGround));
        if !clouds_on {
            t.slots.thermal =
                Arc::new(ThermalSlot::new(Arc::new(SynGround)).with_hooks(Arc::new(NoClouds)));
        }
        return t;
    }
    let mut t = Terms::default();
    // Онгудай: конфиги игры как есть (круг генерации 8 км - только у синтетики `synth_*`)
    t.configure(&configs_with(|_| {}), r.case.seed);
    t.thermal_async = false;
    t.set_conditions(&r.case.conditions);
    t.statics = r.case.static_thermals.clone();
    t.statics_mode = r.case.static_mode;
    t.focuses = r.case.focuses.clone();
    t.set_thermal_place(r.place.clone(), None).unwrap();
    let g = log_ground(r, &r.name);
    t.set_thermal_ground(g.clone());
    t.set_air_field(r.fs.levels(), None);
    t.set_cloud_inputs(Arc::new(AirInputs));
    if !clouds_on {
        t.slots.thermal = Arc::new(ThermalSlot::new(g).with_hooks(Arc::new(NoClouds)));
    }
    t
}

#[derive(Default)]
struct Stats {
    n: usize,
    /// Точки, где подсос или тень меняют ответ (с облаками против нулевых зацепок).
    differs: usize,
    /// ... из них те, где ответ без облаков вне допуска W8 (облако нужно, чтобы совпасть с GD).
    needed: usize,
    /// Вне допуска, но рядом (400 м) ядро, место которого не сошлось с GD (сила источника по растру
    /// места, граница RW-10c/RW-10e): не про облака.
    place: usize,
    bad: Vec<String>,
}

impl Stats {
    fn add(&mut self, o: Stats) {
        self.n += o.n;
        self.differs += o.differs;
        self.needed += o.needed;
        self.place += o.place;
        self.bad.extend(o.bad);
    }
}

/// Динамические ядра GD момента `k` без ядра крейта (место ≤ max(25 м, 2 % радиуса), `w`, радиус, верх
/// и стадия в допуске W6) и ядра крейта без пары: места, где расхождение с GD не из-за облаков.
/// Ещё: число пар, где флаги (облако, Cb) не совпали, и число динамических ядер GD.
fn core_mismatches(t: &Terms, r: &Ref, k: usize, tm: f64) -> (Vec<Core>, usize, usize) {
    let c0 = r.case.focuses[0].pos;
    let mut mine: Vec<Core> = Vec::new();
    if let Some(slot) = t.slots.thermal.as_slot() {
        slot.all_cores(
            [c0[0], 0.0, c0[2]],
            if r.ong { 6000.0 } else { 8000.0 },
            tm,
            &mut mine,
        );
    }
    mine.retain(|c| c.flags as u32 & 1 == 0);
    let same = |c: &Core, g: &Core| {
        (c.w - g.w).abs() <= 0.03 * g.w.abs().max(1.0e-3) + 1e-4
            && (c.radius - g.radius).abs() <= 0.03 * g.radius
            && (c.top - g.top).abs() <= 10.0
            && (c.stage - g.stage).abs() <= 0.05
    };
    let mut used = vec![false; mine.len()];
    let mut off = Vec::new();
    let (mut flag_bad, mut n_gd) = (0, 0);
    for g in r.frames[k].cores.iter().filter(|c| c.flags as u32 & 1 == 0) {
        n_gd += 1;
        let best = (0..mine.len()).filter(|&i| !used[i]).min_by(|&a, &b| {
            let da = (mine[a].x - g.x).hypot(mine[a].z - g.z);
            let db = (mine[b].x - g.x).hypot(mine[b].z - g.z);
            da.total_cmp(&db)
        });
        let ok = best.is_some_and(|i| {
            let ok = (mine[i].x - g.x).hypot(mine[i].z - g.z) <= 25.0f32.max(0.02 * g.radius)
                && same(&mine[i], g);
            if ok {
                used[i] = true;
                if (mine[i].flags as u32 & 6) != (g.flags as u32 & 6) {
                    flag_bad += 1;
                }
            }
            ok
        });
        // погасшее ядро (w ~ 0) воздух не меняет
        if !ok && g.w > 0.05 {
            off.push(*g);
        }
    }
    for (c, u) in mine.iter().zip(&used) {
        if !u && c.w > 0.05 {
            off.push(*c);
        }
    }
    (off, flag_bad, n_gd)
}

/// Точка рядом (400 м) с осью несошедшегося ядра на её высоте.
fn explained(off: &[Core], p: &[f32; 3]) -> bool {
    off.iter().any(|c| {
        let dh = p[1] - c.y_src;
        (c.x + c.lean_x * dh - p[0]).hypot(c.z + c.lean_z * dh - p[2]) <= 400.0
    })
}

/// Шаг игры после `start_at` в случаях `Src::Own` (как `gen_cloud_cases.gd`: 16 шагов по 0,25 с).
const STEP_N: usize = 16;
const STEP_DT: f64 = 0.25;

/// thermal в точках `above_base`, до 250 м под основанием (кромка дампа момента) и у термиков с
/// подсосом (метка `suck_k<момент>`) против W8. Каждый момент - свежие `Terms` (`start_at`), как в GD.
/// Для `Src::Own` после `start_at` идут шаги `advance`: подсос и тень берутся из облаков после старта.
fn near_cloud(name: &str, src: Src) -> Stats {
    let r = ref_load(name, src);
    let ti = thermal_index(&r.case);
    let mut st = Stats::default();
    for (k, &t0) in r.case.times_s.iter().enumerate() {
        let mut t = ref_terms(&r, true);
        let mut off = ref_terms(&r, false);
        t.start_at(t0);
        off.start_at(t0);
        let mut tm = t0;
        if src == Src::Own {
            for i in 1..=STEP_N {
                tm = t0 + STEP_DT * i as f64;
                t.advance(tm);
                off.advance(tm);
            }
        }
        let cb = f64::from(r.frames[k].cloudbase_msl);
        let (off_places, _, _) = core_mismatches(&t, &r, k, t0);
        let want: Vec<[f32; 4]> = r.data.slab(k, 2 + ti).collect();
        for (i, (p, tag)) in r.case.points.iter().zip(&r.case.point_tags).enumerate() {
            let mine = tag == &format!("suck_k{k}");
            let near = tag == "above_base" || mine || f64::from(p[1]) > cb - 250.0;
            // за радиусом физики (6 км) от фокуса термики не действуют (ось на высоте верха уходит от
            // точки выбора на снос и наклон)
            let f0 = r.case.focuses[0].pos;
            if mine && (p[0] - f0[0]).hypot(p[2] - f0[2]) > 5500.0 {
                continue;
            }
            // вне растра места высоту знает только аналитика GD (README фикстур)
            if !near || (tag.starts_with("suck_k") && !mine) || !on_grid(&r.place, *p) {
                continue;
            }
            let g = terms::decompose(&t, &r.fs, Some(&r.place), *p, tm).vel[3][1];
            let g0 = terms::decompose(&off, &r.fs, Some(&r.place), *p, tm).vel[3][1];
            let w = want[i][1];
            st.n += 1;
            if (g - g0).abs() > 1.0e-4 {
                st.differs += 1;
                if (g0 - w).abs() > tol(w) {
                    st.needed += 1;
                }
            }
            if (g - w).abs() > tol(w) && src != Src::W8 && explained(&off_places, p) {
                st.place += 1;
            } else if (g - w).abs() > tol(w) {
                st.bad.push(format!(
                    "{name} t={tm} точка {i} ({tag}) {p:?} y-cb={:.0}: rust {g} (без облаков {g0}), gd {w}",
                    f64::from(p[1]) - cb
                ));
            }
        }
    }
    println!(
        "{name} [{}]: сверено {}, облака меняют ответ в {}, из них без облаков вне допуска {}, у несошедшегося по месту ядра {}, вне допуска с облаками {}",
        match src {
            Src::W8 => "W8",
            Src::Rw10e => "RW-10e",
            Src::Own => "RW-10f",
        },
        st.n,
        st.differs,
        st.needed,
        st.place,
        st.bad.len()
    );
    for b in st.bad.iter().take(12) {
        println!("  {b}");
    }
    st
}

const SYNTH: [&str; 6] = [
    "synth_weak",
    "synth_medium",
    "synth_strong",
    "synth_storm",
    "synth_wave",
    "synth_off",
];
const ONG: [&str; 3] = ["ongudai_medium", "ongudai_strong", "ongudai_wave"];
const OWN: [&str; 7] = [
    "synth_weak",
    "synth_medium",
    "synth_strong",
    "synth_storm",
    "ongudai_medium",
    "ongudai_strong",
    "ongudai_wave",
];

/// (1) Эталоны W8 `synth_*`: thermal в `above_base` и до 250 м под основанием - в допуске.
#[test]
fn synth_w8_near_cloud_in_tolerance() {
    let mut all = Stats::default();
    for n in SYNTH {
        all.add(near_cloud(n, Src::W8));
    }
    assert!(all.n >= 60, "сверено {}", all.n);
    assert!(all.bad.is_empty(), "вне допуска: {}", all.bad.len());
}

/// (2) Эталоны W8 `ongudai_*` (поле воздуха и `AirThermals`; сила источника из журнала GD).
#[test]
fn ongudai_w8_near_cloud_in_tolerance() {
    let mut all = Stats::default();
    for n in ONG {
        all.add(near_cloud(n, Src::Rw10e));
    }
    assert!(all.n >= 50, "сверено {}", all.n);
    assert!(all.bad.is_empty(), "вне допуска: {}", all.bad.len());
}

/// (3) Добавочные эталоны RW-10f: точки на оси и у края термиков с подсосом в слое облаков, снятые на
/// той же опорной ревизии. Подсос меняет ответ во многих точках, и с ним все точки в допуске W8.
#[test]
fn suck_points_from_gd_in_tolerance() {
    let mut all = Stats::default();
    for n in OWN {
        all.add(near_cloud(n, Src::Own));
    }
    println!(
        "RW-10f: сверено {}, подсос меняет ответ в {}, без него вне допуска {}, у несошедшегося по месту ядра {}",
        all.n, all.differs, all.needed, all.place
    );
    assert!(all.n >= 600, "сверено {}", all.n);
    assert!(
        all.differs >= 500,
        "облака ответ почти не меняют: {}",
        all.differs
    );
    assert!(
        all.needed >= 400,
        "без облаков эталон не сходится только в {}",
        all.needed
    );
    assert!(
        all.place * 10 <= all.n,
        "объяснено местом ядер {} из {}",
        all.place,
        all.n
    );
    assert!(all.bad.is_empty(), "вне допуска: {}", all.bad.len());
}

/// Набор ядер после шагов (с тенью облаков в силе источников и подсосом): число, место, `w`, радиус, верх,
/// стадия и флаги облака/Cb - как у дампа GD. Синтетика - без единого расхождения.
#[test]
fn cores_after_steps_match_desc() {
    let (mut gd, mut off, mut flag_bad) = (0, 0, 0);
    for name in OWN {
        let r = ref_load(name, Src::Own);
        for (k, &t0) in r.case.times_s.iter().enumerate() {
            let mut t = ref_terms(&r, true);
            t.start_at(t0);
            for i in 1..=STEP_N {
                t.advance(t0 + STEP_DT * i as f64);
            }
            let (o, f, n) = core_mismatches(&t, &r, k, t0);
            println!(
                "{name} t={t0}: ядер gd {n}, без пары {}, флаги не сошлись {f}",
                o.len()
            );
            if !r.ong {
                assert!(
                    o.is_empty() && f == 0,
                    "{name} t={t0}: без пары {}, флаги {f}",
                    o.len()
                );
            }
            gd += n;
            off += o.len();
            flag_bad += f;
        }
    }
    assert!(gd > 500, "ядер gd {gd}");
    assert!(off * 100 <= gd * 8, "ядер без пары {off} из {gd}");
    assert_eq!(flag_bad, 0, "флаги облака у пар");
}

/// Тень облаков в силе источника: `cloud_shade_factor` × закрытая доля (`air.rs`, `cells.rs`).
struct Fake {
    shade: f64,
    boost: f64,
}
impl CloudHooks for Fake {
    fn shade_at(&self, _x: f64, _z: f64, _sun: [f64; 3]) -> f64 {
        self.shade
    }
    fn suck(&self, th: &dterm::AtmoThermal, _t: f64) -> [f64; 2] {
        [th.suck + self.boost, 0.0]
    }
}

fn strengths(h: Option<Arc<dyn CloudHooks>>) -> std::collections::HashMap<i64, f32> {
    let l = ref_load("synth_medium", Src::W8);
    let mut t = terms_for(&l.case, Arc::new(SynGround));
    if let Some(h) = h {
        t.slots.thermal = Arc::new(ThermalSlot::new(Arc::new(SynGround)).with_hooks(h));
    }
    t.start_at(0.0);
    let st = t.slots.thermal.as_slot().unwrap().state().unwrap();
    st.all
        .iter()
        .filter(|a| !a.is_static)
        .map(|a| (a.id, a.strength as f32))
        .collect()
}

/// (4) Зацепки слота: тень 0,5 уменьшает силу источника в 1 - 0,5 × cloud_shade_factor раз (у части
/// термиков порог `smin` сдвигает результат; часть уходит под порог и не рождается), нулевая реализация
/// и свои зацепки отсутствуют = облака `Terms` (в `start_at` их ещё нет, как у GD).
#[test]
fn hooks_shade_scales_source_strength() {
    let w0 = strengths(Some(Arc::new(NoClouds)));
    let w1 = strengths(Some(Arc::new(Fake {
        shade: 0.5,
        boost: 0.0,
    })));
    let wd = strengths(None);
    assert_eq!(w0, wd, "start_at: облаков ещё нет, сила та же");
    // best_sun *= 1 - shade, затем strength = max(strength(sun_k), smin) * (1 - shade): ослабление
    // не слабее, чем в (1 - shade) раз, и не сильнее, чем в (1 - shade)^(1 + sun_strength_exponent / 2)
    let k = 1.0 - 0.5 * 0.6;
    let (mut ok, mut common, mut exact) = (0, 0, 0);
    for (id, a) in &w0 {
        if let Some(b) = w1.get(id) {
            common += 1;
            let q = *b / *a;
            if q <= k + 1.0e-4 && q >= k * k * k {
                ok += 1;
            }
            if (q - k).abs() <= 1.0e-4 {
                exact += 1;
            }
        }
    }
    println!(
        "тень: общих термиков {common}, ослаблено в [{:.2}, {k}]: {ok}, ровно в {k}: {exact}; без тени {}, с тенью {}",
        k * k * k,
        w0.len(),
        w1.len()
    );
    assert!(common > 80, "общих термиков {common}");
    assert_eq!(ok, common, "ослабление вне [(1-тень)^3, 1-тень]");
    assert!(exact > 0, "нет термиков, ослабленных ровно в {k}");
    assert!(w1.len() < w0.len(), "часть термиков уходит под порог силы");
}

/// (5) `start_at` строит термики без облаков (как `refresh_now` GD: термики, затем облака), первый
/// `advance` подключает облака: подсос меняет ответ в точках, где он есть.
#[test]
fn start_at_has_no_clouds_until_first_advance() {
    let r = ref_load("synth_strong", Src::Own);
    let ti = thermal_index(&r.case);
    let t0 = r.case.times_s[0];
    let mut t = ref_terms(&r, true);
    let mut off = ref_terms(&r, false);
    t.start_at(t0);
    off.start_at(t0);
    let fs = FieldSet::default();
    let pts: Vec<&[f32; 3]> = r
        .case
        .points
        .iter()
        .zip(&r.case.point_tags)
        .filter(|(_, g)| g.starts_with("suck_k0"))
        .map(|(p, _)| p)
        .collect();
    assert!(pts.len() > 20);
    let v = |t: &Terms, p: &[f32; 3], tm: f64| {
        terms::decompose(t, &fs, Some(&r.place), *p, tm).vel[3][1]
    };
    for p in &pts {
        assert_eq!(v(&t, p, t0), v(&off, p, t0), "после start_at облаков нет");
    }
    let _ = ti;
    for i in 1..=STEP_N {
        t.advance(t0 + STEP_DT * i as f64);
        off.advance(t0 + STEP_DT * i as f64);
    }
    let tm = t0 + STEP_DT * STEP_N as f64;
    let moved = pts
        .iter()
        .filter(|p| (v(&t, p, tm) - v(&off, p, tm)).abs() > 1.0e-3)
        .count();
    assert!(
        moved * 2 >= pts.len(),
        "подсос изменил {moved} из {} точек",
        pts.len()
    );
}
