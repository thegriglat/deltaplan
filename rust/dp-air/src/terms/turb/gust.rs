//! Шум порывов `WindModel.gust_unit` (`wind_model.gd` 51–104, 186, 197): «замороженный» шум
//! (симплекс-гладкий FBM Godot), переносимый ветром (гипотеза Тейлора). Общий для болтанки
//! поля (рывки слоя смешения, `sep.rs`), шума аналитики (RW-9 берёт [`GustUnit::gust_unit`]) и
//! бурления в облаке (RW-11).
//!
//! Арифметика повторяет GDScript: `Vector3` — f32, `float` — f64, приведения там, где их делает
//! движок (поэтому значения побитно как у Godot, см. `tests/terms_turb.rs`).
use crate::compat::noise::{FastNoise, Fractal};
use crate::compat::rng::Pcg32;

/// Конфиг шума: `atmosphere.json` → `turbulence`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GustCfg {
    /// `scale_m`: масштаб мелких вихрей.
    pub scale_m: f64,
    /// `large_scale_m`: масштаб крупных вихрей (0 — только мелкие).
    pub large_scale_m: f64,
    /// `octaves` FBM.
    pub octaves: i32,
    /// `evolve_ms`: «перемешивание» по высоте во времени, м/с.
    pub evolve_ms: f64,
}

impl Default for GustCfg {
    fn default() -> Self {
        GustCfg {
            scale_m: 45.0,
            large_scale_m: 300.0,
            octaves: 2,
            evolve_ms: 0.6,
        }
    }
}

impl GustCfg {
    /// `atmosphere.json` → `turbulence` (`scale_m`, `large_scale_m`, `octaves`, `evolve_ms`).
    pub fn from_configs(c: &crate::Configs) -> Self {
        let atm = crate::terms::named_json(c, "atmosphere").unwrap_or(serde_json::Value::Null);
        let d = GustCfg::default();
        let g = |k: &str, dv: f64| {
            atm.pointer(&format!("/turbulence/{k}"))
                .and_then(serde_json::Value::as_f64)
                .unwrap_or(dv)
        };
        GustCfg {
            scale_m: g("scale_m", d.scale_m),
            large_scale_m: g("large_scale_m", d.large_scale_m),
            octaves: g("octaves", f64::from(d.octaves)) as i32,
            evolve_ms: g("evolve_ms", d.evolve_ms),
        }
    }
}

/// Единичные пульсации `WindModel.gust_unit`: СКО ≈ 1 по каждой компоненте.
#[derive(Clone, Debug)]
pub struct GustUnit {
    noise: FastNoise,
    norm: f64,
    inv_scale: f64,
    evolve: f64,
    inv_large: f64,
    amp_large: f64,
    off_v: [f32; 3],
    off_z: [f32; 3],
    off_l: [f32; 3],
}

fn offsets(rng: &mut Pcg32, lo: f32, hi: f32) -> [f32; 3] {
    // порядок вычисления аргументов GDScript — слева направо
    let x = rng.randf_range(lo, hi);
    let y = rng.randf_range(lo, hi);
    let z = rng.randf_range(lo, hi);
    [x, y, z]
}

impl GustUnit {
    /// `WindModel.setup` (шумовая часть): сид мира `seed`; порядок вызовов RNG — сдвиги, потом
    /// нормировка (`_measure_rms`).
    pub fn new(cfg: &GustCfg, seed: i64) -> Self {
        let noise = FastNoise::new(
            seed as i32,
            Fractal::Fbm {
                octaves: cfg.octaves,
                gain: 0.5,
                lacunarity: 2.0,
                weighted_strength: 0.0,
            },
            1.0,
        );
        let mut rng = Pcg32::from_seed(seed as u64);
        let off_v = offsets(&mut rng, 100.0, 200.0);
        let off_z = offsets(&mut rng, 300.0, 400.0);
        let off_l = offsets(&mut rng, 500.0, 600.0);
        let mut sum = 0.0f64;
        for _ in 0..2048 {
            let p = offsets(&mut rng, -500.0, 500.0);
            let v = f64::from(noise.get3(p[0], p[1], p[2]));
            sum += v * v;
        }
        let rms = (sum / 2048.0).sqrt().max(1.0e-4);
        let (inv_large, amp_large) = if cfg.large_scale_m > cfg.scale_m {
            let amp_small = (cfg.scale_m / cfg.large_scale_m).powf(1.0 / 3.0);
            (
                1.0 / cfg.large_scale_m,
                (1.0 - amp_small * amp_small).sqrt(),
            )
        } else {
            (0.0, 0.0)
        };
        GustUnit {
            noise,
            norm: 1.0 / rms,
            inv_scale: 1.0 / cfg.scale_m,
            evolve: cfg.evolve_ms,
            inv_large,
            amp_large,
            off_v,
            off_z,
            off_l,
        }
    }

    /// Три независимых отсчёта шума в точке `q` (`_noise3`).
    fn noise3(&self, q: [f32; 3]) -> [f32; 3] {
        let g = |o: [f32; 3]| self.noise.get3(q[0] + o[0], q[1] + o[1], q[2] + o[2]);
        [
            self.noise.get3(q[0], q[1], q[2]),
            g(self.off_v),
            g(self.off_z),
        ]
    }

    /// Единичные пульсации в точке `pos` в момент `t`; `dir` — направление ветра `(x, z)` (как
    /// `WindModel.dir`, в f32), `advect` — скорость переноса поля, м/с; `large_k` 0..1 — доля
    /// крупных вихрей (0 — только мелкие: у земли, бурление в облаке).
    pub fn gust_unit(
        &self,
        pos: [f32; 3],
        t: f64,
        dir: [f64; 2],
        advect: f64,
        large_k: f64,
    ) -> [f32; 3] {
        let p = [
            (f64::from(pos[0]) - f64::from(dir[0] as f32) * advect * t) as f32,
            (f64::from(pos[1]) + self.evolve * t) as f32,
            (f64::from(pos[2]) - f64::from(dir[1] as f32) * advect * t) as f32,
        ];
        let s = self.inv_scale as f32;
        let mut n = self.noise3([p[0] * s, p[1] * s, p[2] * s]);
        let a_l = self.amp_large * large_k.clamp(0.0, 1.0);
        if a_l > 1.0e-4 {
            let a_s = (1.0 - a_l * a_l).sqrt();
            let il = self.inv_large as f32;
            let q = [
                p[0] * il + self.off_l[0],
                p[1] * il + self.off_l[1],
                p[2] * il + self.off_l[2],
            ];
            let nl = self.noise3(q);
            n = [
                (f64::from(n[0]) * a_s + f64::from(nl[0]) * a_l) as f32,
                (f64::from(n[1]) * a_s) as f32,
                (f64::from(n[2]) * a_s + f64::from(nl[2]) * a_l) as f32,
            ];
        }
        let k = self.norm as f32;
        [n[0] * k, n[1] * k, n[2] * k]
    }

    /// Нормировка шума (1/СКО по 2048 точкам).
    pub fn norm(&self) -> f64 {
        self.norm
    }
}

/// Шум порывов в формате слота: `GustUnit::gust_unit`, значения в f64 — для RW-9 (шум
/// аналитики `gust_unit·amp`) и RW-11 (бурление в облаке).
pub fn gust(
    g: &GustUnit,
    pos: [f32; 3],
    t: f64,
    dir: [f64; 2],
    advect: f64,
    large_k: f64,
) -> [f64; 3] {
    let n = g.gust_unit(pos, t, dir, advect, large_k);
    [f64::from(n[0]), f64::from(n[1]), f64::from(n[2])]
}
