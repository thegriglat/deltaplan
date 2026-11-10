//! RW-10d: источники термиков из поля (`terms::thermal_air`, перенос `AirThermals` GDScript).
//!
//! Две группы:
//! - **против дампа GD** (`tests/data/RW-10d/`, опорная ревизия `c591b1026`, `ongudai_medium`): крейт
//!   строит источники из того же поля (запечённое TI-К3 f16, `field::solved::parse_solved`), что и GD
//!   в дампе; сила источника (`pick_in_column`) и вода (`land_fraction`) берутся из журнала вызовов
//!   GD по точкам — любое расхождение RNG или порядка вызовов даёт промах таблицы, а не тихую
//!   подмену;
//! - **перенос тестов GDScript** `test_air_thermals.gd` (без частей, где нужна атмосфера),
//!   `test_air_thermals_parallel.gd`, `test_air_thermals_relief.gd`, `test_subsidence.gd` (без
//!   части с `CloudField`) на синтетическом поле.
use dp_air::field::solved::parse_solved;
use dp_air::field::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use dp_air::rand::Pcg32;
use dp_air::terms::thermal_air::{
    AirThermals, AirThermalsCfg, BuildIn, FillWeather, K_ALLEN, PickGround, ZI_MIN, allen_r2,
    has_inputs, land_fraction, pick_in_column,
};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn atmosphere_thermal() -> Value {
    let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
    let v: Value = serde_json::from_str(&t).unwrap();
    v["thermal"].clone()
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
    fn load(case: &str) -> Ref {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/data/RW-10d")
            .join(case);
        let j: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("ref.json")).unwrap()).unwrap();
        let raw = std::fs::read(dir.join("ref.bin")).unwrap();
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
    fn i32s(&self, name: &str) -> Vec<i32> {
        self.seg(name, 4)
            .chunks_exact(4)
            .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect()
    }
    fn u8s(&self, name: &str) -> Vec<u8> {
        self.seg(name, 1).to_vec()
    }
    fn num(&self, k: &str) -> f64 {
        self.j[k].as_f64().unwrap()
    }
}

struct Case {
    r: Ref,
    field: Field,
    cfg: AirThermalsCfg,
    u10: f64,
    seed: u64,
}

fn load_case(name: &str) -> Case {
    let r = Ref::load(name);
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/RW-10d")
        .join(name);
    let hdr = std::fs::read_to_string(dir.join("field.json")).unwrap();
    let bin = std::fs::read(dir.join("field.bin")).unwrap();
    let mut b = parse_solved(&hdr, &bin).unwrap();
    let mut field = b.levels.remove(0);
    field.edge_cells = r.num("edge_cells");
    let cfg =
        AirThermalsCfg::from_thermal(&r.j["thermal_cfg"], r.num("duty"), r.num("cloudbase_msl"));
    Case {
        u10: r.num("u10"),
        seed: r.j["seed"].as_i64().unwrap() as u64,
        r,
        field,
        cfg,
    }
}

/// Сила источника и вода по журналу вызовов GD: ключ — `(f32 x, f32 z)`. Промах — паника.
struct LogGround {
    t: HashMap<(u32, u32), (f64, u8)>,
}

impl LogGround {
    fn new(r: &Ref) -> Self {
        let (x, z, s, w) = (
            r.f32s("pl_x"),
            r.f32s("pl_z"),
            r.f64s("pl_s"),
            r.u8s("pl_w"),
        );
        let mut t = HashMap::new();
        for q in 0..x.len() {
            t.insert((x[q].to_bits(), z[q].to_bits()), (s[q], w[q]));
        }
        LogGround { t }
    }
    fn get(&self, x: f64, z: f64) -> (f64, u8) {
        *self
            .t
            .get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .unwrap_or_else(|| panic!("в журнале GD нет вызова sun({x}, {z}) — RNG разошёлся"))
    }
}

impl PickGround for LogGround {
    fn sun(&self, x: f64, z: f64) -> f64 {
        self.get(x, z).0
    }
    fn is_water(&self, x: f64, z: f64) -> bool {
        let w = self.get(x, z).1;
        assert!(w != 2, "GD не спрашивал воду в ({x}, {z})");
        w == 1
    }
}

fn water_log(r: &Ref) -> HashMap<(u32, u32), bool> {
    let (x, z, w) = (r.f32s("wl_x"), r.f32s("wl_z"), r.u8s("wl_w"));
    (0..x.len())
        .map(|q| ((x[q].to_bits(), z[q].to_bits()), w[q] == 1))
        .collect()
}

fn rel(a: f64, b: f64) -> f64 {
    (a - b).abs() / b.abs().max(1.0e-12)
}

fn max_rel(a: &[f32], b: &[f32]) -> f64 {
    assert_eq!(a.len(), b.len());
    let mut m = 0.0f64;
    for (x, y) in a.iter().zip(b) {
        if x.is_nan() && y.is_nan() {
            continue;
        }
        m = m.max(rel(*x as f64, *y as f64).min((*x as f64 - *y as f64).abs() / 1.0e-3));
    }
    m
}

fn flat3(v: &[[f32; 3]]) -> Vec<f32> {
    v.iter().flatten().copied().collect()
}
fn flat2(v: &[[f32; 2]]) -> Vec<f32> {
    v.iter().flatten().copied().collect()
}

/// Сборка по случаю дампа: сила — из журнала, высота — из `pos.y` дампа (по точке), вода — из журнала.
fn build_case(c: &Case, bands: usize, with_land: bool) -> AirThermals {
    let g = LogGround::new(&c.r);
    let grid = *c.field.grid();
    let seed = c.seed;
    let cands = c.cfg.source_candidates;
    let pick = move |i: usize, j: usize| pick_in_column(i, j, &grid, Some(&g), seed, cands);
    let pos = c.r.f32s("pos");
    let hmap: HashMap<(u32, u32), f64> = (0..pos.len() / 3)
        .map(|s| {
            (
                (pos[3 * s].to_bits(), pos[3 * s + 2].to_bits()),
                pos[3 * s + 1] as f64,
            )
        })
        .collect();
    let height = move |x: f64, z: f64| -> f64 {
        *hmap
            .get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .unwrap_or_else(|| panic!("высоты нет в дампе: ({x}, {z})"))
    };
    let wl = water_log(&c.r);
    let water = move |x: f64, z: f64| -> bool {
        *wl.get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .unwrap_or_else(|| panic!("в журнале воды GD нет ({x}, {z})"))
    };
    let mut inp = BuildIn::new(&c.cfg, c.u10);
    inp.pick_fn = Some(&pick);
    inp.height_fn = Some(&height);
    if with_land {
        inp.water_fn = Some(&water);
    }
    inp.bands = bands;
    AirThermals::build(&c.field, &inp).expect("build")
}

#[test]
fn sources_match_gd_dump() {
    let c = load_case("ongudai_medium");
    assert!(has_inputs(&c.field), "в запечённом поле есть H, z_i, gam");
    let s = build_case(&c, 0, true);
    let r = &c.r;
    // число и столбцы источников — точно
    let col: Vec<i32> = s.col.iter().map(|&x| x as i32).collect();
    assert_eq!(s.count(), r.num("count") as usize, "число источников");
    assert_eq!(col, r.i32s("col"), "столбцы источников");
    // точка источника: x, z — побитно (RNG и f32), y — из дампа
    assert_eq!(flat3(&s.pos), r.f32s("pos"), "точки источников побитно");
    assert_eq!(s.owner, r.i32s("owner"), "водосборы по столбцам");
    // доля суши — побитно
    assert_eq!(s.land, r.f32s("land"), "доля суши");
    // величины по источникам и столбцам: относительное расхождение
    let checks: Vec<(&str, f64)> = vec![
        ("w0", max_rel(&s.w0, &r.f32s("w0"))),
        ("radius", max_rel(&s.radius, &r.f32s("radius"))),
        ("wstar", max_rel(&s.wstar, &r.f32s("wstar"))),
        ("top", max_rel(&s.top, &r.f32s("top"))),
        ("flux", max_rel(&s.flux, &r.f32s("flux"))),
        // TB-15: K̄ — шаблона пузыря (bubble_kbar), а не профиля Гедеона, как в дампе GD: `carried` и `net` другие;
        // org = net/carried (доля организованного потока, не зависит от K̄) совпадает с дампом
        ("net/carried", max_rel(
            &s.net.iter().zip(&s.carried).map(|(n, c)| n / c).collect::<Vec<f32>>(),
            &r.f32s("net").iter().zip(&r.f32s("carried")).map(|(n, c)| n / c).collect::<Vec<f32>>(),
        )),
        ("ring", max_rel(&s.ring, &r.f32s("ring"))),
        ("area", max_rel(&s.area, &r.f32s("area"))),
        ("depth", max_rel(&s.depth, &r.f32s("depth"))),
        ("drift", max_rel(&flat2(&s.drift), &r.f32s("drift"))),
        ("phi", max_rel(&s.phi, &r.f32s("phi"))),
        ("col_heat", max_rel(&s.col_heat, &r.f32s("col_heat"))),
        ("col_w", max_rel(&s.col_w, &r.f32s("col_w"))),
        ("col_f", max_rel(&s.col_f, &r.f32s("col_f"))),
        ("c_top", max_rel(&s.c_top, &r.f32s("c_top"))),
        ("col_wstar", max_rel(&s.col_wstar, &r.f32s("col_wstar"))),
        ("col_wm", max_rel(&s.col_wm, &r.f32s("col_wm"))),
        ("col_zi", max_rel(&s.col_zi, &r.f32s("col_zi"))),
        ("col_sub", max_rel(&s.col_sub, &r.f32s("col_sub"))),
    ];
    // K̄ шаблона против K̄ Гедеона: carried_новый / carried_GD по источникам — печать и границы (0,1…10)
    let (cn, cg) = (&s.carried, r.f32s("carried"));
    let mut ratio: Vec<f64> = cn.iter().zip(&cg).map(|(a, b)| f64::from(*a) / f64::from(*b)).collect();
    ratio.sort_by(f64::total_cmp);
    println!("    carried шаблон/GD: мин {:.2} медиана {:.2} макс {:.2}", ratio[0], ratio[ratio.len() / 2], ratio[ratio.len() - 1]);
    assert!(ratio[0] > 0.1 && ratio[ratio.len() - 1] < 10.0, "carried шаблона и GD слишком разные");
    let mut worst = ("", 0.0f64);
    for (n, d) in &checks {
        println!("    {n}: max отн. расхождение {d:.3e}");
        if *d > worst.1 {
            worst = (n, *d);
        }
    }
    assert!(
        worst.1 < 1.0e-5,
        "расхождение {} = {:.3e} (допуск 1e-5)",
        worst.0,
        worst.1
    );
    // скаляры
    // TB-15: shape_area = e⁻¹·π·q_mean, q — таблица шаблона со средним 1 (в дампе GD — профиль Гедеона, 0,805)
    assert!((s.shape_area - std::f64::consts::PI / std::f64::consts::E).abs() < 1.0e-5, "shape_area {}", s.shape_area);
    let sc = &r.j["scalars"];
    // поток, который несут ядра, — K̄ шаблона (TB-15): порядок тот же (0,3…3 от GD)
    let cr = s.carried_flux / sc["carried_flux"].as_f64().unwrap();
    println!("    carried_flux шаблон/GD: {cr:.2}");
    assert!(cr > 0.3 && cr < 3.0, "carried_flux {cr}");
    for (n, v) in [
        ("life_mean", s.life_mean),
        ("alive_frac", s.alive_frac),
        ("phi_ref", s.phi_ref),
        ("lost_flux", s.lost_flux),
        ("total_flux", s.total_flux),
    ] {
        let want = sc[n].as_f64().unwrap();
        println!("    {n}: {v} против {want} ({:.3e})", rel(v, want));
        assert!(rel(v, want) < 1.0e-6, "{n}: {v} ≠ {want}");
    }
}

#[test]
fn pick_in_column_matches_gd_dump() {
    let c = load_case("ongudai_medium");
    let g = LogGround::new(&c.r);
    let cols = c.r.i32s("pick_cols");
    let xz = c.r.f32s("pick_xz");
    let grid = *c.field.grid();
    let mut none = 0;
    for (k, &col) in cols.iter().enumerate() {
        let (i, j) = (col as usize % grid.nx, col as usize / grid.nx);
        let p = pick_in_column(i, j, &grid, Some(&g), c.seed, c.cfg.source_candidates);
        let want = [xz[2 * k], xz[2 * k + 1]];
        match p {
            Some(p) => assert_eq!(p, want, "столбец ({i}, {j})"),
            None => {
                none += 1;
                assert!(want[0].is_infinite() && want[1].is_infinite(), "({i}, {j})");
            }
        }
    }
    println!(
        "    столбцов проверено {}, без источника {}",
        cols.len(),
        none
    );
    assert!(cols.len() > 1000);
}

#[test]
fn land_fraction_matches_gd_dump() {
    let c = load_case("ongudai_medium");
    let wl = water_log(&c.r);
    let water = move |x: f64, z: f64| -> bool {
        *wl.get(&((x as f32).to_bits(), (z as f32).to_bits()))
            .unwrap_or_else(|| panic!("в журнале воды GD нет ({x}, {z})"))
    };
    let land = land_fraction(&c.field, &water);
    let want = c.r.f32s("land");
    assert_eq!(land, want, "доля суши побитно");
    let coast = land.iter().filter(|&&x| x > 0.0 && x < 1.0).count();
    let sea = land.iter().filter(|&&x| x == 0.0).count();
    println!(
        "    столбцов: берег {coast}, вода {sea}, всего {}",
        land.len()
    );
}

fn bits_dump(s: &AirThermals) -> Vec<Vec<u32>> {
    let f = |v: &[f32]| v.iter().map(|x| x.to_bits()).collect::<Vec<u32>>();
    vec![
        s.col.iter().map(|&x| x as u32).collect(),
        f(&flat3(&s.pos)),
        f(&s.w0),
        f(&s.radius),
        f(&s.wstar),
        f(&s.top),
        f(&flat2(&s.drift)),
        f(&s.flux),
        f(&s.carried),
        f(&s.net),
        f(&s.ring),
        f(&s.area),
        f(&s.depth),
        s.owner.iter().map(|&x| x as u32).collect(),
        f(&s.phi),
        f(&s.col_heat),
        f(&s.col_w),
        f(&s.col_f),
        f(&s.c_top),
        f(&s.col_wstar),
        f(&s.col_wm),
        f(&s.col_zi),
        f(&s.col_sub),
        f(&s.land),
        vec![
            s.phi_ref.to_bits() as u32,
            (s.phi_ref.to_bits() >> 32) as u32,
            s.lost_flux.to_bits() as u32,
            s.total_flux.to_bits() as u32,
            s.carried_flux.to_bits() as u32,
        ],
        s.mask_bytes().iter().map(|&x| x as u32).collect(),
    ]
}

#[test]
fn parallel_equals_sequential_bitwise_on_dump_field() {
    let c = load_case("ongudai_medium");
    let one = bits_dump(&build_case(&c, 1, true));
    for nb in [2, 7, 0, 1000] {
        let got = bits_dump(&build_case(&c, nb, true));
        let bad: Vec<usize> = (0..one.len()).filter(|&k| one[k] != got[k]).collect();
        assert!(bad.is_empty(), "полос {nb}: выходы № {bad:?} расходятся");
    }
}

#[test]
fn expected_flux_consistent_on_dump_field() {
    // Среднее по высоте над источником от expected_up в столбце водосбора = carried/area
    // (профиль q нормирован на среднее): проверка таблицы формы и масштабов по столбцам.
    let c = load_case("ongudai_medium");
    let s = build_case(&c, 0, true);
    let g = *c.field.grid();
    let hc = c.field.raw_hc();
    let mut checked = 0;
    for (k, &col) in s.col.iter().enumerate().step_by(37) {
        let (i, j) = (col % g.nx, col / g.nx);
        let x = (g.x0 + (i as f64 + 0.5) * g.dx) as f32;
        let z = (-(g.y0 + (j as f64 + 0.5) * g.dx)) as f32;
        let d = s.depth[k] as f64;
        let n = 400;
        let (mut su, mut sn) = (0.0, 0.0);
        for q in 0..n {
            let y = (hc[col] as f64 + (q as f64 + 0.5) / n as f64 * d) as f32;
            su += s.expected_up([x, y, z]);
            sn += s.expected_net([x, y, z]);
        }
        let want_u = s.carried[k] as f64 / (s.area[k] as f64).max(1.0);
        let want_n = s.net[k] as f64 / (s.area[k] as f64).max(1.0);
        if want_u > 1.0e-6 {
            assert!(
                rel(su / n as f64, want_u) < 0.03,
                "источник {k}: среднее expected_up {} против {want_u}",
                su / n as f64
            );
            assert!(rel(sn / n as f64, want_n) < 0.03 || want_n < 1.0e-6);
            checked += 1;
        }
    }
    assert!(checked > 20, "проверено столбцов {checked}");
    // вне поля и вне столба — ноль
    assert_eq!(s.expected_net([1.0e9, 3000.0, 0.0]), 0.0);
    let c0 = s.col[0];
    let (i, j) = (c0 % g.nx, c0 / g.nx);
    let x = (g.x0 + (i as f64 + 0.5) * g.dx) as f32;
    let z = (-(g.y0 + (j as f64 + 0.5) * g.dx)) as f32;
    assert_eq!(s.expected_up([x, hc[c0] - 5.0, z]), 0.0, "под землёй");
    assert_eq!(s.expected_up([x, hc[c0] + 1.0e5, z]), 0.0, "выше столба");
}

// ================================================================ синтетика (перенос GD-тестов)

const N: usize = 48;
const NZ: usize = 60;
const DX: f64 = 100.0;
const DZ: f64 = 50.0;
const GROUND: f64 = 1000.0;
const Z_BOT: f64 = 950.0;

type Fn2 = dyn Fn(f64, f64) -> f64 + Sync;
type Fn3 = dyn Fn(f64, f64, f64) -> f64;

/// Синтетическое поле (`_flat`): ровная земля `GROUND`, сетка N × N × NZ (−2,4…2,4 км), `heat_fn(x, z)`,
/// `wconv_fn(x, z, agl)`, ветер, θ′(agl); фон — нейтральный до z_i, выше `gam_above`. Второе — u10.
fn flat(
    heat_fn: &Fn2,
    wconv_fn: &Fn3,
    z_i: f64,
    gam_above: f64,
    wind: [f64; 2],
    theta_fn: Option<&dyn Fn(f64) -> f64>,
) -> (Field, f64) {
    let (x0, y0) = (-(N as f64) * DX * 0.5, -(N as f64) * DX * 0.5);
    let grid = FieldGrid {
        dx: DX,
        dz: DZ,
        x0,
        y0,
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
                gam_above as f32
            }
        })
        .collect();
    let n = N * N * NZ;
    let (mut u, mut v, wm) = (vec![0f32; n], vec![0f32; n], vec![0f32; n]);
    let (mut wc, mut th) = (vec![0f32; n], vec![0f32; n]);
    let mut heat = vec![0f32; N * N];
    for j in 0..N {
        for i in 0..N {
            let x = x0 + (i as f64 + 0.5) * DX;
            let zw = -(y0 + (j as f64 + 0.5) * DX);
            heat[j * N + i] = heat_fn(x, zw) as f32;
            for k in 0..NZ {
                let c = (k * N + j) * N + i;
                let agl = Z_BOT + (k as f64 + 0.5) * DZ - GROUND;
                u[c] = wind[0] as f32;
                v[c] = wind[1] as f32;
                wc[c] = if agl > 0.0 {
                    wconv_fn(x, zw, agl) as f32
                } else {
                    0.0
                };
                th[c] = theta_fn.map_or(0.0, |f| f(agl) as f32);
            }
        }
    }
    let meta = FieldMeta {
        z0: Z0::Uniform(0.1),
        gam,
        heat,
        z_i,
        z_i_col: Vec::new(),
    };
    let f = Field::from_arrays(
        &grid,
        u,
        v,
        wm,
        wc,
        th,
        vec![GROUND as f32; N * N],
        meta,
        Limits::default(),
    )
    .unwrap();
    (f, (wind[0].hypot(wind[1])) / 1.8)
}

fn cfg_t(cb: f64) -> AirThermalsCfg {
    AirThermalsCfg::from_thermal(&atmosphere_thermal(), medium_duty(), cb)
}

fn sun_half(x: f64, _z: f64) -> f64 {
    if x < 0.0 { 300.0 } else { -30.0 }
}
/// Полоса схождения на x = −1200 м, σ = 250 м.
fn conv_line(x: f64, _z: f64, agl: f64) -> f64 {
    let zeta = (agl / 1500.0).clamp(0.0, 1.0);
    0.6 * (-((x + 1200.0) / 250.0).powi(2)).exp() * (std::f64::consts::PI * zeta).sin()
}
fn zero3(_x: f64, _z: f64, _a: f64) -> f64 {
    0.0
}
fn heat300(_x: f64, _z: f64) -> f64 {
    300.0
}
fn heat_var(x: f64, z: f64) -> f64 {
    120.0 + 200.0 * (0.5 + 0.5 * (x * 0.0021 + 0.7).sin() * (z * 0.0017).cos())
}
fn is_line(x: f64) -> bool {
    (x + 1200.0).abs() < 300.0
}
fn is_sun(x: f64) -> bool {
    x < -300.0 && (x + 1200.0).abs() > 600.0
}

fn build(f: &Field, u10: f64, cfg: &AirThermalsCfg) -> AirThermals {
    AirThermals::build(f, &BuildIn::new(cfg, u10)).expect("build")
}

struct FnGround<'a> {
    sun: &'a Fn2,
    water: &'a (dyn Fn(f64, f64) -> bool + Sync),
}
impl PickGround for FnGround<'_> {
    fn sun(&self, x: f64, z: f64) -> f64 {
        (self.sun)(x, z)
    }
    fn is_water(&self, x: f64, z: f64) -> bool {
        (self.water)(x, z)
    }
}

#[test]
fn sources_sunny_convergence_not_shade() {
    let (f, u10) = flat(&sun_half, &conv_line, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_t(1.0e9));
    let (mut n_shade, mut n_line, mut n_sun) = (0, 0, 0);
    let mut near_line = false;
    for k in 0..s.count() {
        let x = s.pos[k][0] as f64;
        if x >= 0.0 {
            n_shade += 1;
        } else if is_line(x) {
            n_line += 1;
            near_line |= (x + 1200.0).abs() <= 150.0;
        } else if is_sun(x) {
            n_sun += 1;
        }
    }
    // площади классов — столбцы внутри поля (вес ≥ ½)
    let g = *f.grid();
    let (mut a_line, mut a_sun) = (0.0, 0.0);
    for j in 0..N {
        for i in 0..N {
            let x = g.x0 + (i as f64 + 0.5) * DX;
            let ctr = [
                x as f32,
                (GROUND + 10.0) as f32,
                (-(g.y0 + (j as f64 + 0.5) * DX)) as f32,
            ];
            if f.edge_weight(ctr) < 0.5 {
                continue;
            }
            if is_line(x) {
                a_line += DX * DX * 1.0e-6;
            }
            if is_sun(x) {
                a_sun += DX * DX * 1.0e-6;
            }
        }
    }
    let d_line = n_line as f64 / a_line.max(1e-6);
    let d_sun = n_sun as f64 / a_sun.max(1e-6);
    println!(
        "    источников {}: в тени {n_shade}, в схождении {n_line} ({d_line:.1}/км²), на солнце {n_sun} ({d_sun:.1}/км²)",
        s.count()
    );
    assert_eq!(n_shade, 0, "в тени (H < 0) источников нет");
    assert!(n_sun > 0, "на прогретой равнине источники есть");
    assert!(near_line, "источник на оси схождения (±150 м)");
    assert!(
        d_line > 1.5 * d_sun,
        "в схождении источники гуще (Φ больше)"
    );
    let ws = s.wstar[0] as f64;
    let (mut kmin, mut kmax) = (f64::INFINITY, 0.0f64);
    for k in 0..s.count() {
        let r = s.w0[k] as f64 / s.wstar[k] as f64;
        kmin = kmin.min(r);
        kmax = kmax.max(r);
    }
    assert!(ws > 1.5 && ws < 3.0, "w* в разумных пределах ({ws:.2})");
    assert!(
        (kmin - K_ALLEN).abs() < 1e-3 && (kmax - K_ALLEN).abs() < 1e-3,
        "сила пузыря = k·w* ({kmin:.3}…{kmax:.3})"
    );
    let r_allen = allen_r2(1.0, s.top[0] as f64 - GROUND);
    assert!(
        (s.radius[0] as f64 - r_allen).abs() < 1.0,
        "радиус ядра — Аллен"
    );
}

#[test]
fn no_source_over_water_and_warm_sea() {
    // вода: сила 0 во всех кандидатах востока — столбец не источник
    let sun_east0 = |x: f64, _z: f64| if x >= 0.0 { 0.0 } else { 1.0 };
    let no_water = |_x: f64, _z: f64| false;
    let (f, u10) = flat(&heat300, &zero3, 2500.0, 0.0058, [0.0, 0.0], None);
    let g = FnGround {
        sun: &sun_east0,
        water: &no_water,
    };
    let grid = *f.grid();
    let pick = |i: usize, j: usize| pick_in_column(i, j, &grid, Some(&g), 7, 6);
    let height = |_x: f64, _z: f64| GROUND;
    let cfg = cfg_t(1.0e9);
    let mut inp = BuildIn::new(&cfg, u10);
    inp.pick_fn = Some(&pick);
    inp.height_fn = Some(&height);
    let s = AirThermals::build(&f, &inp).unwrap();
    let n_water = (0..s.count()).filter(|&k| s.pos[k][0] >= 0.0).count();
    let n_land = s.count() - n_water;
    assert_eq!(n_water, 0, "на воде источников нет");
    assert!(n_land > 0, "на суше источники есть");
    assert!(
        pick_in_column(40, 10, &grid, Some(&g), 7, 6).is_none(),
        "над водой — нет источника"
    );
    assert!(
        pick_in_column(5, 10, &grid, Some(&g), 7, 6).is_some(),
        "на суше — точка"
    );

    // тёплое море (VI-7): сила 0,07 > 0, но вода — источника нет, поток воды источникам не идёт
    let sun_warm = |x: f64, _z: f64| if x >= 0.0 { 0.07 } else { 1.0 };
    let water_east = |x: f64, _z: f64| x >= 0.0;
    let reference = build(&f, u10, &cfg);
    let g2 = FnGround {
        sun: &sun_warm,
        water: &water_east,
    };
    let pick2 = |i: usize, j: usize| pick_in_column(i, j, &grid, Some(&g2), 7, 6);
    let mut inp2 = BuildIn::new(&cfg, u10);
    inp2.pick_fn = Some(&pick2);
    inp2.water_fn = Some(&water_east);
    inp2.height_fn = Some(&height);
    let s2 = AirThermals::build(&f, &inp2).unwrap();
    let n_w2 = (0..s2.count()).filter(|&k| s2.pos[k][0] >= 0.0).count();
    assert_eq!(n_w2, 0, "над тёплой водой источников нет");
    assert!(s2.count() > 0);
    let (c_sea, c_land) = (10 * N + 40, 10 * N + 5);
    assert!(
        s2.land[c_sea] == 0.0 && s2.land[c_land] == 1.0,
        "доля суши: вода 0, суша 1"
    );
    assert!(
        s2.owner[c_sea] < 0 && s2.phi[c_sea] == 0.0,
        "столбец воды — ничей, поток 0"
    );
    let r = s2.total_flux / reference.total_flux;
    assert!(
        (r - 0.5).abs() < 0.01,
        "поток источникам — только с суши ({r:.3} от всего)"
    );
    assert!(
        s2.land[10 * N + 23] == 1.0 && s2.land[10 * N + 24] == 0.0,
        "граница по столбцам"
    );
}

#[test]
fn ceiling_inversion_cloudbase_and_warm_lid() {
    let cfg = cfg_t(1.0e9);
    // Инверсия 20 К/км над z_i = 2000 м: частица останавливается у z_i.
    let (f, u10) = flat(&heat300, &zero3, 2000.0, 0.02, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg);
    assert!(s.count() > 0);
    let t0 = s.top[0] as f64;
    println!("    инверсия 20 К/км на 2000 м: потолок частицы {t0:.0} м");
    assert!(
        t0 > 2000.0 && t0 < 2100.0,
        "потолок ≈ высоте инверсии ({t0:.0})"
    );
    // Слабая устойчивость выше (5,8 К/км): проскок выше.
    let (f2, _) = flat(&heat300, &zero3, 2000.0, 0.0058, [0.0, 0.0], None);
    let s2 = build(&f2, u10, &cfg);
    println!("    5,8 К/км над 2000 м: потолок {:.0} м", s2.top[0]);
    assert!(s2.top[0] as f64 > t0 + 50.0, "без сильной инверсии — выше");
    // Тёплый слой θ′ поля (опускание над долиной) — потолок ниже.
    let lid = |agl: f64| 2.0 * dp_air::terms::thermal_air::smoothstep(750.0, 850.0, agl);
    let (f3, _) = flat(&heat300, &zero3, 2000.0, 0.0058, [0.0, 0.0], Some(&lid));
    let s3 = build(&f3, u10, &cfg);
    println!(
        "    тёплый слой θ′ +2 К с 800 м: потолок {:.0} м",
        s3.top[0]
    );
    assert!((s3.top[0] as f64) < GROUND + 900.0, "θ′ поля гасит частицу");
    // Потолок термика = min(частица, кромка) (fill): кромка выше частицы — частица; ниже — кромка.
    let w = FillWeather {
        radius_max: 300.0,
        extreme_chance: 0.0,
        extreme_ms: None,
    };
    let mut rng = Pcg32::from_seed(1);
    let hi = s.fill(0, &mut rng, &w, 2600.0);
    assert_eq!(hi.kind, 0);
    assert!(
        (hi.top - s.top[0] as f64).abs() < 1e-3,
        "кромка 2600 выше частицы — до частицы"
    );
    let lo = s2.fill(0, &mut rng, &w, 2100.0);
    assert!(
        lo.top <= 2100.0 + 1e-3 && lo.kind == 0,
        "частица выше кромки — до кромки"
    );
}

#[test]
fn mass_flux_distributed_over_catchments() {
    let (f, u10) = flat(&heat300, &conv_line, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_t(1.0e9));
    let m_sum: f64 = s.flux.iter().map(|&x| x as f64).sum();
    println!(
        "    поток: поля {:.0} м³/с, водосборам {m_sum:.0}, несут ядра {:.0}, без хозяина {:.0}; жизнь {:.2}",
        s.total_flux, s.carried_flux, s.lost_flux, s.life_mean
    );
    assert!(
        (m_sum + s.lost_flux - s.total_flux).abs() < 1.0e-3 * s.total_flux,
        "поток распределён весь"
    );
    assert!(
        s.lost_flux < 0.05 * s.total_flux,
        "почти весь — водосборам источников"
    );
    // чистый поток пузыря не больше потока ядер; ожидаемый поток в столбце водосбора > 0
    for k in 0..s.count() {
        assert!(s.net[k] <= s.carried[k] * 1.000_001 + 1e-3);
    }
}

fn noisy(f: &Field, amp: f64) -> Field {
    let mut rng = Pcg32::from_seed(12345);
    let g = *f.grid();
    let n = g.nx * g.ny * g.nz;
    let (u0, v0, wm0, wc0, th0) = (
        f.raw_u(),
        f.raw_v(),
        f.raw_w_mech(),
        f.raw_w_conv(),
        f.raw_theta(),
    );
    let (mut u, mut v, mut wm, mut wc, mut th) = (
        vec![0f32; n],
        vec![0f32; n],
        vec![0f32; n],
        vec![0f32; n],
        vec![0f32; n],
    );
    let a = amp as f32;
    for c in 0..n {
        u[c] = (u0[c] as f64 + rng.randf_range(-a, a) as f64) as f32;
        v[c] = (v0[c] as f64 + rng.randf_range(-a, a) as f64) as f32;
        wm[c] = (wm0[c] as f64 + rng.randf_range(-a, a) as f64) as f32;
        wc[c] = (wc0[c] as f64 + rng.randf_range(-a, a) as f64) as f32;
        th[c] = (th0[c] as f64 + rng.randf_range(-a, a) as f64 / 3.0) as f32;
    }
    let meta = FieldMeta {
        z0: Z0::Uniform(f.z0()),
        gam: f.gam().to_vec(),
        heat: f.heat_flux().to_vec(),
        z_i: f.z_i(),
        z_i_col: f.z_i_col().to_vec(),
    };
    Field::from_arrays(
        &g,
        u,
        v,
        wm,
        wc,
        th,
        f.raw_hc().to_vec(),
        meta,
        Limits::default(),
    )
    .unwrap()
}

#[test]
fn host_mask_same_sources_with_noise() {
    let (f, u10) = flat(&sun_half, &conv_line, 2500.0, 0.0058, [0.0, 0.0], None);
    let g = noisy(&f, 1.0e-3 * 3.0);
    let cfg = cfg_t(1.0e9);
    let a = build(&f, u10, &cfg);
    let mask = a.mask_bytes();
    let mut inp = BuildIn::new(&cfg, u10);
    inp.forced = Some(&mask);
    let c2 = AirThermals::build(&g, &inp).unwrap();
    assert_eq!(c2.col, a.col, "с маской ведущего — те же столбцы");
    let (mut dw, mut dt, mut dd) = (0.0f64, 0.0f64, 0.0f64);
    for k in 0..a.count() {
        dw = dw.max((c2.w0[k] - a.w0[k]).abs() as f64 / a.w0[k] as f64);
        dt = dt.max((c2.top[k] - a.top[k]).abs() as f64);
        dd = dd.max(
            ((c2.drift[k][0] - a.drift[k][0]) as f64)
                .hypot((c2.drift[k][1] - a.drift[k][1]) as f64),
        );
    }
    println!("    с маской: |Δw0| ≤ {dw:.5} отн., |Δпотолок| ≤ {dt:.3} м, |Δснос| ≤ {dd:.5} м/с");
    assert!(
        dw < 0.01 && dt < 1.0 && dd < 0.01,
        "параметры — в пределах шума поля"
    );
}

// ---------------------------------------------------------------- опускание (test_subsidence.gd)

const W_SUB: f64 = 0.05;
const TAU: f64 = 10800.0;
const SMOOTH: f64 = 300.0;

fn sub_right(x: f64, _z: f64, _a: f64) -> f64 {
    if x >= 0.0 { -W_SUB } else { 0.0 }
}
fn sub_strong(x: f64, _z: f64, _a: f64) -> f64 {
    if x >= 0.0 { -1.0 } else { 0.0 }
}
/// Шахматка ±W_SUB по клеткам: ячейки организованной конвекции.
fn checker(x: f64, z: f64, _a: f64) -> f64 {
    let (i, j) = ((x / DX).floor() as i64, (z / DX).floor() as i64);
    if (i + j).rem_euclid(2) == 0 {
        W_SUB
    } else {
        -W_SUB
    }
}

fn cfg_sub(tau: f64, smooth: f64) -> AirThermalsCfg {
    let mut c = cfg_t(1.0e9);
    c.subsidence_tau_s = tau;
    c.subsidence_smooth_m = smooth;
    c
}

fn approx(a: f64, b: f64, tol: f64, what: &str) {
    assert!(
        (a - b).abs() <= tol,
        "{what}: {a} против {b} (допуск {tol})"
    );
}

#[test]
fn subsidence_lowers_layer_and_ceiling() {
    let (f, u10) = flat(&heat300, &sub_right, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_sub(TAU, SMOOTH));
    let n = N * N;
    assert!(s.col_zi.len() == n && s.col_sub.len() == n);
    let j = N / 2;
    let (cl, cr) = (j * N + 2, j * N + N - 3);
    approx(s.col_w[cr] as f64, -W_SUB, 1.0e-4, "W̄ справа = опускание");
    approx(s.col_wm[cr] as f64, -W_SUB, 1.0e-4, "W̄_м справа = W̄");
    let sum_w: f64 = s.col_w.iter().map(|&x| x as f64).sum();
    let sum_m: f64 = s.col_wm.iter().map(|&x| x as f64).sum();
    approx(
        sum_m,
        sum_w,
        1.0e-3 * sum_w.abs() + 1.0e-6,
        "сглаживание сохраняет сумму W̄",
    );
    approx(s.col_sub[cl] as f64, 0.0, 1.0e-6, "слева опускания нет");
    approx(
        s.col_sub[cr] as f64,
        W_SUB * TAU,
        1.0e-3,
        "справа Δz_s = |W̄|·τ_s",
    );
    approx(
        s.col_zi[cr] as f64,
        f.z_i() - W_SUB * TAU,
        1.0e-3,
        "z_i столбца ниже на Δz_s",
    );
    approx(s.col_zi[cl] as f64, f.z_i(), 1.0e-6, "слева z_i поля");
    let h_l = f.z_i() - GROUND;
    let h_r = h_l - W_SUB * TAU;
    approx(
        s.col_wstar[cr] as f64 / s.col_wstar[cl] as f64,
        (h_r / h_l).powf(1.0 / 3.0),
        1.0e-4,
        "w* ∝ h^(1/3) по z_i столбца",
    );
    assert!(
        (s.c_top[cr] as f64) < s.c_top[cl] as f64 - 0.5 * W_SUB * TAU,
        "потолок справа ниже"
    );
    assert!(
        s.c_top[cr] > s.col_zi[cr],
        "потолок — над опущенным верхом слоя"
    );
    approx(
        s.phi[cr] as f64,
        s.col_f[cr] as f64,
        1.0e-6,
        "Φ = F̄ (W̄⁻ в Φ не входит)",
    );
    let g = *f.grid();
    for k in 0..s.count() {
        let p = s.pos[k];
        let i = ((p[0] as f64 - g.x0) / g.dx).floor() as usize;
        let jj = ((-(p[2] as f64) - g.y0) / g.dx).floor() as usize;
        assert_eq!(
            s.top[k],
            s.c_top[jj * N + i],
            "потолок источника = c_top его столбца"
        );
    }
}

#[test]
fn tau_zero_same_as_no_subsidence() {
    let (fa, u10) = flat(&heat300, &sub_right, 2500.0, 0.0058, [0.0, 0.0], None);
    let (fb, _) = flat(&heat300, &zero3, 2500.0, 0.0058, [0.0, 0.0], None);
    let a = build(&fa, u10, &cfg_sub(0.0, SMOOTH));
    let b = build(&fb, u10, &cfg_sub(0.0, SMOOTH));
    assert_eq!(a.phi, b.phi);
    assert!(
        a.c_top == b.c_top && a.col_wstar == b.col_wstar,
        "τ_s = 0: c_top, w* побитно"
    );
    assert!(a.col_zi == b.col_zi && a.col == b.col && a.top == b.top);
    assert!(a.col_sub.iter().all(|&v| v == 0.0), "τ_s = 0: col_sub = 0");
}

#[test]
fn cell_scale_sinking_does_not_lower_layer() {
    let (f, u10) = flat(&heat300, &checker, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_sub(TAU, SMOOTH));
    let n = N * N;
    let neg = s.col_w.iter().filter(|&&x| x < 0.0).count();
    let wm_max = s
        .col_wm
        .iter()
        .fold(0.0f64, |m, &x| m.max((x as f64).abs()));
    let sub_max = s.col_sub.iter().fold(0.0f64, |m, &x| m.max(x as f64));
    assert!(neg > n / 3, "W̄ < 0 у половины столбцов ({neg} из {n})");
    assert!(
        wm_max < 1.0e-3 * W_SUB,
        "W̄_м после сглаживания ≈ 0 ({wm_max})"
    );
    assert!(sub_max < 0.01, "опускания верха нет ({sub_max} м)");
    let c0 = (N / 2) * N + N / 2;
    approx(s.col_zi[c0] as f64, f.z_i(), 0.01, "z_i столбца = z_i поля");
    let s0 = build(&f, u10, &cfg_sub(TAU, 0.0));
    let sub0 = s0.col_sub.iter().filter(|&&x| x > 0.0).count();
    assert_eq!(sub0, neg, "σ = 0: ячейковое W̄ < 0 опускало бы столбцы");
}

#[test]
fn floor_zi_min_and_no_zi_day() {
    let (f, u10) = flat(&heat300, &sub_strong, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_sub(TAU, SMOOTH));
    let c = (N / 2) * N + N - 3;
    approx(
        s.col_zi[c] as f64,
        GROUND + ZI_MIN,
        1.0e-3,
        "z_i столбца не ниже земли + ZI_MIN",
    );
    assert!(
        s.col_wstar[c] > 0.0 && !s.c_top[c].is_nan(),
        "столбец считается"
    );
    // день без z_i (нет конвекции): источников нет, build — None
    let (f2, u10) = flat(&heat300, &sub_right, f64::NAN, 0.0058, [0.0, 0.0], None);
    assert!(!has_inputs(&f2));
    assert!(AirThermals::build(&f2, &BuildIn::new(&cfg_sub(TAU, SMOOTH), u10)).is_none());
}

// ---------------------------------------------------------------- параллельность и рельеф

fn pick_det(i: usize, j: usize) -> Option<[f32; 2]> {
    // test_air_thermals_parallel.gd::_pick: каждый седьмой — «вода»
    if (i * 31 + j * 17).is_multiple_of(7) {
        return None;
    }
    let mut rng = Pcg32::from_seed(dp_air::hash::hash_v3i(5, i as i32, j as i32) as u64);
    let o = -(N as f64) * DX * 0.5;
    let x = o + (i as f64 + rng.randf_range(0.1, 0.9) as f64) * DX;
    let z = -(o + (j as f64 + rng.randf_range(0.1, 0.9) as f64) * DX);
    Some([x as f32, z as f32])
}

fn height_wavy(x: f64, z: f64) -> f64 {
    GROUND + 3.0 * (x * 0.01).sin() * (z * 0.013).cos()
}

#[test]
fn bands_bit_identical_synthetic() {
    let (f, u10) = flat(&heat_var, &conv_line, 2200.0, 0.0058, [3.0, 1.0], None);
    let cfg = cfg_t(2900.0);
    let mk = |bands: usize| {
        let mut inp = BuildIn::new(&cfg, u10);
        inp.pick_fn = Some(&pick_det);
        inp.height_fn = Some(&height_wavy);
        inp.bands = bands;
        AirThermals::build(&f, &inp).unwrap()
    };
    let one = mk(1);
    assert!(one.count() > 0, "источники есть ({})", one.count());
    let d1 = bits_dump(&one);
    for nb in [2, 7, 0, 1000] {
        let d = bits_dump(&mk(nb));
        let bad: Vec<usize> = (0..d1.len()).filter(|&k| d1[k] != d[k]).collect();
        assert!(bad.is_empty(), "полос {nb}: выходы {bad:?} расходятся");
    }
    // из рабочего потока (вложенная группа rayon)
    let nested = std::thread::scope(|sc| sc.spawn(|| mk(0)).join().unwrap());
    assert!(bits_dump(&nested) == d1, "из потока — тот же итог");
}

#[test]
fn relief_ready_changes_sources_and_seed_decides() {
    let (f, u10) = flat(&heat_var, &conv_line, 2200.0, 0.0058, [3.0, 1.0], None);
    let cfg = cfg_t(1.0e9);
    let grid = *f.grid();
    let moisture = |ready: bool, x: f64, z: f64| -> f64 {
        if !ready {
            0.5
        } else if ((x * 0.004).sin() * (z * 0.003).cos()).abs() > 0.6 {
            0.95
        } else {
            0.3
        }
    };
    let run = |ready: bool, seed: u64| -> AirThermals {
        let strength = move |x: f64, z: f64| (1.0 - 1.25 * moisture(ready, x, z)).clamp(0.0, 1.0);
        let no_water = |_x: f64, _z: f64| false;
        let g = FnGround {
            sun: &strength,
            water: &no_water,
        };
        let pick = |i: usize, j: usize| pick_in_column(i, j, &grid, Some(&g), seed, 8);
        let height = |_x: f64, _z: f64| GROUND;
        let mut inp = BuildIn::new(&cfg, u10);
        inp.pick_fn = Some(&pick);
        inp.height_fn = Some(&height);
        AirThermals::build(&f, &inp).unwrap()
    };
    let before = run(false, 11);
    let after = run(true, 11);
    assert!(before.count() > 0 && after.count() > 0);
    assert!(
        before.count() != after.count() || before.pos != after.pos,
        "итог зависит от готовности полей рельефа ({} → {})",
        before.count(),
        after.count()
    );
    assert_eq!(
        bits_dump(&after),
        bits_dump(&run(true, 11)),
        "сид 11 дважды — тот же итог"
    );
    let other = run(true, 12);
    assert!(
        after.pos != other.pos,
        "другой сид — другие точки ({} / {})",
        after.count(),
        other.count()
    );
}

// ---------------------------------------------------------------- реальная фикстура (Каянча)

#[test]
fn real_kayancha_fixture() {
    let dir = repo().join("tests/atmosphere/fixtures/air_model/thermals");
    let j: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("kayancha_w100_h12.json")).unwrap())
            .unwrap();
    let raw = std::fs::read(dir.join("kayancha_w100_h12.bin")).unwrap();
    let all: Vec<f32> = raw
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    let arr = |name: &str| -> Vec<f32> {
        let o = j["arrays"][name][0].as_u64().unwrap() as usize;
        let n = j["arrays"][name][1].as_u64().unwrap() as usize;
        all[o..o + n].to_vec()
    };
    let g = |k: &str| j[k].as_f64().unwrap();
    let grid = FieldGrid {
        dx: g("dx"),
        dz: g("dz"),
        x0: g("x0"),
        y0: g("y0"),
        z_bot: g("z_bot"),
        nx: g("nx") as usize,
        ny: g("ny") as usize,
        nz: g("nz") as usize,
    };
    let meta = FieldMeta {
        z0: Z0::Uniform(g("z0")),
        gam: j["gam"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_f64().unwrap() as f32)
            .collect(),
        heat: arr("heat"),
        z_i: g("z_i"),
        z_i_col: Vec::new(),
    };
    let f = Field::from_arrays(
        &grid,
        arr("u"),
        arr("v"),
        arr("w_mech"),
        arr("w_conv"),
        arr("theta"),
        arr("hc"),
        meta,
        Limits::default(),
    )
    .unwrap();
    assert!(has_inputs(&f), "в фикстуре есть H и z_i");
    let cb = g("z_lcl");
    let s = build(&f, g("u10"), &cfg_t(cb));
    let n = s.count();
    assert!(n > 0, "источники есть");
    let (mut kmin, mut kmax) = (f64::INFINITY, 0.0f64);
    for k in 0..n {
        let r = s.w0[k] as f64 / s.wstar[k] as f64;
        kmin = kmin.min(r);
        kmax = kmax.max(r);
    }
    println!(
        "    Каянча 12:00: источников {n}, w* {:.2}, w0/w* {kmin:.2}…{kmax:.2}; поток поля {:.0}, несут ядра {:.0}",
        s.wstar[0], s.total_flux, s.carried_flux
    );
    assert!(
        (kmin - K_ALLEN).abs() < 1e-3 && kmax < K_ALLEN + 1e-3,
        "сила = k·w*"
    );
    assert!(s.carried_flux > 0.0 && s.carried_flux <= s.total_flux);
}

// ---------------------------------------------------------------- fill

#[test]
fn fill_rng_order_matches_gd() {
    let (f, u10) = flat(&heat300, &zero3, 2500.0, 0.0058, [0.0, 0.0], None);
    let s = build(&f, u10, &cfg_t(1.0e9));
    let sunny = 0;
    // обычный: один randf, больше ничего; следующее число — второе в последовательности
    let w0 = FillWeather {
        radius_max: 350.0,
        extreme_chance: 0.0,
        extreme_ms: Some([8.0, 9.0]),
    };
    let mut a = Pcg32::from_seed(77);
    let mut b = Pcg32::from_seed(77);
    let r = s.fill(sunny, &mut a, &w0, 1.0e9);
    assert_eq!(r.kind, 0);
    assert_eq!(r.strength, s.w0[sunny] as f64);
    assert_eq!(r.radius, s.radius[sunny] as f64);
    assert_eq!(r.ring, s.ring[sunny] as f64);
    let _ = b.randf();
    assert_eq!(a.randf().to_bits(), b.randf().to_bits(), "ровно один randf");
    // очень сильный: randf, затем randf_range(8, 9); радиус не меньше пресета
    let w1 = FillWeather {
        radius_max: 350.0,
        extreme_chance: 1.0,
        extreme_ms: Some([8.0, 9.0]),
    };
    let mut a = Pcg32::from_seed(78);
    let mut b = Pcg32::from_seed(78);
    let r = s.fill(sunny, &mut a, &w1, 1.0e9);
    assert_eq!(r.kind, 1);
    let _ = b.randf();
    let want = b.randf_range(8.0, 9.0) as f64;
    assert_eq!(r.strength, want);
    assert!(r.strength >= 8.0 && r.strength <= 9.0);
    assert!(r.radius >= 350.0);
    // без диапазона — randf потреблён, термик обычный
    let w2 = FillWeather {
        radius_max: 350.0,
        extreme_chance: 1.0,
        extreme_ms: None,
    };
    let mut a = Pcg32::from_seed(79);
    let r = s.fill(sunny, &mut a, &w2, 1.0e9);
    assert_eq!(r.kind, 0);
    let mut b = Pcg32::from_seed(79);
    let _ = b.randf();
    assert_eq!(a.randf().to_bits(), b.randf().to_bits());
    // столб ниже ZI_MIN (кромка у земли): −1 и rng не тронут
    let mut a = Pcg32::from_seed(80);
    let mut b = Pcg32::from_seed(80);
    let r = s.fill(sunny, &mut a, &w1, s.pos[sunny][1] as f64 + 100.0);
    assert_eq!(r.kind, -1);
    assert_eq!(a.randf().to_bits(), b.randf().to_bits(), "rng не тронут");
}

// ---------------------------------------------------------------- ядра эталона W6

/// Ядра `desc.json` эталона `ongudai_medium` (кадры t = 0, 900, 3600 с; шаг 15): каждое ядро поля
/// рождено одним из источников, построенных крейтом, — точка высоты `y_src`, радиус ядра (Аллен),
/// потолок `min(top, кромка)` совпадают, а само ядро сдвинуто от источника вдоль его сноса
/// (`drift`) — термик с возрастом уходит по ветру.
#[test]
fn desc_cores_of_fixture_come_from_sources() {
    let c = load_case("ongudai_medium");
    let s = build_case(&c, 0, true);
    let p = repo().join("tests/fixtures/wind/cases/ongudai_medium.desc.json");
    let d: Value = serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap();
    let stride = d["core_stride"].as_u64().unwrap() as usize;
    assert_eq!(stride, 15);
    let mut total = 0;
    let mut worst_cos = 1.0f64;
    let mut worst_r = 0.0f64;
    for fr in d["frames"].as_array().unwrap() {
        let cb = fr["cloudbase_msl"].as_f64().unwrap();
        let cores: Vec<f64> = fr["cores"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_f64().unwrap_or(f64::NAN))
            .collect();
        for k in cores.chunks_exact(stride) {
            let (x, z, y_src, top, r) = (k[2], k[3], k[4], k[5], k[7]);
            let mut best = f64::NEG_INFINITY;
            for q in 0..s.count() {
                if (s.pos[q][1] as f64 - y_src).abs() > 0.01
                    || (s.radius[q] as f64 - r).abs() > 0.005 * r.max(100.0)
                    || (s.top[q] as f64).min(cb) - top > 0.01
                    || top - (s.top[q] as f64).min(cb) > 0.01
                {
                    continue;
                }
                let (ox, oz) = (x - s.pos[q][0] as f64, z - s.pos[q][2] as f64);
                let (dx, dz) = (s.drift[q][0] as f64, s.drift[q][1] as f64);
                let cs = if ox.hypot(oz) < 1.0 {
                    1.0
                } else {
                    (ox * dx + oz * dz) / ox.hypot(oz) / dx.hypot(dz)
                };
                if cs > best {
                    best = cs;
                    worst_r = worst_r.max((s.radius[q] as f64 - r).abs() / r);
                }
            }
            assert!(
                best > 0.98,
                "ядро ({x:.0}, {z:.0}), y_src {y_src}: источник не найден (cos {best})"
            );
            worst_cos = worst_cos.min(best);
            total += 1;
        }
    }
    println!(
        "    ядер {total}: все из источников; min cos сноса {worst_cos:.7}, max отн. радиуса {worst_r:.2e}"
    );
    assert!(total > 700);
}
