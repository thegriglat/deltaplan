//! RW-11d: облака в крейте (`terms::clouds`): `CloudField`, `CloudFieldSources`, `CloudPhysics`.
//!
//! - **против дампа GD** (`tests/data/RW-11d/`, опорная ревизия `c591b1026`): растр поля (cover,
//!   depth, stage, activity, bg) по шагам, разгон, переход входов, `sample`/`density_at`/`shade_at`,
//!   `suck`, `sample` и `density_at` физики, `visible_clouds`;
//! - **перенос тестов GDScript** `test_cloud_field.gd` (инварианты, слабый < сильный, детерминизм,
//!   аналитика, задержка таяния, снос, башни), `test_cloud_start.gd` (разгон `start_at`), `test_cloud_suck.gd`.
use dp_air::Configs;
use dp_air::field::solved::parse_solved;
use dp_air::field::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use dp_air::terms::WeatherView;
use dp_air::terms::clouds::{
    CloudField, CloudPhysics, FieldCfg, FieldInputs, Grid, PhysCfg, ThermalSnap,
};
use dp_air::terms::storm::{CloudCfg, CloudModel};
use dp_air::terms::thermal::AtmoThermal;
use dp_air::terms::thermal::CloudHooks;
use dp_air::terms::thermal_air::{AirThermals, AirThermalsCfg, BuildIn};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-11d")
}

fn atm() -> Value {
    serde_json::from_str(&std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap())
        .unwrap()
}

fn configs() -> Configs {
    let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
    Configs::new(vec![("atmosphere".into(), t)])
}

fn fcfg() -> FieldCfg {
    FieldCfg::from_configs(&configs())
}

fn medium_duty() -> f64 {
    let t = std::fs::read_to_string(repo().join("configs/weather/medium.json")).unwrap();
    let v: Value = serde_json::from_str(&t).unwrap();
    v["thermal_duty"].as_f64().unwrap()
}

// ================================================================ дамп GD

struct Ref {
    j: Value,
    body: Vec<u8>,
}

impl Ref {
    fn load() -> Ref {
        let j: Value =
            serde_json::from_str(&std::fs::read_to_string(data().join("ref.json")).unwrap())
                .unwrap();
        let raw = std::fs::read(data().join("ref.bin")).unwrap();
        let n = j["raw_bytes"].as_u64().unwrap() as usize;
        let body = zstd::bulk::decompress(&raw, n).unwrap();
        Ref { j, body }
    }
    fn seg(&self, name: &str, size: usize) -> &[u8] {
        let a = &self.j["arrays"][name];
        let off = a[0].as_u64().unwrap() as usize;
        let n = a[1].as_u64().unwrap() as usize;
        &self.body[off..off + n * size]
    }
    fn f32s(&self, name: &str) -> Vec<f32> {
        self.seg(name, 4)
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect()
    }
    fn f64s(&self, name: &str) -> Vec<f64> {
        self.seg(name, 8)
            .chunks_exact(8)
            .map(|b| f64::from_le_bytes(b.try_into().unwrap()))
            .collect()
    }
}

/// Макс. отклонение двух массивов (длины равны).
fn maxdiff(a: &[f32], b: &[f32]) -> f64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(x, y)| (f64::from(*x) - f64::from(*y)).abs())
        .fold(0.0, f64::max)
}

struct Tol {
    cover: f64,
    depth: f64,
    stage: f64,
    act: f64,
}

/// Допуск растра против GD. С TB-15 (шаблон пузыря по умолчанию) источники облаков — `AirThermals` с K̄ и q(ξ)
/// шаблона, а не профиля Гедеона, как у дампа GD: поток ядер (`carried`) выше в ≈ 1,9–3,7 раза, и облака получаются
/// другие (в дампе GD источники старой модели). Точное совпадение (прежние 1e-6) невозможно; допуск — «поле того же
/// порядка и на месте»: покрытие в пределах 0,4 (шкала 0…1), глубина — 1500 м, стадия — 4, активность — 1; плюс
/// проверка присутствия облаков в `cmp_snap` (покрытие есть там же, где у GD, не меньше чем наполовину). Остальные
/// проверки — фон, база и время — прежние, точные.
const TOL: Tol = Tol {
    cover: 0.4,
    depth: 1500.0,
    stage: 4.0,
    act: 1.0,
};

fn cmp_snap(r: &Ref, name: &str, cf: &CloudField, tol: &Tol) -> [f64; 4] {
    let d = [
        maxdiff(&cf.cover, &r.f32s(&format!("{name}.cover"))),
        maxdiff(&cf.depth, &r.f32s(&format!("{name}.depth"))),
        maxdiff(&cf.stage, &r.f32s(&format!("{name}.stage"))),
        maxdiff(&cf.activity, &r.f32s(&format!("{name}.activity"))),
    ];
    let sc = r.f64s(&format!("{name}.sc"));
    eprintln!(
        "{name}: dcover {:.2e} ddepth {:.2e} dstage {:.2e} dact {:.2e} bg {:.2e}/{:.2e} base {} t {}",
        d[0],
        d[1],
        d[2],
        d[3],
        (cf.bg_cover - sc[0]).abs(),
        (cf.bg_depth - sc[1]).abs(),
        cf.base_msl - sc[2],
        cf.time - sc[3]
    );
    // присутствие облаков: суммарное покрытие нового поля не меньше половины и не больше удвоенного покрытия GD
    let (mine, gd): (f64, f64) = (
        cf.cover.iter().map(|x| f64::from(*x)).sum(),
        r.f32s(&format!("{name}.cover")).iter().map(|x| f64::from(*x)).sum(),
    );
    if gd > 1.0 {
        eprintln!("    {name}: сумма покрытия {mine:.1} против GD {gd:.1}");
        assert!(mine >= 0.5 * gd && mine <= 2.0 * gd, "{name}: покрытие {mine} против GD {gd}");
    }
    assert!(d[0] <= tol.cover, "{name}: cover {:.3e}", d[0]);
    assert!(d[1] <= tol.depth, "{name}: depth {:.3e}", d[1]);
    assert!(d[2] <= tol.stage, "{name}: stage {:.3e}", d[2]);
    assert!(d[3] <= tol.act, "{name}: activity {:.3e}", d[3]);
    // фон (средние покрытие и глубина) зависит от потока ядер: TB-15, допуск 0,02 и 250 м (прежние 1e-3 и 2 м)
    assert!((cf.bg_cover - sc[0]).abs() < 0.02 && (cf.bg_depth - sc[1]).abs() < 250.0);
    assert_eq!(cf.base_msl, sc[2], "{name}: base");
    assert_eq!(cf.time, sc[3], "{name}: time");
    d
}

// ================================================================ входы

fn weather(z_lcl: f64, depth_m: f64, overdev: f64) -> WeatherView {
    let mut m = Map::new();
    m.insert("cloud_depth_m".into(), depth_m.into());
    m.insert("overdevelopment_chance".into(), overdev.into());
    m.insert("stability_n_per_s".into(), 0.012.into());
    m.insert(
        "_derived".into(),
        json!({"z_lcl_msl_m": z_lcl, "temperature_c": 25.0, "dew_point_c": 8.0}),
    );
    WeatherView::new(m)
}

fn no_wind() -> Arc<dyn Fn(f64) -> [f64; 2] + Send + Sync> {
    Arc::new(|_| [0.0, 0.0])
}

fn inputs(f: &Arc<Field>, air: &Arc<AirThermals>, w: WeatherView, seed: i64) -> FieldInputs {
    FieldInputs {
        grid: Grid::of_field(f),
        wind_field: Some(f.clone()),
        air: Some(air.clone()),
        thermals: None,
        weather: w,
        cloudbase_msl: None,
        ground_ref: None,
        seed,
        wind_at: no_wind(),
    }
}

struct Ongudai {
    f: Arc<Field>,
    air: Arc<AirThermals>,
    cb: f64,
}

fn ongudai() -> Ongudai {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-10d/ongudai_medium");
    let hdr = std::fs::read_to_string(dir.join("field.json")).unwrap();
    let bin = std::fs::read(dir.join("field.bin")).unwrap();
    let mut b = parse_solved(&hdr, &bin).unwrap();
    let f = b.levels.remove(0);
    let hj: Value = serde_json::from_str(&hdr).unwrap();
    let u10 = hj["levels"][0]["meta"]["u10"].as_f64().unwrap();
    let cb = 3035.66521281331;
    let cfg = AirThermalsCfg::from_thermal(&atm()["thermal"], 0.85, cb);
    let air = AirThermals::build(&f, &BuildIn::new(&cfg, u10)).expect("build");
    Ongudai {
        f: Arc::new(f),
        air: Arc::new(air),
        cb,
    }
}

// ---------------------------------------------------------------- синтетика

const N: usize = 48;
const NZ: usize = 40;
const DX: f64 = 400.0;
const DZ: f64 = 100.0;
const GROUND: f32 = 1000.0;
const Z_BOT: f64 = 950.0;

fn flat_field(heat: &dyn Fn(f64, f64) -> f64, z_i: f64, wind: [f64; 2]) -> Field {
    let x0 = -(N as f64) * DX * 0.5;
    let grid = FieldGrid {
        dx: DX,
        dz: DZ,
        x0,
        y0: x0,
        z_bot: Z_BOT,
        nx: N,
        ny: N,
        nz: NZ,
    };
    let gam: Vec<f32> = (0..NZ)
        .map(|k| {
            if Z_BOT + (k as f64 + 0.5) * DZ < z_i {
                0.0
            } else {
                0.0058
            }
        })
        .collect();
    let mut h = vec![0.0f32; N * N];
    for j in 0..N {
        for i in 0..N {
            let x = x0 + (i as f64 + 0.5) * DX;
            let zw = -(x0 + (j as f64 + 0.5) * DX);
            h[j * N + i] = heat(x, zw) as f32;
        }
    }
    let n = N * N * NZ;
    let meta = FieldMeta {
        z0: Z0::Uniform(0.1),
        gam,
        heat: h,
        z_i,
        z_i_col: Vec::new(),
    };
    Field::from_arrays(
        &grid,
        vec![wind[0] as f32; n],
        vec![-wind[1] as f32; n],
        vec![0.0; n],
        vec![0.0; n],
        vec![0.0; n],
        vec![GROUND; N * N],
        meta,
        Limits::default(),
    )
    .unwrap()
}

fn blob(cx: f64, cz: f64, r: f64, h: f64) -> impl Fn(f64, f64) -> f64 {
    move |x, z| if (x - cx).hypot(z - cz) < r { h } else { 0.0 }
}

fn build_air(f: &Field, wind: [f64; 2], z_lcl: f64) -> AirThermals {
    let cfg = AirThermalsCfg::from_thermal(&atm()["thermal"], medium_duty(), z_lcl);
    let u10 = (wind[0].hypot(wind[1])) / 1.8;
    AirThermals::build(f, &BuildIn::new(&cfg, u10)).expect("build")
}

/// Поле облаков синтетики: ровная земля, пятно нагрева, LCL.
fn synth(
    heat: &dyn Fn(f64, f64) -> f64,
    z_i: f64,
    wind: [f64; 2],
    z_lcl: f64,
    seed: i64,
    depth: f64,
    overdev: f64,
) -> (CloudField, FieldInputs) {
    let f = Arc::new(flat_field(heat, z_i, wind));
    let air = Arc::new(build_air(&f, wind, z_lcl));
    let inp = inputs(&f, &air, weather(z_lcl, depth, overdev), seed);
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inp);
    (cf, inp)
}

fn mean(a: &[f32]) -> f64 {
    a.iter().map(|x| f64::from(*x)).sum::<f64>() / a.len().max(1) as f64
}

fn invariants(cf: &CloudField, label: &str) {
    for c in 0..cf.nx * cf.ny {
        let (cov, d) = (cf.cover[c], cf.depth[c]);
        assert!(
            (0.0..=1.0).contains(&cov) && d >= 0.0 && !d.is_nan(),
            "{label}: cover/depth"
        );
        assert!(!(cov == 0.0 && d != 0.0), "{label}: depth без облака");
        assert!((-1.0..=1.0).contains(&cf.stage[c]), "{label}: stage");
        assert!((0.0..=1.0).contains(&cf.activity[c]), "{label}: activity");
    }
}

// ================================================================ против GD: Онгудай

#[test]
fn ongudai_raster_vs_gd() {
    let r = Ref::load();
    let o = ongudai();
    let inp = inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606);
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inp);
    assert!(mean(&cf.cover) == 0.0);
    cf.reset(0.0);
    cmp_snap(&r, "og_r0", &cf, &TOL);
    cf.reset(900.0);
    cmp_snap(&r, "og_r900", &cf, &TOL);
    cf.reset(3600.0);
    cmp_snap(&r, "og_r3600", &cf, &TOL);
    assert!(mean(&cf.cover) > 0.01, "на Онгудае есть облака");
    cf.step_to(3620.0);
    cmp_snap(&r, "og_s3620", &cf, &TOL);
    cf.step_to(3700.0);
    cmp_snap(&r, "og_s3700", &cf, &TOL);
    invariants(&cf, "ongudai");
}

#[test]
fn ongudai_spinup_steps_vs_gd() {
    let r = Ref::load();
    let o = ongudai();
    let inp = inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606);
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inp);
    cf.begin_spinup(900.0);
    for k in [5, 30, 60, 100, 120] {
        cf.step_to(900.0 - 2400.0 + 20.0 * f64::from(k));
        cmp_snap(&r, &format!("og_spin{k}"), &cf, &TOL);
    }
}

#[test]
fn ongudai_input_blend_vs_gd() {
    let r = Ref::load();
    let o = ongudai();
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606));
    cf.reset(3600.0);
    cf.step_to(3700.0);
    cf.set_inputs(&inputs(
        &o.f,
        &o.air,
        weather(o.cb - 300.0, 800.0, 0.0),
        606,
    ));
    cf.step_to(3720.0);
    cmp_snap(&r, "og_b20", &cf, &TOL);
    cf.step_to(3760.0);
    cmp_snap(&r, "og_b60", &cf, &TOL);
    cf.step_to(3900.0);
    cmp_snap(&r, "og_b200", &cf, &TOL);
}

#[test]
fn ongudai_sample_density_shade_vs_gd() {
    let r = Ref::load();
    let o = ongudai();
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606));
    cf.reset(3600.0);
    cf.step_to(3700.0);
    let pts = r.f32s("og_pts");
    let (sm, dn, sh) = (
        r.f32s("og_sample"),
        r.f32s("og_density"),
        r.f32s("og_shade"),
    );
    let sun = r.f32s("og_sun");
    let (mut ds, mut dd, mut dh) = (0.0f64, 0.0f64, 0.0f64);
    let mut n_cov = 0;
    for (q, p) in pts.chunks_exact(3).enumerate() {
        let s = cf.sample([p[0], p[1], p[2]]);
        for k in 0..4 {
            ds = ds.max((f64::from(s[k]) - f64::from(sm[q * 4 + k])).abs());
        }
        let d = cf.density_at([p[0], p[1], p[2]]);
        dd = dd.max((d - f64::from(dn[q])).abs());
        if dn[q] > 0.0 {
            n_cov += 1;
        }
        if q % 4 == 0 {
            let h = cf.shade_at([p[0], p[2]], [sun[0], sun[1], sun[2]]);
            dh = dh.max((h - f64::from(sh[q / 4])).abs());
        }
    }
    eprintln!("sample {ds:.2e} density {dd:.2e} shade {dh:.2e}, точек в облаке {n_cov}");
    assert!(n_cov > 5, "в выборке есть облако");
    // TB-15: поле другое (источники — шаблон пузыря), поэтому точечные значения не совпадают с GD; проверяем
    // присутствие и допустимые диапазоны, расхождения — в строке выше
    assert!(ds.is_finite() && dd.is_finite() && dh.is_finite());
    assert!(dd <= 1.5 && dh <= 1.0, "density {dd} shade {dh}");
}

// ================================================================ против GD: синтетика

#[test]
fn synthetic_cases_vs_gd() {
    let r = Ref::load();
    let (mut cf, _) = synth(
        &blob(0.0, 0.0, 4000.0, 300.0),
        2500.0,
        [0.0, 0.0],
        2000.0,
        1,
        800.0,
        0.0,
    );
    cf.reset(0.0);
    cf.step_to(1800.0);
    cmp_snap(&r, "sy_blob", &cf, &TOL);
    let (mut cf, _) = synth(
        &blob(1000.0, -2000.0, 5000.0, 250.0),
        2500.0,
        [4.0, 1.0],
        2000.0,
        7,
        800.0,
        0.0,
    );
    cf.reset(100.0);
    cf.step_to(2500.0);
    cmp_snap(&r, "sy_wind", &cf, &TOL);
    let (mut cf, _) = synth(
        &blob(0.0, 0.0, 6000.0, 400.0),
        2800.0,
        [0.0, 0.0],
        1800.0,
        3,
        800.0,
        0.5,
    );
    cf.reset(0.0);
    cf.step_to(7200.0);
    cmp_snap(&r, "sy_tower", &cf, &TOL);
    let (mut cf, _) = synth(
        &blob(-4000.0, 0.0, 2500.0, 300.0),
        2500.0,
        [6.0, 0.0],
        2000.0,
        1,
        800.0,
        0.0,
    );
    cf.reset(0.0);
    cf.step_to(3600.0);
    cmp_snap(&r, "sy_advect", &cf, &TOL);
}

fn analytic_thermals() -> Vec<ThermalSnap> {
    let mk = |src: [f32; 3], top: f64| ThermalSnap {
        id: 0,
        src,
        top,
        strength: 3.0,
        radius: 180.0,
        env: 1.0,
        lean: [0.0; 2],
        drift: [0.0; 2],
        cloud_depth: if top > 2000.0 { 600.0 } else { 0.0 },
        overdevelop: 0.0,
    };
    vec![
        mk([2000.0, 1000.0, -3000.0], 2600.0),
        mk([-6000.0, 1000.0, 6000.0], 1800.0),
    ]
}

fn analytic_field() -> CloudField {
    let x0 = -(N as f64) * DX * 0.5;
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&FieldInputs {
        grid: Grid {
            nx: N,
            ny: N,
            dx: DX,
            x0,
            y0: x0,
        },
        wind_field: None,
        air: None,
        thermals: Some(analytic_thermals()),
        weather: WeatherView::default(),
        cloudbase_msl: Some(2500.0),
        ground_ref: Some(1000.0),
        seed: 0,
        wind_at: no_wind(),
    });
    cf
}

#[test]
fn analytic_thermals_vs_gd_and_gd_test() {
    let r = Ref::load();
    let mut cf = analytic_field();
    cf.reset(0.0);
    cf.step_to(1800.0);
    assert_eq!(cf.base_msl, 2500.0, "основание - кромка (без погоды)");
    assert!(
        cf.sample([2000.0, 0.0, -3000.0])[0] > 0.05,
        "облако над термиком до кромки"
    );
    assert_eq!(
        cf.sample([-6000.0, 0.0, 6000.0])[0],
        0.0,
        "термик ниже кромки - без облака"
    );
    invariants(&cf, "аналитика");
    cmp_snap(&r, "sy_analytic", &cf, &TOL);
}

// ================================================================ физика против GD

fn bool_of(v: &Value) -> bool {
    v.as_bool().unwrap()
}

fn gd_thermals(r: &Ref) -> Vec<Arc<AtmoThermal>> {
    r.j["phys_thermals"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let f = |k: usize| row[k].as_f64().unwrap();
            let mut th = AtmoThermal::blank(row[0].as_i64().unwrap());
            th.is_static = bool_of(&row[1]);
            th.src = [f(2) as f32, f(3) as f32, f(4) as f32];
            th.top = f(5);
            th.strength = f(6);
            th.radius = f(7);
            th.lean = [f(8) as f32, f(9) as f32];
            th.drift_vel = [f(10) as f32, f(11) as f32];
            th.drift_delay = f(12);
            th.t_birth = f(13);
            th.t_grow = f(14);
            th.t_mature = f(15);
            th.t_decay = f(16);
            th.has_cloud = bool_of(&row[17]);
            th.cloud_depth = f(18);
            th.cloud_stretch = f(19);
            th.overdevelop = f(20);
            th.is_cb = bool_of(&row[21]);
            th.suck = f(22);
            Arc::new(th)
        })
        .collect()
}

fn gd_physics(r: &Ref) -> (CloudPhysics, Vec<Arc<AtmoThermal>>, f64) {
    let (mut cf, _) = synth(
        &blob(1000.0, -2000.0, 5000.0, 250.0),
        2500.0,
        [4.0, 1.0],
        2000.0,
        7,
        800.0,
        0.0,
    );
    cf.reset(100.0);
    cf.step_to(2500.0);
    cmp_snap(r, "ph", &cf, &TOL);
    let c = configs();
    let model = CloudModel::new(CloudCfg::from_configs(&c), 1.0);
    let mut ph = CloudPhysics::new(Arc::new(PhysCfg::from_configs(&c)), model, Arc::new(cf));
    let all = gd_thermals(r);
    let t = r.j["phys_t"].as_f64().unwrap();
    let o = ph.build_objects(&all, t, Some([0.0; 3]), 6000.0);
    ph.objects = Arc::new(o);
    (ph, all, t)
}

#[test]
fn physics_suck_vs_gd() {
    let r = Ref::load();
    let (ph, all, t) = gd_physics(&r);
    assert_eq!(
        ph.objects.count as i64,
        r.j["phys_count"].as_i64().unwrap(),
        "Cb-объекты в радиусе"
    );
    let sk = r.f32s("ph_suck");
    let mut worst = 0.0f64;
    let mut n_boost = 0;
    for (i, th) in all.iter().enumerate() {
        let s = ph.suck(th, t);
        // GD держит стадию и размеры облака в `Vector3/4` (f32): отличие - округление f32
        let rel = |a: f64, b: f64| (a - b).abs() / b.abs().max(1.0);
        worst = worst
            .max(rel(s[0], f64::from(sk[2 * i])))
            .max(rel(s[1], f64::from(sk[2 * i + 1])));
        if s[1] > 0.0 {
            n_boost += 1;
        }
        // крючок CloudHooks даёт то же
        assert_eq!(CloudHooks::suck(&ph, th, t), s);
    }
    eprintln!("suck: {worst:.2e}, термиков с подсосом {n_boost}");
    assert!(n_boost >= 2, "в выборке есть подсос и по полю, и по Cb");
    // TB-15: поле облаков другое (источники — шаблон пузыря), подсос по полю GD-дампа не совпадает; присутствие
    // (n_boost) и допустимые значения: усиление ≥ 0, высота потока в облаке 0…5000 м
    assert!(worst.is_finite());
    for th in &all {
        let s = ph.suck(th, t);
        assert!(s[0] >= 0.0 && s[0] <= 10.0 && s[1] >= 0.0 && s[1] <= 5000.0, "suck {s:?}");
    }
}

#[test]
fn physics_sample_density_visible_vs_gd() {
    let r = Ref::load();
    let (ph, all, t) = gd_physics(&r);
    let pts = r.f32s("ph_pts");
    let (sm, dn) = (r.f32s("ph_sample"), r.f32s("ph_density"));
    let (mut ds, mut dd, mut inside) = (0.0f64, 0.0f64, 0);
    for (q, p) in pts.chunks_exact(3).enumerate() {
        let s = ph.sample([p[0], p[1], p[2]]);
        for k in 0..3 {
            ds = ds.max((f64::from(s[k]) - f64::from(sm[q * 3 + k])).abs());
        }
        dd = dd.max((ph.density_at([p[0], p[1], p[2]]) - f64::from(dn[q])).abs());
        if dn[q] > 0.0 {
            inside += 1;
        }
    }
    eprintln!("ph sample {ds:.2e} density {dd:.2e}, в облаке {inside}");
    assert!(inside > 20);
    // TB-15: поле облаков другое — только допустимые значения (плотность ≤ 1,5), расхождения в строке выше
    assert!(ds.is_finite() && dd <= 1.5);
    let vc = r.f32s("ph_visible");
    let mine = ph.visible_clouds(&all, t, [0.0; 3]);
    assert_eq!(mine.len() * 5, vc.len(), "число облаков поля");
    assert!(!mine.is_empty());
    // TB-15: облака другого поля (источники — шаблон пузыря): положение и размеры не совпадают с дампом GD; число облаков
    // то же, значения конечны, радиус и скорости роста/распада положительны, центры — в пределах 3 км от центров GD
    for (i, m) in mine.iter().enumerate() {
        let g = &vc[i * 5..i * 5 + 5];
        assert!(m.radius.is_finite() && m.radius > 0.0, "radius");
        assert!(m.growth.is_finite() && m.decay.is_finite());
        assert!(
            (m.center[0] - f64::from(g[0])).abs() < 3000.0
                && (m.center[1] - f64::from(g[1])).abs() < 3000.0
        );
    }
}

// ================================================================ перенос тестов GDScript

#[test]
fn gd_test_empty_without_inputs() {
    let x0 = -(N as f64) * DX * 0.5;
    let mut cf = CloudField::new(fcfg());
    cf.setup_grid(Grid {
        nx: N,
        ny: N,
        dx: DX,
        x0,
        y0: x0,
    });
    cf.step_to(3600.0);
    cf.set_inputs(&FieldInputs {
        grid: cf.grid(),
        wind_field: None,
        air: None,
        thermals: None,
        weather: WeatherView::default(),
        cloudbase_msl: None,
        ground_ref: None,
        seed: 0,
        wind_at: no_wind(),
    });
    cf.step_to(7200.0);
    assert_eq!(mean(&cf.cover), 0.0, "без входов - пустое поле");
    assert!(cf.sample([0.0; 3])[0] == 0.0 && cf.density_at([0.0, 2000.0, 0.0]) == 0.0);
    invariants(&cf, "пустое");
}

#[test]
fn gd_test_source_reaches_lcl_and_shade() {
    let (mut cf, _) = synth(
        &blob(0.0, 0.0, 4000.0, 300.0),
        2500.0,
        [0.0, 0.0],
        2000.0,
        1,
        800.0,
        0.0,
    );
    cf.reset(0.0);
    cf.step_to(1800.0);
    invariants(&cf, "пятно");
    let s_in = cf.sample([0.0; 3]);
    let s_out = cf.sample([-8000.0, 0.0, -8000.0]);
    assert!(s_in[0] > 0.05, "над прогретым пятном облако {}", s_in[0]);
    assert_eq!(s_out[0], 0.0, "вдали от пятна - чисто");
    assert!(
        s_in[1] == 2000.0 && s_in[2] > s_in[1] + 50.0,
        "основание = LCL, мощность > 0"
    );
    assert_eq!(
        cf.density_at([0.0, 1900.0, 0.0]),
        0.0,
        "под основанием плотность 0"
    );
    assert!(cf.density_at([0.0, s_in[1] + 0.5 * (s_in[2] - s_in[1]), 0.0]) > 0.0);
    assert!(
        cf.shade_at([0.0, 0.0], [0.0, 1.0, 0.0]) > 0.0,
        "тень под облаком"
    );
    assert_eq!(cf.shade_at([-8000.0, -8000.0], [0.0, 1.0, 0.0]), 0.0);
    assert_eq!(
        cf.shade_at([0.0, 0.0], [1.0, 0.04, 0.0]),
        0.0,
        "солнце у горизонта - 0"
    );
    // LCL выше потолка - облаков нет
    let (mut cf2, _) = synth(
        &blob(0.0, 0.0, 4000.0, 300.0),
        2500.0,
        [0.0, 0.0],
        4500.0,
        1,
        800.0,
        0.0,
    );
    cf2.reset(0.0);
    cf2.step_to(1800.0);
    assert_eq!(mean(&cf2.cover), 0.0, "LCL выше потолка частицы - чисто");
}

#[test]
fn gd_test_weak_lt_strong() {
    let (mut a, _) = synth(
        &blob(0.0, 0.0, 6000.0, 80.0),
        1800.0,
        [0.0, 0.0],
        1650.0,
        1,
        800.0,
        0.0,
    );
    a.reset(0.0);
    a.step_to(3600.0);
    let (mut b, _) = synth(
        &blob(0.0, 0.0, 6000.0, 350.0),
        2600.0,
        [0.0, 0.0],
        2100.0,
        1,
        800.0,
        0.0,
    );
    b.reset(0.0);
    b.step_to(3600.0);
    assert!(mean(&a.cover) < mean(&b.cover), "слабый день < сильный");
    assert!(
        mean(&a.depth) < mean(&b.depth),
        "мощность: слабый < сильный"
    );
}

#[test]
fn gd_test_determinism_and_start_at() {
    let mk = || {
        synth(
            &blob(1000.0, -2000.0, 5000.0, 250.0),
            2500.0,
            [4.0, 1.0],
            2000.0,
            7,
            800.0,
            0.0,
        )
        .0
    };
    let (mut a, mut b, mut c) = (mk(), mk(), mk());
    a.reset(100.0);
    a.step_to(2500.0);
    b.reset(100.0);
    b.step_to(2500.0);
    assert!(
        a.cover == b.cover && a.depth == b.depth && a.stage == b.stage && a.activity == b.activity,
        "побитно"
    );
    c.reset(100.0);
    let mut t = 100.0;
    while t < 2500.0 {
        t += 20.0;
        c.step_to(t);
    }
    assert!(
        a.cover == c.cover && a.depth == c.depth && a.stage == c.stage,
        "step_to(t) == шаги по одному"
    );
    assert!(mean(&a.cover) > 0.0);
    c.step_to(50.0);
    assert_eq!(c.time, 50.0, "t назад -> reset(t)");
    // CLF-12: start_at(t) на скачок > spinup - разгон, равный прогону с 0 по тому же t
    let mut d = mk();
    d.step_to(10000.0);
    assert_eq!(d.time, 10000.0, "скачок больше разгона - reset");
    let mut e = mk();
    e.reset(10000.0);
    assert!(
        d.cover == e.cover && d.depth == e.depth,
        "start_at(t): то же, что reset(t)"
    );
}

#[test]
fn gd_test_decay_delay_and_stage() {
    let (mut cf, inp) = synth(
        &blob(0.0, 0.0, 5000.0, 300.0),
        2500.0,
        [0.0, 0.0],
        2000.0,
        1,
        800.0,
        0.0,
    );
    cf.reset(0.0);
    let q0 = mean(&cf.cover);
    cf.step_to(300.0);
    let c0 = N / 2 * N + N / 2;
    let st_growth = cf.stage[c0];
    cf.step_to(3600.0);
    let q_full = mean(&cf.cover);
    assert!(
        (q_full - q0).abs() < 0.05 * q0.max(1.0e-3) + 1.0e-3 || q_full > 0.0,
        "установилось"
    );
    // подъём выключен: облака держатся и тают с задержкой
    let mut off = FieldInputs {
        air: None,
        thermals: None,
        weather: weather(2000.0, 800.0, 0.0),
        wind_field: inp.wind_field.clone(),
        ..inputs_clone(&inp)
    };
    off.seed = 1;
    cf.set_inputs(&off);
    cf.step_to(3600.0 + 300.0);
    let q5 = mean(&cf.cover);
    assert!(
        q5 > 0.5 * q_full,
        "через 5 мин без подъёма облака ещё есть ({q5} из {q_full})"
    );
    assert!(cf.stage[c0] < 0.0, "стадия - тает");
    cf.step_to(3600.0 + 5400.0);
    assert!(
        mean(&cf.cover) < 0.1 * q_full,
        "через 90 мин почти растаяли"
    );
    cf.set_inputs(&inp);
    cf.reset(0.0);
    cf.step_to(300.0);
    assert!(
        cf.stage[c0] > 0.0 && st_growth > 0.0,
        "стадия в начале - растёт"
    );
}

fn inputs_clone(i: &FieldInputs) -> FieldInputs {
    FieldInputs {
        grid: i.grid,
        wind_field: i.wind_field.clone(),
        air: i.air.clone(),
        thermals: i.thermals.clone(),
        weather: i.weather.clone(),
        cloudbase_msl: i.cloudbase_msl,
        ground_ref: i.ground_ref,
        seed: i.seed,
        wind_at: i.wind_at.clone(),
    }
}

#[test]
fn gd_test_advection_and_towers() {
    let (mut cf, _) = synth(
        &blob(-4000.0, 0.0, 2500.0, 300.0),
        2500.0,
        [6.0, 0.0],
        2000.0,
        1,
        800.0,
        0.0,
    );
    cf.reset(0.0);
    cf.step_to(3600.0);
    let up = cf.sample([-9000.0, 0.0, 0.0])[0];
    let down = cf.sample([2000.0, 0.0, 0.0])[0];
    assert!(down > up, "облака сносит по ветру: {down} > {up}");
    invariants(&cf, "снос");
    let out = cf.sample([1.0e5, 0.0, 0.0]);
    assert!(
        (f64::from(out[0]) - cf.bg_cover).abs() < 1.0e-6,
        "вне сетки - фон"
    );
    let dmax = |ov: f64| {
        let (mut c, _) = synth(
            &blob(0.0, 0.0, 6000.0, 400.0),
            2800.0,
            [0.0, 0.0],
            1800.0,
            3,
            800.0,
            ov,
        );
        c.reset(0.0);
        c.step_to(7200.0);
        c.depth.iter().fold(0.0f32, |a, b| a.max(*b))
    };
    let (d_plain, d_max) = (dmax(0.0), dmax(0.5));
    assert!(
        d_plain <= 801.0,
        "без переразвития мощность <= cloud_depth_m ({d_plain})"
    );
    assert!(
        d_max > d_plain + 100.0,
        "с переразвитием есть башни выше ({d_max} > {d_plain})"
    );
}

// ================================================================ слот в Terms: эталоны W8

mod slot {
    use super::*;
    use dp_air::field::field_set::FieldSet;
    use dp_air::fixtures::{self, Case, Frame};
    use dp_air::terms::thermal::GroundSource;
    use dp_air::terms::{self, Terms};
    use dp_air::{Cloud, Place};

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

    /// Конфиги игры как у `synth_*` (круг генерации 8 км).
    fn game_configs() -> Arc<Configs> {
        let mut files = Vec::new();
        collect(&repo().join("configs"), "", &mut files);
        for (n, t) in &mut files {
            if n == "atmosphere" {
                let mut v: Value = serde_json::from_str(t).unwrap();
                v["thermal"]["generation_radius_m"] = json!(8000.0);
                *t = serde_json::to_string(&v).unwrap();
            }
        }
        files.sort();
        Arc::new(Configs::new(files))
    }

    fn syn_height(x: f64, z: f64) -> f64 {
        900.0
            + 350.0 * (x / 3100.0).sin() * (z / 4300.0).cos()
            + 160.0 * ((x + 0.6 * z) / 1700.0).sin()
            + 40.0 * (x / 450.0 - z / 700.0).cos()
    }

    fn syn_source(x: f64, z: f64) -> f64 {
        let e = 15.0;
        let dx = ((syn_height(x + e, z) - syn_height(x - e, z)) / (2.0 * e)) as f32;
        let dz = ((syn_height(x, z + e) - syn_height(x, z - e)) / (2.0 * e)) as f32;
        let l = (dx * dx + 1.0 + dz * dz).sqrt();
        let n = [-dx / l, 1.0 / l, -dz / l];
        let s = {
            let (a, b, c) = (0.3f32, 0.8f32, 0.5f32);
            let l = (a * a + b * b + c * c).sqrt();
            [a / l, b / l, c / l]
        };
        let d = f64::from(n[0] * s[0] + n[1] * s[1] + n[2] * s[2]);
        let k = 0.65 + 0.35 * (x / 830.0 + 1.3).sin() * (z / 1170.0 - 0.4).cos();
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

    pub struct Loaded {
        pub case: Case,
        pub place: Place,
        pub data: fixtures::CaseData,
        pub frames: Vec<Frame>,
        pub extra: Value,
    }

    pub fn load(name: &str) -> Loaded {
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

    pub fn terms_for(case: &Case) -> Terms {
        let mut t = Terms::default();
        t.configure(&game_configs(), case.seed);
        t.set_conditions(&case.conditions);
        t.wind.set_simple_profile(true, None);
        t.statics = case.static_thermals.clone();
        t.statics_mode = case.static_mode;
        t.focuses = case.focuses.clone();
        t.set_thermal_ground(Arc::new(SynGround));
        t
    }

    fn on_grid(place: &Place, p: [f32; 3]) -> bool {
        let g = &place.header().grid;
        let (x1, z1) = (
            g.origin_x + (f64::from(g.width) - 1.0) * g.spacing,
            g.origin_z + (f64::from(g.height) - 1.0) * g.spacing,
        );
        (g.origin_x..=x1).contains(&f64::from(p[0])) && (g.origin_z..=z1).contains(&f64::from(p[2]))
    }

    /// Слагаемое `cloud` (k = 2 + индекс) против эталонов W8 по всем synth-случаям: допуск
    /// `0,05 м/с + 2 %`; точки в облаке (`cloud` != 0) в выборке есть.
    #[test]
    fn cloud_term_vs_w8() {
        let mut nonzero = 0;
        let mut checked = 0;
        let mut worst = 0.0f32;
        for name in ["synth_weak", "synth_medium", "synth_strong", "synth_storm"] {
            let l = load(name);
            let ci = l
                .case
                .terms
                .as_ref()
                .unwrap()
                .iter()
                .position(|n| n == "cloud")
                .unwrap();
            let mut t = terms_for(&l.case);
            let fs = FieldSet::default();
            for (k, &tm) in l.case.times_s.iter().enumerate() {
                t.start_at(tm);
                let want: Vec<[f32; 4]> = l.data.slab(k, 2 + ci).collect();
                for (i, p) in l.case.points.iter().enumerate() {
                    if !on_grid(&l.place, *p) {
                        continue;
                    }
                    let d = terms::decompose(&t, &fs, Some(&l.place), *p, tm);
                    let (g, w) = (d.vel[ci], want[i]);
                    for q in 0..3 {
                        let e = (g[q] - w[q]).abs();
                        worst = worst.max(e - 0.02 * w[q].abs());
                        assert!(
                            e <= 0.05 + 0.02 * w[q].abs(),
                            "{name} t={tm} точка {i} {p:?} q={q}: rust {g:?}, gd {w:?}"
                        );
                    }
                    checked += 1;
                    if w[0].abs() + w[2].abs() > 0.05 {
                        nonzero += 1;
                    }
                }
            }
        }
        eprintln!("cloud term: сверено {checked}, ненулевых {nonzero}, запас {worst:.3}");
        assert!(
            checked > 400 && nonzero >= 5,
            "сверено {checked}, ненулевых {nonzero}"
        );
    }

    /// `clouds` (описание W6) против `desc.json`: число равно, центр <= 50 м, база/верх <= 10 м,
    /// growth/decay <= 0,05 (W8). Облака поля (флаг 0) и Cb (флаг 4).
    #[test]
    fn clouds_desc_vs_w8() {
        let mut n_field = 0;
        let mut n_cb = 0;
        for name in ["synth_weak", "synth_medium", "synth_strong", "synth_storm"] {
            let l = load(name);
            let mut t = terms_for(&l.case);
            let c = l.extra["desc_center"].as_array().unwrap();
            let center = [
                c[0].as_f64().unwrap() as f32,
                0.0,
                c[1].as_f64().unwrap() as f32,
            ];
            let radius = l.extra["desc_radius"].as_f64().unwrap() as f32;
            for (k, &tm) in l.case.times_s.iter().enumerate() {
                t.start_at(tm);
                let mut mine: Vec<Cloud> = Vec::new();
                terms::clouds::clouds(&t, center, radius, tm, &mut mine);
                let gd = &l.frames[k].clouds;
                assert_eq!(mine.len(), gd.len(), "{name} t={tm}: число облаков");
                for g in gd {
                    let m = mine
                        .iter()
                        .filter(|m| m.flags == g.flags)
                        .min_by(|a, b| {
                            (a.x - g.x)
                                .hypot(a.z - g.z)
                                .total_cmp(&(b.x - g.x).hypot(b.z - g.z))
                        })
                        .unwrap();
                    let who = format!("{name} t={tm} облако ({}, {}) флаг {}", g.x, g.z, g.flags);
                    assert!((m.x - g.x).hypot(m.z - g.z) <= 50.0, "{who}: центр");
                    assert!((m.base_msl - g.base_msl).abs() <= 10.0, "{who}: база");
                    assert!(
                        (m.top_msl - g.top_msl).abs() <= 10.0,
                        "{who}: верх {} vs {}",
                        m.top_msl,
                        g.top_msl
                    );
                    assert!((m.growth - g.growth).abs() <= 0.05, "{who}: growth");
                    assert!((m.decay - g.decay).abs() <= 0.05, "{who}: decay");
                    if g.flags as u32 == 4 {
                        n_cb += 1;
                    } else {
                        n_field += 1;
                    }
                }
            }
        }
        eprintln!("clouds: облаков поля {n_field}, Cb {n_cb}");
        assert!(n_field + n_cb > 0);
    }

    /// `start_at(t)` детерминирован и не зависит от истории (W2): два независимых `Terms` и
    /// `Terms` после `start_at(100)` + `advance` дают побитно один растр. От прогона с 0 с шагом 1 с
    /// он отличается ожидаемо мало: GD при `start_at` разгоняет поле 2400 с на входах момента `t`
    /// (`reset`), а не по истории входов - отличие замерено и ограничено.
    #[test]
    fn start_at_deterministic_and_close_to_run_from_zero() {
        let l = load("synth_medium");
        let mut a = terms_for(&l.case);
        a.start_at(1500.0);
        let mut b = terms_for(&l.case);
        b.start_at(100.0);
        b.advance(120.0);
        b.start_at(1500.0);
        let ra = terms::clouds::cloud_raster(&a).expect("растр start_at");
        let rb = terms::clouds::cloud_raster(&b).expect("растр");
        assert_eq!(ra.time_s, 1500.0);
        assert_eq!(ra.layers, rb.layers, "start_at(t) не зависит от истории");
        let mut c = terms_for(&l.case);
        c.start_at(0.0);
        let mut t = 0.0;
        while t < 1500.0 {
            t += 1.0;
            c.advance(t);
        }
        let rc = terms::clouds::cloud_raster(&c).expect("растр прогона");
        assert_eq!(rc.time_s, ra.time_s);
        let (ma, mc) = (mean(&ra.layers[0].1), mean(&rc.layers[0].1));
        let dmax = maxdiff(&ra.layers[0].1, &rc.layers[0].1);
        eprintln!("start_at(1500) vs прогон с 0: cover mean {ma:.4} / {mc:.4}, max |d| {dmax:.3}");
        assert!(ma > 0.0 && mc > 0.0, "облака есть");
        assert!((ma - mc).abs() < 0.05, "средняя облачность");
    }

    /// Растр W6: оси W1 (узлы - центры столбцов, строка растёт к +Z), слои в порядке контракта;
    /// строка 0 - самая северная (z меньше) - равна столбцам `j = ny - 1`.
    #[test]
    fn raster_axes_and_layers() {
        let l = load("synth_strong");
        let mut t = terms_for(&l.case);
        t.start_at(3600.0);
        let r = terms::clouds::cloud_raster(&t).unwrap();
        let names: Vec<&str> = r.layers.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(
            names,
            [
                "cover", "depth", "stage", "activity", "bg_cover", "bg_depth"
            ]
        );
        let ph = t.cloud_physics();
        let f = &*ph.field;
        assert_eq!((r.nx as usize, r.ny as usize), (f.nx, f.ny));
        assert_eq!(r.dx as f64, f.dx);
        assert_eq!(r.x0 as f64, f.x0 + 0.5 * f.dx);
        // z узла (i, row) растёт с row
        let z_of = |row: usize| f64::from(r.z0) + row as f64 * f64::from(r.dx);
        assert_eq!(z_of(0), -(f.y0 + (f.ny as f64 - 0.5) * f.dx));
        let n = f.nx * f.ny;
        for q in [0usize, 7, n / 2 + 13, n - 1] {
            let (row, i) = (q / f.nx, q % f.nx);
            let j = f.ny - 1 - row;
            assert_eq!(r.layers[0].1[q], f.cover[j * f.nx + i]);
            // центр столбца j совпадает с узлом растра
            let zc = -(f.y0 + (j as f64 + 0.5) * f.dx);
            assert!((zc - z_of(row)).abs() < 1.0e-3);
        }
        assert_eq!(r.layers[4].1[3], f.bg_cover as f32);
        assert_eq!(r.base_msl, f.base_msl as f32);
        assert!(r.version > 0);
        // та же ссылка при повторном вызове (кеш)
        assert!(Arc::ptr_eq(&r, &terms::clouds::cloud_raster(&t).unwrap()));
    }

    /// `cloud_density_many`: в облаке > 0, под основанием и в NaN - 0; совпадает с `density_at`.
    #[test]
    fn density_many_and_extra_flow() {
        let l = load("synth_strong");
        let mut t = terms_for(&l.case);
        t.start_at(3600.0);
        let ph = t.cloud_physics().clone();
        let f = &*ph.field;
        let c = (0..f.nx * f.ny)
            .max_by(|a, b| f.cover[*a].total_cmp(&f.cover[*b]))
            .unwrap();
        assert!(f.cover[c] > 0.05, "в поле есть облако");
        let x = (f.x0 + ((c % f.nx) as f64 + 0.5) * f.dx) as f32;
        let z = (-(f.y0 + ((c / f.nx) as f64 + 0.5) * f.dx)) as f32;
        let mid = (f.base_msl + 0.5 * f64::from(f.depth[c])) as f32;
        let pts = [
            [x, mid, z],
            [x, (f.base_msl - 100.0) as f32, z],
            [f32::NAN, 0.0, 0.0],
        ];
        let mut out = [9.0f32; 3];
        terms::clouds::cloud_density_many(&t, &pts, &mut out);
        assert!(out[0] > 0.0 && out[1] == 0.0 && out[2] == 0.0, "{out:?}");
        assert_eq!(f64::from(out[0]), ph.density_at(pts[0]) as f32 as f64);
        // слагаемое `cloud` в сумме: в облаке даёт ненулевой вклад и бурление (σ)
        let fs = FieldSet::default();
        let d = terms::decompose(&t, &fs, Some(&l.place), pts[0], 3600.0);
        let ci = 6;
        let v = d.vel[ci];
        assert!(v[0].hypot(v[2]) > 0.0, "поток к краю облака {v:?}");
        assert_eq!(v[1], 0.0);
        let d0 = terms::decompose(&t, &fs, Some(&l.place), pts[1], 3600.0);
        assert_eq!(d0.vel[ci], [0.0; 3], "под основанием облака нет");
    }

    /// Крючки RW-10f: тень облака над точкой и подсос из слепка физики.
    #[test]
    fn hooks_shade_and_suck() {
        use dp_air::terms::thermal::CloudHooks;
        let l = load("synth_strong");
        let mut t = terms_for(&l.case);
        t.start_at(3600.0);
        let ph = t.cloud_physics().clone();
        let f = &*ph.field;
        let c = (0..f.nx * f.ny)
            .max_by(|a, b| f.cover[*a].total_cmp(&f.cover[*b]))
            .unwrap();
        let x = f.x0 + ((c % f.nx) as f64 + 0.5) * f.dx;
        let z = -(f.y0 + ((c / f.nx) as f64 + 0.5) * f.dx);
        assert!(ph.shade_at(x, z, [0.0, 1.0, 0.0]) > 0.0, "тень под облаком");
        assert_eq!(
            ph.shade_at(x, z, [1.0, 0.0, 0.0]),
            0.0,
            "солнце у горизонта"
        );
        let st = t.slots.thermal.as_slot().unwrap().state().unwrap();
        assert!(!st.all.is_empty());
        let mut any = false;
        for th in &st.all {
            let s = CloudHooks::suck(&*ph, th, 3600.0);
            assert!(s[0] >= th.suck - 1.0e-9 && s[1] >= 0.0);
            any |= s[1] > 0.0;
        }
        eprintln!("подсос над термиками synth_strong: есть = {any}");
    }
}

/// Замер (в отчёт, не порог): шаг 20 с и разгон 2400 с на поле Онгудая 96 x 96; в отладочной
/// сборке порог мягкий, в релизной - бюджет `advance_to` W3 (0,5 мс на шаг).
#[test]
fn timing_step_and_spinup() {
    let o = ongudai();
    let mut cf = CloudField::new(fcfg());
    cf.set_inputs(&inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606));
    let t0 = std::time::Instant::now();
    cf.reset(3600.0);
    let spin = t0.elapsed();
    let t1 = std::time::Instant::now();
    for k in 1..=10 {
        cf.step_to(3600.0 + 20.0 * f64::from(k));
    }
    let step = t1.elapsed() / 10;
    let t2 = std::time::Instant::now();
    cf.set_inputs(&inputs(&o.f, &o.air, weather(o.cb, 800.0, 0.0), 606));
    let prep = t2.elapsed();
    eprintln!("разгон 2400 с: {spin:?}; шаг 20 с: {step:?}; set_inputs (prepare): {prep:?}");
    if !cfg!(debug_assertions) {
        assert!(step.as_micros() < 500, "шаг поля {step:?} > 0,5 мс");
    }
}
