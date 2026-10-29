//! Входы `CloudField` по столбцам (`cloud_field_sources.gd`): доля площади подъёма, дошедшего до
//! основания (`a_u`), целевая мощность `D*`, снос на высоте основания, рельеф. Три источника:
//! конвекция поля (`AirThermals`), склон (ветер у поверхности), аналитика (живые термики).
//! Массивы - `f32`, арифметика - `f64`, как в GDScript.
use super::cfg::FieldCfg;
use crate::field::wind_field::Field;
use crate::terms::WeatherView;
use crate::terms::thermal_air::AirThermals;
use std::sync::Arc;

pub const G: f64 = 9.81;
pub const THETA0: f64 = 300.0;
/// Наклон θ вдоль влажной адиабаты, К/м.
pub const GAM_MOIST: f64 = 0.0038;
/// Высота выборки ветра над землёй у склона, м.
pub const SURF_AGL: f64 = 100.0;

/// Сетка поля (столбец `c = j·nx + i`, `x = x0 + (i + ½)dx`, `z = −(y0 + (j + ½)dx)`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Grid {
    pub nx: usize,
    pub ny: usize,
    pub dx: f64,
    pub x0: f64,
    pub y0: f64,
}

impl Grid {
    /// Область места без поля воздуха: `AirPlace.DOMAIN_L / AirRuntime.DX`.
    pub fn default_domain() -> Grid {
        Grid {
            nx: 96,
            ny: 96,
            dx: 400.0,
            x0: -19200.0,
            y0: -19200.0,
        }
    }
    pub fn of_field(f: &Field) -> Grid {
        let g = f.grid();
        Grid {
            nx: g.nx,
            ny: g.ny,
            dx: g.dx,
            x0: g.x0,
            y0: g.y0,
        }
    }
}

/// Термик для аналитического пути: копия на момент `t` (`CloudPhysics.snapshot_thermals`).
#[derive(Clone, Debug, PartialEq)]
pub struct ThermalSnap {
    pub id: i64,
    pub src: [f32; 3],
    /// Верх уже с мощностью облака (`top + cloud_depth`).
    pub top: f64,
    pub strength: f64,
    pub radius: f64,
    pub env: f64,
    pub lean: [f32; 2],
    pub drift: [f32; 2],
    pub cloud_depth: f64,
    pub overdevelop: f64,
}

impl ThermalSnap {
    /// Ось столба на высоте `y` (`Vector2` GDScript: f32).
    pub fn axis_at(&self, y: f64) -> [f64; 2] {
        let dh = (y - f64::from(self.src[1])).max(0.0);
        [
            f64::from(
                (f64::from(self.src[0]) + f64::from(self.lean[0]) * dh + f64::from(self.drift[0]))
                    as f32,
            ),
            f64::from(
                (f64::from(self.src[2]) + f64::from(self.lean[1]) * dh + f64::from(self.drift[1]))
                    as f32,
            ),
        ]
    }
}

/// Входы столбцов.
pub struct PrepIn<'a> {
    pub wf: Option<&'a Field>,
    pub air: Option<&'a AirThermals>,
    pub thermals: Option<&'a [ThermalSnap]>,
    pub weather: &'a WeatherView,
    pub ground_ref: Option<f64>,
    /// Ветер профиля на высоте MSL: `Callable wind_at`.
    pub wind_at: &'a dyn Fn(f64) -> [f64; 2],
}

pub struct Prep {
    pub au: Vec<f32>,
    pub ds: Vec<f32>,
    pub vx: Vec<f32>,
    pub vz: Vec<f32>,
    pub hc: Vec<f32>,
    pub mean_v: [f32; 2],
}

fn gmax(a: f64, b: f64) -> f64 {
    if a > b { a } else { b }
}
fn gclamp(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

/// `z_i` над точкой (`WindField.z_i_at`): билинейно по `z_i_col`; нет столбцов - `z_i()`.
pub fn z_i_at(f: &Field, x: f64, z: f64) -> f64 {
    let zic = f.z_i_col();
    if zic.is_empty() {
        return f.z_i();
    }
    let g = f.grid();
    let inv = 1.0 / g.dx;
    let gx = gclamp((x - g.x0) * inv - 0.5, 0.0, g.nx as f64 - 1.0);
    let gy = gclamp((-z - g.y0) * inv - 0.5, 0.0, g.ny as f64 - 1.0);
    let i0 = (gx as usize).min(g.nx - 2);
    let j0 = (gy as usize).min(g.ny - 2);
    let fx = gx - i0 as f64;
    let fy = gy - j0 as f64;
    let c = j0 * g.nx + i0;
    let l = |a: f32, b: f32, t: f64| f64::from(a) + (f64::from(b) - f64::from(a)) * t;
    let r0 = l(zic[c], zic[c + 1], fx);
    let r1 = l(zic[c + g.nx], zic[c + g.nx + 1], fx);
    r0 + (r1 - r0) * fy
}

/// Доля потока массы столбца, доходящая до высоты `z` (0..2): Холтслаг-Бовилль.
pub fn penetration(z: f64, hc: f64, z_i: f64, top: f64, eps: f64) -> f64 {
    if top.is_nan() || z >= top {
        return 0.0;
    }
    let zi = if z_i.is_nan() {
        top
    } else {
        gmax(z_i, hc + 300.0)
    };
    if z <= zi {
        return 2.0 * gmax(1.0 - (z - hc) / gmax(zi - hc, 1.0), eps);
    }
    2.0 * eps * gclamp((top - z) / gmax(top - zi, 1.0), 0.0, 1.0)
}

/// dθ̄/dz на высоте основания, К/м.
fn gam_at_base(wf: Option<&Field>, weather: &WeatherView, base: f64) -> f64 {
    if let Some(f) = wf {
        let g = f.gam();
        let gr = f.grid();
        if g.len() == gr.nz && gr.nz > 0 {
            let z = if f.z_i().is_nan() {
                base
            } else {
                gmax(base, f.z_i())
            };
            let k = ((z - gr.z_bot) / gr.dz).floor() as i64;
            let k = k.clamp(0, gr.nz as i64 - 1) as usize;
            return gmax(f64::from(g[k]), 0.0);
        }
    }
    if let Some(n) = weather.get("stability_n_per_s").and_then(|v| v.as_f64()) {
        return n * n * THETA0 / G;
    }
    0.0058
}

/// Копии живых термиков на момент `t` (`CloudPhysics.snapshot_thermals`): без Cb, без слабых и
/// ещё не рождённых, по возрастанию `id`.
pub fn snapshot_thermals(
    all: &[Arc<crate::terms::thermal::AtmoThermal>],
    t: f64,
) -> Vec<ThermalSnap> {
    let mut out: Vec<ThermalSnap> = Vec::new();
    for th in all {
        if th.is_cb {
            continue;
        }
        let ph = th.phase(t);
        if th.strength <= 0.0 || ph.env <= 0.0 {
            continue;
        }
        out.push(ThermalSnap {
            id: th.id,
            src: th.src,
            top: th.top + th.cloud_depth,
            strength: th.strength,
            radius: th.radius,
            env: ph.env,
            lean: th.lean,
            drift: ph.drift,
            cloud_depth: th.cloud_depth,
            overdevelop: th.overdevelop,
        });
    }
    out.sort_by_key(|a| a.id);
    out
}

/// Собрать входы по столбцам сетки `gr` при основании `base`.
pub fn prepare(gr: Grid, base: f64, inp: &PrepIn, cfg: &FieldCfg) -> Prep {
    let (nx, ny, dx) = (gr.nx, gr.ny, gr.dx);
    let n = nx * ny;
    let mut au = vec![0.0f32; n];
    let mut ds = vec![0.0f32; n];
    let mut vx = vec![0.0f32; n];
    let mut vz = vec![0.0f32; n];
    let wf = inp.wf;
    let weather = inp.weather;
    let ground_ref = inp.ground_ref.unwrap_or(base - 1000.0);
    let same_grid = wf.is_some_and(|f| {
        let g = f.grid();
        g.nx == nx && g.ny == ny && g.dx == dx
    });
    let hc: Vec<f32> = if same_grid {
        wf.unwrap().raw_hc().to_vec()
    } else {
        vec![ground_ref as f32; n]
    };
    let mut mean_v = [0.0f32; 2];
    let mut w_surf: Vec<f32> = Vec::new();
    if same_grid {
        let f = wf.unwrap();
        let fg = f.grid();
        w_surf = vec![0.0f32; n];
        for j in 0..ny {
            for i in 0..nx {
                let c = j * nx + i;
                let x = fg.x0 + (i as f64 + 0.5) * dx;
                let z = -(fg.y0 + (j as f64 + 0.5) * dx);
                let h = hc[c];
                let vb = f.sample(
                    [x as f32, gmax(base, f64::from(h) + 50.0) as f32, z as f32],
                    h,
                );
                vx[c] = vb[0];
                vz[c] = vb[2];
                let vs = f.sample([x as f32, (f64::from(h) + SURF_AGL) as f32, z as f32], h);
                w_surf[c] = vs[1];
                mean_v[0] += vb[0];
                mean_v[1] += vb[2];
            }
        }
        let nf = n as f32;
        mean_v = [mean_v[0] / nf, mean_v[1] / nf];
    } else {
        let v = (inp.wind_at)(base);
        let v = [v[0] as f32, v[1] as f32];
        vx.fill(v[0]);
        vz.fill(v[1]);
        mean_v = v;
    }
    let gam = gam_at_base(wf, weather, base);
    let k_max = cfg.k_moist_max;
    let mut k_moist = k_max;
    if gam > GAM_MOIST + 1.0e-4 {
        k_moist = gclamp(gam / (gam - GAM_MOIST), 1.0, k_max);
    }
    let w_k = cfg.w_updraft_k;
    let w_min = cfg.w_updraft_min_ms;
    let depth_day = weather.f64_or("cloud_depth_m", cfg.depth_day_default_m);
    let air = inp.air.filter(|a| a.phi.len() == n && a.c_top.len() == n);
    if let Some(air) = air {
        let z_i = wf.map_or(f64::NAN, |f| f.z_i());
        let zic: Vec<f32> = if air.col_zi.len() == n {
            air.col_zi.clone()
        } else if let (Some(f), true) = (wf, same_grid) {
            f.z_i_col().to_vec()
        } else {
            Vec::new()
        };
        let eps = cfg.overshoot_flux_frac;
        for c in 0..n {
            let top = f64::from(air.c_top[c]);
            if top.is_nan() || top <= base {
                continue;
            }
            let h = f64::from(hc[c]);
            let zi = if zic.is_empty() {
                z_i
            } else {
                f64::from(zic[c])
            };
            let pen = penetration(base, h, zi, top, eps);
            let mut share = 0.0;
            let o = air.owner[c];
            if o >= 0 && (o as usize) < air.carried.len() {
                let o = o as usize;
                share = f64::from(air.carried[o]) / gmax(f64::from(air.area[o]), 1.0);
            }
            let between = gmax(f64::from(air.phi[c]) - share, 0.0);
            let w_u = gmax(w_k * f64::from(air.col_wstar[c]), w_min);
            au[c] = (f64::from(au[c]) + pen * between / w_u) as f32;
            ds[c] = gmax(f64::from(ds[c]), k_moist * (top - base)) as f32;
        }
        let rise_k = cfg.rise_w_k;
        for s in 0..air.count() {
            let top = f64::from(air.top[s]);
            let p = air.pos[s];
            if top.is_nan() || top <= base {
                continue;
            }
            let w0 = f64::from(air.w0[s]);
            let t_rise = gmax(base - f64::from(p[1]), 0.0) / gmax(rise_k * w0, 0.3);
            let dr = air.drift[s];
            let px = f64::from(p[0]) + f64::from(dr[0]) * t_rise;
            let pz = f64::from(p[2]) + f64::from(dr[1]) * t_rise;
            let i = ((px - gr.x0) / dx).floor() as i64;
            let j = ((-pz - gr.y0) / dx).floor() as i64;
            if i < 0 || i >= nx as i64 || j < 0 || j >= ny as i64 {
                continue;
            }
            let c = j as usize * nx + i as usize;
            let mut zi_s = z_i;
            if zic.len() == n && air.col[s] < n {
                zi_s = f64::from(zic[air.col[s]]);
            } else if let Some(f) = wf {
                zi_s = z_i_at(f, f64::from(p[0]), f64::from(p[2]));
            }
            let pen = penetration(base, f64::from(p[1]), zi_s, top, eps);
            let w_u = gmax(w_k * f64::from(air.wstar[s]), w_min);
            au[c] = (f64::from(au[c]) + pen * f64::from(air.carried[s]) / (dx * dx * w_u)) as f32;
            ds[c] = gmax(f64::from(ds[c]), k_moist * (top - base)) as f32;
        }
    } else if let Some(ths) = inp.thermals {
        for th in ths {
            if th.strength <= 0.0 || th.env <= 0.0 {
                continue;
            }
            let top = th.top;
            let y = f64::from(th.src[1]);
            if top <= base - 1.0 {
                continue;
            }
            let ax = th.axis_at(base);
            let i = ((ax[0] - gr.x0) / dx).floor() as i64;
            let j = ((-ax[1] - gr.y0) / dx).floor() as i64;
            if i < 0 || i >= nx as i64 || j < 0 || j >= ny as i64 {
                continue;
            }
            let c = j as usize * nx + i as usize;
            let pen = 2.0 * gclamp(1.0 - (base - y) / gmax(top - y, 1.0), 0.0, 1.0);
            au[c] = (f64::from(au[c])
                + pen * std::f64::consts::PI * th.radius * th.radius * th.env / (dx * dx))
                as f32;
            let d = if th.cloud_depth > 0.0 {
                th.cloud_depth
            } else {
                depth_day
            };
            ds[c] = gmax(f64::from(ds[c]), d * (1.0 + th.overdevelop)) as f32;
        }
    }
    if same_grid {
        let tau_oro = cfg.oro_rise_s;
        let ramp = gmax(cfg.oro_ramp_m, 1.0);
        let w_ref = gmax(cfg.oro_w_ref_ms, 1.0e-3);
        for c in 0..n {
            let wp = gmax(f64::from(w_surf[c]), 0.0);
            if wp <= 0.0 {
                continue;
            }
            let z_reach = f64::from(hc[c]) + wp * tau_oro;
            let reach = gclamp((z_reach - base + ramp) / ramp, 0.0, 1.0);
            if reach <= 0.0 {
                continue;
            }
            let a_oro = reach * gclamp(wp / w_ref, 0.0, 1.0);
            if a_oro <= 0.0 {
                continue;
            }
            au[c] = (f64::from(au[c]) + a_oro) as f32;
            ds[c] = gmax(f64::from(ds[c]), z_reach - base + ramp) as f32;
        }
    }
    for a in au.iter_mut() {
        *a = if *a < 1.0 { *a } else { 1.0 };
    }
    Prep {
        au,
        ds,
        vx,
        vz,
        hc,
        mean_v,
    }
}
