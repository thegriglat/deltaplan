//! Вход области Пикара из растров места (RW-6b); эталон — `air_place.gd:domain_case` (без нагрева).
//!
//! Что строится: рельеф клеток `hc` (блочное среднее узлов 25 м, `block_mean`), сетка и `nz`,
//! `gam` (dθ̄/dz в центрах `nz + 2` уровней), `z_i` (поиск по профилю θ̄), `z_i_col` (`AirZiTerrain`),
//! доли классов и влажность клеток (`cell_surface`), шероховатость клеток (`cell_z0`).
//! Тот же код на любом `dx` (400, 1200 м), кратном 25 м.
//!
//! Интерфейс для RW-6d: [`build_domain_input`]`(place, cfg, dx, day, spec) -> `[`DomainInput`].
//! Погода — параметром [`DayProfile`] (поля словаря `d` из `AirPlace.day`; их даст RW-6c).
//! Оси — как в GDScript: `hc` и массивы по клеткам — `[j * nx + i]`, `j` растёт на СЕВЕР
//! (`y = -z` мира W1), узел сетки `y0 + dx * j`; в W1 это не выходит. Редукции — f64.
//!
//! Границы модели: область — квадрат `spec.l` с центром в начале координат мира, он целиком
//! в растре места (иначе `BAD_INPUT`, как `push_error` в GDScript); растр места — 25 м с началом,
//! кратным 25 м (снимок поверхности = растр `cls`/`moist`).
use crate::{Configs, Error, Place};
use rayon::prelude::*;

pub const DOMAIN_L: f64 = 38400.0;
pub const TOP_ABOVE: f64 = 3000.0;
pub const GAMMA_D: f64 = 9.8;
pub const NODE_STEP: f64 = 25.0;
pub const CLASS_COUNT: usize = 9;
pub const CLASS_NONE: usize = 0;
pub const CLASS_WATER: usize = 6;
const CLASS_NAMES: [&str; CLASS_COUNT] = [
    "none", "forest", "grass", "crop", "shrub", "bare", "water", "built", "snow",
];
const ZI_STEPS: usize = 23000;

/// Числа конфигов, нужные входу.
#[derive(Clone, Debug, PartialEq)]
pub struct FieldCfg {
    /// `air_model.zi_terrain_alpha`.
    pub zi_alpha: f64,
    /// `air_model.zi_terrain_smooth_m`.
    pub zi_smooth_m: f64,
    /// Мин. толщина слоя перемешивания (`AirCase.p.zi_min`), м.
    pub zi_min: f64,
    /// `surface_heat.moisture.m_norm`.
    pub m_norm: f64,
    /// `surface_heat.classes.<имя>.z0_m` по номерам классов.
    pub z0_m: [f64; CLASS_COUNT],
}

impl FieldCfg {
    /// Из конфигов W5 (`atmosphere`, `surface_heat`; имя с `.json` или без).
    pub fn from_configs(cfg: &Configs) -> Result<Self, Error> {
        let parsed = cfg.parse()?;
        let find = |name: &str| {
            parsed
                .iter()
                .find(|(n, _)| n.strip_suffix(".json").unwrap_or(n) == name)
                .map(|(_, v)| v)
                .ok_or_else(|| Error::bad_input(format!("config '{name}' missing")))
        };
        let am = find("atmosphere")?.get("air_model");
        let num = |v: Option<&serde_json::Value>, d: f64| {
            v.and_then(serde_json::Value::as_f64).unwrap_or(d)
        };
        let sh = find("surface_heat")?;
        let mut z0_m = [0.0; CLASS_COUNT];
        for (k, name) in CLASS_NAMES.iter().enumerate() {
            z0_m[k] = sh
                .pointer(&format!("/classes/{name}/z0_m"))
                .and_then(serde_json::Value::as_f64)
                .filter(|v| *v > 0.0)
                .ok_or_else(|| Error::bad_input(format!("surface_heat: classes.{name}.z0_m")))?;
        }
        Ok(FieldCfg {
            zi_alpha: num(am.and_then(|a| a.get("zi_terrain_alpha")), 0.0),
            zi_smooth_m: num(am.and_then(|a| a.get("zi_terrain_smooth_m")), 5000.0),
            zi_min: 300.0,
            m_norm: num(sh.pointer("/moisture/m_norm"), 0.5),
            z0_m,
        })
    }
}

/// Погода дня для профиля θ̄ (`AirPlace.day`): те же поля, что в словаре `d`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DayProfile {
    /// Температура у долины, °C (`d.t`).
    pub t: f64,
    /// Высота слоя дня, м над землёй (`d.cap`); `INFINITY` — ночной профиль не применяется.
    pub cap: f64,
    /// Высота долины, м над морем (`ctx.valley_msl_m`).
    pub valley_msl_m: f64,
    /// Верхний воздух: температура, °C; высота, км; градиент, К/км.
    pub t_u: f64,
    pub z_u_km: f64,
    pub gam_u: f64,
    /// Ночной профиль: `t_min`, `t_res`, `t_full` (°C), глубина инверсии, км.
    pub t_min: f64,
    pub t_res: f64,
    pub t_full: f64,
    pub dep_km: f64,
    /// Избыток частицы, К (`parcel_excess_k`).
    pub parcel_excess_k: f64,
}

impl DayProfile {
    fn h_v(&self) -> f64 {
        self.valley_msl_m / 1000.0
    }

    /// Потенциальная температура частицы `theta_s`, К.
    pub fn theta_s(&self) -> f64 {
        self.t + self.parcel_excess_k + GAMMA_D * self.h_v()
    }

    fn theta_upper(&self, zk: f64) -> f64 {
        let fa = self.t_u + self.gam_u * (self.z_u_km - zk) + GAMMA_D * zk;
        if self.cap.is_infinite() {
            return fa;
        }
        let h_v = self.h_v();
        let th_min = self.t_min + GAMMA_D * h_v;
        let th_res = self.t_res + GAMMA_D * h_v;
        let slope = (self.t_full - self.t_min) / self.dep_km;
        let night = (th_min + slope * (zk - h_v).max(0.0)).min(th_res);
        night.max(fa)
    }

    /// θ̄(z) над морем (м), К.
    pub fn theta(&self, z_m: f64) -> f64 {
        self.theta_upper(z_m / 1000.0).max(self.theta_s())
    }

    /// dθ̄/dz, К/м (разность ±5 м).
    pub fn gamma(&self, z_m: f64) -> f64 {
        (self.theta(z_m + 5.0) - self.theta(z_m - 5.0)) / 10.0
    }

    /// Верх слоя перемешивания, м над морем: где профиль над слоем впервые теплее частицы.
    pub fn z_i(&self) -> f64 {
        let h_v = self.h_v();
        let ths = self.theta_s();
        let step = (12.0 - h_v) / ZI_STEPS as f64;
        let mut zi = 12.0;
        for k in 0..=ZI_STEPS {
            let z = if k < ZI_STEPS {
                h_v + k as f64 * step
            } else {
                12.0
            };
            if self.theta_upper(z) > ths {
                zi = z;
                break;
            }
        }
        zi * 1000.0
    }
}

/// Область: квадрат со стороной `l`, центр — начало координат мира.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DomainSpec {
    pub l: f64,
    /// Есть карта поверхности (`cls`/`moist` места); `false` — доли только по воде места,
    /// влажность `m_norm` (путь GDScript без снимка).
    pub surface_map: bool,
}

impl Default for DomainSpec {
    fn default() -> Self {
        DomainSpec {
            l: DOMAIN_L,
            surface_map: true,
        }
    }
}

/// Доли классов и влажность клеток.
#[derive(Clone, Debug, PartialEq)]
pub struct CellSurface {
    /// `[(j * nx + i) * CLASS_COUNT + класс]`.
    pub fr: Vec<f32>,
    pub m: Vec<f32>,
}

/// Вход области (без нагрева и притока).
#[derive(Clone, Debug, PartialEq)]
pub struct DomainInput {
    pub dx: f64,
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub dz: f64,
    pub z_bot: f64,
    pub x0: f64,
    pub y0: f64,
    pub hc: Vec<f64>,
    /// `nz + 2` значений, центр уровня `k`: `zc(k)`.
    pub gam: Vec<f64>,
    pub z_i: f64,
    pub z_i_col: Vec<f32>,
    pub z0_map: Vec<f64>,
    pub cells: CellSurface,
}

impl DomainInput {
    /// Центр клетки `k` (с ореолом), м над морем.
    pub fn zc(&self, k: usize) -> f64 {
        self.z_bot + (k as f64 - 0.5) * self.dz
    }
}

fn bad(msg: impl Into<String>) -> Error {
    Error::bad_input(format!("field input: {}", msg.into()))
}

fn grid_ok(x0: f64, y0: f64, dx: f64) -> Result<(), Error> {
    for v in [x0, y0, dx] {
        if !v.is_finite() || (v / NODE_STEP - (v / NODE_STEP).round()).abs() > 1.0e-9 {
            return Err(bad("dx, x0, y0 must be multiples of 25 m"));
        }
    }
    Ok(())
}

struct Axis {
    i0: Vec<usize>,
    t: Vec<f64>,
    f: Vec<f64>,
}

/// Узлы решётки 25 м вдоль оси → дробный индекс слоя; `None` — узел вне слоя.
fn axis_nodes(a0: f64, cnt: usize, sign: f64, o: f64, s: f64, n_layer: usize) -> Option<Axis> {
    let hi = (n_layer - 1) as f64;
    let mut ax = Axis {
        i0: Vec::with_capacity(cnt),
        t: Vec::with_capacity(cnt),
        f: Vec::with_capacity(cnt),
    };
    for m in 0..cnt {
        let mut v = (sign * (a0 + NODE_STEP * m as f64) - o) / s;
        if !(-1.0e-9..=hi + 1.0e-9).contains(&v) {
            return None;
        }
        v = v.clamp(0.0, hi);
        let i = (v as usize).min(n_layer.saturating_sub(2));
        ax.i0.push(i);
        ax.t.push(v - i as f64);
        ax.f.push(v);
    }
    Some(ax)
}

fn axes(place: &Place, x0: f64, y0: f64, dx: f64, nx: usize, ny: usize) -> Result<(usize, Axis, Axis), Error> {
    grid_ok(x0, y0, dx)?;
    let g = &place.header().grid;
    if g.width < 2 || g.height < 2 {
        return Err(bad("place grid too small"));
    }
    let f = (dx / NODE_STEP).round() as usize;
    let ax = axis_nodes(x0, f * nx, 1.0, g.origin_x, g.spacing, g.width as usize);
    let ay = axis_nodes(y0, f * ny, -1.0, g.origin_z, g.spacing, g.height as usize);
    match (ax, ay) {
        (Some(ax), Some(ay)) => Ok((f, ax, ay)),
        _ => Err(bad("domain outside the place raster")),
    }
}

/// Высота клетки — блочное среднее билинейных значений растра в узлах решётки 25 м
/// (`AirPlace.block_mean`: суммы по столбцам клетки в f64, порядок сложения тот же).
/// `(ny * nx)`, `j` — на север.
pub fn block_mean(place: &Place, x0: f64, y0: f64, dx: f64, nx: usize, ny: usize) -> Result<Vec<f64>, Error> {
    let (f, ax, ay) = axes(place, x0, y0, dx, nx, ny)?;
    let w = place.header().grid.width as usize;
    let h = place.heights();
    // веса столбцов клетки: Σ узлов (1 − t)·H[c] + t·H[c + 1] → Σ_q cw·H[c0 + q]
    let mut cstart = Vec::with_capacity(nx);
    let mut woff = Vec::with_capacity(nx + 1);
    let mut cw: Vec<f64> = Vec::new();
    for i in 0..nx {
        let (mut c0, mut c1) = (ax.i0[i * f], ax.i0[i * f]);
        for q in 0..f {
            c0 = c0.min(ax.i0[i * f + q]);
            c1 = c1.max(ax.i0[i * f + q] + 1);
        }
        let base = cw.len();
        cw.resize(base + c1 - c0 + 1, 0.0);
        for q in 0..f {
            let c = i * f + q;
            cw[base + ax.i0[c] - c0] += 1.0 - ax.t[c];
            cw[base + ax.i0[c] + 1 - c0] += ax.t[c];
        }
        cstart.push(c0);
        woff.push(base);
    }
    woff.push(cw.len());
    let inv_n = 1.0 / (f * f) as f64;
    let mut out = vec![0.0f64; nx * ny];
    out.par_chunks_mut(nx).enumerate().for_each_init(
        || vec![0.0f64; nx],
        |acc, (j, row)| {
            acc.fill(0.0);
            for m in 0..f {
                let node = j * f + m;
                let r0 = ay.i0[node];
                let tz = ay.t[node];
                for rr in 0..2 {
                    let wr = if rr == 1 { tz } else { 1.0 - tz };
                    if wr == 0.0 {
                        continue;
                    }
                    let base = (r0 + rr) * w;
                    for (i, a) in acc.iter_mut().enumerate() {
                        let k = base + cstart[i];
                        let wts = &cw[woff[i]..woff[i + 1]];
                        let mut sum = 0.0;
                        for (q, c) in wts.iter().enumerate() {
                            sum += c * f64::from(h[k + q]);
                        }
                        *a += wr * sum;
                    }
                }
            }
            for (o, a) in row.iter_mut().zip(acc.iter()) {
                *o = a * inv_n;
            }
        },
    );
    Ok(out)
}

/// Доля воды по клеткам (`AirPlace.water_fraction`): узлы решётки 25 м, ближайший узел растра
/// `water` (> 0), доля узлов клетки.
pub fn water_fraction(place: &Place, x0: f64, y0: f64, dx: f64, nx: usize, ny: usize) -> Result<Vec<f64>, Error> {
    let (f, ax, ay) = axes(place, x0, y0, dx, nx, ny)?;
    let w = place.header().grid.width as usize;
    let water = place.water();
    let cols: Vec<usize> = ax.f.iter().map(|v| v.round() as usize).collect();
    let rows: Vec<usize> = ay.f.iter().map(|v| v.round() as usize * w).collect();
    let inv = (f * f) as f64;
    let mut out = vec![0.0f64; nx * ny];
    out.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (i, o) in row.iter_mut().enumerate() {
            let mut cnt = 0usize;
            for m in 0..f {
                let rb = rows[j * f + m];
                for q in 0..f {
                    if water[rb + cols[i * f + q]] > 0 {
                        cnt += 1;
                    }
                }
            }
            *o = cnt as f64 / inv;
        }
    });
    Ok(out)
}

/// Доли классов и влажность клеток (`AirPlace.cell_surface`): по тем же узлам 25 м, что
/// `block_mean`. `surface_map = false` — только вода места, `m_norm`.
pub fn cell_surface(
    place: &Place,
    cfg: &FieldCfg,
    surface_map: bool,
    x0: f64,
    y0: f64,
    dx: f64,
    nx: usize,
    ny: usize,
) -> Result<CellSurface, Error> {
    grid_ok(x0, y0, dx)?;
    let nc = CLASS_COUNT;
    let mut fr = vec![0.0f32; nx * ny * nc];
    let mut m = vec![0.0f32; nx * ny];
    if !surface_map {
        let wf = water_fraction(place, x0, y0, dx, nx, ny)?;
        for (q, &wq) in wf.iter().enumerate() {
            fr[q * nc + CLASS_WATER] = wq as f32;
            fr[q * nc + CLASS_NONE] = (1.0 - wq) as f32;
        }
        m.fill(cfg.m_norm as f32);
        return Ok(CellSurface { fr, m });
    }
    let g = &place.header().grid;
    let ok_grid = g.spacing == NODE_STEP
        && (g.origin_x / NODE_STEP).fract() == 0.0
        && (g.origin_z / NODE_STEP).fract() == 0.0;
    if !ok_grid {
        return Err(bad("surface map needs a 25 m raster with origin multiple of 25 m"));
    }
    let (sw, sh) = (g.width as usize, g.height as usize);
    let (cls, mo) = (place.cls(), place.moist());
    let f = (dx / NODE_STEP).round() as usize;
    let i0 = ((x0 - g.origin_x) / NODE_STEP).round() as i64;
    let r0 = ((-y0 - g.origin_z) / NODE_STEP).round() as i64;
    let inv = 1.0 / (f * f) as f64;
    let m_norm = cfg.m_norm as f32;
    let class_of = |c: u8| (c as usize).min(CLASS_COUNT - 1);
    fr.par_chunks_mut(nx * nc)
        .zip(m.par_chunks_mut(nx))
        .enumerate()
        .for_each(|(j, (frow, mrow))| {
            let top = r0 - (j * f + f - 1) as i64;
            let bot = r0 - (j * f) as i64;
            for i in 0..nx {
                let mut cnt = [0u32; CLASS_COUNT];
                let mut msum = 0.0f64;
                let c0 = i0 + (i * f) as i64;
                if top >= 0 && bot < sh as i64 && c0 >= 0 && c0 + f as i64 <= sw as i64 {
                    for row in top..=bot {
                        let k = row as usize * sw + c0 as usize;
                        for qq in 0..f {
                            cnt[class_of(cls[k + qq])] += 1;
                            msum += f64::from(mo[k + qq]);
                        }
                    }
                } else {
                    for mm in 0..f {
                        let row = r0 - (j * f + mm) as i64;
                        for qq in 0..f {
                            let col = c0 + qq as i64;
                            if row < 0 || row >= sh as i64 || col < 0 || col >= sw as i64 {
                                cnt[CLASS_NONE] += 1;
                                msum += f64::from(m_norm);
                            } else {
                                let k = row as usize * sw + col as usize;
                                cnt[class_of(cls[k])] += 1;
                                msum += f64::from(mo[k]);
                            }
                        }
                    }
                }
                for (c, n) in cnt.iter().enumerate() {
                    frow[i * nc + c] = (f64::from(*n) * inv) as f32;
                }
                mrow[i] = (msum * inv) as f32;
            }
        });
    Ok(CellSurface { fr, m })
}

/// Шероховатость клеток, м: лог-среднее по площади `z0` классов (`AirPlace.cell_z0`).
pub fn cell_z0(cells: &CellSurface, cfg: &FieldCfg) -> Vec<f64> {
    let nc = CLASS_COUNT;
    let lz: Vec<f64> = cfg.z0_m.iter().map(|z| z.ln()).collect();
    let mut out = vec![0.0f64; cells.fr.len() / nc];
    out.par_iter_mut().zip(cells.fr.par_chunks(nc)).for_each(|(o, fr)| {
        let (mut s, mut w) = (0.0f64, 0.0f64);
        for (k, &f) in fr.iter().enumerate() {
            s += f64::from(f) * lz[k];
            w += f64::from(f);
        }
        *o = if w > 0.0 { (s / w).exp() } else { lz[CLASS_NONE].exp() };
    });
    out
}

fn reflect(i: i64, n: i64) -> usize {
    if n == 1 {
        return 0;
    }
    let period = 2 * (n - 1);
    let m = i.rem_euclid(period);
    (if m < n { m } else { period - m }) as usize
}

/// Отводы оси: для каждого выходного индекса — (источник, вес), ядро сложено по отражению.
fn axis_taps(n: usize, ker: &[f64], r: usize) -> Vec<Vec<(usize, f64)>> {
    (0..n)
        .map(|i| {
            let mut acc = vec![0.0f64; n];
            for (q, k) in ker.iter().enumerate() {
                acc[reflect(i as i64 + q as i64 - r as i64, n as i64)] += k;
            }
            acc.iter()
                .enumerate()
                .filter(|(_, w)| **w != 0.0)
                .map(|(s, w)| (s, *w))
                .collect()
        })
        .collect()
}

/// Гауссово сглаживание (σ в клетках), края — отражение без повтора (numpy `reflect`).
pub fn gauss2d(a: &[f64], w: usize, h: usize, sigma: f64) -> Vec<f64> {
    if sigma <= 0.3 {
        return a.to_vec();
    }
    let r = (3.0 * sigma).ceil() as usize;
    let mut ker: Vec<f64> = (0..=2 * r)
        .map(|q| {
            let d = (q as f64 - r as f64) / sigma;
            (-0.5 * d * d).exp()
        })
        .collect();
    let ks: f64 = ker.iter().sum();
    ker.iter_mut().for_each(|k| *k /= ks);
    let tx = axis_taps(w, &ker, r);
    let ty = axis_taps(h, &ker, r);
    let mut tmp = vec![0.0f64; w * h];
    tmp.par_chunks_mut(w).zip(a.par_chunks(w)).for_each(|(o, src)| {
        for (v, taps) in o.iter_mut().zip(&tx) {
            let mut s = 0.0;
            for (k, wt) in taps {
                s += wt * src[*k];
            }
            *v = s;
        }
    });
    let mut out = vec![0.0f64; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(j, o)| {
        for (i, v) in o.iter_mut().enumerate() {
            let mut s = 0.0;
            for (k, wt) in &ty[j] {
                s += wt * tmp[k * w + i];
            }
            *v = s;
        }
    });
    out
}

/// `z_i` по столбцам (`AirZiTerrain.columns`): `z_i_ref + α·(h̃ − h_ref)`, не ниже `hc + zi_min`.
pub fn zi_columns(hc: &[f64], nx: usize, ny: usize, dx: f64, z_i_ref: f64, h_ref: f64, cfg: &FieldCfg) -> Vec<f32> {
    if z_i_ref.is_nan() || hc.len() != nx * ny || hc.is_empty() {
        return Vec::new();
    }
    if cfg.zi_alpha == 0.0 {
        return vec![z_i_ref as f32; nx * ny];
    }
    let hs = gauss2d(hc, nx, ny, cfg.zi_smooth_m / dx);
    let mut out = vec![0.0f32; nx * ny];
    out.par_iter_mut().zip(hs.par_iter().zip(hc.par_iter())).for_each(|(o, (s, h))| {
        *o = (z_i_ref + cfg.zi_alpha * (s - h_ref)).max(h + cfg.zi_min) as f32;
    });
    out
}

/// Вход области из растров места: рельеф, сетка, `gam`, `z_i`, `z_i_col`, `z0_map`, доли клеток.
pub fn build_domain_input(
    place: &Place,
    cfg: &FieldCfg,
    dx: f64,
    day: &DayProfile,
    spec: &DomainSpec,
) -> Result<DomainInput, Error> {
    if !(dx.is_finite() && dx > 0.0 && spec.l.is_finite() && spec.l > 0.0) {
        return Err(bad("dx and l must be > 0"));
    }
    let n = (spec.l / dx).round() as usize;
    let x0 = -spec.l / 2.0;
    let y0 = -spec.l / 2.0;
    let hc = block_mean(place, x0, y0, dx, n, n)?;
    let dz = if dx >= 200.0 { 105.0 } else { dx / 2.0 };
    let lo = hc.iter().copied().fold(f64::INFINITY, f64::min);
    let hi = hc.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let z_bot = (lo / dz).floor() * dz - dz;
    let mut nz = ((hi + TOP_ABOVE - z_bot) / dz).ceil() as usize;
    nz += nz % 2;
    let z_i = day.z_i();
    let z_i_col = zi_columns(&hc, n, n, dx, z_i, day.valley_msl_m, cfg);
    let cells = cell_surface(place, cfg, spec.surface_map, x0, y0, dx, n, n)?;
    let z0_map = if spec.surface_map {
        cell_z0(&cells, cfg)
    } else {
        Vec::new()
    };
    let mut inp = DomainInput {
        dx,
        nx: n,
        ny: n,
        nz,
        dz,
        z_bot,
        x0,
        y0,
        hc,
        gam: Vec::new(),
        z_i,
        z_i_col,
        z0_map,
        cells,
    };
    inp.gam = (0..nz + 2).map(|k| day.gamma(inp.zc(k))).collect();
    Ok(inp)
}
