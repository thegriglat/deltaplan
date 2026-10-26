//! Набор уровней среднего поля и плавная подмена поля: перенос `AirFieldSet` (GDScript,
//! `scripts/atmosphere/air_model/air_field_set.gd`).
//!
//! Уровни — от мелкого к грубому (окна 50/100 м, область 400 м); сейчас один — область 400 м
//! (окна добавят RW-6n/6o). Выборка: мелкий уровень с весом края `w₁`, остаток `1 − w₁` — следующему,
//! …; что не покрыто ни одним уровнем — аналитике (доля поля < 1; сама аналитика — вне набора,
//! фасад дополняет: итог для пилота `xyz + (1 − доля)·аналитика`).
//!
//! Подмена `set_field(new, blend_s)`: новое поле за `blend_s` секунд времени атмосферы смешивается
//! со старым (доля нового — smoothstep по времени, монотонно); старое — набор уровней или «нет
//! поля» (`set_field(vec![], blend_s)` плавно выключает). Подмена во время подмены: «старым»
//! становится снимок текущей смеси (не больше `MAX_OLD` наборов, доли < `OLD_MIN_W` отбрасываются)
//! — выборка не скачет. Время идёт вызовом `advance(dt)`; два опроса между `advance` равны.
//!
//! Уровни — `Arc<Field>`: снимок «старого» делит их с набором, без копий массивов.
use super::wind_field::{Channel, Field, Limits, T_SIZE};
use rayon::prelude::*;
use std::sync::Arc;

/// Не больше наборов в снимке «старого».
pub const MAX_OLD: usize = 3;
/// Доли «старого» меньше этой отбрасываются.
pub const OLD_MIN_W: f64 = 1.0e-3;

type Levels = Vec<Arc<Field>>;

/// Взвешенная скорость поля: сумма вкладов уровней и доля поля 0..1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vel {
    /// (x, y, z) мира, м/с (y — w_mech).
    pub v: [f64; 3],
    /// Доля поля 0..1.
    pub share: f64,
}

#[derive(Clone)]
pub struct FieldSet {
    levels: Levels,
    /// Ограничители, применяются к каждому новому полю (`air_model.max_speed_ms`, `max_w_ms`).
    pub limits: Limits,
    /// Ширина полосы края, клеток (`air_model.edge_blend_cells`) — ставится каждому уровню.
    pub edge_cells: f64,
    /// «Старое» поле подмены: `(уровни, вес)`, Σ весов = 1.
    old: Vec<(Levels, f64)>,
    blend_total: f64,
    blend_t: f64,
}

impl Default for FieldSet {
    fn default() -> Self {
        FieldSet {
            levels: Vec::new(),
            limits: Limits::default(),
            edge_cells: 5.0,
            old: Vec::new(),
            blend_total: 0.0,
            blend_t: 0.0,
        }
    }
}

fn smoothstep01(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

impl FieldSet {
    pub fn new(limits: Limits, edge_cells: f64) -> Self {
        FieldSet {
            limits,
            edge_cells,
            ..Default::default()
        }
    }

    /// Уровни (от мелкого к грубому).
    pub fn levels(&self) -> &[Arc<Field>] {
        &self.levels
    }

    /// Подготовка уровней к подаче (ограничители, ширина края) — тяжёлая часть `set_field`; её
    /// делают в фоне, а на главном потоке остаётся [`FieldSet::set_levels`] (только подмена `Arc`).
    pub fn prepare(levels: Vec<Field>, limits: Limits, edge_cells: f64) -> Vec<Arc<Field>> {
        levels
            .into_iter()
            .map(|mut f| {
                f.clamp_values(limits);
                f.edge_cells = edge_cells;
                Arc::new(f)
            })
            .collect()
    }

    /// Задать уровни (пусто — без поля) и смешивать со старым `blend_s` секунд (≤ 0 — сразу).
    /// Каждому уровню ставятся ограничители и ширина края набора.
    pub fn set_field(&mut self, levels: Vec<Field>, blend_s: f64) {
        let lv = Self::prepare(levels, self.limits, self.edge_cells);
        self.set_levels(lv, blend_s);
    }

    /// То же для уровней, подготовленных [`FieldSet::prepare`]: без обхода массивов.
    pub fn set_levels(&mut self, lv: Vec<Arc<Field>>, blend_s: f64) {
        if blend_s > 0.0 && (!self.levels.is_empty() || !lv.is_empty() || self.blend_total > 0.0) {
            self.old = self.snapshot();
            self.blend_total = blend_s;
            self.blend_t = 0.0;
        } else {
            self.old.clear();
            self.blend_total = 0.0;
        }
        self.levels = lv;
    }

    /// Снимок текущей смеси (старое × (1 − s) + текущие уровни × s) — «старое» новой подмены.
    fn snapshot(&self) -> Vec<(Levels, f64)> {
        let s = self.blend_fraction();
        let mut out: Vec<(Levels, f64)> = Vec::new();
        if self.blend_total > 0.0 {
            for (lv, w) in &self.old {
                out.push((lv.clone(), w * (1.0 - s)));
            }
            out.push((self.levels.clone(), s));
        } else {
            out.push((self.levels.clone(), 1.0));
        }
        out.retain(|p| p.1 >= OLD_MIN_W);
        // не больше MAX_OLD наборов: самые лёгкие отбросить (остаток ≤ их доли)
        out.sort_by(|a, b| b.1.total_cmp(&a.1));
        out.truncate(MAX_OLD);
        let total: f64 = out.iter().map(|p| p.1).sum();
        for p in &mut out {
            p.1 /= total.max(1.0e-9);
        }
        out
    }

    /// Продвинуть подмену на `dt` секунд.
    pub fn advance(&mut self, dt: f64) {
        if self.blend_total <= 0.0 {
            return;
        }
        self.blend_t += dt;
        if self.blend_t >= self.blend_total {
            self.blend_total = 0.0;
            self.old.clear();
        }
    }

    /// Доля нового поля в подмене 0..1 (1 — подмены нет).
    pub fn blend_fraction(&self) -> f64 {
        if self.blend_total <= 0.0 {
            return 1.0;
        }
        smoothstep01(self.blend_t / self.blend_total)
    }

    /// Есть ли что выбирать (поле или идёт подмена).
    pub fn is_active(&self) -> bool {
        !self.levels.is_empty() || self.blend_total > 0.0
    }

    /// Точка покрыта хотя бы одним уровнем.
    pub fn contains(&self, pos: [f32; 3]) -> bool {
        self.levels.iter().any(|f| f.contains(pos))
    }

    /// Скорость поля, взвешенная долей: сумма вкладов уровней (мир, м/с; y — `w_mech`) и доля
    /// поля 0..1. Итог для пилота: `v + (1 − share)·аналитика`.
    pub fn sample(&self, pos: [f32; 3], ground_h: f32) -> Vel {
        let cur = sample_levels(&self.levels, pos, ground_h);
        if self.blend_total <= 0.0 {
            return cur;
        }
        let mut old = Vel {
            v: [0.0; 3],
            share: 0.0,
        };
        for (lv, w) in &self.old {
            let o = sample_levels(lv, pos, ground_h);
            for q in 0..3 {
                old.v[q] += o.v[q] * w;
            }
            old.share += o.share * w;
        }
        let s = self.blend_fraction();
        let mut r = cur;
        for q in 0..3 {
            r.v[q] = old.v[q] + (cur.v[q] - old.v[q]) * s;
        }
        r.share = old.share + (cur.share - old.share) * s;
        r
    }

    /// Пачка: `out[i] = sample(pos[i], ground_h[i])` как `[x, y, z, доля]`; без выделений.
    pub fn sample_many(&self, pos: &[[f32; 3]], ground_h: &[f32], out: &mut [[f32; 4]]) {
        let n = pos.len().min(ground_h.len()).min(out.len());
        out[..n]
            .par_chunks_mut(256)
            .zip(pos[..n].par_chunks(256))
            .zip(ground_h[..n].par_chunks(256))
            .for_each(|((o, p), g)| {
                for q in 0..o.len() {
                    let r = self.sample(p[q], g[q]);
                    o[q] = [r.v[0] as f32, r.v[1] as f32, r.v[2] as f32, r.share as f32];
                }
            });
    }

    /// θ′ (К), взвешенная долей поля: `(вклад, доля)`.
    pub fn sample_theta(&self, pos: [f32; 3], ground_h: f32) -> (f64, f64) {
        self.scalar(Channel::Theta, pos, ground_h)
    }

    /// `w_conv` (м/с), взвешенная долей поля: `(вклад, доля)`. Пилоту напрямую не отдаётся.
    pub fn sample_w_conv(&self, pos: [f32; 3], ground_h: f32) -> (f64, f64) {
        self.scalar(Channel::WConv, pos, ground_h)
    }

    fn scalar(&self, ch: Channel, pos: [f32; 3], ground_h: f32) -> (f64, f64) {
        let cur = scalar_levels(&self.levels, ch, pos, ground_h);
        if self.blend_total <= 0.0 {
            return cur;
        }
        let mut old = (0.0, 0.0);
        for (lv, w) in &self.old {
            let o = scalar_levels(lv, ch, pos, ground_h);
            old.0 += o.0 * w;
            old.1 += o.1 * w;
        }
        let s = self.blend_fraction();
        (old.0 + (cur.0 - old.0) * s, old.1 + (cur.1 - old.1) * s)
    }

    /// Величины пограничного слоя (`Field::turb_at`), среднее по уровням с их весами (не
    /// умножено на долю): `T_SIZE + 1` чисел, последнее — доля поля 0..1. N² = NaN, если хоть у
    /// одного участвующего уровня нет `gam`. Нет поля — нули.
    pub fn sample_turb(&self, pos: [f32; 3], ground_h: f32) -> [f32; T_SIZE + 1] {
        let mut cur = turb_levels(&self.levels, pos, ground_h);
        if self.blend_total <= 0.0 {
            return cur;
        }
        // среднее по наборам снимка «старого» и новому с весами (вес набора × его доля поля)
        let s = self.blend_fraction();
        let wn = cur[T_SIZE] as f64 * s;
        let mut tot = wn;
        for c in cur.iter_mut().take(T_SIZE) {
            *c = (*c as f64 * wn) as f32;
        }
        for (lv, w) in &self.old {
            let o = turb_levels(lv, pos, ground_h);
            let wo = o[T_SIZE] as f64 * w * (1.0 - s);
            tot += wo;
            for q in 0..T_SIZE {
                cur[q] = (cur[q] as f64 + o[q] as f64 * wo) as f32;
            }
        }
        if tot <= 0.0 {
            return turb_levels(&self.levels, pos, ground_h);
        }
        for c in cur.iter_mut().take(T_SIZE) {
            *c = (*c as f64 / tot) as f32;
        }
        cur[T_SIZE] = tot as f32;
        cur
    }

    /// Размер клетки уровней в точке, м: среднее `dx` уровней с весами, как в `sample` (текущий
    /// набор, без снимка подмены), нормированное на долю; вне поля / нет уровней — 0.
    pub fn sample_dx(&self, pos: [f32; 3]) -> f64 {
        let (mut acc, mut rem) = (0.0, 1.0);
        for f in &self.levels {
            let w = f.edge_weight(pos);
            if w <= 0.0 {
                continue;
            }
            acc += f.grid().dx * rem * w;
            rem *= 1.0 - w;
            if rem <= 0.0 {
                break;
            }
        }
        let share = 1.0 - rem;
        if share > 0.0 { acc / share } else { 0.0 }
    }
}

fn sample_levels(lv: &[Arc<Field>], pos: [f32; 3], ground_h: f32) -> Vel {
    let mut acc = [0.0f64; 3];
    let mut rem = 1.0f64;
    for f in lv {
        let w = f.edge_weight(pos);
        if w <= 0.0 {
            continue;
        }
        let s = f.sample(pos, ground_h);
        for q in 0..3 {
            acc[q] += s[q] as f64 * (rem * w);
        }
        rem *= 1.0 - w;
        if rem <= 0.0 {
            break;
        }
    }
    Vel {
        v: acc,
        share: 1.0 - rem,
    }
}

fn scalar_levels(lv: &[Arc<Field>], ch: Channel, pos: [f32; 3], ground_h: f32) -> (f64, f64) {
    let mut acc = 0.0;
    let mut rem = 1.0;
    for f in lv {
        let w = f.edge_weight(pos);
        if w <= 0.0 {
            continue;
        }
        acc += f.sample_scalar(ch, pos, ground_h) * rem * w;
        rem *= 1.0 - w;
        if rem <= 0.0 {
            break;
        }
    }
    (acc, 1.0 - rem)
}

fn turb_levels(lv: &[Arc<Field>], pos: [f32; 3], ground_h: f32) -> [f32; T_SIZE + 1] {
    let mut acc = [0f32; T_SIZE + 1];
    let mut rem = 1.0f64;
    for f in lv {
        let w = f.edge_weight(pos);
        if w <= 0.0 {
            continue;
        }
        let t = f.turb_at(pos, ground_h);
        let k = rem * w;
        for q in 0..T_SIZE {
            acc[q] += (t[q] as f64 * k) as f32;
        }
        rem *= 1.0 - w;
        if rem <= 0.0 {
            break;
        }
    }
    let share = 1.0 - rem;
    if share > 0.0 {
        for a in acc.iter_mut().take(T_SIZE) {
            *a = (*a as f64 / share) as f32;
        }
    }
    acc[T_SIZE] = share as f32;
    acc
}
