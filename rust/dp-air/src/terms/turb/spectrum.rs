//! Порывы со спектром фон Кармана: сумма октав «замороженного» симплекс-шума,
//! вес октавы — дисперсия спектра фон Кармана с интегральным масштабом `L` в полосе этой октавы
//! (MIL-HDBK-1797, п. 4.9.1/B.4.9: продольная форма для u, v, поперечная для w).
//!
//! Таблицы весов не зависят от сида (строятся один раз на процесс, f32 — как массив f32).
//! Арифметика (f32 для `Vector3`/`Packed*`, f64 для `float`) повторяет эталон.
use crate::noise::{FastNoise, Fractal};
use crate::rand::Pcg32;
use std::sync::OnceLock;

/// Наименьший масштаб октавы, м, и число октав: полосы 14 м … 2,5 км.
pub const S0: f64 = 8.0;
pub const OCTAVES: usize = 8;
/// Пик `k·S` одной октавы — на длине волны `PEAK·s`.
pub const PEAK: f64 = 1.75;
/// Таблица весов по `L`: от `L_MIN` до `L_MAX`, логарифмически.
pub const L_MIN: f64 = 2.0;
pub const L_MAX: f64 = 4000.0;
pub const L_STEPS: usize = 64;
/// Коэффициент формы фон Кармана (MIL-HDBK-1797: 1,339).
pub const VK_A: f64 = 1.339;

struct Tables {
    wu: Vec<f32>,
    ww: Vec<f32>,
    inv_dl: f64,
}

fn tables() -> &'static Tables {
    static T: OnceLock<Tables> = OnceLock::new();
    T.get_or_init(|| {
        let mut wu = vec![0f32; L_STEPS * OCTAVES];
        let mut ww = vec![0f32; L_STEPS * OCTAVES];
        let inv_dl = (L_STEPS - 1) as f64 / (L_MAX / L_MIN).ln();
        for li in 0..L_STEPS {
            let el = L_MIN * (li as f64 / inv_dl).exp();
            for o in 0..OCTAVES {
                let kp = std::f64::consts::TAU / (PEAK * S0 * 2f64.powi(o as i32));
                let k_hi = kp * 2f64.sqrt();
                let k_lo = kp / 2f64.sqrt();
                wu[li * OCTAVES + o] = band(el, k_lo, k_hi, false) as f32;
                ww[li * OCTAVES + o] = band(el, k_lo, k_hi, true) as f32;
            }
        }
        Tables { wu, ww, inv_dl }
    })
}

/// `∫ E(k) dk` по `[k_lo, k_hi]` для нормированного (`∫₀^∞ E = 1`) спектра фон Кармана, `k` —
/// рад/м: продольный `E = (2L/π)/(1 + (aLk)²)^(5/6)`, поперечный
/// `E = (L/π)(1 + 8/3(aLk)²)/(1 + (aLk)²)^(11/6)`.
pub fn band(el: f64, k_lo: f64, k_hi: f64, transverse: bool) -> f64 {
    let n = 24;
    let pi = std::f64::consts::PI;
    let r = (k_hi / k_lo).ln();
    let mut s = 0.0;
    for q in 0..n {
        let k = k_lo * ((f64::from(q) + 0.5) / f64::from(n) * r).exp();
        let x = VK_A * el * k;
        let x2 = x * x;
        let e = if transverse {
            el / pi * (1.0 + 8.0 / 3.0 * x2) / (1.0 + x2).powf(11.0 / 6.0)
        } else {
            2.0 * el / pi / (1.0 + x2).powf(5.0 / 6.0)
        };
        s += e * k;
    }
    s * r / f64::from(n)
}

/// Шаг таблицы по `ln L`: `(L_STEPS − 1)/ln(L_MAX/L_MIN)`.
pub fn inv_dl() -> f64 {
    tables().inv_dl
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Дробный номер строки таблицы для `L` (`_row`).
fn row(el: f64) -> f64 {
    let t = tables();
    let r = (el.clamp(L_MIN, L_MAX) / L_MIN).ln() * t.inv_dl;
    r.min(L_STEPS as f64 - 1.0001)
}

/// Доли дисперсии октав для масштаба `el` (таблица `tab`), нормированные на сумму 1.
fn weights(tab: &[f32], el: f64) -> [f32; OCTAVES] {
    let b = row(el);
    let f = b - b.floor();
    let i = (b as usize) * OCTAVES;
    let mut out = [0f32; OCTAVES];
    let mut sum = 0.0f64;
    for o in 0..OCTAVES {
        out[o] = lerp(f64::from(tab[i + o]), f64::from(tab[i + OCTAVES + o]), f) as f32;
        sum += f64::from(out[o]);
    }
    let k = 1.0 / sum.max(1.0e-6);
    for w in &mut out {
        *w = (f64::from(*w) * k) as f32;
    }
    out
}

/// Доля дисперсии (из 1), которую несут октавы при масштабе `L`: (горизонталь, вертикаль).
pub fn carried(el_u: f64, el_w: f64) -> [f64; 2] {
    let t = tables();
    let (bu, bw) = (row(el_u), row(el_w));
    let (mut su, mut sw) = (0.0, 0.0);
    for o in 0..OCTAVES {
        let iu = (bu as usize) * OCTAVES + o;
        let iw = (bw as usize) * OCTAVES + o;
        su += lerp(
            f64::from(t.wu[iu]),
            f64::from(t.wu[iu + OCTAVES]),
            bu - bu.floor(),
        );
        sw += lerp(
            f64::from(t.ww[iw]),
            f64::from(t.ww[iw + OCTAVES]),
            bw - bw.floor(),
        );
    }
    [su, sw]
}

/// Сырые веса октав (до нормировки) для `L` — для проверок спектра.
pub fn octave_weights(el: f64, transverse: bool) -> [f64; OCTAVES] {
    let t = tables();
    let w = weights(if transverse { &t.ww } else { &t.wu }, el);
    let mut out = [0.0; OCTAVES];
    for (o, x) in out.iter_mut().zip(w) {
        *o = f64::from(x);
    }
    out
}

/// Источник порывов со спектром.
#[derive(Clone, Debug)]
pub struct GustSpectrum {
    noise: FastNoise,
    norm: f64,
    evolve: f64,
    /// Смещения координат: октава × компонента (u, w, v).
    off: Vec<[f32; 3]>,
}

/// Параметры одного отсчёта.
#[derive(Clone, Copy, Debug)]
pub struct SampleIn {
    pub pos: [f32; 3],
    pub t: f64,
    pub advect: f64,
    /// Направление ветра `(x, z)` (`WindModel.dir`).
    pub dir: [f64; 2],
    pub l_u: f64,
    pub l_w: f64,
    /// Второй масштаб горизонтали (конвективные вихри) и доли дисперсии у `a` и `c`.
    pub l_2: f64,
    pub f_a: f64,
    pub f_c: f64,
}

impl GustSpectrum {
    /// `setup`: сид и сдвиги `seed + 7919`; порядок RNG — 24 сдвига, потом 4096 точек нормировки.
    pub fn new(seed: i64, evolve_ms: f64) -> Self {
        let s = seed + 7919;
        let noise = FastNoise::new(s as i32, Fractal::None, 1.0);
        let mut rng = Pcg32::from_seed(s as u64);
        let mut off = Vec::with_capacity(OCTAVES * 3);
        for _ in 0..OCTAVES * 3 {
            let x = rng.randf_range(-5000.0, 5000.0);
            let y = rng.randf_range(-5000.0, 5000.0);
            let z = rng.randf_range(-5000.0, 5000.0);
            off.push([x, y, z]);
        }
        let mut sum = 0.0f64;
        for _ in 0..4096 {
            let x = rng.randf_range(-800.0, 800.0);
            let y = rng.randf_range(-800.0, 800.0);
            let z = rng.randf_range(-800.0, 800.0);
            let v = f64::from(noise.get3(x, y, z));
            sum += v * v;
        }
        tables();
        GustSpectrum {
            noise,
            norm: 1.0 / (sum / 4096.0).sqrt().max(1.0e-4),
            evolve: evolve_ms,
            off,
        }
    }

    /// Нормировка шума на СКО 1.
    pub fn norm(&self) -> f64 {
        self.norm
    }

    /// Сдвиги координат октав: октава × компонента (u, w, v).
    pub fn offsets(&self) -> &[[f32; 3]] {
        &self.off
    }

    /// Пульсации в точке, СКО каждой компоненты 1: `[a, w, c]` — `a`, `c` две независимые
    /// горизонтальные компоненты (потребитель кладёт их вдоль и поперёк ветра), `w` — вертикаль.
    /// Умножать на σ.
    pub fn sample(&self, s: &SampleIn) -> [f32; 3] {
        let d = [s.dir[0] as f32, s.dir[1] as f32];
        let p = [
            (f64::from(s.pos[0]) - f64::from(d[0]) * s.advect * s.t) as f32,
            (f64::from(s.pos[1]) + self.evolve * s.t) as f32,
            (f64::from(s.pos[2]) - f64::from(d[1]) * s.advect * s.t) as f32,
        ];
        let t = tables();
        let wu = weights(&t.wu, s.l_u);
        let ww = weights(&t.ww, s.l_w);
        let w2 = if s.l_2 > 0.0 && (s.f_a > 0.0 || s.f_c > 0.0) {
            weights(&t.wu, s.l_2)
        } else {
            wu
        };
        let mut out = [0f32; 3];
        let mut sc = S0;
        for o in 0..OCTAVES {
            let aa = lerp(f64::from(wu[o]), f64::from(w2[o]), s.f_a).sqrt();
            let ac = lerp(f64::from(wu[o]), f64::from(w2[o]), s.f_c).sqrt();
            let aw = f64::from(ww[o]).sqrt();
            let sf = sc as f32;
            let q = [p[0] / sf, p[1] / sf, p[2] / sf];
            let j = o * 3;
            let at = |off: [f32; 3]| self.noise.get3(q[0] + off[0], q[1] + off[1], q[2] + off[2]);
            if aa > 1.0e-3 {
                out[0] = (f64::from(out[0]) + aa * f64::from(at(self.off[j]))) as f32;
            }
            if ac > 1.0e-3 {
                out[2] = (f64::from(out[2]) + ac * f64::from(at(self.off[j + 2]))) as f32;
            }
            if aw > 1.0e-3 {
                out[1] = (f64::from(out[1]) + aw * f64::from(at(self.off[j + 1]))) as f32;
            }
            sc *= 2.0;
        }
        let k = self.norm as f32;
        [out[0] * k, out[1] * k, out[2] * k]
    }
}
