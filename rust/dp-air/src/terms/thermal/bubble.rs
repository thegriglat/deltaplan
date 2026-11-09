//! Шаблон пузыря-термика (TB4 v1): порт `tools/research/thermal_bubble/bubble.py` v2 (TB1) и таблицы
//! `(u_ρ, w)` на пузырь для опроса.
//!
//! Аналитика (голова Хилла, шлейф MTT с виртуальным источником, линия стоков квадратурой Гаусса, образы
//! земли и крышки) нужна только для сборки таблиц и тестов; опрос игры — билинейная выборка из
//! [`BubbleTable`]. Ось прототипа — x, y горизонталь, z вверх; здесь пузырь сразу в своей осесимметричной
//! системе: центр `(0, 0)`, точка `(ρ, z над землёй)`.
//!
//! Соответствие термику игры — в одном месте, [`source_of`] (TB-8 заменит F0 на `from_strength`).
use super::life::AtmoThermal;
use rayon::prelude::*;
use std::f64::consts::PI;

// ---------------------------------------------------------------- числа шаблона (как в bubble.py v2)
const AL_P: f64 = 0.12; // PARAMS["alpha_plume"]
const AL_H: f64 = 0.15; // alpha_head
const AL_T: f64 = 0.25; // alpha_thermal
const PHI: f64 = 0.6; // front_fraction
const S0: f64 = 3.0;
const BLEND: f64 = 0.5;
const PANEL: f64 = 0.6;
const GL_N: usize = 8;
const END_FRAC: f64 = 0.02;
/// Радиус шлейфа у земли / z_l (Аллен 2006: r₂(ζ = 0,1)/z_l = 0,0461).
fn b0_frac() -> f64 {
    0.102 * 0.1f64.powf(1.0 / 3.0) * (1.0 - 0.25 * 0.1)
}

/// Шаг таблицы у оси и по высоте, м (контракт TB4: ≤ 5 м).
pub const STEP_AXIS_M: f64 = 4.0;
/// Рост шага по ρ за зоной головы: на 4 % расстояния от её края.
const STEP_GROWTH: f64 = 0.04;
/// Порог радиуса влияния: доля пика (силы термика).
pub const INFLUENCE_FRAC: f64 = 0.01;
/// Верхний предел радиуса таблицы, м.
pub const R_CAP_M: f64 = 3000.0;

fn ss(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    x * x * x * (10.0 - 15.0 * x + 6.0 * x * x)
}

fn dss(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    30.0 * x * x * (1.0 - x) * (1.0 - x)
}

fn kp(f0: f64) -> f64 {
    5.0 / (6.0 * AL_P) * (0.9 * AL_P * f0 / PI).cbrt()
}

fn cq(f0: f64) -> f64 {
    PI * 1.2 * AL_P * (0.9 * AL_P * f0 / PI).cbrt()
}

fn zv_of(b0: f64) -> f64 {
    5.0 * b0 / (6.0 * AL_P)
}

// ---------------------------------------------------------------- вход и состояние
/// Источник пузыря (`bubble.Source`): центр в системе пузыря всегда `(0, 0)`, снос задаёт игра.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Source {
    pub t0: f64,
    /// Поток плавучести источника, м⁴/с³.
    pub f0: f64,
    /// Сколько источник включён, с.
    pub tau: f64,
    /// Радиус шлейфа у земли, м.
    pub b0: f64,
    /// Время гашения головы у крышки, с.
    pub t_decay: f64,
}

impl Source {
    /// `bubble.from_game`: F0 = w*³·z_l/8,5; b0 = 0,0461·z_l; t_decay = z_l/w*; `tau` задаёт вызывающий
    /// (в игре — `t_grow + t_mature`; у `from_game` Python — 690 с).
    pub fn from_game(t0: f64, wstar: f64, zl: f64, tau: f64) -> Source {
        Source {
            t0,
            f0: wstar.powi(3) * zl / 8.5,
            tau,
            b0: b0_frac() * zl,
            t_decay: zl / wstar,
        }
    }
}

/// Состояние пузыря (`bubble.State` без осей шлейфа): ось вертикальна, центр головы `(0, 0, zc)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BState {
    pub zc: f64,
    pub r: f64,
    pub u: f64,
    pub q: f64,
    pub f0: f64,
    pub zb: f64,
    /// Сила поля головы (Хилл), м/с; `< 0` — равна `u`.
    pub uh: f64,
    pub b0: f64,
}

// ---------------------------------------------------------------- траектория
fn s0_of(zv: f64) -> f64 {
    (1.0 + AL_H) * zv / (1.0 - AL_H)
}

/// Фронт стартового факела: `(s_f, ds_f/dt)`.
fn front(f0: f64, zv: f64, tp: f64) -> (f64, f64) {
    let k = kp(f0);
    let s = (s0_of(zv).powf(4.0 / 3.0) + 4.0 / 3.0 * PHI * k * tp).powf(0.75);
    (s, PHI * k * s.powf(-1.0 / 3.0))
}

/// `(zc, R, U)` без крышки.
fn raw(src: &Source, tp: f64) -> (f64, f64, f64) {
    let zv = zv_of(src.b0);
    let k = 1.0 + AL_H;
    if tp <= src.tau {
        let (sf, vf) = front(src.f0, zv, tp);
        let sc = sf / k;
        return (sc - zv, AL_H * sc, vf / k);
    }
    let (sf, vf) = front(src.f0, zv, src.tau);
    let sc0 = sf / k;
    let (zc0, r0) = (sc0 - zv, AL_H * sc0);
    let zvt = zc0 - r0 / AL_T;
    let kk = (vf / k) * (r0 / AL_T);
    let d = ((r0 / AL_T).powi(2) + 2.0 * kk * (tp - src.tau)).sqrt();
    (zvt + d, AL_T * d, kk / d)
}

fn onset(src: &Source, tp: f64) -> f64 {
    let (_, r, u) = raw(src, 0.0);
    ss(tp / (r / u))
}

fn free(src: &Source, zi: f64, te: f64) -> f64 {
    let (zc, r, _) = raw(src, te);
    ss((zi - zc - r) / r.max(1e-9))
}

/// Таблица траектории (`bubble._Traj`): собственное время головы, гашение вихря, низ шлейфа; шаг 1 с.
#[derive(Clone, Debug)]
pub struct Traj {
    te: Vec<f64>,
    theta: Vec<f64>,
    zb: Vec<f64>,
    pub t_end: f64,
}

const TRAJ_DT: f64 = 1.0;

fn interp(tab: &[f64], tp: f64) -> f64 {
    // np.interp(tp, arange(n)·dt, tab): вне сетки — крайние значения
    let x = tp / TRAJ_DT;
    if x <= 0.0 {
        return tab[0];
    }
    let n = tab.len();
    if x >= (n - 1) as f64 {
        return tab[n - 1];
    }
    let i = x.floor() as usize;
    let f = x - i as f64;
    tab[i] + (tab[i + 1] - tab[i]) * f
}

fn tail(src: &Source, zb_t: f64, tp: f64, zc: f64, r: f64) -> (f64, f64) {
    if tp <= src.tau {
        return (0.0, 1.0);
    }
    let top = zc - r;
    let zb = zb_t.min(top);
    let lf = (2.0 * r).min(0.4 * top);
    let f = if lf > 0.0 { ss((top - zb) / lf) } else { 0.0 };
    (zb, f)
}

fn state_tp(src: &Source, zi: f64, tr: &Traj, tp: f64) -> BState {
    let te = interp(&tr.te, tp);
    let th = interp(&tr.theta, tp);
    let zbt = interp(&tr.zb, tp);
    let (zc, r, ur) = raw(src, te);
    let sf = ss((zi - zc - r) / r.max(1e-9));
    let (zb, mut f) = tail(src, zbt, tp, zc, r);
    let on = onset(src, tp);
    f *= on;
    let f0 = src.f0 * f * f * f;
    let top = zc - r + zv_of(src.b0);
    let q = if f0 > 0.0 {
        cq(f0) * top.powf(5.0 / 3.0)
    } else {
        0.0
    };
    BState {
        zc,
        r,
        u: ur * sf,
        q,
        f0,
        zb,
        uh: ur * on * (-th).exp(),
        b0: src.b0,
    }
}

fn amp(src: &Source, zi: f64, tr: &Traj, tp: f64) -> f64 {
    let st = state_tp(src, zi, tr, tp);
    let uh = if st.uh < 0.0 { st.u } else { st.uh };
    let mut wp = 0.0;
    if st.f0 > 0.0 {
        wp = kp(st.f0) * (st.zb + zv_of(st.b0) + st.b0).powf(-1.0 / 3.0);
    }
    (2.5 * uh).max(wp)
}

impl Traj {
    /// `bubble._traj`: гладкая остановка у крышки, низ шлейфа, конец жизни по оценке амплитуды.
    pub fn new(src: &Source, zi: f64) -> Traj {
        let dt = TRAJ_DT;
        let t_cap = 4.0 * src.tau + 3000.0;
        let n = (t_cap / dt) as usize + 2;
        let (mut te, mut th, mut zb) = (vec![0.0; n], vec![0.0; n], vec![0.0; n]);
        let zv = zv_of(src.b0);
        let k = kp(src.f0);
        let t_up = 3.0 * src.b0 / (k * zv.powf(-1.0 / 3.0));
        for i in 1..n {
            let tm = (i as f64 - 0.5) * dt - src.tau;
            let st = ss(tm / t_up);
            let zm = zb[i - 1] + 0.5 * dt * k * (zb[i - 1] + zv).powf(-1.0 / 3.0) * st;
            zb[i] = zb[i - 1] + dt * k * (zm + zv).powf(-1.0 / 3.0) * st;
            let a = te[i - 1];
            let k1 = free(src, zi, a);
            let k2 = free(src, zi, a + 0.5 * dt * k1);
            te[i] = a + dt * k2;
            let sf = 0.5 * (k1 + k2);
            th[i] = th[i - 1] + dt * (1.0 - sf) / src.t_decay;
        }
        let mut tr = Traj {
            te,
            theta: th,
            zb,
            t_end: t_cap,
        };
        let a: Vec<f64> = (0..n).map(|i| amp(src, zi, &tr, i as f64 * dt)).collect();
        let (mut pk, mut ipk) = (a[0], 0usize);
        for (i, &x) in a.iter().enumerate() {
            if x > pk {
                pk = x;
                ipk = i;
            }
        }
        let t_end = a[ipk..]
            .iter()
            .position(|&x| x < END_FRAC * pk)
            .map_or(t_cap, |j| (ipk + j) as f64 * dt);
        tr.t_end = t_end.min(t_cap);
        tr
    }

    /// `bubble.state` для времени от начала выпуска `tp` (ветра нет: центр в `(0, 0)`).
    pub fn state(&self, src: &Source, zi: f64, tp: f64) -> Option<BState> {
        if tp <= 0.0 || tp >= self.t_end {
            return None;
        }
        Some(state_tp(src, zi, self, tp))
    }
}

/// `bubble.state` в момент `t` (строит траекторию; для многих моментов — [`Traj`]).
pub fn state(src: &Source, zi: f64, t: f64) -> Option<BState> {
    Traj::new(src, zi).state(src, zi, t - src.t0)
}

// ---------------------------------------------------------------- поле одного пузыря
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

/// Шлейф: вертикальная ось, начало `s` — виртуальный источник на глубине `z_v`.
#[derive(Clone)]
struct Plume {
    zv: f64,
    k: f64,
    s: Vec<f64>,
    m4: Vec<f64>, // сила стоков / 4π (отрицательная)
}

impl Plume {
    fn new(st: &BState) -> Plume {
        let zv = zv_of(st.b0);
        let l = st.zc + zv;
        let sb = st.zb + zv;
        let stb = st.zc - st.r + zv;
        let cqv = cq(st.f0);
        let lb = st.b0.max(0.5 * st.zb);
        let lt = st.r;
        let k = 1.2 * AL_P;
        let mut pts = [sb, sb + lb, stb, l];
        pts.sort_by(|a, b| a.total_cmp(b));
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
        Plume { zv, k, s, m4 }
    }

    /// `(u_s, B, ψ)` в точке `(ρ², s)` по линии стоков.
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

    /// Скорость в точке `(dx, dy, z)` относительно оси (z — над землёй).
    fn velocity(&self, dx: f64, dy: f64, z: f64) -> [f64; 3] {
        let s = z + self.zv;
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

fn hill(st: &BState, dx: f64, dy: f64, s: f64) -> [f64; 3] {
    let rho2 = dx * dx + dy * dy;
    let r2 = rho2 + s * s;
    let u = if st.uh < 0.0 { st.u } else { st.uh };
    let rr = st.r;
    if r2 < rr * rr {
        let k = 1.5 * u * s / (rr * rr);
        [
            k * dx,
            k * dy,
            u + 1.5 * u * (1.0 - r2 / (rr * rr)) - 1.5 * u * rho2 / (rr * rr),
        ]
    } else {
        let r = r2.sqrt();
        let r5 = r.powi(5);
        let k = 1.5 * u * rr.powi(3) * s / r5;
        [
            k * dx,
            k * dy,
            u * rr.powi(3) / (r * r * r) - 1.5 * u * rr.powi(3) * rho2 / r5,
        ]
    }
}

/// Один пузырь: состояние и предрасчитанный шлейф.
#[derive(Clone)]
pub struct Bubble {
    pub st: BState,
    plume: Option<Plume>,
}

impl Bubble {
    pub fn new(st: BState) -> Bubble {
        let plume = (st.f0 > 0.0 && st.zb < st.zc - 1e-6).then(|| Plume::new(&st));
        Bubble { st, plume }
    }

    /// Вклад без образов: точка `(dx, dy)` от оси, высота `z` (над землёй, может быть образом).
    fn contribution(&self, dx: f64, dy: f64, z: f64) -> [f64; 3] {
        let uh = if self.st.uh < 0.0 {
            self.st.u
        } else {
            self.st.uh
        };
        let mut v = if uh != 0.0 {
            hill(&self.st, dx, dy, z - self.st.zc)
        } else {
            [0.0; 3]
        };
        if let Some(pl) = &self.plume {
            let w = pl.velocity(dx, dy, z);
            for i in 0..3 {
                v[i] += w[i];
            }
        }
        v
    }

    /// Возмущение в точке `(dx, dy)` от оси на высоте `z`: сумма по образам земли и крышки (n = −2..2,
    /// оба знака). `z` вне `[0, zi]` — 0.
    pub fn velocity(&self, dx: f64, dy: f64, z: f64, zi: f64) -> [f64; 3] {
        if z < 0.0 || z > zi {
            return [0.0; 3];
        }
        let mut acc = [0.0; 3];
        for n in -2..=2 {
            for sgn in [1.0, -1.0] {
                let v = self.contribution(dx, dy, sgn * z + 2.0 * n as f64 * zi);
                acc[0] += v[0];
                acc[1] += v[1];
                acc[2] += sgn * v[2];
            }
        }
        acc
    }
}

// ---------------------------------------------------------------- таблица (u_ρ, w)
/// Таблица `(u_ρ, w)` `f32` одного пузыря по `(ρ, z)`: ρ — узлы с шагом ≤ [`STEP_AXIS_M`] у оси (дальше
/// растёт), z — равномерно от 0 до `zi`; билинейная выборка; вне таблицы — 0.
#[derive(Clone, Debug)]
pub struct BubbleTable {
    rho: Vec<f64>,
    nz: usize,
    dz: f64,
    pub zi: f64,
    /// `data[i * nz + j]` — `(u_ρ, w)` в `(rho[i], j·dz)`.
    data: Vec<[f32; 2]>,
    /// Радиус таблицы (влияния), м.
    pub r_max: f64,
    /// Скорость подъёма головы на момент сборки, м/с: таблица сдвигается вверх на `U·(t − t_build)`.
    pub rise: f64,
    pub t_build: f64,
}

fn rho_nodes(r_max: f64, r_fine: f64) -> Vec<f64> {
    let mut v = vec![0.0];
    let mut r = 0.0;
    while r < r_max {
        let h = STEP_AXIS_M + STEP_GROWTH * (r - r_fine).max(0.0);
        r += h;
        v.push(r.min(r_max));
    }
    // последний узел ровно r_max, без вырожденного шага
    if v.len() > 2 && v[v.len() - 1] - v[v.len() - 2] < 1e-6 {
        v.pop();
    }
    v
}

impl BubbleTable {
    /// Сборка по состоянию; `r_max` — радиус влияния, `t_build` — момент состояния.
    pub fn build(b: &Bubble, zi: f64, r_max: f64, t_build: f64) -> BubbleTable {
        let r_fine = 1.5 * b.st.r + 150.0;
        let rho = rho_nodes(r_max.max(STEP_AXIS_M), r_fine);
        let nz = (zi / STEP_AXIS_M).ceil() as usize + 1;
        let dz = zi / (nz - 1) as f64;
        let mut data = vec![[0f32; 2]; rho.len() * nz];
        data.par_chunks_mut(nz).enumerate().for_each(|(i, col)| {
            for (j, c) in col.iter_mut().enumerate() {
                let v = b.velocity(rho[i], 0.0, (j as f64 * dz).min(zi), zi);
                *c = [v[0] as f32, v[2] as f32];
            }
        });
        BubbleTable {
            rho,
            nz,
            dz,
            zi,
            data,
            r_max,
            rise: b.st.u,
            t_build,
        }
    }

    pub fn bytes(&self) -> usize {
        self.data.len() * std::mem::size_of::<[f32; 2]>()
            + self.rho.len() * std::mem::size_of::<f64>()
    }

    /// `(u_ρ, w)` в `(ρ, z)`; `None` — вне таблицы (ρ ≥ r_max или z вне `[0, zi]`).
    #[inline]
    pub fn lookup(&self, rho: f64, z: f64) -> Option<[f64; 2]> {
        let last = self.rho.len() - 1;
        if !rho.is_finite()
            || !z.is_finite()
            || rho < 0.0
            || rho >= self.rho[last]
            || z < 0.0
            || z > self.zi
        {
            return None;
        }
        // узел слева: rho[i] ≤ ρ < rho[i + 1]
        let i = self.rho.partition_point(|&r| r <= rho) - 1;
        let fz = z / self.dz;
        let j = (fz as usize).min(self.nz - 2);
        let tz = fz - j as f64;
        let tr = (rho - self.rho[i]) / (self.rho[i + 1] - self.rho[i]);
        let at = |a: usize, b: usize| self.data[a * self.nz + b];
        let (c00, c01, c10, c11) = (at(i, j), at(i, j + 1), at(i + 1, j), at(i + 1, j + 1));
        let l = |k: usize| {
            f64::from(c00[k]) * (1.0 - tr) * (1.0 - tz)
                + f64::from(c01[k]) * (1.0 - tr) * tz
                + f64::from(c10[k]) * tr * (1.0 - tz)
                + f64::from(c11[k]) * tr * tz
        };
        Some([l(0), l(1)])
    }
}

/// Радиус влияния и пик `|v|`: ρ от оси, где `max_z |v|` ещё ≥ `cut`; сетка ρ шаг 40 м до [`R_CAP_M`], z шаг 100 м.
pub fn influence_radius(b: &Bubble, zi: f64, cut: f64) -> (f64, f64) {
    let nr = (R_CAP_M / 40.0) as usize;
    let prof: Vec<f64> = (0..=nr)
        .into_par_iter()
        .map(|i| {
            let mut m: f64 = 0.0;
            let mut z = 0.0;
            while z <= zi {
                let v = b.velocity(i as f64 * 40.0, 0.0, z, zi);
                m = m.max((v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt());
                z += 100.0;
            }
            m
        })
        .collect();
    let peak = prof.iter().copied().fold(0.0, f64::max);
    let r = prof
        .iter()
        .rposition(|&m| m >= cut)
        .map_or(0.0, |i| (i as f64 * 40.0 + 40.0).min(R_CAP_M));
    (r, peak)
}

// ---------------------------------------------------------------- термик игры → пузырь
/// Пузырь термика игры: земля — плоскость `src[1]`, крышка `zi = top − src[1]`; `None` — термик не
/// описывается шаблоном (статичный, нет силы или столба).
///
/// TB-7 (временно): F0 = w*³·z_l/8,5 с w* = `strength`, z_l = zi, tau = `t_grow + t_mature`
/// (`bubble.from_game`). TB-8 заменит тело на `from_strength(w0 = strength, zl, tau)` и добавит K̄.
pub fn source_of(th: &AtmoThermal) -> Option<(Source, f64)> {
    let zi = th.top - f64::from(th.src[1]);
    if th.is_static || th.strength <= 0.0 || zi < 100.0 || th.t_grow + th.t_mature <= 0.0 {
        return None;
    }
    let src = Source::from_game(th.t_birth, th.strength, zi, th.t_grow + th.t_mature);
    Some((src, zi))
}

/// Пузырь термика игры на момент `t` и его радиус влияния (порог — [`INFLUENCE_FRAC`] силы термика):
/// `(пузырь, zi, r_max)`; `None` — пузыря в этот момент нет.
pub fn prepare(th: &AtmoThermal, t: f64) -> Option<(Bubble, f64, f64)> {
    let (src, zi) = source_of(th)?;
    let st = state(&src, zi, t)?;
    let b = Bubble::new(st);
    let (r_max, _) = influence_radius(&b, zi, INFLUENCE_FRAC * th.strength);
    (r_max > 0.0).then_some((b, zi, r_max))
}

/// Таблица пузыря термика игры на момент `t` (сборка набора): `None` — пузыря в этот момент нет.
pub fn table_for(th: &AtmoThermal, t: f64) -> Option<BubbleTable> {
    let (b, zi, r_max) = prepare(th, t)?;
    Some(BubbleTable::build(&b, zi, r_max, t))
}

impl BubbleTable {
    /// Вклад в точке игры: `high` — высота над землёй источника, `dx`, `dz` — горизонталь от оси (x, z игры),
    /// `t` — момент опроса (сдвиг вверх на `U·(t − t_build)`). Возвращает `(w, [uh_x, uh_z])`.
    #[inline]
    pub fn eval(&self, high: f64, dx: f64, dz: f64, t: f64) -> (f64, [f64; 2]) {
        if !(0.0..=self.zi).contains(&high) {
            return (0.0, [0.0; 2]);
        }
        let z = (high - self.rise * (t - self.t_build)).clamp(0.0, self.zi);
        let rho = dx.hypot(dz);
        match self.lookup(rho, z) {
            None => (0.0, [0.0; 2]),
            Some([ur, w]) => {
                if rho < 1e-6 {
                    (w, [0.0; 2])
                } else {
                    (w, [ur * dx / rho, ur * dz / rho])
                }
            }
        }
    }
}
