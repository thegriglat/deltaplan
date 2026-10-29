//! Статичные термики (`add_static`, `set_static_thermals`): стоят над источником, сила постоянна,
//! наклонены ветром целиком; id отрицательные (−1, −2, …). `noise_seed` — `hash(Vector2i(x, z))`.
use super::GroundSource;
use super::cells::Setup;
use super::life::AtmoThermal;
use crate::hash::hash_v2i;
use std::sync::Arc;

/// Термики из списка `[x, z, сила, радиус]` (W4 `set_static_thermals`).
pub fn build_statics(
    setup: &Setup,
    ground: &dyn GroundSource,
    list: &[[f32; 4]],
) -> Vec<Arc<AtmoThermal>> {
    let mut out = Vec::with_capacity(list.len());
    for (i, s) in list.iter().enumerate() {
        let (x, z) = (f64::from(s[0]), f64::from(s[1]));
        let mut th = AtmoThermal::blank(-1 - i as i64);
        th.is_static = true;
        // `int(x)` эталона — усечение к нулю
        th.noise_seed = i64::from(hash_v2i(x as i32, z as i32));
        let h = ground.height(x, z);
        th.src = [s[0], h as f32, s[1]];
        th.top = setup
            .cloudbase_msl
            .max(f64::from(th.src[1]) + setup.cfg.min_depth_m);
        th.strength = f64::from(s[2]);
        th.radius = f64::from(s[3]);
        th.setup_cloud(&setup.w, 0.0);
        th.apply_wind(&setup.cfg, &setup.wind, setup.street, None);
        out.push(Arc::new(th));
    }
    out
}
