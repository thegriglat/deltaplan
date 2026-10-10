//! O6: сводка `stats` (детерминированный JSON — ключи по алфавиту).

use crate::codec::*;
use crate::manifest::list_tiles;
use crate::pb::{self, Kind};
use crate::Result;
use prost::Message;
use rayon::prelude::*;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;

fn is_linear(k: Kind) -> bool {
    matches!(k, Kind::Roads | Kind::Track | Kind::Powerline | Kind::Aerialway | Kind::Aeroway | Kind::Rail | Kind::River | Kind::Canal)
}

/// Длина линейных объектов потока, м (aeroway — только runway, класс 3).
pub fn stream_len_m(s: &StreamData) -> f64 {
    match &s.objects {
        Objects::Roads(v) => v.iter().map(|r| line_len_m(&r.pts)).sum(),
        Objects::Generic(v) if s.kind == Kind::Aeroway => v.iter().filter(|o| o.cls == 3).map(|o| line_len_m(&o.pts)).sum(),
        Objects::Generic(v) if is_linear(s.kind) => v.iter().map(|o| line_len_m(&o.pts)).sum(),
        _ => 0.0,
    }
}

fn r3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

pub struct TileStat {
    pub j: i32,
    pub i: u32,
    pub file_bytes: u64,
    /// (kind, count, raw, zstd, len_m)
    pub streams: Vec<(Kind, u64, u64, Option<u64>, f64)>,
}

pub fn tile_stat(path: &Path, zstd_per_stream: bool) -> Result<TileStat> {
    let file = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let (h, raw) = open_container(&file).map_err(|e| format!("{}: {e}", path.display()))?;
    let p = pb::OsmTile::decode(raw.as_slice()).map_err(|e| e.to_string())?;
    let t = tile_from_pb(&p, h.flags & 1 != 0)?;
    let mut streams = Vec::new();
    for s in &p.streams {
        let Ok(kind) = Kind::try_from(s.kind) else { continue };
        let Some(sd) = t.stream(kind) else { continue };
        let z = if zstd_per_stream {
            Some(zstd::bulk::compress(&s.data, 19).map_err(|e| e.to_string())?.len() as u64)
        } else {
            None
        };
        let len = if is_linear(kind) { stream_len_m(sd) } else { 0.0 };
        streams.push((kind, s.count as u64, s.data.len() as u64, z, len));
    }
    Ok(TileStat { j: t.j, i: t.i, file_bytes: file.len() as u64, streams })
}

pub fn stats_json(root: &Path, zstd_per_stream: bool, only: Option<BTreeSet<(i32, u32)>>, threads: Option<usize>) -> Result<Value> {
    let files: Vec<_> = list_tiles(root)?.into_iter().filter(|(k, _)| only.as_ref().map_or(true, |o| o.contains(k))).collect();
    let run = || -> Result<Vec<TileStat>> { files.par_iter().map(|(_, p)| tile_stat(p, zstd_per_stream)).collect() };
    let stats = match threads {
        Some(n) => rayon::ThreadPoolBuilder::new().num_threads(n).build().map_err(|e| e.to_string())?.install(run)?,
        None => run()?,
    };
    let mut tiles = Map::new();
    let mut totals: std::collections::BTreeMap<&'static str, (u64, u64, u64, f64)> = Default::default();
    let mut file_total = 0u64;
    for ts in &stats {
        file_total += ts.file_bytes;
        let mut sm = Map::new();
        for &(kind, count, raw, z, len) in &ts.streams {
            let mut e = Map::new();
            e.insert("count".into(), json!(count));
            e.insert("raw".into(), json!(raw));
            if let Some(z) = z {
                e.insert("zstd".into(), json!(z));
            }
            if is_linear(kind) {
                e.insert("len_km".into(), json!(r3(len / 1000.0)));
            }
            sm.insert(kind_name(kind).into(), Value::Object(e));
            let t = totals.entry(kind_name(kind)).or_default();
            t.0 += count;
            t.1 += raw;
            t.2 += z.unwrap_or(0);
            t.3 += len;
        }
        tiles.insert(format!("{},{}", ts.j, ts.i), json!({"file_bytes": ts.file_bytes, "streams": Value::Object(sm)}));
    }
    let mut tm = Map::new();
    for (name, (c, r, z, l)) in totals {
        let kind = ALL_KINDS.iter().find(|k| kind_name(**k) == name).unwrap();
        let mut e = Map::new();
        e.insert("count".into(), json!(c));
        e.insert("raw".into(), json!(r));
        if zstd_per_stream {
            e.insert("zstd".into(), json!(z));
        }
        if is_linear(*kind) {
            e.insert("len_km".into(), json!(r3(l / 1000.0)));
        }
        tm.insert(name.into(), Value::Object(e));
    }
    Ok(json!({"schema": "osmtiles-stats/1", "n_tiles": stats.len(), "file_bytes_total": file_total,
              "tiles": Value::Object(tiles), "totals": Value::Object(tm)}))
}
