//! Сумма ветра: порядок `Atmosphere.air_velocity_at` (`atmosphere.gd` 921–988) и
//! `_air_velocity_field` (1071–1213), слагаемые — из слотов `terms::slots`.
//!
//! Порядок: поле → аналитика (среднее) → поле (поправка) → термик → `_extra_flow` → σ → шум.
//! Формулы ограничителей и полосы края `a < 1` перенесены буквально (формулы, не физика).
use super::decompose::{
    Rec, T_ANALYTIC, T_CLOUD, T_FIELD, T_GUST, T_RIDGE, T_STORM, T_THERMAL, T_TURB, T_WAVE,
};
use super::slots::{AnalyticMean, ExtraOut, ThermalOut, TurbMean};
use super::{Ctx, Terms};
use crate::SampleMode;
use crate::field::field_set::FieldSet;
use crate::field::runtime::ground_height;
use crate::place::Place;

/// Что болтанке поля известно о середине суммы (после `_extra_flow`, до шума).
#[derive(Clone, Copy, Debug, Default)]
pub struct Mid {
    /// Средняя скорость в точке.
    pub v: [f64; 3],
    pub analytic: Option<AnalyticMean>,
    pub turb: Option<TurbMean>,
    pub thermal: Option<ThermalOut>,
    pub extra: Option<ExtraOut>,
}

fn finite(x: f64) -> f32 {
    let y = x as f32;
    if y.is_finite() { y } else { 0.0 }
}

/// Скорость и σ в точке `p` в момент `t`: `[vx, vy, vz, σ]`; NaN/inf на входе, нет места — нули.
/// `rec` — запись вкладов для `decompose` (не меняет счёта).
pub fn sum(
    terms: &Terms,
    fs: &FieldSet,
    place: Option<&Place>,
    p: [f32; 3],
    mode: SampleMode,
    t: f64,
    mut rec: Option<&mut Rec>,
) -> [f32; 4] {
    if !p.iter().all(|v| v.is_finite()) {
        return [0.0; 4];
    }
    let Some(place) = place else {
        return [0.0; 4];
    };
    let g = ground_height(place, p[0], p[2]);
    let (fw, a) = if fs.is_active() {
        let v = fs.sample(p, g);
        (v.v, v.share)
    } else {
        ([0.0; 3], 0.0)
    };
    let agl = f64::from((p[1] - g).max(0.0));
    let wind = &terms.wind;
    let c = Ctx {
        pos: p,
        ground: g,
        agl,
        t,
        mode,
        a,
        fw,
        u: wind.speed_at_pos(agl, f64::from(p[1])),
        terms,
        fs,
        place,
    };
    let wd = wind.dir();
    let cfg = &terms.cfg;
    let s = &terms.slots;

    let am = s.analytic.mean(&c);
    let tm = if a > 0.0 {
        s.turb.mean(&c, am.as_ref())
    } else {
        None
    };
    let th = s.thermal.sample(&c);
    let fade = (agl / cfg.ground_fade_m).min(1.0);
    let mut v = fw;
    if let Some(r) = rec.as_deref_mut() {
        r.add(T_FIELD, fw);
    }
    // средняя горизонталь вдоль ветра и вертикаль
    if am.is_some() || tm.is_some() {
        let h = am.map_or(0.0, |m| m.h) + tm.map_or(0.0, |m| m.dh);
        v[0] += wd[0] * h;
        v[2] += wd[1] * h;
        if let Some(r) = rec.as_deref_mut() {
            r.add(T_ANALYTIC, [wd[0] * h, 0.0, wd[1] * h]);
        }
    }
    if let Some(m) = am {
        v[1] += m.w_ridge + m.w_lee;
        if let Some(r) = rec.as_deref_mut() {
            r.add(T_ANALYTIC, [0.0, m.w_lee, 0.0]);
            r.add(T_RIDGE, [0.0, m.w_ridge, 0.0]);
        }
    }
    if let Some(t) = th {
        let bg_sink = terms.weather.f64_or("background_sink_ms", 0.0);
        let w_th = fade * (bg_sink * (1.0 - t.mask) + t.w);
        v[1] += w_th;
        if let Some(r) = rec.as_deref_mut() {
            r.add(T_THERMAL, [0.0, w_th, 0.0]);
        }
    }
    let ex = s.extra.flow(&c, v);
    if let Some(e) = &ex {
        for (q, x) in v.iter_mut().enumerate() {
            *x += e.storm[q] + e.wave[q] + e.cloud[q];
        }
        if let Some(r) = rec.as_deref_mut() {
            r.add(T_STORM, e.storm);
            r.add(T_WAVE, e.wave);
            r.add(T_CLOUD, e.cloud);
        }
    }

    // σ и шум
    let mid = Mid {
        v,
        analytic: am,
        turb: tm,
        thermal: th,
        extra: ex,
    };
    let ex2 = th.map_or(0.0, |t| t.sigma * t.sigma)
        + ex.map_or(0.0, |e| {
            e.sigma_storm * e.sigma_storm + e.sigma_rotor * e.sigma_rotor
        });
    let full = mode == SampleMode::Full;
    let to = if a > 0.0 {
        s.turb.sigma(&c, &mid)
    } else {
        None
    };
    // болтанка поля
    let mut field_part: Option<([f64; 3], f64)> = None;
    if let Some(o) = to {
        let cap_h = cfg.turb_max_ms.max(o.sep[0].min(cfg.rotor_max_ms));
        let cap_v = cfg.turb_max_ms.max(o.sep[1].min(cfg.rotor_max_ms));
        let vr = cfg.vertical_ratio;
        let s_u = (o.s_u * o.s_u + ex2).sqrt().min(cap_h);
        let s_v = (o.s_v * o.s_v + ex2).sqrt().min(cap_h);
        let s_w = (o.s_w * o.s_w + ex2 * vr * vr).sqrt().min(cap_v);
        let mh = [v[0], v[2]];
        let ml = (mh[0] * mh[0] + mh[1] * mh[1]).sqrt();
        let e = if ml > 0.3 {
            [mh[0] / ml, mh[1] / ml]
        } else {
            let l = (wd[0] * wd[0] + wd[1] * wd[1]).sqrt();
            if l > 0.0 {
                [wd[0] / l, wd[1] / l]
            } else {
                [0.0, 0.0]
            }
        };
        let n = o.n;
        let tv = [
            e[0] * n[0] * s_u - e[1] * n[2] * s_v,
            n[1] * s_w + a * o.w_burst,
            e[1] * n[0] * s_u + e[0] * n[2] * s_v,
        ];
        field_part = Some((tv, s_u));
        if let Some(r) = rec.as_deref_mut() {
            r.add(T_TURB, tv);
            r.sigma[T_TURB] = s_u;
        }
    }
    // аналитическая болтанка (вся при a = 0, полоса края при a < 1)
    let mut an_part: Option<([f64; 3], f64)> = None;
    if a < 1.0
        && let Some(at) = s.analytic.turb(&c, am.as_ref(), th.as_ref())
    {
        let amp = (at.var + ex2)
            .sqrt()
            .min(cfg.turb_max_ms.max(at.rot.min(cfg.rotor_max_ms)));
        // при a = 0 тихий шум не считают (`amp < 1e-3`), в полосе края — всегда
        let ta = if full && (a > 0.0 || amp >= 1.0e-3) {
            s.analytic.gust(&c, amp, fade)
        } else {
            [0.0; 3]
        };
        an_part = Some((ta, amp));
    }
    let (tv, mut sig) = match (field_part, an_part) {
        (Some((tf, su)), Some((ta, amp))) => {
            // полоса края: два независимых шума — дисперсия сохраняется
            let k = 1.0 / (a * a + (1.0 - a) * (1.0 - a)).sqrt();
            if let Some(r) = rec.as_deref_mut() {
                r.vel[T_TURB] = [0.0; 3];
                r.add(T_TURB, [tf[0] * (a * k), tf[1] * (a * k), tf[2] * (a * k)]);
                r.add(
                    T_GUST,
                    [
                        ta[0] * ((1.0 - a) * k),
                        ta[1] * ((1.0 - a) * k),
                        ta[2] * ((1.0 - a) * k),
                    ],
                );
                r.sigma[T_GUST] = amp;
            }
            let tv = [
                (tf[0] * a + ta[0] * (1.0 - a)) * k,
                (tf[1] * a + ta[1] * (1.0 - a)) * k,
                (tf[2] * a + ta[2] * (1.0 - a)) * k,
            ];
            (tv, (a * su * su + (1.0 - a) * amp * amp).sqrt())
        }
        (Some((tf, su)), None) => (tf, su),
        (None, Some((ta, amp))) => {
            if let Some(r) = rec.as_deref_mut() {
                r.add(T_GUST, ta);
                r.sigma[T_GUST] = amp;
            }
            (ta, amp)
        }
        (None, None) => ([0.0; 3], 0.0),
    };
    // бурление в облаке
    let chaos = ex.map_or(0.0, |e| e.chaos);
    if chaos > 1.0e-3 && full {
        let nc = s.extra.chaos_noise(&c);
        for q in 0..3 {
            v[q] += nc[q] * chaos;
        }
        if let Some(r) = rec {
            r.add(T_GUST, [nc[0] * chaos, nc[1] * chaos, nc[2] * chaos]);
        }
    }
    if chaos > 0.0 {
        sig = (sig * sig + chaos * chaos).sqrt();
    }
    if full && (field_part.is_some() || an_part.is_some()) {
        for q in 0..3 {
            v[q] += tv[q];
        }
    }
    [finite(v[0]), finite(v[1]), finite(v[2]), finite(sig)]
}
