//! Один термик: наклонённый ветром столб от источника до верха, огибающая
//! роста и распада, отрыв низа, снос; наклон и снос от ветра (`_apply_wind`), облачные поля
//! (`_setup_cloud`, `_setup_cb`) и времена жизни (`_set_life`).
use super::cfg::ThermalCfg;
use crate::rand::Pcg32;
use crate::terms::{WeatherView, WindModel};

/// `smoothstep(from, to, x)` эталона.
pub fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if (from - to).abs() < 1.0e-12 {
        return if x < from { 0.0 } else { 1.0 };
    }
    let t = ((x - from) / (to - from)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Запись термика. Поля `Vector2/Vector3` эталона — `f32` (как там), остальное `f64`.
#[derive(Clone, Debug, PartialEq)]
pub struct AtmoThermal {
    pub id: i64,
    pub is_static: bool,
    pub noise_seed: i64,
    /// Источник: x, высота земли в источнике, z.
    pub src: [f32; 3],
    /// Верх столба над уровнем моря, м.
    pub top: f64,
    /// Сила ядра на пике, м/с.
    pub strength: f64,
    /// Радиус ядра у верха, м.
    pub radius: f64,
    /// Горизонтальное смещение оси (x, z) на 1 м подъёма.
    pub lean: [f32; 2],
    /// Скорость сноса, м/с (x, z).
    pub drift_vel: [f32; 2],
    /// Через сколько секунд после рождения термик отрывается и идёт с ветром; `< 0` — на распаде.
    pub drift_delay: f64,
    pub t_birth: f64,
    pub t_grow: f64,
    pub t_mature: f64,
    pub t_decay: f64,
    /// Облако (RW-11): есть ли, мощность, вытянутость по ветру, переразвитие.
    pub has_cloud: bool,
    pub cloud_depth: f64,
    pub cloud_stretch: f64,
    pub overdevelop: f64,
    /// Кучево-дождевой.
    pub is_cb: bool,
    /// Облачный подсос (у Cb > 0).
    pub suck: f64,
    /// Множитель кольца опускания; `< 0` — общий.
    pub ring: f64,
    /// Клетка источника (ось a — по ветру, c — поперёк).
    pub cell: (i64, i64),
    /// До какого момента цикл помнят (не рождают заново), с.
    pub cycle_forget: f64,
}

/// Состояние на момент (`update_time`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Phase {
    /// Огибающая силы 0..1.
    pub env: f64,
    /// Ниже этой высоты подъёма нет (оторвавшийся низ).
    pub cut_h: f64,
    /// Смещение сносом, м.
    pub drift: [f32; 2],
}

impl AtmoThermal {
    pub fn t_end(&self) -> f64 {
        self.t_birth + self.t_grow + self.t_mature + self.t_decay
    }

    pub fn t_decay_start(&self) -> f64 {
        self.t_birth + self.t_grow + self.t_mature
    }

    /// Момент, с которого термик сносится: отрыв (`drift_delay` после рождения) или распад.
    pub fn drift_start(&self) -> f64 {
        if self.drift_delay >= 0.0 {
            self.t_birth + self.drift_delay
        } else {
            self.t_decay_start()
        }
    }

    /// Смещение сносом в момент `t`.
    pub fn drift_at(&self, t: f64) -> [f32; 2] {
        if self.is_static {
            return [0.0; 2];
        }
        let k = (t - self.drift_start()).max(0.0) as f32;
        [self.drift_vel[0] * k, self.drift_vel[1] * k]
    }

    /// Доля распада 0..1.
    pub fn decay_progress(&self, t: f64) -> f64 {
        if self.is_static {
            return 0.0;
        }
        ((t - self.t_decay_start()) / self.t_decay.max(0.001)).clamp(0.0, 1.0)
    }

    /// `update_time(t)`: огибающая, отрыв низа, снос.
    pub fn phase(&self, t: f64) -> Phase {
        if self.is_static {
            return Phase {
                env: 1.0,
                cut_h: -1.0e9,
                drift: [0.0; 2],
            };
        }
        let a = t - self.t_birth;
        let ds = self.t_grow + self.t_mature;
        let mut env = if a <= 0.0 {
            0.0
        } else if a < self.t_grow {
            smoothstep(0.0, self.t_grow, a)
        } else {
            1.0
        };
        let mut cut_h = -1.0e9;
        if a > ds {
            let u = ((a - ds) / self.t_decay.max(0.001)).min(1.0);
            env = 1.0 - smoothstep(0.0, 1.0, u);
            let sy = f64::from(self.src[1]);
            cut_h = sy + (self.top - sy) * u;
        }
        Phase {
            env,
            cut_h,
            drift: self.drift_at(t),
        }
    }

    /// Ось столба на высоте `y` с учётом наклона и сноса `drift`.
    pub fn axis_at(&self, y: f64, drift: [f32; 2]) -> [f64; 2] {
        let dh = (y - f64::from(self.src[1])).max(0.0);
        [
            f64::from(self.src[0]) + f64::from(self.lean[0]) * dh + f64::from(drift[0]),
            f64::from(self.src[2]) + f64::from(self.lean[1]) * dh + f64::from(drift[1]),
        ]
    }

    /// Стадия жизни для описания W6 (`cores`): рост 0..1, зрелость 1..2, распад 2..3; статичный 1,5.
    pub fn stage(&self, t: f64) -> f64 {
        if self.is_static {
            return 1.5;
        }
        let age = t - self.t_birth;
        if age < self.t_grow {
            (age / self.t_grow.max(1.0e-6)).clamp(0.0, 1.0)
        } else if age <= self.t_grow + self.t_mature {
            1.0 + (age - self.t_grow) / self.t_mature.max(1.0e-6)
        } else {
            2.0 + self.decay_progress(t)
        }
    }

    /// Пустой термик с полями по умолчанию.
    pub fn blank(id: i64) -> Self {
        AtmoThermal {
            id,
            is_static: false,
            noise_seed: id,
            src: [0.0; 3],
            top: 0.0,
            strength: 0.0,
            radius: 100.0,
            lean: [0.0; 2],
            drift_vel: [0.0; 2],
            drift_delay: -1.0,
            t_birth: 0.0,
            t_grow: 1.0,
            t_mature: 1.0,
            t_decay: 1.0,
            has_cloud: false,
            cloud_depth: 0.0,
            cloud_stretch: 1.0,
            overdevelop: 0.0,
            is_cb: false,
            suck: 0.0,
            ring: -1.0,
            cell: (0, 0),
            cycle_forget: 0.0,
        }
    }

    /// `_apply_wind`: наклон ствола и снос. `street` — сила улиц, `wcol` — средний ветер столба
    /// источника поля (RW-10e); иначе ветер профиля на середине столба.
    pub fn apply_wind(
        &mut self,
        cfg: &ThermalCfg,
        wind: &WindModel,
        street: f64,
        wcol: Option<[f32; 2]>,
    ) {
        let span = self.top - f64::from(self.src[1]);
        let wmid: [f32; 2] = wcol.unwrap_or_else(|| vec2_f32(wind, span * 0.5));
        let rise = (self.strength * cfg.rise_factor).max(cfg.rise_min_ms);
        let f = if self.is_static {
            0.0
        } else {
            cfg.drift_factor.clamp(0.0, 1.0)
        };
        let k = ((1.0 - f) / rise) as f32;
        let mut lean = [wmid[0] * k, wmid[1] * k];
        let max_lean = cfg.max_lean_deg.to_radians().tan();
        let len = f64::from(lean[0] * lean[0] + lean[1] * lean[1]).sqrt();
        if len > max_lean {
            let s = (max_lean / len) as f32;
            lean = [lean[0] * s, lean[1] * s];
        }
        self.lean = lean;
        if f > 0.0 {
            let ff = f as f32;
            self.drift_vel = [wmid[0] * ff, wmid[1] * ff];
            self.drift_delay = cfg.drift_delay_s;
        } else {
            self.drift_vel = wcol.unwrap_or_else(|| vec2_f32(wind, span));
            self.drift_delay = -1.0;
        }
        self.cloud_stretch = 1.0 + cfg.street_cloud_stretch * street;
    }

    /// `_setup_cloud`: мощность и переразвитие облака поля (входы RW-11). `rnd` — число генератора.
    pub fn setup_cloud(&mut self, w: &WeatherView, rnd: f64) {
        self.has_cloud = false;
        let smax = pair(w, "thermal_strength_ms", [0.0, 0.0])[1];
        let k = (self.strength / smax.max(0.01)).clamp(0.0, 1.0);
        self.cloud_depth = w.f64_or("cloud_depth_m", 0.0) * (0.35 + 0.65 * k);
        self.overdevelop = 0.0;
        if rnd < w.f64_or("overdevelopment_chance", 0.0) && k > 0.6 {
            self.overdevelop = 1.0;
        }
    }

    /// `_setup_cb`: сильный термик в грозовой день может стать Cb.
    pub fn setup_cb(&mut self, cfg: &ThermalCfg, w: &WeatherView, rnd: f64) {
        let smax = pair(w, "thermal_strength_ms", [0.0, 0.0])[1];
        let chance = cb_thermal_chance(w);
        if chance <= 0.0 || rnd >= chance || self.strength < smax * cfg.cb_min_strength_frac {
            return;
        }
        self.is_cb = true;
        self.has_cloud = true;
        self.strength *= cfg.cb_strength_factor;
        self.suck = cfg.cb_suck;
        self.t_mature *= cfg.cb_mature_factor;
        self.cloud_depth = w
            .f64_or("cb_top_above_base_m", 6000.0)
            .max(self.cloud_depth);
        self.overdevelop = 1.0;
    }

    /// `_set_life`: пауза + рост + зрелость + распад = период клетки.
    pub fn set_life(&mut self, cfg: &ThermalCfg, rng: &mut Pcg32, t_start: f64, period: f64) {
        let mut rr = |r: [f64; 2]| f64::from(rng.randf_range(r[0] as f32, r[1] as f32));
        let gap = rr(cfg.gap_s);
        let g = rr(cfg.grow_s);
        let m = rr(cfg.mature_s);
        let d = rr(cfg.decay_s);
        let life = (period - gap).max(1.0);
        let k = life / (g + m + d);
        self.t_birth = t_start;
        self.t_grow = g * k;
        self.t_mature = m * k;
        self.t_decay = d * k;
    }
}

/// Доля сильных термиков, переразвивающихся в Cb: `cb_thermal_chance`, у старых пресетов `cb_chance`.
pub fn cb_thermal_chance(w: &WeatherView) -> f64 {
    w.f64_or("cb_thermal_chance", w.f64_or("cb_chance", 0.0))
}

/// Пара чисел из словаря погоды (`thermal_strength_ms`, `thermal_radius_m`, ...).
pub fn pair(w: &WeatherView, key: &str, dv: [f64; 2]) -> [f64; 2] {
    match w.get(key).and_then(|v| v.as_array()) {
        Some(a) if a.len() >= 2 => [
            a[0].as_f64().unwrap_or(dv[0]),
            a[1].as_f64().unwrap_or(dv[1]),
        ],
        _ => dv,
    }
}

/// `wind.vec2_at(agl)` как `Vector2` эталона.
pub fn vec2_f32(wind: &WindModel, agl: f64) -> [f32; 2] {
    let v = wind.vec2_at(agl);
    [v[0] as f32, v[1] as f32]
}
