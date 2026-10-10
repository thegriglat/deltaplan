//! O7: манифест `<корень>/v1/manifest.pb` по файлам на диске.

use crate::pb::{Source, TileEntry, TileManifest};
use crate::Result;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Все файлы `<корень>/v1/<j>/<i>.dpt`: ((j, i), путь), по возрастанию (j, i).
pub fn list_tiles(root: &Path) -> Result<Vec<((i32, u32), PathBuf)>> {
    let v1 = root.join("v1");
    let mut out = Vec::new();
    let rd = std::fs::read_dir(&v1).map_err(|e| format!("{}: {e}", v1.display()))?;
    for jd in rd.flatten() {
        let Ok(j) = jd.file_name().to_string_lossy().parse::<i32>() else { continue };
        if !jd.path().is_dir() {
            continue;
        }
        for f in std::fs::read_dir(jd.path()).map_err(|e| e.to_string())?.flatten() {
            let name = f.file_name().to_string_lossy().to_string();
            let Some(stem) = name.strip_suffix(".dpt") else { continue };
            if let Ok(i) = stem.parse::<u32>() {
                out.push(((j, i), f.path()));
            }
        }
    }
    out.sort();
    Ok(out)
}

pub fn sha256_of(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

pub fn parse_sources(v: &Value) -> Result<Vec<Source>> {
    let arr = v.as_array().ok_or("sources.json: ожидался список")?;
    let mut out: Vec<Source> = arr
        .iter()
        .map(|o| {
            Ok(Source {
                region: o["region"].as_str().ok_or("sources: нет region")?.to_string(),
                url: o["url"].as_str().unwrap_or("").to_string(),
                md5: o["md5"].as_str().unwrap_or("").to_string(),
                osm_timestamp: o["osm_timestamp"].as_i64().unwrap_or(0),
                pbf_bytes: o["pbf_bytes"].as_u64().unwrap_or(0),
            })
        })
        .collect::<Result<_>>()?;
    out.sort_by(|a, b| a.region.cmp(&b.region));
    Ok(out)
}

pub fn build_manifest(root: &Path, sources: Vec<Source>, created_unix: i64) -> Result<TileManifest> {
    use rayon::prelude::*;
    let files = list_tiles(root)?;
    let tiles: Vec<TileEntry> = files
        .par_iter()
        .map(|((j, i), p)| {
            let data = std::fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
            Ok(TileEntry { j: *j, i: *i, bytes: data.len() as u32, sha256: sha256_of(&data) })
        })
        .collect::<Result<_>>()?;
    let total_bytes = tiles.iter().map(|t| t.bytes as u64).sum();
    Ok(TileManifest { format_version: 1, created_unix, sources, tiles, total_bytes })
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn manifest_json(m: &TileManifest) -> Value {
    serde_json::json!({
        "format_version": m.format_version, "created_unix": m.created_unix, "total_bytes": m.total_bytes,
        "sources": m.sources.iter().map(|s| serde_json::json!({"region": s.region, "url": s.url, "md5": s.md5,
            "osm_timestamp": s.osm_timestamp, "pbf_bytes": s.pbf_bytes})).collect::<Vec<_>>(),
        "tiles": m.tiles.iter().map(|t| serde_json::json!({"j": t.j, "i": t.i, "bytes": t.bytes,
            "sha256": hex(&t.sha256)})).collect::<Vec<_>>(),
    })
}
