//! Идеальные формы корпуса: холм и хребет поперёк ветра в памяти, на сетке мест фикстур
//! (1601 × 1601 узел, шаг 25 м, 40 км). Заголовок (loc, климат, дата) — как у
//! `tests/fixtures/wind/places/synthetic.json`; поверхность — луг, без воды.
use dp_air::{Place, PlaceHeader};

pub const N: usize = 1601;
pub const STEP_M: f64 = 25.0;
pub const ORIGIN_M: f64 = -20000.0;

/// Что строить: форма, высота, σ (м) и направление ветра «откуда» (для хребта — его ориентация).
pub struct Ideal<'a> {
    pub id: &'a str,
    pub shape: &'a str,
    pub h_m: f64,
    pub sigma_m: f64,
    pub dir_deg: f64,
}

/// Высота формы в точке (`east`, `north`) от центра, м; основание 0.
/// Холм: `h·exp(−r²/2σ²)`; хребет: `h·exp(−x'²/2σ²)`, `x'` — расстояние вдоль ветра (ветер дует
/// «куда» `(−sin φ, −cos φ)` в (восток, север), `φ` — направление «откуда»).
pub fn height(s: &Ideal, east: f64, north: f64) -> f64 {
    let two_s2 = 2.0 * s.sigma_m * s.sigma_m;
    match s.shape {
        "ridge" => {
            let a = s.dir_deg.to_radians();
            let xp = -east * a.sin() - north * a.cos();
            s.h_m * (-xp * xp / two_s2).exp()
        }
        _ => s.h_m * (-(east * east + north * north) / two_s2).exp(),
    }
}

/// Расстояние от вершины до середины высоты склона (форма на высоте h/2), м.
pub fn half_height_radius(sigma_m: f64) -> f64 {
    sigma_m * (2.0 * std::f64::consts::LN_2).sqrt()
}

/// Точки стартов идеальной формы (восток, север): вершина, середина наветренного и подветренного
/// склона (середина высоты) по направлению ветра.
pub fn start_sites(s: &Ideal) -> Vec<(f64, f64)> {
    let r = half_height_radius(s.sigma_m);
    let a = s.dir_deg.to_radians();
    let (e, n) = (r * a.sin(), r * a.cos()); // наветренная сторона — туда, откуда дует
    vec![(0.0, 0.0), (e, n), (-e, -n)]
}

pub fn build(s: &Ideal) -> Result<Place, String> {
    let header = format!(
        r#"{{"version":1,"loc":{{"id":"{}","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,"month":7,"day":15,
        "climate":{{"tx_c":20.19,"dtr_k":10.37,"z_cell_m":0.0,"has_hh1":true,"has_hh5":true}},
        "climate_lag":{{"tx_c":19.48,"dtr_k":11.46,"z_cell_m":0.0,"has_hh1":true,"has_hh5":true}}}},
        "grid":{{"origin_x":{ORIGIN_M},"origin_z":{ORIGIN_M},"spacing":{STEP_M},"width":{N},"height":{N}}},
        "surface_classes":{{"none":0,"forest":1,"grass":2,"crop":3,"shrub":4,"bare":5,"water":6,"built":7,"snow":8}},
        "start_sites":[]}}"#,
        s.id
    );
    let header = PlaceHeader::from_json(&header).map_err(|e| format!("{e:?}"))?;
    let mut heights = Vec::with_capacity(N * N);
    for j in 0..N {
        // строка j к +Z; север = −Z
        let north = -(ORIGIN_M + j as f64 * STEP_M);
        for i in 0..N {
            let east = ORIGIN_M + i as f64 * STEP_M;
            heights.push(height(s, east, north) as f32);
        }
    }
    Place::new(
        header,
        heights,
        vec![0; N * N],
        vec![2; N * N],
        vec![1.0; N * N],
    )
    .map_err(|e| format!("{e:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hill_peak_and_half_height() {
        let s = Ideal {
            id: "t",
            shape: "hill",
            h_m: 1000.0,
            sigma_m: 3000.0,
            dir_deg: 270.0,
        };
        assert!((height(&s, 0.0, 0.0) - 1000.0).abs() < 1e-9);
        let r = half_height_radius(3000.0);
        assert!((height(&s, r, 0.0) - 500.0).abs() < 1e-6);
        assert!((height(&s, 0.0, -r) - 500.0).abs() < 1e-6);
    }

    #[test]
    fn ridge_is_across_the_wind() {
        // ветер с запада (270°): хребет вытянут с севера на юг, высота зависит от востока
        let s = Ideal {
            id: "t",
            shape: "ridge",
            h_m: 600.0,
            sigma_m: 3000.0,
            dir_deg: 270.0,
        };
        let (a, b) = (height(&s, 2000.0, 0.0), height(&s, 2000.0, 15000.0));
        assert!((a - b).abs() < 1e-6, "{a} {b}");
        assert!(height(&s, 0.0, 0.0) > a);
    }

    #[test]
    fn start_sites_windward_is_upwind() {
        // ветер с запада: наветренный склон — к западу (e < 0)
        let s = Ideal {
            id: "t",
            shape: "hill",
            h_m: 300.0,
            sigma_m: 3000.0,
            dir_deg: 270.0,
        };
        let v = start_sites(&s);
        assert_eq!(v[0], (0.0, 0.0));
        assert!(v[1].0 < -3000.0 && v[1].1.abs() < 1e-6);
        assert!(v[2].0 > 3000.0);
    }

    #[test]
    fn place_builds_with_the_fixture_grid() {
        let s = Ideal {
            id: "t",
            shape: "hill",
            h_m: 300.0,
            sigma_m: 3000.0,
            dir_deg: 270.0,
        };
        let p = build(&s).unwrap();
        let g = &p.header().grid;
        assert_eq!((g.width, g.height), (1601, 1601));
        let c = N / 2;
        assert!((f64::from(p.heights()[c * N + c]) - 300.0).abs() < 1e-3);
        assert!(p.heights()[0] < 1e-6);
    }
}
