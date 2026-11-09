//! Шаблон пузыря-термика (TB4 v2): порт `tools/research/thermal_bubble/bubble.py` v4 (TB1: ядро по измерениям,
//! оболочка ψ головы `hill_shell` 0,2R, `from_strength`) и таблицы `(u_ρ, w)` на пузырь для опроса.
//!
//! Аналитика (голова Хилла со сглаженным краем, шлейф MTT с виртуальным источником, линия стоков квадратурой
//! Гаусса, образы земли и крышки) нужна только для сборки таблиц и тестов; опрос игры — билинейная выборка из
//! [`BubbleTable`]. Ось прототипа — x, y горизонталь, z вверх; здесь пузырь сразу в своей осесимметричной
//! системе: центр `(0, 0)`, точка `(ρ, z над землёй)`.
//!
//! Соответствие термику игры — в одном месте, [`source_of`]: `from_strength(w0 = strength, zl, tau)`.
use super::life::AtmoThermal;
use rayon::prelude::*;
use std::f64::consts::PI;
use std::sync::OnceLock;

// ---------------------------------------------------------------- числа шаблона (как в bubble.py v4)
const AL_P: f64 = 0.12; // PARAMS["alpha_plume"]
const PHI: f64 = 0.6; // front_fraction
const SHELL: f64 = 0.2; // hill_shell: полная толщина оболочки смешения ψ, доли R
/// `core_flux_fraction` = A_CORE / A_UP = 0,13 / 0,35 (Аллен 2006; Lenschow & Stephens 1980, Stull 1988).
const CORE_FLUX_FRAC: f64 = 0.13 / 0.35;
const S0: f64 = 3.0;
const BLEND: f64 = 0.5;
const PANEL: f64 = 0.6;
const GL_N: usize = 8;
/// Квадратура линии стоков для таблиц (панель шире, меньше узлов): ошибка поля против точной — в `table_accuracy`.
const PANEL_TABLE: f64 = 1.2;
const GL_N_TABLE: usize = 4;
const END_FRAC: f64 = 0.02;
/// Отношение пиковой скорости термика игры к `w*`: `w0 = 1,24 w*` (`from_strength`, t_decay = 1,24·z_l/w0).
const W0_OVER_WSTAR: f64 = 1.24;
/// Радиус шлейфа у земли / z_l (Аллен 2006: r₂(ζ = 0,1)/z_l = 0,0461).
fn b0_frac() -> f64 {
    0.102 * 0.1f64.powf(1.0 / 3.0) * (1.0 - 0.25 * 0.1)
}

/// w/U на экваторе головы (R = 1, U = 1) при ρ = x со сглаженным краем (`bubble._eq_w`).
fn eq_w(x: f64, shell: f64) -> f64 {
    let (r1, r2) = (1.0 - 0.5 * shell, 1.0 + 0.5 * shell);
    let u = ((x - r1) / (r2 - r1)).clamp(0.0, 1.0);
    let sm = u.powi(3) * (10.0 - 15.0 * u + 6.0 * u * u);
    let dsm = 30.0 * u * u * (1.0 - u) * (1.0 - u) / (r2 - r1);
    let xs = x.max(r1);
    let (g_in, g_out) = (1.25 - 0.75 * x * x, 0.5 / xs.powi(3));
    let dgr = (1.0 - sm) * (-1.5) + sm * (-1.5 / xs.powi(5)) + dsm * (g_out - g_in) / xs;
    2.0 * ((1.0 - sm) * g_in + sm * g_out) + x * x * dgr
}

/// Радиус смены знака w на экваторе / R (бисекция, `bubble._sign_over_r`).
fn sign_over_r(shell: f64) -> f64 {
    let (mut lo, mut hi) = (0.5, 1.5);
    for _ in 0..60 {
        let mid = 0.5 * (lo + hi);
        if eq_w(mid, shell) > 0.0 {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    0.5 * (lo + hi)
}

/// Линейная МНК-подгонка радиуса ядра L&S 1980 `(α, z_h/z_i)` (`bubble._fit_core`): R/z_i = α(ζ + z_h/z_i)
/// на ζ = 0,2…0,8 (25 точек), радиус ядра = d/2 = радиус смены знака w.
fn fit_core(c_d: f64) -> (f64, f64) {
    let sg = sign_over_r(SHELL);
    let n = 25usize;
    let (mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0);
    for i in 0..n {
        let zeta = 0.2 + 0.6 * i as f64 / (n - 1) as f64;
        let r = 0.5 * c_d * zeta.cbrt() * (1.0 - 0.25 * zeta) / sg;
        sx += zeta;
        sy += r;
        sxx += zeta * zeta;
        sxy += zeta * r;
    }
    let nf = n as f64;
    let slope = (nf * sxy - sx * sy) / (nf * sxx - sx * sx);
    let icpt = (sy - slope * sx) / nf;
    (slope, icpt / slope)
}

/// `(alpha_thermal, z_h/z_l)` — считается один раз.
fn core_fit() -> (f64, f64) {
    static FIT: OnceLock<(f64, f64)> = OnceLock::new();
    *FIT.get_or_init(|| fit_core(0.16))
}

fn al_t() -> f64 {
    core_fit().0
}

/// Шаг таблицы у оси и по высоте, м (контракт TB4: ≤ 5 м).
pub const STEP_AXIS_M: f64 = 4.0;
/// Рост шага по ρ за зоной головы: на 4 % расстояния от её края.
const STEP_GROWTH: f64 = 0.04;
/// Порог радиуса влияния: доля пика (силы термика).
pub const INFLUENCE_FRAC: f64 = 0.01;
/// Оценка сверху радиуса таблицы в долях столба `z_l` для предотбора термиков до расчёта источника (по измерению на
/// стадиях жизни сцен `table_accuracy`: 0,14…0,43 `z_l` при пороге [`INFLUENCE_FRAC`]).
pub const R_GUESS_FRAC: f64 = 0.6;
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
    /// Вершина конуса головы под землёй, м: `R = α(z + z_h)`.
    pub zh: f64,
}

impl Source {
    /// `bubble.from_game` (v3): F0 = core_flux_fraction·w*³·z_l/8,5; b0 = 0,0461·z_l; t_decay = z_l/w*;
    /// z_h = (z_h/z_l)·z_l; `tau` задаёт вызывающий (в игре — `t_grow + t_mature`).
    pub fn from_game(t0: f64, wstar: f64, zl: f64, tau: f64) -> Source {
        Source {
            t0,
            f0: CORE_FLUX_FRAC * wstar.powi(3) * zl / 8.5,
            tau,
            b0: b0_frac() * zl,
            t_decay: zl / wstar,
            zh: core_fit().1 * zl,
        }
    }

    /// `bubble.from_strength` (без кеша): F0 подобран так, что максимум w на оси за жизнь = `w0` (секущая по
    /// log F0, не более 15 вычислений, останов при |ln(wmax/w0)| < 0,3 %). Остальное — как `from_game` с
    /// w* = w0/1,24 (`t_decay = 1,24·z_l/w0`). Крышка — `zi = zl`.
    pub fn from_strength(t0: f64, w0: f64, zl: f64, tau: f64) -> Source {
        let base = Source::from_game(t0, w0 / W0_OVER_WSTAR, zl, tau);
        let f = |lf: f64| -> f64 {
            let src = Source {
                f0: lf.exp(),
                ..base
            };
            (axis_wmax(&src, zl) / w0).ln()
        };
        let mut lf = base.f0.ln();
        let mut e = f(lf);
        let mut pts = vec![(lf, e)];
        for _ in 0..14 {
            if e.abs() < 0.003 {
                break;
            }
            let nl = if pts.len() == 1 {
                lf + 3.0 * (-e)
            } else {
                let ((la, ea), (lb, eb)) = (pts[pts.len() - 2], pts[pts.len() - 1]);
                let n = if (eb - ea).abs() > 1e-12 {
                    lb - eb * (lb - la) / (eb - ea)
                } else {
                    lb - 3.0 * eb
                };
                n.clamp(lb - 2.0, lb + 2.0)
            };
            lf = nl;
            e = f(nl);
            pts.push((lf, e));
        }
        let best = pts
            .iter()
            .copied()
            .min_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
            .unwrap_or((lf, e));
        Source {
            f0: best.0.exp(),
            ..base
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
/// Начало жизни `s = z + z_v`: голова радиуса R = α(z_c + z_h), посаженная на землю, верх головы — фронт.
fn s0_of(zv: f64, zh: f64) -> f64 {
    let al = al_t();
    2.0 * (al * zh / (1.0 - al)) + zv
}

/// Фронт стартового факела: `(s_f, ds_f/dt)`.
fn front(f0: f64, zv: f64, zh: f64, tp: f64) -> (f64, f64) {
    let k = kp(f0);
    let s = (s0_of(zv, zh).powf(4.0 / 3.0) + 4.0 / 3.0 * PHI * k * tp).powf(0.75);
    (s, PHI * k * s.powf(-1.0 / 3.0))
}

/// `(zc, R, U)` головы по фронту: верх z_f = z_c + R, R = α(z_c + z_h).
fn head_from_front(zf: f64, vf: f64, zh: f64) -> (f64, f64, f64) {
    let al = al_t();
    let zc = (zf - al * zh) / (1.0 + al);
    (zc, al * (zc + zh), vf / (1.0 + al))
}

/// `(zc, R, U)` без крышки: пока источник включён — голова на фронте шлейфа; после — свободный термик,
/// `U (z_c + z_h) = K` (подобие Скорера), радиус везде `α(z_c + z_h)`.
fn raw(src: &Source, tp: f64) -> (f64, f64, f64) {
    let zv = zv_of(src.b0);
    if tp <= src.tau {
        let (sf, vf) = front(src.f0, zv, src.zh, tp);
        return head_from_front(sf - zv, vf, src.zh);
    }
    let (sf, vf) = front(src.f0, zv, src.zh, src.tau);
    let (zc0, _, u0) = head_from_front(sf - zv, vf, src.zh);
    let d0 = zc0 + src.zh;
    let kk = u0 * d0;
    let d = (d0 * d0 + 2.0 * kk * (tp - src.tau)).sqrt();
    (d - src.zh, al_t() * d, kk / d)
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

/// Суммы по линии стоков `(u_s, B, ψ)`: четыре независимых накопителя (порядок суммы фиксирован, результат не
/// зависит от потоков), с AVX2 там, где он есть.
#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn sums3(sn: &[f64], m4: &[f64], rho2: f64, s: f64) -> (f64, f64, f64) {
    let n4 = sn.len() / 4 * 4;
    let (mut a, mut b, mut p) = ([0.0f64; 4], [0.0f64; 4], [0.0f64; 4]);
    for (cs, cm) in sn[..n4].chunks_exact(4).zip(m4[..n4].chunks_exact(4)) {
        for l in 0..4 {
            let ds = s - cs[l];
            let inv = 1.0 / (rho2 + ds * ds).sqrt();
            let inv3 = inv * inv * inv;
            a[l] += cm[l] * ds * inv3;
            b[l] -= cm[l] * inv3;
            p[l] -= cm[l] * ds * inv;
        }
    }
    let (mut ra, mut rb, mut rp) = (
        a[0] + a[1] + (a[2] + a[3]),
        b[0] + b[1] + (b[2] + b[3]),
        p[0] + p[1] + (p[2] + p[3]),
    );
    for i in n4..sn.len() {
        let ds = s - sn[i];
        let inv = 1.0 / (rho2 + ds * ds).sqrt();
        let inv3 = inv * inv * inv;
        ra += m4[i] * ds * inv3;
        rb -= m4[i] * inv3;
        rp -= m4[i] * ds * inv;
    }
    (ra, rb, rp)
}

/// Только ψ линии стоков (ось: `ρ² = b²`).
#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn psi3(sn: &[f64], m4: &[f64], rho2: f64, s: f64) -> f64 {
    let n4 = sn.len() / 4 * 4;
    let mut p = [0.0f64; 4];
    for (cs, cm) in sn[..n4].chunks_exact(4).zip(m4[..n4].chunks_exact(4)) {
        for l in 0..4 {
            let ds = s - cs[l];
            p[l] -= cm[l] * ds / (rho2 + ds * ds).sqrt();
        }
    }
    let mut rp = p[0] + p[1] + (p[2] + p[3]);
    for i in n4..sn.len() {
        let ds = s - sn[i];
        rp -= m4[i] * ds / (rho2 + ds * ds).sqrt();
    }
    rp
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
    fn new(st: &BState, panel: f64, gl_n: usize) -> Plume {
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
            let h = panel * k * 0.5 * (lo + hi);
            let n = (((hi - lo) / h).ceil() as usize).max(2);
            let step = (hi - lo) / n as f64;
            for i in 1..=n {
                edges.push(if i == n { hi } else { lo + step * i as f64 });
            }
        }
        let (g, gw) = gauss_legendre(gl_n);
        let (mut s, mut m4) = (Vec::new(), Vec::new());
        for e in edges.windows(2) {
            let (a, b) = (e[0], e[1]);
            for j in 0..gl_n {
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
        sums3(&self.s, &self.m4, rho2, s)
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

/// Голова: ψ = ρ² g(r), g = (1 − s) g_in + s g_out в оболочке `r ∈ [R(1 − δ/2), R(1 + δ/2)]` (s — квинтика),
/// g_in = U(5/4 − 3r²/4R²), g_out = (U/2)R³/r³ (Хилл). w = 2g + ρ² g′/r, u_ρ = −ρ s_z g′/r.
fn hill(st: &BState, dx: f64, dy: f64, sz: f64) -> [f64; 3] {
    let rho2 = dx * dx + dy * dy;
    let r2 = rho2 + sz * sz;
    let u = if st.uh < 0.0 { st.u } else { st.uh };
    let rr = st.r;
    let (r1, r2o) = (rr * (1.0 - 0.5 * SHELL), rr * (1.0 + 0.5 * SHELL));
    let r = r2.sqrt();
    let rs = r.max(r1);
    let x = ((r - r1) / (r2o - r1)).clamp(0.0, 1.0);
    let sm = x * x * x * (10.0 - 15.0 * x + 6.0 * x * x);
    let dsm = 30.0 * x * x * (1.0 - x) * (1.0 - x) / (r2o - r1);
    let g_in = u * (1.25 - 0.75 * r2 / (rr * rr));
    let g_out = 0.5 * u * rr.powi(3) / rs.powi(3);
    let g = (1.0 - sm) * g_in + sm * g_out;
    let dgr = (1.0 - sm) * (-1.5 * u / (rr * rr))
        + sm * (-1.5 * u * rr.powi(3) / rs.powi(5))
        + dsm * (g_out - g_in) / rs;
    [-sz * dgr * dx, -sz * dgr * dy, 2.0 * g + rho2 * dgr]
}

/// Один пузырь: состояние и предрасчитанный шлейф.
#[derive(Clone)]
pub struct Bubble {
    pub st: BState,
    plume: Option<Plume>,
}

/// Образы земли и крышки аналитики: `n = −2…2`, оба знака.
const IMAGES_ALL: [(i32, f64); 10] = [
    (-2, 1.0),
    (-2, -1.0),
    (-1, 1.0),
    (-1, -1.0),
    (0, 1.0),
    (0, -1.0),
    (1, 1.0),
    (1, -1.0),
    (2, 1.0),
    (2, -1.0),
];
/// Образы для сборки таблицы: сам пузырь, зеркало в земле и зеркало в крышке. Остальные (сдвиги на 2·zi и двойные
/// отражения) дальше `z_i` от точки: вклад ≤ Q/(4π z_i²) ≲ 10⁻³ м/с (проверяет `table_accuracy` против полной суммы).
const IMAGES_TABLE: [(i32, f64); 3] = [(0, 1.0), (0, -1.0), (1, -1.0)];

impl Bubble {
    pub fn new(st: BState) -> Bubble {
        Self::with_quadrature(st, PANEL, GL_N)
    }

    /// Пузырь с облегчённой квадратурой линии стоков (панель [`PANEL_TABLE`] b, Гаусс–Лежандр [`GL_N_TABLE`]) —
    /// для сборки таблиц.
    pub fn for_table(st: BState) -> Bubble {
        Self::with_quadrature(st, PANEL_TABLE, GL_N_TABLE)
    }

    fn with_quadrature(st: BState, panel: f64, gl_n: usize) -> Bubble {
        let plume = (st.f0 > 0.0 && st.zb < st.zc - 1e-6).then(|| Plume::new(&st, panel, gl_n));
        Bubble { st, plume }
    }

    fn uh_eff(&self) -> f64 {
        if self.st.uh < 0.0 {
            self.st.u
        } else {
            self.st.uh
        }
    }

    /// Вклад без образов: точка `(dx, dy)` от оси, высота `z` (над землёй, может быть образом).
    fn contribution(&self, dx: f64, dy: f64, z: f64) -> [f64; 3] {
        let mut v = self.hill_part(dx, dy, z);
        let w = self.plume_part(dx, dy, z);
        for i in 0..3 {
            v[i] += w[i];
        }
        v
    }

    fn hill_part(&self, dx: f64, dy: f64, z: f64) -> [f64; 3] {
        if self.uh_eff() != 0.0 {
            hill(&self.st, dx, dy, z - self.st.zc)
        } else {
            [0.0; 3]
        }
    }

    fn plume_part(&self, dx: f64, dy: f64, z: f64) -> [f64; 3] {
        self.plume
            .as_ref()
            .map_or([0.0; 3], |pl| pl.velocity(dx, dy, z))
    }

    /// Сумма вклада `part` по образам `set` (пары `(n, знак)`: `z′ = знак·z + 2n·zi`); `z` вне `[0, zi]` — 0.
    fn images(
        &self,
        dx: f64,
        dy: f64,
        z: f64,
        zi: f64,
        part: fn(&Bubble, f64, f64, f64) -> [f64; 3],
        set: &[(i32, f64)],
    ) -> [f64; 3] {
        if z < 0.0 || z > zi {
            return [0.0; 3];
        }
        let mut acc = [0.0; 3];
        for &(n, sgn) in set {
            let v = part(self, dx, dy, sgn * z + 2.0 * f64::from(n) * zi);
            acc[0] += v[0];
            acc[1] += v[1];
            acc[2] += sgn * v[2];
        }
        acc
    }

    /// Возмущение в точке `(dx, dy)` от оси на высоте `z`: сумма по образам земли и крышки (n = −2..2,
    /// оба знака). `z` вне `[0, zi]` — 0.
    pub fn velocity(&self, dx: f64, dy: f64, z: f64, zi: f64) -> [f64; 3] {
        self.images(dx, dy, z, zi, Bubble::contribution, &IMAGES_ALL)
    }
}

impl Plume {
    /// `w` на оси `ρ = 0`: труба `u_s = 2ψ_out(b, s)/b²` (только сумма ψ, остальное `velocity` на оси не даёт).
    fn axis_w(&self, z: f64) -> f64 {
        let s = z + self.zv;
        let b = self.k * (s * s + S0 * S0).sqrt();
        let b2 = b * b;
        let p = psi3(&self.s, &self.m4, b2, s);
        2.0 * p / b2
    }
}

impl Bubble {
    /// `w` на оси `ρ = 0` на высоте `z ∈ [0, zi]` с образами; то же число, что `velocity(0, 0, z, zi)[2]`.
    pub fn axis_w(&self, z: f64, zi: f64) -> f64 {
        if z < 0.0 || z > zi {
            return 0.0;
        }
        let uh = if self.st.uh < 0.0 {
            self.st.u
        } else {
            self.st.uh
        };
        let mut acc = 0.0;
        for n in -2..=2 {
            for sgn in [1.0, -1.0] {
                let zz = sgn * z + 2.0 * n as f64 * zi;
                let mut v = 0.0;
                if uh != 0.0 {
                    v += hill(&self.st, 0.0, 0.0, zz - self.st.zc)[2];
                }
                if let Some(pl) = &self.plume {
                    v += pl.axis_w(zz);
                }
                acc += sgn * v;
            }
        }
        acc
    }
}

/// Максимум `w` на оси за жизнь (`bubble._axis_wmax`): моменты шагом 10 с до конца жизни, ось `z = 1, 6, …` ≤ zi.
/// Тот же максимум по той же дискретной сетке, но без полного перебора: грубая сетка (каждый 3-й момент, каждая
/// 5-я высота), на ней три лучших локальных максимума, вокруг каждого — полный перебор мелкой сетки в пределах
/// грубого шага. Поле на оси гладко (голова ≥ 40 м, шлейф ≥ 60 м, жизнь ≥ минут); сверка с полным перебором —
/// [`axis_wmax_full`] и тест `axis_wmax_fast`.
pub fn axis_wmax(src: &Source, zi: f64) -> f64 {
    let tr = Traj::new(src, zi);
    let (times, nz) = axis_grid(&tr, zi);
    let nt = times.len();
    if nt == 0 {
        return 0.0;
    }
    let bubbles: Vec<std::sync::OnceLock<Option<Bubble>>> =
        (0..nt).map(|_| std::sync::OnceLock::new()).collect();
    let at = |k: usize, i: usize| -> f64 {
        let b = bubbles[k].get_or_init(|| tr.state(src, zi, times[k]).map(Bubble::new));
        b.as_ref()
            .map_or(0.0, |b| b.axis_w(1.0 + 5.0 * i as f64, zi))
    };
    const KS: usize = 3;
    const IS: usize = 5;
    let kc: Vec<usize> = coarse_idx(nt, KS);
    let ic: Vec<usize> = coarse_idx(nz, IS);
    // грубая сетка по моментам параллельно (OnceLock делает построение пузыря один раз)
    let grid: Vec<Vec<f64>> = kc
        .par_iter()
        .map(|&k| ic.iter().map(|&i| at(k, i)).collect())
        .collect();
    // локальные максимумы грубой сетки
    let mut peaks: Vec<(f64, usize, usize)> = Vec::new();
    for (a, row) in grid.iter().enumerate() {
        for (b, &v) in row.iter().enumerate() {
            let mut top = true;
            for da in [-1i64, 0, 1] {
                for db in [-1i64, 0, 1] {
                    let (na, nb) = (a as i64 + da, b as i64 + db);
                    if (da, db) != (0, 0)
                        && na >= 0
                        && nb >= 0
                        && (na as usize) < grid.len()
                        && (nb as usize) < row.len()
                        && grid[na as usize][nb as usize] > v
                    {
                        top = false;
                    }
                }
            }
            if top {
                peaks.push((v, a, b));
            }
        }
    }
    peaks.sort_by(|x, y| y.0.total_cmp(&x.0));
    peaks.truncate(3);
    let mut best = grid.iter().flatten().copied().fold(0.0f64, f64::max);
    // подъём по мелкой сетке от каждого пика: окно ±грубый шаг, сдвиг к лучшему узлу, пока он на краю окна
    for &(_, a, b) in &peaks {
        let (mut k, mut i) = (kc[a], ic[b]);
        let mut seen: std::collections::HashMap<(usize, usize), f64> =
            std::collections::HashMap::new();
        loop {
            let (k_lo, k_hi) = (k.saturating_sub(KS), (k + KS).min(nt - 1));
            let (i_lo, i_hi) = (i.saturating_sub(IS), (i + IS).min(nz - 1));
            let todo: Vec<(usize, usize)> = (k_lo..=k_hi)
                .flat_map(|kk| (i_lo..=i_hi).map(move |ii| (kk, ii)))
                .filter(|p| !seen.contains_key(p))
                .collect();
            let vals: Vec<f64> = todo.par_iter().map(|&(kk, ii)| at(kk, ii)).collect();
            for (p, v) in todo.into_iter().zip(vals) {
                seen.insert(p, v);
            }
            let (mut bk, mut bi, mut bv) = (k, i, f64::NEG_INFINITY);
            for kk in k_lo..=k_hi {
                for ii in i_lo..=i_hi {
                    let v = seen[&(kk, ii)];
                    if v > bv {
                        (bk, bi, bv) = (kk, ii, v);
                    }
                }
            }
            best = best.max(bv);
            let edge = (bk == k_lo && k_lo > 0)
                || (bk == k_hi && k_hi < nt - 1)
                || (bi == i_lo && i_lo > 0)
                || (bi == i_hi && i_hi < nz - 1);
            if !edge || (bk, bi) == (k, i) {
                break;
            }
            (k, i) = (bk, bi);
        }
    }
    best
}

/// Моменты `10, 20, … < t_end` и число высот оси `1, 6, … ≤ zi`.
fn axis_grid(tr: &Traj, zi: f64) -> (Vec<f64>, usize) {
    let nz = ((zi - 1.0) / 5.0 + 1e-9).floor() as usize + 1;
    let mut times = Vec::new();
    let mut k = 1usize;
    while (k as f64) * 10.0 < tr.t_end {
        times.push(k as f64 * 10.0);
        k += 1;
    }
    (times, nz)
}

/// Полный перебор сетки [`axis_wmax`] (сверка и тесты).
pub fn axis_wmax_full(src: &Source, zi: f64) -> f64 {
    let tr = Traj::new(src, zi);
    let (times, nz) = axis_grid(&tr, zi);
    times
        .par_iter()
        .map(|&tp| {
            let Some(st) = tr.state(src, zi, tp) else {
                return 0.0;
            };
            let b = Bubble::new(st);
            (0..nz)
                .map(|i| b.axis_w(1.0 + 5.0 * i as f64, zi))
                .fold(0.0f64, f64::max)
        })
        .reduce(|| 0.0, f64::max)
}

/// Средний по жизни и по столбу `0…zl` поток вверх `∫max(w,0)dA`, м³/с, пузыря `from_strength(w0, zl, tau)`
/// (`bubble.mean_up_flux`: сечения — середины 28 слоёв, моменты `15, 45, … < t_end`, ρ до 900 м, 90 узлов
/// трапеций). Только для сверки таблицы K̄ ([`super::bubble_kbar`]); дорого (секунды).
pub fn mean_up_flux(w0: f64, zl: f64, tau: f64) -> f64 {
    let src = Source::from_strength(0.0, w0, zl, tau);
    let tr = Traj::new(&src, zl);
    let nz = 28usize;
    let zs: Vec<f64> = (0..nz).map(|i| (i as f64 + 0.5) * zl / nz as f64).collect();
    let mut rho: Vec<f64> = (0..46).map(|i| 150.0 * i as f64 / 45.0).collect();
    rho.extend((1..45).map(|i| 150.0 + 750.0 * i as f64 / 44.0));
    let mut ts = Vec::new();
    let mut t = 15.0;
    while t < tr.t_end {
        ts.push(t);
        t += 30.0;
    }
    let acc: Vec<f64> = ts
        .par_iter()
        .map(|&t| {
            let Some(st) = tr.state(&src, zl, t) else {
                return 0.0;
            };
            let b = Bubble::new(st);
            let mut sum = 0.0;
            for &z in &zs {
                let w: Vec<f64> = rho
                    .iter()
                    .map(|&r| b.velocity(r, 0.0, z, zl)[2].max(0.0))
                    .collect();
                let mut f = 0.0;
                for i in 1..rho.len() {
                    f += 0.5
                        * (w[i - 1] * 2.0 * PI * rho[i - 1] + w[i] * 2.0 * PI * rho[i])
                        * (rho[i] - rho[i - 1]);
                }
                sum += f;
            }
            sum / nz as f64
        })
        .collect();
    acc.iter().sum::<f64>() / acc.len() as f64
}

// ---------------------------------------------------------------- таблица (u_ρ, w)
/// Положение пузыря по высоте над землёй: низ шлейфа и центр головы, м.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub zb: f64,
    pub zc: f64,
}

impl Frame {
    pub fn of(st: &BState) -> Frame {
        Frame {
            zb: st.zb,
            zc: st.zc,
        }
    }
}

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
    /// Состояние пузыря на момент сборки.
    pub st: BState,
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

/// Грубая подсетка: каждый `m`-й узел и последний.
fn coarse_idx(n: usize, m: usize) -> Vec<usize> {
    let mut v: Vec<usize> = (0..n).step_by(m).collect();
    if v.last() != Some(&(n - 1)) {
        v.push(n - 1);
    }
    v
}

/// Кубическая интерполяция Лагранжа по четырём ближайшим узлам грубой сетки (неравномерной).
#[derive(Clone, Copy)]
struct Stencil {
    c0: usize,
    w: [f64; 4],
}

fn stencil(xc: &[f64], x: f64) -> Stencil {
    let n = xc.len();
    let k = xc.partition_point(|&v| v <= x).saturating_sub(1).min(n - 2);
    let c0 = k.saturating_sub(1).min(n - 4);
    let mut w = [1.0; 4];
    for a in 0..4 {
        for b in 0..4 {
            if a != b {
                w[a] *= (x - xc[c0 + b]) / (xc[c0 + a] - xc[c0 + b]);
            }
        }
    }
    Stencil { c0, w }
}

impl Bubble {
    /// Голова с образами [`IMAGES_TABLE`] для сборки таблицы: образы дальше `15R` от точки не считаются (вклад Хилла ≤ 3·10⁻⁴ U).
    fn hill_for_table(&self, rho: f64, z: f64, zi: f64) -> [f64; 2] {
        if self.uh_eff() == 0.0 {
            return [0.0; 2];
        }
        let cut2 = (15.0 * self.st.r).powi(2);
        let (mut ur, mut w) = (0.0, 0.0);
        for &(n, sgn) in &IMAGES_TABLE {
            let zz = sgn * z + 2.0 * f64::from(n) * zi;
            let sz = zz - self.st.zc;
            if rho * rho + sz * sz > cut2 {
                continue;
            }
            let v = hill(&self.st, rho, 0.0, sz);
            ur += v[0];
            w += sgn * v[2];
        }
        [ur, w]
    }
}

/// Шаг грубой подсетки шлейфа по высоте при сборке таблицы (узлов): поле шлейфа по `z` меняется на масштабе радиуса у
/// земли `b0` (подъёмы профиля — `b0` и `R`), поэтому узлы подсетки не реже `b0/4`; по ρ — каждый узел (край трубы
/// и сшивка резки, кубическая интерполяция по ρ теряла 3× точности). Голова считается в каждом узле точно.
fn plume_stride_z(b0: f64) -> usize {
    ((b0 / (4.0 * STEP_AXIS_M)).floor() as usize).clamp(1, 6)
}

impl BubbleTable {
    /// Сборка по состоянию; `r_max` — радиус влияния, `t_build` — момент состояния. Голова (Хилл с образами) —
    /// в каждом узле; шлейф (дорогая линия стоков) — на грубой подсетке (каждый [`plume_stride_z`]-й узел по высоте) и
    /// кубической интерполяцией между узлами.
    pub fn build(b: &Bubble, zi: f64, r_max: f64, t_build: f64) -> BubbleTable {
        let r_fine = 1.5 * b.st.r + 150.0;
        let rho = rho_nodes(r_max.max(STEP_AXIS_M), r_fine);
        let nz = (zi / STEP_AXIS_M).ceil() as usize + 1;
        let dz = zi / (nz - 1) as f64;
        let nr = rho.len();
        let plume_at = |r: f64, z: f64| -> [f64; 2] {
            let v = b.images(r, 0.0, z, zi, Bubble::plume_part, &IMAGES_TABLE);
            [v[0], v[2]]
        };
        // шлейф: значения в узлах таблицы (f64) — `plume[i * nz + j]`
        let plume: Vec<[f64; 2]> = if b.plume.is_none() {
            vec![[0.0; 2]; nr * nz]
        } else {
            let sz_ = plume_stride_z(b.st.b0);
            let (ci, cj) = (coarse_idx(nr, 1), coarse_idx(nz, sz_));
            if ci.len() < 4 || cj.len() < 4 {
                (0..nr * nz)
                    .into_par_iter()
                    .map(|k| plume_at(rho[k / nz], ((k % nz) as f64 * dz).min(zi)))
                    .collect()
            } else {
                let xr: Vec<f64> = ci.iter().map(|&i| rho[i]).collect();
                let xz: Vec<f64> = cj.iter().map(|&j| (j as f64 * dz).min(zi)).collect();
                let coarse: Vec<Vec<[f64; 2]>> = xr
                    .par_iter()
                    .map(|&r| xz.iter().map(|&z| plume_at(r, z)).collect())
                    .collect();
                let sz: Vec<Stencil> = (0..nz)
                    .map(|j| stencil(&xz, (j as f64 * dz).min(zi)))
                    .collect();
                let sr: Vec<Stencil> = rho.iter().map(|&r| stencil(&xr, r)).collect();
                // по z для каждой грубой колонки
                let mid: Vec<Vec<[f64; 2]>> = coarse
                    .iter()
                    .map(|col| {
                        sz.iter()
                            .map(|s| {
                                let mut o = [0.0; 2];
                                for a in 0..4 {
                                    for c in 0..2 {
                                        o[c] += s.w[a] * col[s.c0 + a][c];
                                    }
                                }
                                o
                            })
                            .collect()
                    })
                    .collect();
                let mut out = vec![[0.0; 2]; nr * nz];
                out.par_chunks_mut(nz).enumerate().for_each(|(i, col)| {
                    let s = sr[i];
                    for (j, c) in col.iter_mut().enumerate() {
                        for a in 0..4 {
                            for k in 0..2 {
                                c[k] += s.w[a] * mid[s.c0 + a][j][k];
                            }
                        }
                    }
                });
                out
            }
        };
        let mut data = vec![[0f32; 2]; nr * nz];
        data.par_chunks_mut(nz).enumerate().for_each(|(i, col)| {
            for (j, c) in col.iter_mut().enumerate() {
                let z = (j as f64 * dz).min(zi);
                let h = b.hill_for_table(rho[i], z, zi);
                let p = plume[i * nz + j];
                *c = [(h[0] + p[0]) as f32, (h[1] + p[1]) as f32];
            }
        });
        BubbleTable {
            rho,
            nz,
            dz,
            zi,
            data,
            r_max,
            st: b.st,
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

    /// Высота в таблице для высоты `z` пузыря в положении `now`: земля неподвижна, шлейф растягивается между низом
    /// и центром головы вслед за подъёмом, выше головы — сдвиг на подъём головы; ниже оторвавшегося низа —
    /// сдвиг на его подъём.
    #[inline]
    pub fn z_tab(&self, z: f64, now: Frame) -> f64 {
        let (zb_b, zc_b) = (self.st.zb, self.st.zc);
        let zt = if z <= now.zb {
            z - (now.zb - zb_b)
        } else if z >= now.zc {
            z - (now.zc - zc_b)
        } else {
            let span = (now.zc - now.zb).max(1.0);
            zb_b + (z - now.zb) / span * (zc_b - zb_b)
        };
        zt.clamp(0.0, self.zi)
    }

    /// Вклад в точке игры: `high` — высота над землёй источника, `dx`, `dz` — горизонталь от оси (x, z игры),
    /// `now` — положение пузыря в момент опроса. Возвращает `(w, [uh_x, uh_z])`.
    #[inline]
    pub fn eval(&self, high: f64, dx: f64, dz: f64, now: Frame) -> (f64, [f64; 2]) {
        if !(0.0..=self.zi).contains(&high) {
            return (0.0, [0.0; 2]);
        }
        let z = self.z_tab(high, now);
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

/// Шаг ключевых кадров таблиц термика, с, в момент жизни `tp` (от рождения; `tau` — работа источника). Таблицы строятся
/// на ключевых кадрах `T₀ = 0, T₁ = T₀ + dt(T₀), …` (свои у каждого термика, не зависят от момента обновления набора);
/// между кадрами поле — линейная смесь двух таблиц, каждая приведена к текущему положению пузыря
/// ([`BubbleTable::z_tab`]). Ошибка смеси растёт там, где форма пузыря меняется быстро (становление головы, отрыв
/// источника и подъём оторвавшегося низа шлейфа): там кадры чаще — 15 с (измерено `table_accuracy`: через 30 с
/// ошибка 0,12 пика, через 15 с — 0,03); в спокойной зрелости и распаде — 30 с.
pub fn keyframe_dt(tp: f64, tau: f64) -> f64 {
    if tp < KF_ONSET_S || (tp > tau - 30.0 && tp < tau + KF_DETACH_S) {
        KEYFRAME_FAST_S
    } else {
        KEYFRAME_SLOW_S
    }
}

/// Частые кадры (с), редкие кадры, окно становления после рождения и окно после отрыва источника.
pub const KEYFRAME_FAST_S: f64 = 15.0;
pub const KEYFRAME_SLOW_S: f64 = 30.0;
pub const KF_ONSET_S: f64 = 90.0;
pub const KF_DETACH_S: f64 = 240.0;

/// Ключевые кадры `tp` термика до конца жизни пузыря (включая первый после конца: он нужен смеси).
pub fn keyframe_times(tau: f64, t_end: f64) -> Vec<f64> {
    let mut v = vec![0.0];
    while *v.last().unwrap_or(&0.0) < t_end {
        let t = *v.last().unwrap_or(&0.0);
        v.push(t + keyframe_dt(t, tau));
    }
    v
}

/// Пара таблиц ключевых кадров термика и положение пузыря в момент обновления `t0` (линейно по состояниям траектории
/// на `t0` и через интервал обновления; `rate` — м/с). Нет одной из таблиц (пузыря не было в тот кадр) — вес другой 1.
#[derive(Clone, Debug)]
pub struct Blend {
    pub a: Option<std::sync::Arc<BubbleTable>>,
    pub b: Option<std::sync::Arc<BubbleTable>>,
    /// Моменты ключевых кадров таблиц `a` и `b`.
    pub t_a: f64,
    pub t_b: f64,
    pub t0: f64,
    pub f0: Frame,
    pub rate: Frame,
}

impl Blend {
    /// Радиус влияния пары, м.
    pub fn r_max(&self) -> f64 {
        let r = |t: &Option<std::sync::Arc<BubbleTable>>| t.as_ref().map_or(0.0, |t| t.r_max);
        r(&self.a).max(r(&self.b))
    }

    #[inline]
    pub fn frame(&self, t: f64) -> Frame {
        let d = t - self.t0;
        Frame {
            zb: self.f0.zb + self.rate.zb * d,
            zc: self.f0.zc + self.rate.zc * d,
        }
    }

    /// `(w, [uh_x, uh_z])` в момент `t`.
    #[inline]
    pub fn eval(&self, high: f64, dx: f64, dz: f64, t: f64) -> (f64, [f64; 2]) {
        let now = self.frame(t);
        let l = ((t - self.t_a) / (self.t_b - self.t_a)).clamp(0.0, 1.0);
        let (wa, wb) = match (&self.a, &self.b) {
            (Some(_), Some(_)) => (1.0 - l, l),
            (Some(_), None) => (1.0, 0.0),
            _ => (0.0, 1.0),
        };
        let mut w = 0.0;
        let mut h = [0.0; 2];
        for (tb, k) in [(&self.a, wa), (&self.b, wb)] {
            if let (Some(tb), true) = (tb, k > 0.0) {
                let (wt, ht) = tb.eval(high, dx, dz, now);
                w += k * wt;
                h[0] += k * ht[0];
                h[1] += k * ht[1];
            }
        }
        (w, h)
    }
}

/// Радиус влияния и пик `|v|`: ρ от оси, где `max_z |v|` ещё ≥ `cut`; сетка ρ шаг 100 м до [`R_CAP_M`], z — 7 слоёв
/// по `zi`. Оценка сверху с точностью до шага (на границе поле плавное).
pub fn influence_radius(b: &Bubble, zi: f64, cut: f64) -> (f64, f64) {
    const STEP: f64 = 100.0;
    let nr = (R_CAP_M / STEP) as usize;
    let prof: Vec<f64> = (0..=nr)
        .into_par_iter()
        .map(|i| {
            let mut m: f64 = 0.0;
            for k in 0..=6 {
                let v = b.velocity(i as f64 * STEP, 0.0, zi * f64::from(k) / 6.0, zi);
                m = m.max((v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt());
            }
            m
        })
        .collect();
    let peak = prof.iter().copied().fold(0.0, f64::max);
    let r = prof
        .iter()
        .rposition(|&m| m >= cut)
        .map_or(0.0, |i| (i as f64 * STEP + STEP).min(R_CAP_M));
    (r, peak)
}

// ---------------------------------------------------------------- термик игры → пузырь
/// Входы шаблона для термика игры: `(w0, zi, tau)`; земля — плоскость `src[1]`, крышка `zi = top − src[1]`;
/// `None` — термик не описывается шаблоном (статичный, нет силы или столба).
pub fn bubble_inputs(th: &AtmoThermal) -> Option<(f64, f64, f64)> {
    let zi = th.top - f64::from(th.src[1]);
    if th.is_static || th.strength <= 0.0 || zi < 100.0 || th.t_grow + th.t_mature <= 0.0 {
        return None;
    }
    Some((th.strength, zi, th.t_grow + th.t_mature))
}

/// Источник пузыря термика игры: `from_strength(w0 = strength, zl = zi, tau = t_grow + t_mature)`, t0 = `t_birth`.
/// Дорого (секущая по F0) — в игре кешируется по `id` в [`BubbleCache`].
pub fn source_of(th: &AtmoThermal) -> Option<(Source, f64)> {
    let (w0, zi, tau) = bubble_inputs(th)?;
    Some((Source::from_strength(th.t_birth, w0, zi, tau), zi))
}

/// Таблица ключевого кадра на момент `tk`; `None` — пузыря в этот момент нет или радиус влияния 0.
pub fn build_keyframe(
    src: &Source,
    zi: f64,
    traj: &Traj,
    w0: f64,
    tk: f64,
) -> Option<std::sync::Arc<BubbleTable>> {
    let st = traj.state(src, zi, tk - src.t0)?;
    let b = Bubble::for_table(st);
    let (r_max, _) = influence_radius(&b, zi, INFLUENCE_FRAC * w0);
    (r_max > 0.0).then(|| std::sync::Arc::new(BubbleTable::build(&b, zi, r_max, tk)))
}

/// Запись кеша термика: источник пузыря (дорогой), траектория, моменты ключевых кадров и таблицы кадров (номер кадра →
/// таблица; `None` — пузыря в тот кадр нет). Держатся не больше трёх соседних кадров.
#[derive(Clone)]
pub struct CacheEntry {
    /// `None` — термик не описывается шаблоном.
    pub src: Option<(Source, f64)>,
    pub traj: Option<std::sync::Arc<Traj>>,
    /// Моменты ключевых кадров (абсолютные, с): `t_birth + keyframe_times`.
    pub kf: Vec<f64>,
    pub frames: Vec<(usize, Option<std::sync::Arc<BubbleTable>>)>,
}

impl CacheEntry {
    pub fn new(th: &AtmoThermal) -> CacheEntry {
        match source_of(th) {
            Some((src, zi)) => {
                let traj = std::sync::Arc::new(Traj::new(&src, zi));
                let kf = keyframe_times(src.tau, traj.t_end)
                    .into_iter()
                    .map(|t| src.t0 + t)
                    .collect();
                CacheEntry {
                    src: Some((src, zi)),
                    traj: Some(traj),
                    kf,
                    frames: Vec::new(),
                }
            }
            None => CacheEntry {
                src: None,
                traj: None,
                kf: Vec::new(),
                frames: Vec::new(),
            },
        }
    }

    /// Состояние пузыря на момент `t`.
    pub fn state_at(&self, t: f64) -> Option<BState> {
        let (src, zi) = self.src.as_ref()?;
        self.traj.as_ref()?.state(src, *zi, t - src.t0)
    }

    /// Номер ключевого кадра, с которого начинается интервал, содержащий `t` (`None` — до первого кадра).
    pub fn interval(&self, t: f64) -> Option<usize> {
        self.kf.partition_point(|&x| x <= t).checked_sub(1)
    }

    pub fn frame(&self, k: usize) -> Option<&Option<std::sync::Arc<BubbleTable>>> {
        self.frames.iter().find(|f| f.0 == k).map(|f| &f.1)
    }
}

/// Кеш таблиц пузырей по `id` термика; переживает пересборки набора (`ThermalSlot` передаёт его дальше).
#[derive(Default)]
pub struct BubbleCache {
    map: std::sync::Mutex<std::collections::HashMap<i64, CacheEntry>>,
    /// Счётчики цены: время сборки таблиц (с радиусом влияния) и источников, число сборок и источников.
    pub stats: CacheStats,
}

/// Счётчики [`BubbleCache`] (нс суммарно по задачам, штуки).
#[derive(Default)]
pub struct CacheStats {
    pub build_ns: std::sync::atomic::AtomicU64,
    pub source_ns: std::sync::atomic::AtomicU64,
    pub rebuilds: std::sync::atomic::AtomicU64,
    pub sources: std::sync::atomic::AtomicU64,
}

impl BubbleCache {
    pub fn lock(&self) -> std::sync::MutexGuard<'_, std::collections::HashMap<i64, CacheEntry>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }
}
