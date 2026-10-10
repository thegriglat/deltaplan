//! O1: мировая сетка 20 км. Все формулы — ровно как в контракте (f64).

pub const R: f64 = 6371008.8;
pub const DLAT: f64 = 0.18;
pub const T: f64 = 20000.0;
pub const J_MIN: i32 = -500;
pub const J_MAX: i32 = 499;

/// Метров на градус: M = π·R/180.
pub fn m_per_deg() -> f64 {
    std::f64::consts::PI * R / 180.0
}

/// Пояс шириной DLAT: параметры сетки.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Band {
    pub j: i32,
    pub n: u32,
    pub dlon: f64,
    pub kx: f64,
    pub ky: f64,
    pub lat0: f64,
}

impl Band {
    pub fn new(j: i32) -> Band {
        let m = m_per_deg();
        let latc = (j as f64 + 0.5) * DLAT;
        let kx = m * (latc * std::f64::consts::PI / 180.0).cos();
        let n = ((360.0 * kx / T).floor() as i64).max(1) as u32;
        Band { j, n, dlon: 360.0 / n as f64, kx, ky: m, lat0: j as f64 * DLAT }
    }
    pub fn lon0(&self, i: u32) -> f64 {
        -180.0 + i as f64 * self.dlon
    }
    /// Индекс тайла по долготе (lon уже в [-180, 180)).
    pub fn index_of(&self, lon: f64) -> u32 {
        let i = ((lon + 180.0) / self.dlon).floor();
        i.max(0.0).min((self.n - 1) as f64) as u32
    }
    /// Ширина и высота тайла, м.
    pub fn size_m(&self) -> (f64, f64) {
        (self.dlon * self.kx, DLAT * self.ky)
    }
}

pub fn normalize_lon(lon: f64) -> f64 {
    if (-180.0..180.0).contains(&lon) {
        lon
    } else {
        (lon + 180.0).rem_euclid(360.0) - 180.0
    }
}

pub fn band_of_lat(lat: f64) -> i32 {
    let lat = lat.clamp(-90.0, 90.0);
    ((lat / DLAT).floor() as i32).clamp(J_MIN, J_MAX)
}

/// Тайл `(j, i)` точки.
pub fn tile_of(lat: f64, lon: f64) -> (i32, u32) {
    let j = band_of_lat(lat);
    (j, Band::new(j).index_of(normalize_lon(lon)))
}

/// Точка → (j, i, x, y), x/y — метры от юго-западного угла тайла.
pub fn project(lat: f64, lon: f64) -> (i32, u32, f64, f64) {
    let lon = normalize_lon(lon);
    let j = band_of_lat(lat);
    let b = Band::new(j);
    let i = b.index_of(lon);
    ((j), i, (lon - b.lon0(i)) * b.kx, (lat - b.lat0) * b.ky)
}

/// Тайл `(j, i)`, x, y (м) → (lat, lon).
pub fn unproject(j: i32, i: u32, x: f64, y: f64) -> (f64, f64) {
    let b = Band::new(j);
    (b.lat0 + y / b.ky, b.lon0(i) + x / b.kx)
}

/// Соседи 3×3: пояса снизу вверх, столбцы запад → восток (по кругу), без повторов.
pub fn neighbors(lat: f64, lon: f64) -> Vec<(i32, u32)> {
    let lon = normalize_lon(lon);
    let j = band_of_lat(lat);
    let mut out: Vec<(i32, u32)> = Vec::with_capacity(9);
    for jj in (j - 1)..=(j + 1) {
        if !(J_MIN..=J_MAX).contains(&jj) {
            continue;
        }
        let b = Band::new(jj);
        let ic = b.index_of(lon) as i64;
        let n = b.n as i64;
        for d in -1..=1i64 {
            let t = (jj, (ic + d).rem_euclid(n) as u32);
            if !out.contains(&t) {
                out.push(t);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bands_basic() {
        let b = Band::new(0);
        assert!(b.n == 2001);
        let (w, h) = b.size_m();
        assert!((20000.0..20500.0).contains(&w), "{w}");
        assert!((h - 20015.11).abs() < 0.01);
        assert_eq!(Band::new(499).n >= 1, true);
    }

    #[test]
    fn project_roundtrip() {
        let (j, i, x, y) = project(46.05, 14.5);
        let (lat, lon) = unproject(j, i, x, y);
        assert!((lat - 46.05).abs() < 1e-9 && (lon - 14.5).abs() < 1e-9);
    }

    #[test]
    fn poles_and_antimeridian() {
        assert_eq!(tile_of(90.0, 0.0).0, 499);
        assert_eq!(tile_of(-90.0, 0.0).0, -500);
        assert_eq!(tile_of(10.0, 180.0).1, 0);
        let nb = neighbors(0.01, -179.999);
        assert_eq!(nb.len(), 9);
        let nb = neighbors(89.99, 10.0);
        assert!(nb.iter().all(|t| t.0 <= 499));
    }
}
