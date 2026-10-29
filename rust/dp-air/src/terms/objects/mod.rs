//! Объекты-облака W6 v4 (RW-11f): запись для рисования облаков Godot (`cloud_layer.gd`) по
//! термикам набора и грозе - шаг 22 описаний.
//!
//! Что рисовать - у крейта (`CloudModel.stage/size/center/_life_window`, `StormField.storm_start/
//! intensity`), как и сколько (выбор, слияние, затухание) - у Godot. Ответ - чистая функция
//! набора термиков слота (`state.all`: живые на момент обновления, статичные, доживающие с
//! облаком) и момента `t`: те же формулы с подставленным `t`, поэтому окно истории `CloudLayer`
//! (`t ∈ [now − fade_out_s, now]`) считается одним вызовом на момент. Термик, которого набор уже
//! забыл, на прошлом `t` не виден - как в GDScript (`merge_winners` читает текущий набор).
//! Зажим `t` в окно (`t` вне окна - как ближайшая граница, у `Live` - только `now`) знает «сейчас»
//! и делает фасад (RW-12z): здесь `t` берётся как есть.
//!
//! Границы модели: `id & 0xFFFFFF` в f32 точен до 2^24, уникальность гарантируется по всему
//! набору (при совпадении младших 24 бит - следующий свободный по порядку исходных `id`), но
//! `Core.id` ядер W6 при этом не меняется; охват по радиусу - по центру облака, не по источнику.
use super::Terms;
use super::storm::{self, CloudCfg, CloudModel, StormCfg};
use super::thermal::AtmoThermal;
pub use crate::{OBJ_STRIDE, ObjRecord};
use std::collections::HashSet;

/// Бит 0 `flags`: статичный термик.
pub const FLAG_STATIC: u32 = 1;
/// Бит 2 `flags`: Cb.
pub const FLAG_CB: u32 = 4;
/// Для статичных: начало и конец жизни облака (`∓1e30`), начало сноса (`+1e30`).
pub const FOREVER: f32 = 1.0e30;

/// Уникальные ключи `id & 0xFFFFFF` термиков набора в порядке возрастания исходных `id`:
/// при совпадении - следующий свободный. Не зависит от `t` и охвата.
fn unique_ids(all: &[std::sync::Arc<AtmoThermal>]) -> Vec<(i64, u32)> {
    let mut v: Vec<&AtmoThermal> = all.iter().map(|a| &**a).collect();
    v.sort_by_key(|th| th.id);
    let mut used: HashSet<u32> = HashSet::with_capacity(v.len());
    v.iter()
        .map(|th| {
            let mut k = (th.id & 0xFF_FFFF) as u32;
            while !used.insert(k) {
                k = (k + 1) & 0xFF_FFFF;
            }
            (th.id, k)
        })
        .collect()
}

/// Запись облака над термиком `th` на `t` (стадия `st` уже посчитана).
fn record(
    th: &AtmoThermal,
    key: u32,
    t: f64,
    cm: &CloudModel,
    storm: &storm::StormField,
) -> Option<ObjRecord> {
    let st = cm.stage(th, t);
    if st[0] < 0.0 {
        return None;
    }
    let ce = cm.center(th, t);
    let sz = cm.size(th, st);
    let w = cm.life_window(th);
    let mut flags = 0u32;
    if th.is_static {
        flags |= FLAG_STATIC;
    }
    if th.is_cb {
        flags |= FLAG_CB;
    }
    let (life0, life1, drift_t0, dv) = if th.is_static {
        (-FOREVER, FOREVER, FOREVER, [0.0, 0.0])
    } else {
        (
            w[0] as f32,
            w[2] as f32,
            th.drift_start() as f32,
            th.drift_vel,
        )
    };
    let (s0, sk) = if th.is_cb {
        (storm.storm_start(th) as f32, storm.intensity(th, t) as f32)
    } else {
        (0.0, 0.0)
    };
    Some(ObjRecord {
        id: key as f32,
        flags: flags as f32,
        cx: ce[0],
        cz: ce[1],
        base_msl: th.top as f32,
        growth: st[0] as f32,
        decay: st[1] as f32,
        activity: st[2] as f32,
        rx: sz[0] as f32,
        rz: sz[1] as f32,
        depth: sz[2] as f32,
        spread: sz[3] as f32,
        vis_seed: (th.noise_seed % 9973) as f32,
        life_t0: life0,
        life_t1: life1,
        src_x: th.src[0],
        src_z: th.src[2],
        drift_vx: dv[0],
        drift_vz: dv[1],
        drift_t0,
        storm_t0: s0,
        storm_k: sk,
    })
}

/// Объекты-облака на момент `t` (`out` очищается): все термики набора с облаком, существующим на
/// `t` (`stage.x ≥ 0`), с центром облака в круге `radius` от `center` по горизонтали
/// (`radius < 0` - без ограничения), по возрастанию исходного `id`. Нет набора термиков - пусто.
pub fn cloud_objects_into(
    terms: &Terms,
    center: [f32; 3],
    radius: f32,
    t: f64,
    out: &mut Vec<ObjRecord>,
) {
    out.clear();
    let Some(state) = terms.slots.thermal.as_slot().and_then(|s| s.state()) else {
        return;
    };
    let cm = CloudModel::new(
        CloudCfg::from_configs(&terms.configs),
        terms.weather.f64_or("cloud_size_factor", 1.0),
    );
    let sf = storm::field_of(terms, StormCfg::from_configs(&terms.configs));
    let keys = unique_ids(&state.all);
    let mut by_id: Vec<&AtmoThermal> = state.all.iter().map(|a| &**a).collect();
    by_id.sort_by_key(|th| th.id);
    for (th, &(id, key)) in by_id.into_iter().zip(&keys) {
        debug_assert_eq!(th.id, id);
        if !th.has_cloud {
            continue;
        }
        let Some(r) = record(th, key, t, &cm, &sf) else {
            continue;
        };
        if radius >= 0.0
            && f64::from(center[0] - r.cx).hypot(f64::from(center[2] - r.cz)) > f64::from(radius)
        {
            continue;
        }
        out.push(r);
    }
}

/// [`cloud_objects_into`] с новым вектором.
pub fn cloud_objects(terms: &Terms, center: [f32; 3], radius: f32, t: f64) -> Vec<ObjRecord> {
    let mut v = Vec::new();
    cloud_objects_into(terms, center, radius, t, &mut v);
    v
}
