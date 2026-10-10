//! `osmtiles finalize` (O4, O5): склейка итоговых тайлов из фрагментов регионов.

use crate::codec::{decode_tile, encode_tile};
use crate::pack::frag_path;
use crate::runinfo::{peak_rss_mb, run_queue, Stages};
use crate::tilebuild::{build_tile, tile_items, Item};
use crate::Result;
use rayon::prelude::*;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct FinalizeOpts {
    pub frag_dir: PathBuf,
    pub out: PathBuf,
    pub list: PathBuf,
    pub report: Option<PathBuf>,
}

pub fn tile_path(root: &Path, j: i32, i: u32) -> PathBuf {
    root.join("v1").join(j.to_string()).join(format!("{i}.dpt"))
}

/// Часть нарезки O8 v2 `<id>__p<n>` → `<id>` (для `sources` итогового тайла, O4).
pub fn base_region(reg: &str) -> &str {
    match reg.rfind("__p") {
        Some(k) if k > 0 && reg.len() > k + 3 && reg[k + 3..].bytes().all(|c| c.is_ascii_digit()) => &reg[..k],
        _ => reg,
    }
}

/// Склейка одного тайла из фрагментов (байты файлов по регионам, по алфавиту). `None` — пусто.
pub fn merge_tile(j: i32, i: u32, frags: &[(String, Vec<u8>)]) -> Result<Option<(Vec<u8>, usize)>> {
    let mut regs: Vec<&(String, Vec<u8>)> = frags.iter().collect();
    regs.sort_by(|a, b| a.0.cmp(&b.0));
    // (поток, ключ) → (регион-номер, части)
    let mut groups: BTreeMap<(i32, i64), (usize, usize, Vec<Item>)> = BTreeMap::new();
    let mut sources = Vec::new();
    let mut ts = 0i64;
    for (ri, (reg, data)) in regs.iter().enumerate() {
        let t = decode_tile(data).map_err(|e| format!("фрагмент {j} {i} {reg}: {e}"))?;
        if !t.fragment {
            return Err(format!("{j} {i} {reg}: не фрагмент"));
        }
        if (t.j, t.i) != (j, i) {
            return Err(format!("{j} {i} {reg}: в файле тайл {} {}", t.j, t.i));
        }
        ts = ts.max(t.osm_timestamp);
        sources.push(base_region(reg).to_string());
        let mut local: BTreeMap<(i32, i64), Vec<Item>> = BTreeMap::new();
        for it in tile_items(&t) {
            local.entry((it.kind as i32, it.key)).or_default().push(it);
        }
        for (k, v) in local {
            let np: usize = v.iter().map(|x| x.data.n_points()).sum();
            match groups.get(&k) {
                Some((_, best, _)) if *best >= np => {} // равенство — остаётся регион раньше по алфавиту
                _ => {
                    groups.insert(k, (ri, np, v));
                }
            }
        }
    }
    sources.sort();
    sources.dedup();
    let items: Vec<Item> = groups.into_values().flat_map(|g| g.2).collect();
    if items.is_empty() {
        return Ok(None);
    }
    let n = items.len();
    let tile = build_tile(j, i, items, false, ts, sources);
    Ok(Some((encode_tile(&tile, None)?, n)))
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, data).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn finalize(o: &FinalizeOpts) -> Result<()> {
    let mut st = Stages::new();
    let text = std::fs::read_to_string(&o.list).map_err(|e| format!("{}: {e}", o.list.display()))?;
    let mut jobs: Vec<(i32, u32, Vec<String>)> = Vec::new();
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        let mut it = l.split_whitespace();
        let j: i32 = it.next().and_then(|x| x.parse().ok()).ok_or_else(|| format!("--list: «{l}»"))?;
        let i: u32 = it.next().and_then(|x| x.parse().ok()).ok_or_else(|| format!("--list: «{l}»"))?;
        let regs: Vec<String> = it.map(str::to_string).collect();
        jobs.push((j, i, regs));
    }
    st.start("finalize");
    // тяжёлые тайлы — первыми (балансировка)
    let mut sized: Vec<(u64, usize)> = jobs
        .par_iter()
        .enumerate()
        .map(|(k, (j, i, regs))| {
            let s: u64 = regs.iter().filter_map(|r| std::fs::metadata(frag_path(&o.frag_dir, *j, *i, r)).ok()).map(|m| m.len()).sum();
            (s, k)
        })
        .collect();
    sized.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let mut rows: Vec<(usize, serde_json::Value, u64)> = run_queue(&sized, |&(_, k)| -> Result<(usize, serde_json::Value, u64)> {
            let (j, i, regs) = &jobs[k];
            let mut frags = Vec::new();
            for r in regs {
                match std::fs::read(frag_path(&o.frag_dir, *j, *i, r)) {
                    Ok(d) => frags.push((r.clone(), d)),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(format!("фрагмент {j} {i} {r}: {e}")),
                }
            }
            let p = tile_path(&o.out, *j, *i);
            match merge_tile(*j, *i, &frags)? {
                Some((data, n)) => {
                    std::fs::create_dir_all(p.parent().unwrap()).map_err(|e| e.to_string())?;
                    write_atomic(&p, &data)?;
                    let sha = hex(&Sha256::digest(&data));
                    Ok((k, json!({"j": j, "i": i, "bytes": data.len(), "sha256": sha, "objects": n}), data.len() as u64))
                }
                None => {
                    let _ = std::fs::remove_file(&p);
                    Ok((k, json!({"j": j, "i": i, "bytes": 0, "sha256": "", "objects": 0}), 0))
                }
            }
        })
        .into_iter()
        .collect::<Result<_>>()?;
    rows.sort_by_key(|r| r.0);
    st.finish();
    let total: u64 = rows.iter().map(|r| r.2).sum();
    let nonempty = rows.iter().filter(|r| r.2 > 0).count();
    if let Some(rp) = &o.report {
        let mut f = std::io::BufWriter::new(std::fs::File::create(rp).map_err(|e| format!("{}: {e}", rp.display()))?);
        for r in &rows {
            writeln!(f, "{}", r.1).map_err(|e| e.to_string())?;
        }
        f.flush().map_err(|e| e.to_string())?;
    }
    let (_, cores) = st.json();
    eprintln!(
        "osmtiles: finalize: тайлов {} (непустых {nonempty}), {total} Б, {:.1} с, ядер {}, пик RSS {:.0} МБ",
        rows.len(),
        st.total_s(),
        cores["finalize"],
        peak_rss_mb()
    );
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
