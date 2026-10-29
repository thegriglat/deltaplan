//! Описания ядер подъёма W6 (`Atmosphere.cores`): ядра в радиусе физики вокруг фокуса (охват
//! W6 v3 — активные термики набора), живые (`w > 0`), с осью ближе `radius` к `center`.
//! Порядок — по возрастанию id (как в GDScript: статичные, отрицательные, первыми).
use super::life::AtmoThermal;
use super::sample::State;
use crate::Core;
use std::sync::Arc;

/// Запись ядра термика `th` на момент `t`.
fn core_of(th: &AtmoThermal, t: f64) -> (Core, f64) {
    let ph = th.phase(t);
    let ax = th.axis_at(f64::from(th.src[1]), ph.drift);
    let flags = u8::from(th.is_static) | (u8::from(th.has_cloud) << 1) | (u8::from(th.is_cb) << 2);
    let w = th.strength * ph.env;
    let c = Core {
        id: (th.id & 0xFF_FFFF) as f32,
        flags: f32::from(flags),
        x: ax[0] as f32,
        z: ax[1] as f32,
        y_src: th.src[1],
        top: th.top as f32,
        w: w as f32,
        radius: th.radius as f32,
        lean_x: th.lean[0],
        lean_z: th.lean[1],
        age_s: (t - th.t_birth) as f32,
        life_s: if th.is_static {
            f32::NAN
        } else {
            (th.t_end() - th.t_birth) as f32
        },
        stage: th.stage(t) as f32,
        vis_seed: th.noise_seed as f32,
        // интенсивность грозы у Cb — RW-11
        storm: 0.0,
    };
    (c, w)
}

fn within(c: &Core, center: [f32; 3], radius: f32) -> bool {
    f64::from(center[0] - c.x).hypot(f64::from(center[2] - c.z)) <= f64::from(radius)
}

fn sorted(list: &[Arc<AtmoThermal>]) -> Vec<&Arc<AtmoThermal>> {
    let mut v: Vec<_> = list.iter().collect();
    v.sort_by_key(|th| th.id);
    v
}

/// Ядра W6 на момент `t`; `out` очищается. Только активные (радиус физики вокруг фокуса) и
/// живые (`w > 0`).
pub fn cores(state: &State, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
    out.clear();
    for th in sorted(&state.active) {
        let (c, w) = core_of(th, t);
        if w > 0.0 && within(&c, center, radius) {
            out.push(c);
        }
    }
}

/// Все термики набора (живые, доживающие с облаком, статичные) в радиусе `radius` от `center`,
/// без фильтра активности и силы: то, что держит `ThermalField.thermals`. Сверка с дампом W8,
/// RW-11 (облака над доживающими).
pub fn all_cores(state: &State, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
    out.clear();
    for th in sorted(&state.all) {
        let (c, _) = core_of(th, t);
        if within(&c, center, radius) {
            out.push(c);
        }
    }
}
