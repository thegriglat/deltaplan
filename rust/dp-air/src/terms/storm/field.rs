//! Гроза: нисходящий поток ливня, растекание у земли и фронт порывов от
//! термиков-Cb. Чистая функция набора термиков и времени, состояния нет: ячейки — это термики
//! набора с `is_cb` (`StormField.refresh` вызывается при каждом обновлении набора).
use crate::Configs;
use crate::terms::named_json;
use crate::terms::thermal::AtmoThermal;
use crate::terms::thermal::life::smoothstep;

/// Коэффициенты секция `atmosphere` → `storm` (запасные значения — как в эталоне) и ширина облака
/// на 1 м/с (`clouds.width_per_ms_m`, умножается на `cloud_size_factor` погоды).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StormCfg {
    /// `downdraft_ms`: нисходящий поток в центре ливня, м/с.
    pub downdraft_ms: f64,
    /// `downdraft_radius_frac`: радиус ливня в долях радиуса облака.
    pub downdraft_radius_frac: f64,
    /// `downdraft_turn_height_m`: ниже этой высоты над землёй поток уходит в стороны, м.
    pub downdraft_turn_height_m: f64,
    /// `outflow_ms`: растекание у земли, м/с (и предел горизонтали суммы ячеек).
    pub outflow_ms: f64,
    /// `outflow_depth_m`: толщина слоя растекания, м.
    pub outflow_depth_m: f64,
    /// `front_speed_ms`: скорость ухода фронта порывов, м/с.
    pub front_speed_ms: f64,
    /// `front_max_radius_m`: дальше фронт не уходит, м.
    pub front_max_radius_m: f64,
    /// `front_width_m`: ширина зоны фронта, м.
    pub front_width_m: f64,
    /// `front_updraft_ms`: подъём над фронтом, м/с.
    pub front_updraft_ms: f64,
    /// `turbulence_per_outflow`: σ = множитель × скорость растекания.
    pub turbulence_per_outflow: f64,
    /// `start_mature_frac`: буря начинается с этой доли зрелой стадии.
    pub start_mature_frac: f64,
    /// `ramp_s`: нарастание и затухание бури, с.
    pub ramp_s: f64,
    /// `linger_s`: буря держится после конца термика, с.
    pub linger_s: f64,
    /// `clouds.width_per_ms_m` (до поправки погоды).
    pub cloud_width_per_ms: f64,
}

impl Default for StormCfg {
    fn default() -> Self {
        StormCfg {
            downdraft_ms: 6.0,
            downdraft_radius_frac: 0.5,
            downdraft_turn_height_m: 300.0,
            outflow_ms: 12.0,
            outflow_depth_m: 600.0,
            front_speed_ms: 8.0,
            front_max_radius_m: 12000.0,
            front_width_m: 800.0,
            front_updraft_ms: 2.0,
            turbulence_per_outflow: 0.35,
            start_mature_frac: 0.4,
            ramp_s: 300.0,
            linger_s: 900.0,
            cloud_width_per_ms: 500.0,
        }
    }
}

impl StormCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(serde_json::Value::Null);
        let d = StormCfg::default();
        let s = |k: &str, dv: f64| {
            atm.pointer(&format!("/storm/{k}"))
                .and_then(serde_json::Value::as_f64)
                .unwrap_or(dv)
        };
        StormCfg {
            downdraft_ms: s("downdraft_ms", d.downdraft_ms),
            downdraft_radius_frac: s("downdraft_radius_frac", d.downdraft_radius_frac),
            downdraft_turn_height_m: s("downdraft_turn_height_m", d.downdraft_turn_height_m),
            outflow_ms: s("outflow_ms", d.outflow_ms),
            outflow_depth_m: s("outflow_depth_m", d.outflow_depth_m),
            front_speed_ms: s("front_speed_ms", d.front_speed_ms),
            front_max_radius_m: s("front_max_radius_m", d.front_max_radius_m),
            front_width_m: s("front_width_m", d.front_width_m),
            front_updraft_ms: s("front_updraft_ms", d.front_updraft_ms),
            turbulence_per_outflow: s("turbulence_per_outflow", d.turbulence_per_outflow),
            start_mature_frac: s("start_mature_frac", d.start_mature_frac),
            ramp_s: s("ramp_s", d.ramp_s),
            linger_s: s("linger_s", d.linger_s),
            cloud_width_per_ms: atm
                .pointer("/clouds/width_per_ms_m")
                .and_then(serde_json::Value::as_f64)
                .unwrap_or(d.cloud_width_per_ms),
        }
    }
}

/// Центр облака над столбом в момент `t` (x, z): верх наклонённого столба плюс снос
/// (`AtmoThermal.cloud_center`).
pub fn cloud_center(th: &AtmoThermal, t: f64) -> [f32; 2] {
    let span = th.top - f64::from(th.src[1]);
    let d = th.drift_at(t);
    [
        th.src[0] + (f64::from(th.lean[0]) * span) as f32 + d[0],
        th.src[2] + (f64::from(th.lean[1]) * span) as f32 + d[1],
    ]
}

/// Вклад бурь в точке: ветер x, вертикаль, ветер z, σ болтанки (`Vector4` эталона).
pub type StormSample = [f64; 4];

/// Гроза с коэффициентами `cfg` и шириной облака на 1 м/с `cloud_w_per_ms` (с поправкой погоды).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StormField {
    pub cfg: StormCfg,
    pub cloud_w_per_ms: f64,
}

impl StormField {
    pub fn new(cfg: StormCfg, size_factor: f64) -> Self {
        StormField {
            cloud_w_per_ms: cfg.cloud_width_per_ms * size_factor,
            cfg,
        }
    }

    /// Начало стадии бури (ливень, нисходящий поток), с.
    pub fn storm_start(&self, th: &AtmoThermal) -> f64 {
        th.t_birth + th.t_grow + th.t_mature * self.cfg.start_mature_frac
    }

    /// Сила бури 0..1 в момент `t`.
    pub fn intensity(&self, th: &AtmoThermal, t: f64) -> f64 {
        let s0 = self.storm_start(th);
        let s1 = th.t_end() + self.cfg.linger_s;
        let r = self.cfg.ramp_s;
        smoothstep(s0, s0 + r, t) * (1.0 - smoothstep(s1 - r, s1, t))
    }

    /// Радиус нисходящего потока (ливня), м.
    pub fn downdraft_radius(&self, th: &AtmoThermal) -> f64 {
        self.cloud_w_per_ms * th.strength * 0.5 * self.cfg.downdraft_radius_frac
    }

    /// Радиус фронта порывов в момент `t`, м.
    pub fn front_radius(&self, th: &AtmoThermal, t: f64) -> f64 {
        let r0 = self.downdraft_radius(th);
        (r0 + self.cfg.front_speed_ms * (t - self.storm_start(th)).max(0.0))
            .min(self.cfg.front_max_radius_m)
    }

    /// Вклад бурь ячеек `cells` (термики с `is_cb`) в точке `pos` на высоте `agl` над землёй.
    pub fn sample<'a>(
        &self,
        cells: impl IntoIterator<Item = &'a AtmoThermal>,
        pos: [f32; 3],
        agl: f64,
        t: f64,
    ) -> StormSample {
        let c = &self.cfg;
        let mut out = [0.0f64; 4];
        for th in cells {
            let e = self.intensity(th, t);
            if e <= 0.0 {
                continue;
            }
            let ce = cloud_center(th, t);
            let dx = f64::from(pos[0] - ce[0]);
            let dz = f64::from(pos[2] - ce[1]);
            let r2 = dx * dx + dz * dz;
            let rf = self.front_radius(th, t);
            let reach = rf + c.front_width_m * 2.0;
            if r2 > reach * reach {
                continue;
            }
            let r = r2.sqrt();
            let rd = self.downdraft_radius(th);
            // Нисходящий поток: под основанием, у земли поворачивает в стороны.
            if f64::from(pos[1]) < th.top {
                let dd =
                    (-(r * r) / (rd * rd)).exp() * smoothstep(0.0, c.downdraft_turn_height_m, agl);
                out[1] -= c.downdraft_ms * e * dd;
            }
            // Растекание у земли: радиально от центра, до фронта; слой толщиной ~outflow_depth.
            let prof = (-agl / c.outflow_depth_m).exp();
            let radial = (r / rd).min(1.0) * (1.0 - smoothstep(rf - c.front_width_m, rf, r));
            let u = c.outflow_ms * e * prof * radial;
            if r > 1.0 {
                out[0] += dx / r * u;
                out[2] += dz / r * u;
            }
            // Фронт порывов: подъём тёплого воздуха над «языком» холодного и болтанка.
            let fr = (r - rf) / c.front_width_m;
            let front = (-fr * fr).exp();
            out[1] += c.front_updraft_ms
                * e
                * front
                * smoothstep(0.0, 150.0, agl)
                * (-agl / 1500.0).exp();
            out[3] = out[3]
                .max(c.turbulence_per_outflow * c.outflow_ms * e * (front + 0.5 * radial) * prof);
        }
        // Холодные «языки» соседних ячеек сливаются, а не складываются: поток не сильнее одной.
        let h2 = out[0] * out[0] + out[2] * out[2];
        if h2 > c.outflow_ms * c.outflow_ms {
            let k = c.outflow_ms / h2.sqrt();
            out[0] *= k;
            out[2] *= k;
        }
        out[1] = out[1].clamp(-c.downdraft_ms, c.front_updraft_ms);
        out
    }
}
