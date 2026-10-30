//! Единичные пульсации `WindModel.gust_unit` (`setup`,
//! `gust_unit` 186, `_noise3` 197): замороженное поле шума `FastNoise` (OpenSimplex2S, FBM),
//! переносимое ветром (гипотеза Тейлора); два масштаба (мелкие `scale_m`, крупные
//! `large_scale_m`), СКО ≈ 1 по каждой компоненте. Шум и генератор — `dp_air::compat`
//! (побитно с эталоном).
//!
//! Эта копия нужна аналитике сама по себе (рывки подветренной зоны входят в среднее, а шум
//! аналитики — в `gust`), а общей рамки шума в каркасе нет: RW-8 заменит её своей (`WindModel`),
//! когда та будет влита, — тогда `GustNoise::gust_unit` переадресуется, формулы не меняются.
use crate::noise::{FastNoise, Fractal};
use crate::rand::Pcg32;

/// Параметры шума: `turbulence.*` из секция `atmosphere`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NoiseCfg {
    pub scale_m: f64,
    pub octaves: i32,
    pub evolve_ms: f64,
    pub large_scale_m: f64,
    pub large_fade_agl_m: f64,
}

impl Default for NoiseCfg {
    fn default() -> Self {
        NoiseCfg {
            scale_m: 45.0,
            octaves: 2,
            evolve_ms: 0.6,
            large_scale_m: 300.0,
            large_fade_agl_m: 300.0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct GustNoise {
    noise: FastNoise,
    norm: f64,
    inv_scale: f64,
    evolve: f64,
    off_v: [f32; 3],
    off_z: [f32; 3],
    off_l: [f32; 3],
    inv_large: f64,
    amp_large: f64,
    /// Высота над рельефом, до которой крупные вихри нарастают линейно (`large_fade_agl_m`, ≥ 1).
    pub large_fade_agl: f64,
}

impl GustNoise {
    /// `WindModel.setup`: порядок вызовов генератора — сдвиги `v`, `z`, `l`, затем 2048 точек
    /// нормировки (перестановка меняет шум).
    pub fn new(cfg: &NoiseCfg, seed: u64) -> Self {
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
        let mut rng = Pcg32::from_seed(seed);
        let mut off = |a: f32, b: f32| {
            let x = rng.randf_range(a, b);
            let y = rng.randf_range(a, b);
            let z = rng.randf_range(a, b);
            [x, y, z]
        };
        let off_v = off(100.0, 200.0);
        let off_z = off(300.0, 400.0);
        let off_l = off(500.0, 600.0);
        let mut sum = 0.0f64;
        for _ in 0..2048 {
            let x = rng.randf_range(-500.0, 500.0);
            let y = rng.randf_range(-500.0, 500.0);
            let z = rng.randf_range(-500.0, 500.0);
            let v = f64::from(noise.get3(x, y, z));
            sum += v * v;
        }
        let rms = (sum / 2048.0).sqrt().max(1.0e-4);
        let large = cfg.large_scale_m;
        let (inv_large, amp_large) = if large > cfg.scale_m {
            let amp_small = (cfg.scale_m / large).powf(1.0 / 3.0);
            (1.0 / large, (1.0 - amp_small * amp_small).sqrt())
        } else {
            (0.0, 0.0)
        };
        GustNoise {
            noise,
            norm: 1.0 / rms,
            inv_scale: 1.0 / cfg.scale_m,
            evolve: cfg.evolve_ms,
            off_v,
            off_z,
            off_l,
            inv_large,
            amp_large,
            large_fade_agl: cfg.large_fade_agl_m.max(1.0),
        }
    }

    fn noise3(&self, q: [f32; 3]) -> [f32; 3] {
        let at = |o: [f32; 3]| {
            let c = |a: f32, b: f32| (f64::from(a) + f64::from(b)) as f32;
            self.noise.get3(c(q[0], o[0]), c(q[1], o[1]), c(q[2], o[2]))
        };
        [
            self.noise.get3(q[0], q[1], q[2]),
            at(self.off_v),
            at(self.off_z),
        ]
    }

    /// Единичные пульсации в `pos` в момент `t`; `dir` — куда дует ветер `(x, z)`, `advect` —
    /// скорость переноса, `large_k` 0..1 — доля крупных вихрей.
    pub fn gust_unit(
        &self,
        pos: [f32; 3],
        t: f64,
        dir: [f64; 2],
        advect: f64,
        large_k: f64,
    ) -> [f64; 3] {
        let (dx, dz) = (f64::from(dir[0] as f32), f64::from(dir[1] as f32));
        let p = [
            (f64::from(pos[0]) - dx * advect * t) as f32,
            (f64::from(pos[1]) + self.evolve * t) as f32,
            (f64::from(pos[2]) - dz * advect * t) as f32,
        ];
        let s = self.inv_scale as f32;
        let mut n = self.noise3([p[0] * s, p[1] * s, p[2] * s]);
        let a_l = self.amp_large * large_k.clamp(0.0, 1.0);
        let mut nn = [f64::from(n[0]), f64::from(n[1]), f64::from(n[2])];
        if a_l > 1.0e-4 {
            let a_s = (1.0 - a_l * a_l).sqrt();
            let il = self.inv_large as f32;
            let nl = self.noise3([
                p[0] * il + self.off_l[0],
                p[1] * il + self.off_l[1],
                p[2] * il + self.off_l[2],
            ]);
            n = [
                (f64::from(n[0]) * a_s + f64::from(nl[0]) * a_l) as f32,
                (f64::from(n[1]) * a_s) as f32,
                (f64::from(n[2]) * a_s + f64::from(nl[2]) * a_l) as f32,
            ];
            nn = [f64::from(n[0]), f64::from(n[1]), f64::from(n[2])];
        }
        let k = self.norm as f32;
        [
            f64::from(nn[0] as f32 * k),
            f64::from(nn[1] as f32 * k),
            f64::from(nn[2] as f32 * k),
        ]
    }
}
