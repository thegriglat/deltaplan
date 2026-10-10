//! Объекты одного тайла → `Tile` (O3: порядок объектов, NAMES; O4: `ids` фрагмента).
//! Общая часть `pack` (фрагмент) и `finalize` (итог).

use crate::codec::{morton, Building, Obj, Objects, Road, StreamData, Tile};
use crate::grid::Band;
use crate::pb::Kind;

/// Тип объекта OSM в ключе O4.
pub const T_NODE: i64 = 0;
pub const T_WAY: i64 = 1;
pub const T_REL: i64 = 2;

#[derive(Clone, Debug, PartialEq)]
pub enum Data {
    Road(Road),
    Bld(Building),
    Gen(Obj),
}

impl Data {
    pub fn n_points(&self) -> usize {
        match self {
            Data::Road(r) => r.pts.len(),
            Data::Bld(_) => 1,
            Data::Gen(o) => o.pts.len(),
        }
    }
}

/// Объект (часть) в тайле.
#[derive(Clone, Debug)]
pub struct Item {
    pub kind: Kind,
    /// `id·4 + тип` (O4).
    pub key: i64,
    /// Номер части объекта в тайле (клип, мультиполигон).
    pub part: u32,
    pub data: Data,
    /// Имя вершины/перевала (флаг 0 в PEAK/PASS).
    pub name: Option<String>,
}

impl Default for Item {
    fn default() -> Self {
        Item { kind: Kind::Unspecified, key: 0, part: 0, data: Data::Gen(Obj::default()), name: None }
    }
}

/// Порядок O3: линии и точки — (тип, id, часть); дома — (Мортон, id, тип, часть).
pub fn order_key(it: &Item) -> (u32, i64, i64, u32) {
    let (id, typ) = (it.key >> 2, it.key & 3);
    match &it.data {
        Data::Bld(b) => (morton(b.x, b.y), id, typ, it.part),
        _ => (0, typ, id, it.part),
    }
}

/// Сборка тайла: объекты любого порядка; сортировка O3 внутри потоков.
pub fn build_tile(j: i32, i: u32, mut items: Vec<Item>, fragment: bool, osm_timestamp: i64, sources: Vec<String>) -> Tile {
    if items.len() > 20_000 {
        use rayon::slice::ParallelSliceMut;
        items.par_sort_by_cached_key(|a| (a.kind as i32, order_key(a)));
    } else {
        items.sort_by_cached_key(|a| (a.kind as i32, order_key(a)));
    }
    let mut streams: Vec<StreamData> = Vec::new();
    let mut names: Vec<String> = Vec::new();
    let mut name_ids: Vec<i64> = Vec::new();
    let mut pass_names: Vec<(String, i64)> = Vec::new();
    for it in items {
        if streams.last().map_or(true, |s| s.kind != it.kind) {
            streams.push(StreamData { kind: it.kind, objects: Objects::empty_for(it.kind), ids: vec![] });
        }
        let s = streams.last_mut().unwrap();
        if fragment {
            s.ids.push(it.key);
        }
        if let Data::Gen(o) = &it.data {
            if o.flags & 1 != 0 && matches!(it.kind, Kind::Peak | Kind::Pass) {
                let nm = it.name.clone().unwrap_or_default();
                if it.kind == Kind::Peak {
                    names.push(nm);
                    name_ids.push(it.key);
                } else {
                    pass_names.push((nm, it.key));
                }
            }
        }
        match (&mut s.objects, it.data) {
            (Objects::Roads(v), Data::Road(r)) => v.push(r),
            (Objects::Buildings(v), Data::Bld(b)) => v.push(b),
            (Objects::Generic(v), Data::Gen(o)) => v.push(o),
            _ => unreachable!("тип объекта не подходит потоку"),
        }
    }
    for (n, k) in pass_names {
        names.push(n);
        name_ids.push(k);
    }
    if !names.is_empty() {
        streams.push(StreamData {
            kind: Kind::Names,
            objects: Objects::Names(names),
            ids: if fragment { name_ids } else { vec![] },
        });
    }
    let n = Band::new(j).n;
    Tile { fragment, j, i, n, osm_timestamp, sources, streams }
}

/// Тайл (фрагмент или итог) → объекты с ключами (у итогового ключей нет — 0) и именами.
pub fn tile_items(t: &Tile) -> Vec<Item> {
    use std::collections::HashMap;
    let mut name_of: HashMap<i64, String> = HashMap::new();
    if let Some(s) = t.stream(Kind::Names) {
        if let Objects::Names(v) = &s.objects {
            for (k, n) in s.ids.iter().zip(v) {
                name_of.insert(*k, n.clone());
            }
        }
    }
    let mut out = Vec::new();
    for s in &t.streams {
        if s.kind == Kind::Names {
            continue;
        }
        let key_at = |k: usize| s.ids.get(k).copied().unwrap_or(0);
        let mut parts: HashMap<i64, u32> = HashMap::new();
        let mut push = |k: usize, data: Data, out: &mut Vec<Item>| {
            let key = key_at(k);
            let c = parts.entry(key).or_insert(0);
            let part = *c;
            *c += 1;
            out.push(Item { kind: s.kind, key, part, data, name: None });
        };
        match &s.objects {
            Objects::Roads(v) => v.iter().enumerate().for_each(|(k, r)| push(k, Data::Road(r.clone()), &mut out)),
            Objects::Buildings(v) => v.iter().enumerate().for_each(|(k, b)| push(k, Data::Bld(b.clone()), &mut out)),
            Objects::Generic(v) => v.iter().enumerate().for_each(|(k, o)| push(k, Data::Gen(o.clone()), &mut out)),
            Objects::Names(_) => {}
        }
    }
    for it in out.iter_mut() {
        if let Data::Gen(o) = &it.data {
            if o.flags & 1 != 0 && matches!(it.kind, Kind::Peak | Kind::Pass) {
                it.name = name_of.get(&it.key).cloned();
            }
        }
    }
    out
}
