//! `GroundField` (`scripts/atmosphere/ground_field.gd`): кеш рельефа аналитики — сетка узлов
//! `cell_m` (30 м) кусками `chunk_cells × chunk_cells` (16 × 16, узлов `17 × 17` с перекрытием),
//! в узле `(высота, dh/dx, dh/dz, линия тени против ветра, превышение гребня)`; между узлами —
//! билинейно.
//!
//! Линия тени: `s = max_i (h(p − ŵ·d_i) − d_i·tan θ)` по дистанциям `upwind_distances_m`;
//! превышение гребня: `max(0, max_i h(p − ŵ·d_i) − h(p))`.
//!
//! Отличие от GD (риск 1 разбора RW-8a): высота — `ground_height(place)` (билинейно по растру места,
//! 25 м), а не `terrain.height_at`. Кусок строится целиком по первому обращению (как в GD), но
//! кеш — на пару «место, направление ветра»: направление берётся из `Terms::ground_dir`
//! (правило «пересчёт при повороте > 5°» — там), смена направления или места — новый кеш.
use crate::field::runtime::ground_height;
use crate::place::Place;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

/// Чисел на узел: высота, dh/dx, dh/dz, линия тени, превышение гребня.
const CH: usize = 5;

/// Параметры `ground.*` и `lee.*` (`GroundField.setup`).
#[derive(Clone, Debug, PartialEq)]
pub struct GroundCfg {
    pub cell: f64,
    pub chunk_cells: usize,
    pub max_chunks: usize,
    pub dists: Vec<f64>,
    pub tan_shadow: f64,
    pub ref_radius: f64,
    pub ref_samples: usize,
}

impl Default for GroundCfg {
    fn default() -> Self {
        GroundCfg {
            cell: 30.0,
            chunk_cells: 16,
            max_chunks: 400,
            dists: vec![60.0, 150.0, 300.0, 600.0, 1000.0, 1600.0],
            tan_shadow: 12.0f64.to_radians().tan(),
            ref_radius: 10_000.0,
            ref_samples: 15,
        }
    }
}

/// `(высота, dh/dx, dh/dz, линия тени)` в точке.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GroundSample {
    pub h: f64,
    pub dhdx: f64,
    pub dhdz: f64,
    pub shadow: f64,
}

/// Признак места: указатель и размер растра, шапка сетки, три высоты. Кеш живёт на одно место.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PlaceSig([u64; 7]);

impl PlaceSig {
    pub fn of(place: &Place) -> Self {
        Self::keyed(place, 0)
    }

    /// С ключом места - поколением `load_place` (`Terms::place_key`): адрес освобождённого растра
    /// мог достаться новому месту, поколение - нет.
    pub fn keyed(place: &Place, key: u64) -> Self {
        let hs = place.heights();
        let g = &place.header().grid;
        let at = |i: usize| hs.get(i).map_or(0, |h| u64::from(h.to_bits()));
        PlaceSig([
            hs.as_ptr() as usize as u64,
            hs.len() as u64,
            g.origin_x.to_bits() ^ g.spacing.to_bits().rotate_left(17),
            at(0),
            at(hs.len() / 2),
            at(hs.len().saturating_sub(1)),
            key,
        ])
    }
}

/// Кеш кусков для одного места и одного направления ветра.
pub struct GroundField {
    cfg: GroundCfg,
    sig: PlaceSig,
    dir: [f32; 2],
    chunks: RwLock<HashMap<i64, Arc<Vec<f32>>>>,
    ref_h: OnceLock<f64>,
}

impl GroundField {
    pub fn new(cfg: &GroundCfg, sig: PlaceSig, dir: [f32; 2]) -> Self {
        GroundField {
            cfg: cfg.clone(),
            sig,
            dir,
            chunks: RwLock::new(HashMap::new()),
            ref_h: OnceLock::new(),
        }
    }

    pub fn matches(&self, sig: PlaceSig, dir: [f32; 2]) -> bool {
        self.sig == sig && self.dir == dir
    }

    /// Высота рельефа без сетки узлов (`height_fn`).
    pub fn height(place: &Place, x: f64, z: f64) -> f64 {
        f64::from(ground_height(place, x as f32, z as f32))
    }

    fn key(cx: i64, cz: i64) -> i64 {
        ((cx + (1 << 20)) << 21) + (cz + (1 << 20))
    }

    fn chunk(&self, place: &Place, ix: i64, iz: i64) -> Arc<Vec<f32>> {
        let n = self.cfg.chunk_cells as i64;
        let (cx, cz) = (ix.div_euclid(n), iz.div_euclid(n));
        let key = Self::key(cx, cz);
        if let Some(c) = self
            .chunks
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&key)
        {
            return c.clone();
        }
        let built = Arc::new(self.build(place, cx, cz));
        let mut w = self
            .chunks
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if w.len() >= self.cfg.max_chunks {
            w.clear();
        }
        w.insert(key, built.clone());
        built
    }

    fn build(&self, place: &Place, cx: i64, cz: i64) -> Vec<f32> {
        let n = self.cfg.chunk_cells;
        let stride = n + 1;
        let m = stride + 2;
        let cell = self.cfg.cell;
        let x0 = (cx * n as i64 - 1) as f64 * cell;
        let z0 = (cz * n as i64 - 1) as f64 * cell;
        let mut hs = vec![0.0f32; m * m];
        for j in 0..m {
            for i in 0..m {
                hs[j * m + i] =
                    Self::height(place, x0 + i as f64 * cell, z0 + j as f64 * cell) as f32;
            }
        }
        let mut out = vec![0.0f32; stride * stride * CH];
        let inv2c = 0.5 / cell;
        let (dx, dz) = (f64::from(self.dir[0]), f64::from(self.dir[1]));
        for j in 0..stride {
            for i in 0..stride {
                let hi = (j + 1) * m + (i + 1);
                let h = f64::from(hs[hi]);
                let wx = x0 + (i + 1) as f64 * cell;
                let wz = z0 + (j + 1) as f64 * cell;
                let mut shadow = -1.0e9f64;
                let mut crest = h;
                for &dist in &self.cfg.dists {
                    let hc = Self::height(place, wx - dx * dist, wz - dz * dist);
                    shadow = shadow.max(hc - dist * self.cfg.tan_shadow);
                    crest = crest.max(hc);
                }
                let o = (j * stride + i) * CH;
                out[o] = h as f32;
                out[o + 1] = ((f64::from(hs[hi + 1]) - f64::from(hs[hi - 1])) * inv2c) as f32;
                out[o + 2] = ((f64::from(hs[hi + m]) - f64::from(hs[hi - m])) * inv2c) as f32;
                out[o + 3] = shadow as f32;
                out[o + 4] = (crest - h) as f32;
            }
        }
        out
    }

    /// Индекс узла `(ix, iz)` в куске и сам кусок.
    fn node(&self, place: &Place, ix: i64, iz: i64) -> (Arc<Vec<f32>>, usize) {
        let n = self.cfg.chunk_cells as i64;
        let c = self.chunk(place, ix, iz);
        let (lx, lz) = (ix.rem_euclid(n), iz.rem_euclid(n));
        let o = (lz as usize * (self.cfg.chunk_cells + 1) + lx as usize) * CH;
        (c, o)
    }

    /// `(высота, dh/dx, dh/dz, линия тени)` — билинейно по сетке.
    pub fn sample(&self, place: &Place, x: f64, z: f64) -> GroundSample {
        let fx = x / self.cfg.cell;
        let fz = z / self.cfg.cell;
        let (ixf, izf) = (fx.floor(), fz.floor());
        let (ix, iz) = (ixf as i64, izf as i64);
        let (d, i00) = self.node(place, ix, iz);
        let stride = (self.cfg.chunk_cells + 1) * CH;
        let (i10, i01, i11) = (i00 + CH, i00 + stride, i00 + stride + CH);
        let (tx, tz) = (fx - ixf, fz - izf);
        let w00 = (1.0 - tx) * (1.0 - tz);
        let w10 = tx * (1.0 - tz);
        let w01 = (1.0 - tx) * tz;
        let w11 = tx * tz;
        let at = |k: usize| {
            f64::from(d[i00 + k]) * w00
                + f64::from(d[i10 + k]) * w10
                + f64::from(d[i01 + k]) * w01
                + f64::from(d[i11 + k]) * w11
        };
        GroundSample {
            h: at(0),
            dhdx: at(1),
            dhdz: at(2),
            shadow: at(3),
        }
    }

    /// Превышение гребня против ветра над землёй, м (0 — наветренный склон, равнина).
    pub fn relief_at(&self, place: &Place, x: f64, z: f64) -> f64 {
        let fx = x / self.cfg.cell;
        let fz = z / self.cfg.cell;
        let (ixf, izf) = (fx.floor(), fz.floor());
        let (d, i0) = self.node(place, ixf as i64, izf as i64);
        let i00 = i0 + 4;
        let i01 = i00 + (self.cfg.chunk_cells + 1) * CH;
        let (tx, tz) = (fx - ixf, fz - izf);
        let lerp = |a: f64, b: f64, t: f64| a + (b - a) * t;
        let v = |i: usize| f64::from(d[i]);
        lerp(
            lerp(v(i00), v(i00 + CH), tx),
            lerp(v(i01), v(i01 + CH), tx),
            tz,
        )
    }

    /// Средняя высота земли вокруг `(cx, cz)` по сетке `samples × samples` в круге `radius`.
    pub fn mean_height(place: &Place, cx: f64, cz: f64, radius: f64, samples: usize) -> f64 {
        let mut sum = 0.0;
        let mut cnt = 0usize;
        let den = (samples.max(2) - 1) as f64;
        for j in 0..samples {
            for i in 0..samples {
                let u = (i as f64 / den) * 2.0 - 1.0;
                let v = (j as f64 / den) * 2.0 - 1.0;
                if u * u + v * v > 1.0 {
                    continue;
                }
                sum += Self::height(place, cx + u * radius, cz + v * radius);
                cnt += 1;
            }
        }
        sum / cnt.max(1) as f64
    }

    /// Средняя высота земли вокруг начала координат (`_ground_ref` атмосферы), считается раз.
    pub fn ground_ref(&self, place: &Place) -> f64 {
        *self.ref_h.get_or_init(|| {
            Self::mean_height(place, 0.0, 0.0, self.cfg.ref_radius, self.cfg.ref_samples)
        })
    }

    pub fn chunk_count(&self) -> usize {
        self.chunks
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }
}
