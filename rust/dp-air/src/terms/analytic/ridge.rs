//! Склоновый подъём аналитики: `V·∇h` впереди по ветру,
//! затухает с высотой над склоном.
use super::ground::GroundField;
use crate::place::Place;

/// `ridge.*`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RidgeCfg {
    pub eff: f64,
    pub decay: f64,
    pub shift_k: f64,
    pub shift_max: f64,
    pub max: f64,
}

impl Default for RidgeCfg {
    fn default() -> Self {
        RidgeCfg {
            eff: 0.7,
            decay: 250.0,
            shift_k: 0.8,
            shift_max: 400.0,
            max: 6.0,
        }
    }
}

/// Подъём в точке `pos` на высоте `agl` над землёй при ветре `u` вдоль `dir` (куда дует), м/с.
pub fn lift(
    cfg: &RidgeCfg,
    gf: &GroundField,
    place: &Place,
    pos: [f32; 3],
    agl: f64,
    u: f64,
    dir: [f64; 2],
) -> f64 {
    let shift = (agl * cfg.shift_k).min(cfg.shift_max);
    let gr = gf.sample(
        place,
        f64::from(pos[0]) + dir[0] * shift,
        f64::from(pos[2]) + dir[1] * shift,
    );
    let slope = dir[0] * gr.dhdx + dir[1] * gr.dhdz;
    let agl_s = (f64::from(pos[1]) - gr.h).max(0.0);
    (cfg.eff * u * slope * (-agl_s / cfg.decay).exp()).clamp(-cfg.max, cfg.max)
}
