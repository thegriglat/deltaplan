//! TB-3: цена опроса шаблона пузыря-термика против нынешнего профиля (`profile::contribution`, `State::sample`).
//!
//! Весь порт `tools/research/thermal_bubble/bubble.py::velocity` (голова Хилла, шлейф MTT с виртуальным
//! источником, сшивка χ, линия стоков квадратурой Гаусса, отражения земли и крышки) живёт здесь: `src` dp-air не
//! тронут. Оси порта — прототипа (x восток, y север, z вверх); для `current_*` — оси игры (y вверх): горизонталь
//! прототипа (x, y) = игры (x, z), высота z = y игры.
//!
//! Замеры (ns на точку, медиана выборок criterion, профиль release): `current_contribution`, `current_sample`,
//! `bubble_analytic`, `bubble_table`. Итог — `tools/research/thermal_bubble/out/bench.json` (после замеров, временный
//! файл + переименование; в режиме `--test` и при `--filter` не пишется). Фикстура —
//! `out/bench_fixture.json` (`bench_fixture.py`): `port_max_rel_err = max|v_rust − v_py| / max|v_py|`.
//! Запуск: `.dpcli/dpcli lock cpu tb3 -- cargo bench --manifest-path rust/Cargo.toml -p dp-air --bench thermal_bubble`.
use criterion::{Criterion, black_box};
use dp_air::terms::thermal::profile::{Edge, contribution};
use dp_air::terms::thermal::{AtmoThermal, NoClouds, Setup, State, ThermalCfg};
use dp_air::terms::{WeatherView, WindCfg, WindModel};
use rayon::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::f64::consts::PI;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- числа порта (как в bubble.py)
const AL_P: f64 = 0.12; // PARAMS["alpha_plume"]
const S0: f64 = 3.0;
const BLEND: f64 = 0.5;
const PANEL: f64 = 0.6;
const GL_N: usize = 8;

// ---------------------------------------------------------------- параметры стенда (не физика)
const ZL: f64 = 1400.0; // толщина слоя z_l, м
const N_ALLEN: f64 = 8.5 / (ZL * ZL); // плотность ядер Аллена, 1/м²
const TOP_R_FRAC: f64 = 0.0765; // радиус ядра у верха / z_l
const W0: f64 = 2.5; // сила ядра нынешней модели = w*, м/с
const DISC_R: f64 = 5000.0; // термики/пузыри — в круге этого радиуса, м
const POINT_R: f64 = 4000.0; // точки опроса — в круге этого радиуса, м
const N_POINTS: usize = 20000;
const CUT_FRAC: f64 = 0.01; // радиус влияния: |v| < 1 % пика
const BUCKET: f64 = 500.0; // как cfg.bucket_m
const TABLE_STEP: f64 = 10.0; // шаг таблицы по ρ и z, м

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn out_dir() -> PathBuf {
    repo().join("tools/research/thermal_bubble/out")
}

// ---------------------------------------------------------------- ГСЧ стенда
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
    fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.next()
    }
    /// Точка в круге радиуса `r`.
    fn disc(&mut self, r: f64) -> (f64, f64) {
        let rr = r * self.next().sqrt();
        let a = 2.0 * PI * self.next();
        (rr * a.cos(), rr * a.sin())
    }
}

// ---------------------------------------------------------------- порт bubble.py
#[derive(Clone, Copy, Debug, Deserialize)]
struct St {
    xc: f64,
    yc: f64,
    zc: f64,
    #[serde(rename = "R")]
    r: f64,
    #[serde(rename = "U")]
    u: f64,
    #[serde(rename = "Q")]
    _q: f64,
    #[serde(rename = "F0")]
    f0: f64,
    zb: f64,
    #[serde(rename = "Uh")]
    uh: f64,
    b0: f64,
}

fn ss(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    x * x * x * (10.0 - 15.0 * x + 6.0 * x * x)
}

fn dss(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    30.0 * x * x * (1.0 - x) * (1.0 - x)
}

fn cq(f0: f64) -> f64 {
    PI * 1.2 * AL_P * (0.9 * AL_P * f0 / PI).cbrt()
}

fn gauss_legendre(n: usize) -> (Vec<f64>, Vec<f64>) {
    let (mut x, mut w) = (vec![0.0; n], vec![0.0; n]);
    for i in 0..n {
        let mut z = (PI * (i as f64 + 0.75) / (n as f64 + 0.5)).cos();
        let mut dp = 1.0;
        for _ in 0..100 {
            let (mut p1, mut p2) = (1.0, 0.0);
            for j in 0..n {
                let p3 = p2;
                p2 = p1;
                p1 = ((2 * j + 1) as f64 * z * p2 - j as f64 * p3) / (j + 1) as f64;
            }
            dp = n as f64 * (z * p1 - p2) / (z * z - 1.0);
            let dz = p1 / dp;
            z -= dz;
            if dz.abs() < 1e-15 {
                break;
            }
        }
        x[n - 1 - i] = z;
        w[n - 1 - i] = 2.0 / ((1.0 - z * z) * dp * dp);
    }
    (x, w)
}

/// Шлейф одного пузыря: вертикальная ось через (xc, yc), начало s — виртуальный источник на глубине z_v.
#[derive(Clone)]
struct Plume {
    a: [f64; 3],
    k: f64,
    s: Vec<f64>,
    m4: Vec<f64>, // сила стоков / 4π (отрицательная)
}

impl Plume {
    fn new(st: &St) -> Plume {
        let zv = 5.0 * st.b0 / (6.0 * AL_P);
        let l = st.zc + zv;
        let sb = st.zb + zv;
        let stb = st.zc - st.r + zv;
        let cqv = cq(st.f0);
        let lb = st.b0.max(0.5 * st.zb);
        let lt = st.r;
        let k = 1.2 * AL_P;
        let mut pts = [sb, sb + lb, stb, l];
        pts.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mut uniq: Vec<f64> = Vec::new();
        for p in pts {
            if uniq.last() != Some(&p) {
                uniq.push(p);
            }
        }
        let mut edges = vec![uniq[0]];
        for w in uniq.windows(2) {
            let (lo, hi) = (w[0], w[1]);
            if hi - lo <= 0.0 {
                continue;
            }
            let h = PANEL * k * 0.5 * (lo + hi);
            let n = (((hi - lo) / h).ceil() as usize).max(2);
            let step = (hi - lo) / n as f64;
            for i in 1..=n {
                edges.push(if i == n { hi } else { lo + step * i as f64 });
            }
        }
        let (g, gw) = gauss_legendre(GL_N);
        let (mut s, mut m4) = (Vec::new(), Vec::new());
        for e in edges.windows(2) {
            let (a, b) = (e[0], e[1]);
            for j in 0..GL_N {
                let sn = 0.5 * (b - a) * g[j] + 0.5 * (b + a);
                let wq = 0.5 * (b - a) * gw[j];
                // dQ/ds
                let se = (sn * sn + S0 * S0).sqrt();
                let g1 = sn * sn * se.powf(-1.0 / 3.0);
                let dg1 = 2.0 * sn * se.powf(-1.0 / 3.0) - sn.powi(3) * se.powf(-7.0 / 3.0) / 3.0;
                let ttop = 1.0 - ss((sn - stb) / lt);
                let dttop = -dss((sn - stb) / lt) / lt;
                let x = (sn - sb) / lb;
                let (bb, dbb) = (ss(x), dss(x) / lb);
                let bt = bb * ttop;
                let dbt = dbb * ttop + bb * dttop;
                let dq = cqv * (dg1 * bt + g1 * dbt);
                s.push(sn);
                m4.push(-dq * wq / (4.0 * PI));
            }
        }
        Plume {
            a: [st.xc, st.yc, -zv],
            k,
            s,
            m4,
        }
    }

    /// (u_s, B, psi) в точке (rho², s) по линии стоков.
    #[inline]
    fn sums(&self, rho2: f64, s: f64) -> (f64, f64, f64) {
        let (mut a, mut b, mut p) = (0.0, 0.0, 0.0);
        for (sn, m) in self.s.iter().zip(&self.m4) {
            let ds = s - sn;
            let r = (rho2 + ds * ds).sqrt();
            let r3 = r * r * r;
            a += m * ds / r3;
            b -= m / r3;
            p -= m * ds / r;
        }
        (a, b, p)
    }

    fn velocity(&self, p: [f64; 3]) -> [f64; 3] {
        let (dx, dy, s) = (p[0] - self.a[0], p[1] - self.a[1], p[2] - self.a[2]);
        let rho2 = dx * dx + dy * dy;
        let rho = rho2.sqrt();
        let se = (s * s + S0 * S0).sqrt();
        let b = self.k * se;
        let db = self.k * s / se;
        let t = (rho / b - 1.0) / BLEND;
        let chi = 1.0 - ss(t);
        let (mut us, mut bs) = (0.0, 0.0);
        let (mut gn, mut dgn) = (0.0, 0.0);
        if t < 1.0 {
            let (a, bb, ps) = self.sums(b * b, s);
            let g = ps / (b * b);
            let dg = bb + a * db / b - 2.0 * ps * db / (b * b * b);
            us = chi * 2.0 * g;
            bs = chi * dg;
            gn = g;
            dgn = dg;
        }
        if t > 0.0 {
            let (aout, bout, psi_out) = self.sums(rho2, s);
            let diff = gn * rho2 - psi_out;
            let sp = dss(t);
            us = chi * 2.0 * gn + (1.0 - chi) * aout - diff * sp / (BLEND * b * rho);
            bs = chi * dgn + (1.0 - chi) * bout + diff * sp * db / (BLEND * b * b * rho);
        }
        [-bs * dx, -bs * dy, us]
    }
}

fn hill(st: &St, p: [f64; 3]) -> [f64; 3] {
    let (dx, dy, s) = (p[0] - st.xc, p[1] - st.yc, p[2] - st.zc);
    let rho2 = dx * dx + dy * dy;
    let r2 = rho2 + s * s;
    let u = if st.uh < 0.0 { st.u } else { st.uh };
    let rr = st.r;
    if r2 < rr * rr {
        let k = 1.5 * u * s / (rr * rr);
        [k * dx, k * dy, u + 1.5 * u * (1.0 - r2 / (rr * rr)) - 1.5 * u * rho2 / (rr * rr)]
    } else {
        let r = r2.sqrt();
        let r5 = r.powi(5);
        let k = 1.5 * u * rr.powi(3) * s / r5;
        [k * dx, k * dy, u * rr.powi(3) / (r * r * r) - 1.5 * u * rr.powi(3) * rho2 / r5]
    }
}

/// Один пузырь: состояние и предрасчитанный шлейф (узлы стоков строятся раз на State, как таблица на обновление).
#[derive(Clone)]
struct Bubble {
    st: St,
    plume: Option<Plume>,
}

impl Bubble {
    fn new(st: St) -> Bubble {
        let plume = (st.f0 > 0.0 && st.zb < st.zc - 1e-6).then(|| Plume::new(&st));
        Bubble { st, plume }
    }

    fn contribution(&self, p: [f64; 3]) -> [f64; 3] {
        let uh = if self.st.uh < 0.0 { self.st.u } else { self.st.uh };
        let mut v = if uh != 0.0 { hill(&self.st, p) } else { [0.0; 3] };
        if let Some(pl) = &self.plume {
            let w = pl.velocity(p);
            for i in 0..3 {
                v[i] += w[i];
            }
        }
        v
    }

    /// Возмущение в точке: сумма по образам земли и крышки (n = −2..2, оба знака).
    fn velocity(&self, p: [f64; 3], zi: f64) -> [f64; 3] {
        if p[2] < 0.0 || p[2] > zi {
            return [0.0; 3];
        }
        let mut acc = [0.0; 3];
        for n in -2..=2 {
            for sgn in [1.0, -1.0] {
                let q = [p[0], p[1], sgn * p[2] + 2.0 * n as f64 * zi];
                let v = self.contribution(q);
                acc[0] += v[0];
                acc[1] += v[1];
                acc[2] += sgn * v[2];
            }
        }
        acc
    }
}

/// Таблица (u_ρ, w) по (ρ, z) одного пузыря, билинейная выборка; за `rho_max` — 0.
#[derive(Clone)]
struct Table {
    nr: usize,
    nz: usize,
    d: f64,
    data: Vec<[f32; 2]>,
}

impl Table {
    fn build(b: &Bubble, rho_max: f64, zi: f64) -> Table {
        let d = TABLE_STEP;
        let nr = (rho_max / d).ceil() as usize + 2;
        let nz = (zi / d).ceil() as usize + 2;
        let mut data = vec![[0f32; 2]; nr * nz];
        let (xc, yc) = (b.st.xc, b.st.yc);
        data.par_chunks_mut(nz).enumerate().for_each(|(i, col)| {
            for (j, c) in col.iter_mut().enumerate() {
                let v = b.velocity([xc + i as f64 * d, yc, (j as f64 * d).min(zi)], zi);
                *c = [v[0] as f32, v[2] as f32];
            }
        });
        Table { nr, nz, d, data }
    }

    fn bytes(&self) -> usize {
        self.data.len() * std::mem::size_of::<[f32; 2]>()
    }

    #[inline]
    fn sample(&self, st: &St, p: [f64; 3]) -> [f64; 3] {
        let (dx, dy) = (p[0] - st.xc, p[1] - st.yc);
        let rho = dx.hypot(dy);
        let (fr, fz) = (rho / self.d, p[2].max(0.0) / self.d);
        let (i, j) = (fr as usize, fz as usize);
        if i + 1 >= self.nr || j + 1 >= self.nz {
            return [0.0; 3];
        }
        let (tr, tz) = (fr - i as f64, fz - j as f64);
        let at = |a: usize, b: usize| self.data[a * self.nz + b];
        let (c00, c01, c10, c11) = (at(i, j), at(i, j + 1), at(i + 1, j), at(i + 1, j + 1));
        let l = |k: usize| {
            f64::from(c00[k]) * (1.0 - tr) * (1.0 - tz)
                + f64::from(c01[k]) * (1.0 - tr) * tz
                + f64::from(c10[k]) * tr * (1.0 - tz)
                + f64::from(c11[k]) * tr * tz
        };
        let ur = l(0);
        let k = if rho > 1e-9 { ur / rho } else { 0.0 };
        [k * dx, k * dy, l(1)]
    }
}

// ---------------------------------------------------------------- фикстура
#[derive(Deserialize)]
struct Case {
    name: String,
    states: Vec<St>,
    points: Vec<[f64; 3]>,
    v: Vec<[f64; 3]>,
}

#[derive(Deserialize)]
struct EnvJ {
    zi: f64,
}

#[derive(Deserialize)]
struct Fixture {
    env: EnvJ,
    cases: Vec<Case>,
    population: Vec<St>,
}

fn load_fixture() -> Fixture {
    let p = out_dir().join("bench_fixture.json");
    let t = std::fs::read_to_string(&p).unwrap_or_else(|e| {
        panic!("{}: {e}; python3 tools/research/thermal_bubble/bench_fixture.py", p.display())
    });
    serde_json::from_str(&t).expect("bench_fixture.json")
}

fn norm(v: &[f64; 3]) -> f64 {
    (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
}

// ---------------------------------------------------------------- сцена пузырей
struct Inst {
    b: Bubble,
    r_inf: f64,
    table: Table,
}

struct BubbleScene {
    insts: Vec<Inst>,
    grid: HashMap<(i64, i64), Vec<u32>>,
    zi: f64,
}

impl BubbleScene {
    /// Список пузырей в бакете точки и расстояние-отсев: вызывает `f(index)` для пузырей в радиусе влияния.
    #[inline]
    fn for_near(&self, p: [f64; 3], mut f: impl FnMut(&Inst)) {
        let key = ((p[0] / BUCKET).floor() as i64, (p[1] / BUCKET).floor() as i64);
        if let Some(l) = self.grid.get(&key) {
            for &i in l {
                let it = &self.insts[i as usize];
                let (dx, dy) = (p[0] - it.b.st.xc, p[1] - it.b.st.yc);
                if dx * dx + dy * dy <= it.r_inf * it.r_inf {
                    f(it);
                }
            }
        }
    }

    fn analytic(&self, p: [f64; 3]) -> [f64; 3] {
        let mut a = [0.0; 3];
        self.for_near(p, |it| {
            let v = it.b.velocity(p, self.zi);
            for k in 0..3 {
                a[k] += v[k];
            }
        });
        a
    }

    fn table(&self, p: [f64; 3]) -> [f64; 3] {
        let mut a = [0.0; 3];
        self.for_near(p, |it| {
            let v = it.table.sample(&it.b.st, p);
            for k in 0..3 {
                a[k] += v[k];
            }
        });
        a
    }
}

/// Радиус влияния состояния и пик |v| по сетке (ρ шаг 20 м до 3000 м × z шаг 50 м): (r_inf при пороге `cut`, пик).
fn sweep(b: &Bubble, zi: f64) -> (Vec<f64>, f64) {
    let nr = 150;
    let prof: Vec<f64> = (0..=nr)
        .into_par_iter()
        .map(|i| {
            let mut m: f64 = 0.0;
            let mut z = 0.0;
            while z <= zi {
                let v = b.velocity([b.st.xc + i as f64 * 20.0, b.st.yc, z], zi);
                m = m.max(norm(&v));
                z += 50.0;
            }
            m
        })
        .collect();
    let peak = prof.iter().cloned().fold(0.0, f64::max);
    (prof, peak)
}

fn build_scene(fx: &Fixture, rng: &mut Rng, with_stats: &mut Value) -> BubbleScene {
    let zi = fx.env.zi;
    let t0 = Instant::now();
    let sweeps: Vec<(Vec<f64>, f64)> = fx
        .population
        .iter()
        .map(|st| sweep(&Bubble::new(St { xc: 0.0, yc: 0.0, ..*st }), zi))
        .collect();
    let peak = sweeps.iter().map(|s| s.1).fold(0.0, f64::max);
    let cut = CUT_FRAC * peak;
    let r_inf: Vec<f64> = sweeps
        .iter()
        .map(|(prof, _)| prof.iter().rposition(|&m| m >= cut).map_or(0.0, |i| i as f64 * 20.0 + 20.0))
        .collect();
    // таблицы по состояниям (ширина = r_inf своего состояния), копии на каждый пузырь — свой кеш-след
    let tables: Vec<Table> = fx
        .population
        .par_iter()
        .zip(&r_inf)
        .map(|(st, &r)| Table::build(&Bubble::new(St { xc: 0.0, yc: 0.0, ..*st }), r.max(TABLE_STEP), zi))
        .collect();
    let nb = (N_ALLEN * PI * DISC_R * DISC_R).round() as usize;
    let mut insts = Vec::with_capacity(nb);
    let mut grid: HashMap<(i64, i64), Vec<u32>> = HashMap::new();
    for n in 0..nb {
        let k = (rng.next() * fx.population.len() as f64) as usize % fx.population.len();
        let (x, y) = rng.disc(DISC_R);
        let st = St { xc: x, yc: y, ..fx.population[k] };
        let r = r_inf[k];
        let b = Bubble::new(st);
        let (b0x, b1x) = (((x - r) / BUCKET).floor() as i64, ((x + r) / BUCKET).floor() as i64);
        let (b0y, b1y) = (((y - r) / BUCKET).floor() as i64, ((y + r) / BUCKET).floor() as i64);
        for bx in b0x..=b1x {
            for by in b0y..=b1y {
                grid.entry((bx, by)).or_default().push(n as u32);
            }
        }
        insts.push(Inst { b, r_inf: r, table: tables[k].clone() });
    }
    let tb_mean = insts.iter().map(|i| i.table.bytes()).sum::<usize>() as f64 / nb as f64;
    let tb_max = insts.iter().map(|i| i.table.bytes()).max().unwrap_or(0);
    let tb_pop_mean = tables.iter().map(Table::bytes).sum::<usize>() as f64 / tables.len() as f64;
    with_stats["scene"] = json!({
        "bubbles": nb, "v_peak_ms": peak, "v_cut_ms": cut, "r_inf_m": r_inf,
        "r_inf_max_m": r_inf.iter().cloned().fold(0.0, f64::max),
        "table_bytes_mean_inst": tb_mean, "table_bytes_max": tb_max, "table_bytes_mean_pop": tb_pop_mean,
        "setup_s": t0.elapsed().as_secs_f64(),
    });
    BubbleScene { insts, grid, zi }
}

// ---------------------------------------------------------------- нынешняя модель
struct CurrentScene {
    setup: Setup,
    state: State,
    th_one: AtmoThermal,
    n_th: usize,
}

fn make_thermal(id: i64, x: f64, z: f64) -> AtmoThermal {
    let mut th = AtmoThermal::blank(id);
    th.src = [x as f32, 0.0, z as f32];
    th.top = ZL;
    th.strength = W0;
    th.radius = TOP_R_FRAC * ZL;
    th.t_birth = -1.0e4;
    th.t_grow = 100.0;
    th.t_mature = 1.0e7; // зрелость, огибающая 1
    th.t_decay = 1000.0;
    th
}

fn current_scene(rng: &mut Rng) -> CurrentScene {
    let cfg = ThermalCfg::default();
    let setup = Setup {
        edge_k: cfg.edge_factor,
        edge_w: cfg.edge_width,
        cfg,
        w: WeatherView::new(serde_json::Map::new()),
        wind: WindModel::new(WindCfg::default()),
        seed: 0,
        ax: [0.0, 1.0],
        cx: [-1.0, 0.0],
        street: 0.0,
        street_spacing: 3000.0,
        spacing: 2000.0,
        cloudbase_msl: 0.0,
        ins: 1.0,
        sun: [0.0, 1.0, 0.0],
        static_only: false,
        air: None,
    };
    let n_th = (N_ALLEN * PI * DISC_R * DISC_R).round() as usize;
    let all: Vec<Arc<AtmoThermal>> = (0..n_th)
        .map(|i| {
            let (x, z) = rng.disc(DISC_R);
            Arc::new(make_thermal(i as i64, x, z))
        })
        .collect();
    let state = State::build(&setup, all, 0.0, &[[0.0, 0.0]], setup.cfg.refresh_interval_s, 0);
    CurrentScene { setup, state, th_one: make_thermal(0, 0.0, 0.0), n_th }
}

// ---------------------------------------------------------------- замеры
thread_local! {
    static MED: RefCell<HashMap<String, Vec<f64>>> = RefCell::new(HashMap::new());
}

/// Замер: `f(i)` — один опрос точки `i`; в `MED` кладём ns/точку каждой выборки criterion.
fn bench_points(c: &mut Criterion, name: &str, n: usize, mut f: impl FnMut(usize)) {
    let mut off = 0usize;
    c.bench_function(name, |b| {
        b.iter_custom(|iters| {
            let t0 = Instant::now();
            for i in 0..iters as usize {
                f((off + i) % n);
            }
            let dt = t0.elapsed();
            off = (off + iters as usize) % n;
            MED.with(|m| m.borrow_mut().entry(name.to_string()).or_default().push(dt.as_nanos() as f64 / iters as f64));
            dt
        })
    });
}

fn median(name: &str) -> Option<f64> {
    MED.with(|m| {
        let mut v = m.borrow().get(name)?.clone();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        (!v.is_empty()).then(|| v[v.len() / 2])
    })
}

fn cpu_name() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|t| t.lines().find(|l| l.starts_with("model name")).map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string()))
        .unwrap_or_else(|| "unknown".into())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let test_mode = args.iter().any(|a| a == "--test");
    let fx = load_fixture();
    let zi = fx.env.zi;

    // --- порт против Python
    let (mut max_err, mut max_ref) = (0.0f64, 0.0f64);
    let mut per_case = Vec::new();
    for c in &fx.cases {
        let bs: Vec<Bubble> = c.states.iter().map(|s| Bubble::new(*s)).collect();
        let (mut e, mut m) = (0.0f64, 0.0f64);
        for (p, vp) in c.points.iter().zip(&c.v) {
            let mut v = [0.0; 3];
            for b in &bs {
                let w = b.velocity(*p, zi);
                for k in 0..3 {
                    v[k] += w[k];
                }
            }
            e = e.max(norm(&[v[0] - vp[0], v[1] - vp[1], v[2] - vp[2]]));
            m = m.max(norm(vp));
        }
        per_case.push(json!({"case": c.name, "max_abs_err": e, "max_ref": m, "rel": e / m}));
        max_err = max_err.max(e);
        max_ref = max_ref.max(m);
    }
    let port_err = max_err / max_ref;
    println!("port_max_rel_err = {port_err:e}");

    // --- сцены
    let mut rng = Rng(0x7B_0003);
    let mut stats = json!({});
    let cur = current_scene(&mut rng);
    let bs = build_scene(&fx, &mut rng, &mut stats);
    let pts: Vec<[f64; 3]> = (0..N_POINTS)
        .map(|_| {
            let (x, y) = rng.disc(POINT_R);
            [x, y, rng.range(1.0, zi - 1.0)]
        })
        .collect();
    let pts32: Vec<[f32; 3]> = pts.iter().map(|p| [p[0] as f32, p[2] as f32, p[1] as f32]).collect(); // оси игры (x, y вверх, z)

    // --- статистика сцен (вне замера)
    let mut n_pb = 0usize;
    let (mut hit, mut tot_list) = (0usize, 0usize);
    for p in &pts {
        bs.for_near(*p, |_| n_pb += 1);
        let key = ((p[0] / BUCKET).floor() as i64, (p[1] / BUCKET).floor() as i64);
        if let Some(l) = bs.grid.get(&key) {
            hit += 1;
            tot_list += l.len();
        }
    }
    let bubbles_per_point = n_pb as f64 / N_POINTS as f64;
    let (mut cur_nonzero, mut cur_w2) = (0usize, 0.0f64);
    for p in &pts32 {
        let r = cur.state.sample(&cur.setup, &NoClouds, *p, 0.0);
        if r[0] != 0.0 {
            cur_nonzero += 1;
        }
        cur_w2 += r[0] * r[0];
    }
    // сколько термиков в бакете точки (нынешний): считаем по тем же ключам обратным ходом через contribution
    let mut cur_in_bucket = 0usize;
    for p in &pts32 {
        for th in &cur.state.active {
            let ph = th.phase(0.0);
            let sk = [th.suck, 0.0];
            let e = Edge { k: cur.setup.edge_k, w: cur.setup.edge_w };
            if contribution(th, &ph, &cur.setup.cfg, e, *p, sk).is_some() {
                cur_in_bucket += 1;
            }
        }
    }
    stats["current"] = json!({
        "thermals": cur.n_th, "active": cur.state.active.len(),
        "points_nonzero_frac": cur_nonzero as f64 / N_POINTS as f64,
        "contributing_thermals_per_point": cur_in_bucket as f64 / N_POINTS as f64,
        "w_rms_ms": (cur_w2 / N_POINTS as f64).sqrt(),
    });
    stats["bubble"] = json!({
        "bubbles_per_point": bubbles_per_point,
        "points_with_nonempty_bucket_frac": hit as f64 / N_POINTS as f64,
        "mean_bucket_list_len": if hit > 0 { tot_list as f64 / hit as f64 } else { 0.0 },
    });

    // --- точность таблицы: фикстура (одиночные состояния, точки внутри r_inf = 3000) и случайные точки сцены
    let mut tab_rel = 0.0f64;
    {
        let (mut e, mut m) = (0.0f64, 0.0f64);
        for c in fx.cases.iter().filter(|c| c.states.len() == 1) {
            let st = c.states[0];
            let b = Bubble::new(st);
            let t = Table::build(&b, 1500.0, zi);
            for (p, vp) in c.points.iter().zip(&c.v) {
                if (p[0] - st.xc).hypot(p[1] - st.yc) < 1400.0 {
                    let v = t.sample(&st, *p);
                    e = e.max(norm(&[v[0] - vp[0], v[1] - vp[1], v[2] - vp[2]]));
                    m = m.max(norm(vp));
                }
            }
        }
        tab_rel = tab_rel.max(e / m);
    }
    let (mut te, mut tm, mut te_cut) = (0.0f64, 0.0f64, 0.0f64);
    let v_cut = stats["scene"]["v_cut_ms"].as_f64().unwrap();
    for p in pts.iter().step_by(10) {
        let a = bs.analytic(*p);
        let t = bs.table(*p);
        let d = norm(&[a[0] - t[0], a[1] - t[1], a[2] - t[2]]);
        te = te.max(d);
        tm = tm.max(norm(&a));
        te_cut += d * d;
    }
    stats["table"] = json!({
        "rel_err_fixture_max": tab_rel,
        "scene_max_abs_err_ms": te, "scene_rel_err_to_peak": te / tm.max(1e-12),
        "scene_rms_err_ms": (te_cut / (N_POINTS / 10) as f64).sqrt(), "v_cut_ms": v_cut,
        "step_m": TABLE_STEP,
    });
    stats["port"] = json!(per_case);
    println!("{}", serde_json::to_string_pretty(&stats).unwrap());

    // --- замеры
    let mut c = Criterion::default()
        .configure_from_args()
        .sample_size(30)
        .warm_up_time(Duration::from_secs(1))
        .measurement_time(Duration::from_secs(4));
    // current_contribution: точки в ядре одного термика (x² ≤ 1 на своей высоте)
    let one: Vec<[f32; 3]> = (0..N_POINTS)
        .map(|_| {
            let xi: f64 = rng.range(0.05, 0.95);
            let h = xi * ZL;
            let rr = TOP_R_FRAC * ZL * xi.cbrt() * (1.0 - 0.25 * xi) / 0.75;
            let (x, z) = rng.disc(rr);
            [x as f32, h as f32, z as f32]
        })
        .collect();
    let cfg = &cur.setup.cfg;
    let edge = Edge { k: cur.setup.edge_k, w: cur.setup.edge_w };
    let ph = cur.th_one.phase(0.0);
    let mut sink = 0.0f64;
    bench_points(&mut c, "current_contribution", N_POINTS, |i| {
        if let Some(r) = contribution(&cur.th_one, &ph, cfg, edge, black_box(one[i]), [0.0, 0.0]) {
            sink += r.w;
        }
    });
    bench_points(&mut c, "current_sample", N_POINTS, |i| {
        let r = cur.state.sample(&cur.setup, &NoClouds, black_box(pts32[i]), 0.0);
        sink += r[0];
    });
    bench_points(&mut c, "bubble_analytic", N_POINTS, |i| {
        let r = bs.analytic(black_box(pts[i]));
        sink += r[2];
    });
    bench_points(&mut c, "bubble_table", N_POINTS, |i| {
        let r = bs.table(black_box(pts[i]));
        sink += r[2];
    });
    black_box(sink);
    c.final_summary();

    if test_mode {
        println!("--test: bench.json не пишется");
        return;
    }
    let names = ["current_contribution", "current_sample", "bubble_analytic", "bubble_table"];
    let med: Vec<Option<f64>> = names.iter().map(|n| median(n)).collect();
    if med.iter().any(Option::is_none) {
        println!("не все замеры сделаны (фильтр?) — bench.json не пишется");
        return;
    }
    let m = |i: usize| med[i].unwrap();
    let sc = &stats["scene"];
    let out = json!({
        "format": "tb-bench", "version": 1,
        "machine": {"cpu": cpu_name(), "threads": std::thread::available_parallelism().map_or(0, |n| n.get())},
        "profile": "release",
        "ns_per_point": {
            "current_contribution": m(0), "current_sample": m(1), "bubble_analytic": m(2), "bubble_table": m(3),
        },
        "bubbles_per_point": bubbles_per_point,
        "table_bytes": sc["table_bytes_mean_inst"].as_f64().unwrap().round() as i64,
        "port_max_rel_err": port_err,
        "extra": {
            "scene": stats["scene"], "current": stats["current"], "bubble": stats["bubble"],
            "table": stats["table"], "port_cases": stats["port"],
            "setup": {
                "density_per_m2": N_ALLEN, "zl_m": ZL, "w0_ms": W0, "disc_r_m": DISC_R, "point_r_m": POINT_R,
                "n_points": N_POINTS, "cut_frac": CUT_FRAC, "bucket_m": BUCKET,
            },
        },
    });
    let dir = out_dir();
    let tmp = dir.join("bench.json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&out).unwrap()).unwrap();
    std::fs::rename(&tmp, dir.join("bench.json")).unwrap();
    println!("записан {}", dir.join("bench.json").display());
}
