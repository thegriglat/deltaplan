//! `WaveField`: подветренные волны — упрощённая
//! линейная теория захваченных волн за хребтом.
//!
//! При устойчивой стратификации (частота Брента — Вяйсяля N) поток, перевалив хребет, колеблется
//! с длиной волны `λ = 2πU/N` (U — ветер на высоте `wind_reference_agl_m`). Смещение линий тока в
//! точке — свёртка уклона рельефа против ветра с откликом `g(d) = cos(k·d)·exp(−d/L)`,
//! `L = decay_wavelengths·λ`:
//!   `η(p) = Σ h'(p − ŵd)·g(d)·Δ` (м; > 0 — гребень волны), `w = U·∂η/∂x`.
//! По высоте волна нарастает от уровня гребня хребта до пика и медленно гаснет выше; под гребнями
//! волн у земли — роторы (σ). Поля — на грубой сетке `cell_m` кусками `chunk_cells`², билинейно.
//!
//! Границы модели: линейная, без нелинейного опрокидывания; рельеф — единственный источник
//! (стратификация однородна по высоте и времени в пределах `N` пресета); `wave_strength` и `gain`
//! — калибровка, не физические величины.
use crate::{Configs, Crest};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::terms::named_json;

const KEY_OFFSET: i64 = 1 << 20;
const KEY_MUL: i64 = 1 << 21;
/// η, ∂η/∂x (на 1 м/с ветра), высота гребня хребта против ветра.
const FIELDS: usize = 3;

/// секция `atmosphere` → `wave` (запасные значения — как в секция `atmosphere`).
#[derive(Clone, Debug, PartialEq)]
pub struct WaveCfg {
    pub default_n_per_s: f64,
    pub wind_reference_agl_m: f64,
    pub cell_m: f64,
    pub chunk_cells: i64,
    pub max_chunks: usize,
    pub upwind_samples: usize,
    pub decay_wavelengths: f64,
    pub gain: f64,
    pub max_ms: f64,
    pub peak_above_crest_m: f64,
    pub decay_height_m: f64,
    pub below_crest_m: f64,
    pub rotor_per_wind: f64,
    pub rotor_depth_m: f64,
    pub rotor_ref_m: f64,
    pub lens_min_eta_m: f64,
    pub lens_radius_m: f64,
    /// `lens_length_m[1]`: верхняя граница длины линзы, м.
    pub lens_length_max_m: f64,
}

impl Default for WaveCfg {
    fn default() -> Self {
        WaveCfg {
            default_n_per_s: 0.01,
            wind_reference_agl_m: 1500.0,
            cell_m: 300.0,
            chunk_cells: 8,
            max_chunks: 200,
            upwind_samples: 24,
            decay_wavelengths: 3.0,
            gain: 0.5,
            max_ms: 8.0,
            peak_above_crest_m: 2500.0,
            decay_height_m: 5000.0,
            below_crest_m: 300.0,
            rotor_per_wind: 0.35,
            rotor_depth_m: 500.0,
            rotor_ref_m: 300.0,
            lens_min_eta_m: 60.0,
            lens_radius_m: 22000.0,
            lens_length_max_m: 9000.0,
        }
    }
}

impl WaveCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = WaveCfg::default();
        let g = |k: &str, dv: f64| {
            atm.pointer(&format!("/wave/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        let lens_max = atm
            .pointer("/wave/lens_length_m/1")
            .and_then(Value::as_f64)
            .unwrap_or(d.lens_length_max_m);
        WaveCfg {
            default_n_per_s: g("default_stability_n_per_s", d.default_n_per_s),
            wind_reference_agl_m: g("wind_reference_agl_m", d.wind_reference_agl_m),
            cell_m: g("cell_m", d.cell_m).max(1.0),
            chunk_cells: (g("chunk_cells", d.chunk_cells as f64) as i64).max(1),
            max_chunks: g("max_chunks", d.max_chunks as f64).max(1.0) as usize,
            upwind_samples: g("upwind_samples", d.upwind_samples as f64).max(0.0) as usize,
            decay_wavelengths: g("decay_wavelengths", d.decay_wavelengths),
            gain: g("gain", d.gain),
            max_ms: g("max_ms", d.max_ms),
            peak_above_crest_m: g("peak_above_crest_m", d.peak_above_crest_m),
            decay_height_m: g("decay_height_m", d.decay_height_m),
            below_crest_m: g("below_crest_m", d.below_crest_m),
            rotor_per_wind: g("rotor_turbulence_per_wind", d.rotor_per_wind),
            rotor_depth_m: g("rotor_depth_m", d.rotor_depth_m),
            rotor_ref_m: g("rotor_ref_m", d.rotor_ref_m),
            lens_min_eta_m: g("lens_min_eta_m", d.lens_min_eta_m),
            lens_radius_m: g("lens_radius_m", d.lens_radius_m),
            lens_length_max_m: lens_max,
        }
    }
}

/// `smoothstep` эталона: при `from == to` — ступенька.
pub(super) fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if from == to {
        return if x < from { 0.0 } else { 1.0 };
    }
    let s = ((x - from) / (to - from)).clamp(0.0, 1.0);
    s * s * (3.0 - 2.0 * s)
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Направление ветра (куда дует) как `Vector2` эталона: `f32`, нормировано при длине² > 1e-6.
pub fn dir_f32(d: [f64; 2]) -> [f32; 2] {
    let (x, y) = (d[0] as f32, d[1] as f32);
    let l2 = x * x + y * y;
    if l2 > 1.0e-6 {
        let l = l2.sqrt();
        [x / l, y / l]
    } else {
        [x, y]
    }
}

/// Поле волн одной погоды/ветра/места. Кеш кусков — внутри (производный, чистый).
pub struct WaveField {
    cfg: WaveCfg,
    pub strength: f64,
    lambda: f64,
    k: f64,
    dir: [f32; 2],
    stride: usize,
    chunks: Mutex<HashMap<i64, Arc<Vec<f32>>>>,
}

/// Высота рельефа в (x, z), м.
pub type Ground<'a> = &'a dyn Fn(f64, f64) -> f64;

impl WaveField {
    /// `n_bv` — частота Брента — Вяйсяля, 1/с; `speed` — ветер на `wind_reference_agl_m`, м/с;
    /// `dir` — куда дует (x, z).
    pub fn new(cfg: &WaveCfg, strength: f64, n_bv: f64, speed: f64, dir: [f64; 2]) -> Self {
        let lambda = std::f64::consts::TAU * speed.max(1.0) / n_bv.max(1.0e-4);
        WaveField {
            cfg: cfg.clone(),
            strength,
            lambda,
            k: std::f64::consts::TAU / lambda,
            dir: dir_f32(dir),
            stride: cfg.chunk_cells as usize + 1,
            chunks: Mutex::new(HashMap::new()),
        }
    }

    pub fn enabled(&self) -> bool {
        self.strength > 0.0
    }

    pub fn wavelength(&self) -> f64 {
        self.lambda
    }

    pub fn dir(&self) -> [f32; 2] {
        self.dir
    }

    /// Совместимость параметров с `set_wind` GD: пересборка кеша, если λ изменилась больше чем на
    /// 1 м или направление — больше чем на 1e-3.
    pub fn same_wind(&self, other: &WaveField) -> bool {
        let dx = f64::from(self.dir[0] - other.dir[0]);
        let dz = f64::from(self.dir[1] - other.dir[1]);
        (self.lambda - other.lambda).abs() <= 1.0 && (dx * dx + dz * dz).sqrt() <= 1.0e-3
    }

    fn build(&self, cx: i64, cz: i64, ground: Ground) -> Vec<f32> {
        let c = &self.cfg;
        let n = c.chunk_cells;
        let mut out = vec![0.0f32; self.stride * self.stride * FIELDS];
        let dd = self.lambda / 8.0;
        let decay_l = self.lambda * c.decay_wavelengths;
        let (wx, wz) = (f64::from(self.dir[0]), f64::from(self.dir[1]));
        for j in 0..self.stride {
            for i in 0..self.stride {
                let x = ((cx * n + i as i64) as f64) * c.cell_m;
                let z = ((cz * n + j as i64) as f64) * c.cell_m;
                let (mut eta, mut deta) = (0.0f64, 0.0f64);
                let mut crest = ground(x, z);
                let mut h_prev = crest;
                for s in 0..c.upwind_samples {
                    let d = (s + 1) as f64 * dd;
                    let h = ground(x - wx * d, z - wz * d);
                    if d < self.lambda * 2.0 {
                        crest = crest.max(h);
                    }
                    // уклон по ветру на отрезке [d, d − dd]: подъём рельефа к точке — положительный
                    let slope = (h_prev - h) / dd;
                    h_prev = h;
                    let dm = d - dd * 0.5;
                    let e = (-dm / decay_l).exp();
                    let (cs, sn) = ((self.k * dm).cos(), (self.k * dm).sin());
                    eta += slope * cs * e * dd;
                    deta += slope * (-self.k * sn - cs / decay_l) * e * dd;
                }
                let o = (j * self.stride + i) * FIELDS;
                out[o] = eta as f32;
                out[o + 1] = deta as f32;
                out[o + 2] = crest as f32;
            }
        }
        out
    }

    /// `(η, ∂η/∂x, гребень)` в точке — билинейно по сетке.
    pub fn fields(&self, x: f64, z: f64, ground: Ground) -> [f64; 3] {
        let c = &self.cfg;
        let n = c.chunk_cells;
        let (fx, fz) = (x / c.cell_m, z / c.cell_m);
        let (ix, iz) = (fx.floor() as i64, fz.floor() as i64);
        let (cx, cz) = (ix.div_euclid(n), iz.div_euclid(n));
        let key = (cx + KEY_OFFSET) * KEY_MUL + (cz + KEY_OFFSET);
        let cached = self.chunks.lock().unwrap().get(&key).cloned();
        let d = match cached {
            Some(d) => d,
            None => {
                let d = Arc::new(self.build(cx, cz, ground));
                let mut m = self.chunks.lock().unwrap();
                if m.len() >= c.max_chunks {
                    m.clear();
                }
                m.insert(key, d.clone());
                d
            }
        };
        let (lx, lz) = ((ix - cx * n) as usize, (iz - cz * n) as usize);
        let (tx, tz) = (fx - ix as f64, fz - iz as f64);
        let mut out = [0.0; 3];
        for (f, o) in out.iter_mut().enumerate() {
            let i00 = (lz * self.stride + lx) * FIELDS + f;
            let i10 = i00 + FIELDS;
            let i01 = i00 + self.stride * FIELDS;
            let i11 = i01 + FIELDS;
            let g = |i: usize| f64::from(d[i]);
            *o = lerp(lerp(g(i00), g(i10), tx), lerp(g(i01), g(i11), tx), tz);
        }
        out
    }

    /// Вертикальный поток и σ ротора `(w, σ)`: `u` — ветер на `wind_reference_agl_m`, `y` — высота
    /// точки (MSL), `agl` — над землёй.
    pub fn sample(&self, x: f64, y: f64, z: f64, agl: f64, u: f64, ground: Ground) -> (f64, f64) {
        if !self.enabled() {
            return (0.0, 0.0);
        }
        let c = &self.cfg;
        let f = self.fields(x, z, ground);
        let crest = f[2];
        // по высоте: от уровня гребня до пика, выше медленно гаснет
        let mut prof = smoothstep(
            crest - c.below_crest_m,
            crest + c.peak_above_crest_m * 0.4,
            y,
        );
        prof *= (-(y - crest - c.peak_above_crest_m).max(0.0) / c.decay_height_m).exp();
        let w = (self.strength * c.gain * u * f[1] * prof).clamp(-c.max_ms, c.max_ms);
        // ротор: у земли, ниже гребня хребта + rotor_depth, под гребнем волны (η > 0)
        let mut rotor = 0.0;
        if y < crest + c.rotor_depth_m && f[0] > 0.0 {
            rotor = self.strength * c.rotor_per_wind * u * (f[0] / c.rotor_ref_m).clamp(0.0, 1.0);
            rotor *= 1.0 - smoothstep(crest, crest + c.rotor_depth_m, y);
            rotor *= smoothstep(0.0, 60.0, agl);
        }
        (w, rotor)
    }

    /// Гребни волн рядом с точкой (для лентикулярных облаков, W6): максимумы η вдоль ветра, вдоль
    /// гребня — линзы не ближе `spacing`. `pos` сдвинут против ветра на четверть λ от максимума η
    /// (там максимален подъём `w = U·∂η/∂x`). Сильные первыми.
    pub fn crests(
        &self,
        center: [f32; 2],
        radius: f32,
        min_eta: f32,
        spacing: f32,
        ground: Ground,
    ) -> Vec<Crest> {
        if !self.enabled() {
            return Vec::new();
        }
        let step = self.cfg.cell_m * 2.0;
        let n = (f64::from(radius) / step) as i32;
        let [wx, wz] = self.dir;
        let shift = [
            wx * (self.lambda * 0.25) as f32,
            wz * (self.lambda * 0.25) as f32,
        ];
        let mut cand: Vec<Crest> = Vec::new();
        for j in -n..=n {
            for i in -n..=n {
                // `Vector2` эталона — f32: точка сетки округляется, шаг к соседям считается в f64
                let p = [
                    (f64::from(center[0]) + f64::from(i) * step) as f32,
                    (f64::from(center[1]) + f64::from(j) * step) as f32,
                ];
                let f = self.fields(f64::from(p[0]), f64::from(p[1]), ground);
                if f[0] < f64::from(min_eta) {
                    continue;
                }
                let at = |s: f64| {
                    self.fields(
                        f64::from(p[0]) + f64::from(wx) * s,
                        f64::from(p[1]) + f64::from(wz) * s,
                        ground,
                    )
                };
                let (fa, fb) = (at(step), at(-step));
                if f[0] > fa[0] && f[0] >= fb[0] {
                    cand.push(Crest {
                        x: p[0] - shift[0],
                        z: p[1] - shift[1],
                        eta: f[0] as f32,
                        crest: f[2] as f32,
                    });
                }
            }
        }
        cand.sort_by(|a, b| b.eta.total_cmp(&a.eta));
        let across = [-wz, wx];
        let lam40 = (self.lambda * 0.4) as f32;
        let mut out: Vec<Crest> = Vec::new();
        for c in cand {
            let near = out.iter().any(|o| {
                let d = [c.x - o.x, c.z - o.z];
                (d[0] * across[0] + d[1] * across[1]).abs() < spacing
                    && (d[0] * wx + d[1] * wz).abs() < lam40
            });
            if !near {
                out.push(c);
            }
        }
        out
    }
}
