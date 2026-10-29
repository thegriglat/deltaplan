//! Физика облака Cb над термиком: стадия, окно жизни, центр и размеры.
//! Выбор облаков для рисования, затухание по дальности и слияние (`select*`, `life_fade`,
//! `range_fade`, `far_m`, `step_fade`, `merge_winners`) остаются у потребителя.
use super::field::cloud_center;
use crate::Configs;
use crate::terms::named_json;
use crate::terms::thermal::AtmoThermal;
use crate::terms::thermal::life::smoothstep;
use serde_json::Value;

/// секция `atmosphere` → `clouds` (запасные значения — как в эталоне).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CloudCfg {
    pub delay_factor: f64,
    pub grow_s: f64,
    pub linger_s: f64,
    pub width_per_ms_m: f64,
    pub width_min_m: f64,
    pub width_max_m: f64,
    pub overdev_depth_factor: f64,
    pub overdev_spread: f64,
    pub height_to_width: [f64; 2],
    pub cb_width_max_m: f64,
}

impl Default for CloudCfg {
    fn default() -> Self {
        CloudCfg {
            delay_factor: 0.6,
            grow_s: 300.0,
            linger_s: 240.0,
            width_per_ms_m: 300.0,
            width_min_m: 350.0,
            width_max_m: 1800.0,
            overdev_depth_factor: 2.4,
            overdev_spread: 0.7,
            height_to_width: [0.45, 0.9],
            cb_width_max_m: 8000.0,
        }
    }
}

impl CloudCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = CloudCfg::default();
        let g = |k: &str, dv: f64| {
            atm.pointer(&format!("/clouds/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        let hw = atm
            .pointer("/clouds/height_to_width")
            .and_then(Value::as_array)
            .filter(|a| a.len() >= 2)
            .map_or(d.height_to_width, |a| {
                [
                    a[0].as_f64().unwrap_or(d.height_to_width[0]),
                    a[1].as_f64().unwrap_or(d.height_to_width[1]),
                ]
            });
        CloudCfg {
            delay_factor: g("delay_factor", d.delay_factor),
            grow_s: g("grow_s", d.grow_s),
            linger_s: g("linger_s", d.linger_s),
            width_per_ms_m: g("width_per_ms_m", d.width_per_ms_m),
            width_min_m: g("width_min_m", d.width_min_m),
            width_max_m: g("width_max_m", d.width_max_m),
            overdev_depth_factor: g("overdev_depth_factor", d.overdev_depth_factor),
            overdev_spread: g("overdev_spread", d.overdev_spread),
            height_to_width: hw,
            cb_width_max_m: g("cb_width_max_m", d.cb_width_max_m),
        }
    }
}

/// `clampf` эталона: без паники при `min > max`.
fn clampf(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

/// Стадия облака: рост 0..1, распад 0..1, активность 0..1; `x < 0` — облака нет.
pub type Stage = [f64; 3];
/// Облака нет (слабый термик, ещё не выросло или уже растаяло).
pub const NO_CLOUD: Stage = [-1.0, 0.0, 0.0];

/// Физика облаков над термиками с множителем размера погоды `size_factor` (`cloud_size_factor`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CloudModel {
    pub cfg: CloudCfg,
    pub size_factor: f64,
}

impl CloudModel {
    pub fn new(cfg: CloudCfg, size_factor: f64) -> Self {
        CloudModel { cfg, size_factor }
    }

    /// Окно жизни облака: (появление, начало распада облака, конец — облака нет), с.
    /// Облако появляется, когда воздух дошёл до кромки, и растёт, пока термик жив.
    pub fn life_window(&self, th: &AtmoThermal) -> [f64; 3] {
        let span = th.top - f64::from(th.src[1]);
        let delay = (span / th.strength.max(0.5) * self.cfg.delay_factor)
            .min(th.t_grow + th.t_mature * 0.5);
        let ds = th.t_birth + th.t_grow + th.t_mature;
        [
            th.t_birth + delay,
            ds + delay * 0.3,
            ds + th.t_decay + self.cfg.linger_s,
        ]
    }

    /// Стадия облака над термиком в момент `t` (`CloudModel.stage`; принудительная стадия
    /// `stage_override` - тестовая сцена, не переносится).
    pub fn stage(&self, th: &AtmoThermal, t: f64) -> Stage {
        if !th.has_cloud {
            return NO_CLOUD;
        }
        if th.is_static {
            return [1.0, 0.0, 1.0];
        }
        let w = self.life_window(th);
        if t <= w[0] {
            return NO_CLOUD;
        }
        let g = smoothstep(w[0], w[0] + self.cfg.grow_s, t);
        let dcy = clampf((t - w[1]) / (w[2] - w[1]).max(1.0), 0.0, 1.0);
        if g <= 0.0 || dcy >= 1.0 {
            return NO_CLOUD;
        }
        [g, dcy, th.phase(t).env]
    }

    /// Центр основания облака (x, z): верх наклонённого столба плюс снос на распаде.
    pub fn center(&self, th: &AtmoThermal, t: f64) -> [f32; 2] {
        cloud_center(th, t)
    }

    /// Размеры: (полуось по ветру, полуось поперёк, мощность, растекание верха), м.
    pub fn size(&self, th: &AtmoThermal, st: Stage) -> [f64; 4] {
        let c = &self.cfg;
        let (g, dcy) = (st[0], st[1]);
        let mut width = clampf(
            c.width_per_ms_m * th.strength * self.size_factor,
            c.width_min_m,
            c.width_max_m,
        );
        if th.is_cb {
            width = clampf(width * 3.0, c.width_max_m, c.cb_width_max_m);
        }
        // Растёт вширь, на распаде расползается.
        let rz = width * 0.5 * (0.55 + 0.45 * g) * (1.0 + 0.3 * dcy);
        let rx = rz * th.cloud_stretch;
        let mut od = th.overdevelop * g;
        // Кучевые хорошей погоды шире, чем выше: мощность в пределах доли ширины.
        let mut depth = clampf(
            th.cloud_depth,
            width * c.height_to_width[0],
            width * c.height_to_width[1],
        );
        if th.is_cb {
            // Верх Cb - тропопауза: мощность задана, переразвитие её не умножает.
            depth = th.cloud_depth;
            od = 0.0;
        }
        let h = depth
            * (1.0 + od * (c.overdev_depth_factor - 1.0))
            * (0.3 + 0.7 * g)
            * (1.0 - 0.35 * dcy);
        let spread = od * c.overdev_spread * smoothstep(0.3, 1.0, g);
        [rx, rz, h, spread]
    }
}
