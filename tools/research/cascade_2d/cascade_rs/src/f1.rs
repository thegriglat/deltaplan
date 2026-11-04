//! F1 (field) reading/writing, balance statistics, reference speed (docs/contracts/cascade-2d.md).

use crate::geo::Geo;
use crate::level::Level;
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::path::Path;

pub const X_MIN: f64 = -6400.0;

pub struct ParentMeta {
    pub case: String,
    pub dx: usize,
}

fn arr<'a>(m: &Value, bin: &'a [f32], name: &str) -> Result<&'a [f32]> {
    let a = m["arrays"][name]
        .as_array()
        .with_context(|| format!("F1: no array {name}"))?;
    let (off, len) = (
        a[0].as_u64().unwrap_or(0) as usize,
        a[1].as_u64().unwrap_or(0) as usize,
    );
    if off + len > bin.len() {
        bail!("F1: array {name} beyond .bin");
    }
    Ok(&bin[off..off + len])
}

/// Reads a F1 pair: fields and the geometry stored with it.
pub fn read_f1(path: &Path) -> Result<(ParentMeta, Level, Geo)> {
    let m: Value = serde_json::from_str(
        &std::fs::read_to_string(path).with_context(|| format!("read {path:?}"))?,
    )?;
    if m["format"] != "cascade2d-field" || m["version"] != 1 {
        bail!("{path:?}: not a cascade2d-field v1");
    }
    let bytes = std::fs::read(path.with_extension("bin"))
        .with_context(|| format!("read .bin of {path:?}"))?;
    let bin: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    let (nx, nz) = (
        m["nx"].as_u64().unwrap_or(0) as usize,
        m["nz"].as_u64().unwrap_or(0) as usize,
    );
    let (dx, dz) = (
        m["dx"].as_f64().unwrap_or(0.0),
        m["dz"].as_f64().unwrap_or(0.0),
    );
    let ty =
        |n: &str| -> Result<Vec<u8>> { Ok(arr(&m, &bin, n)?.iter().map(|&v| v as u8).collect()) };
    let lvl = Level {
        nx,
        nz,
        u: arr(&m, &bin, "u")?.to_vec(),
        w: arr(&m, &bin, "w")?.to_vec(),
        th: arr(&m, &bin, "th")?.to_vec(),
    };
    let geo = Geo {
        nx,
        nz,
        dx,
        dz,
        z0: m["z0"].as_f64().unwrap_or(-dz),
        cell: ty("cell")?,
        tu: ty("tu")?,
        tw: ty("tw")?,
        h: arr(&m, &bin, "h")?.to_vec(),
        q: vec![0.0; nz * nx],
    };
    if lvl.u.len() != nz * (nx + 1)
        || lvl.w.len() != (nz + 1) * nx
        || lvl.th.len() != nz * nx
        || geo.h.len() != nx
    {
        bail!("{path:?}: array lengths do not match nx, nz");
    }
    let meta = ParentMeta {
        case: m["case"].as_str().unwrap_or("").to_string(),
        dx: dx as usize,
    };
    Ok((meta, lvl, geo))
}

pub struct WriteMeta<'a> {
    pub case: &'a str,
    pub source: &'a str,
    pub variant: Option<&'a str>,
    pub parent_dx: Option<usize>,
    pub seed: Option<u64>,
    pub git: Option<String>,
}

/// Writes F1 (`.bin` first, `.json` last, both through temporary files).
pub fn write_f1(path: &Path, wm: &WriteMeta, lvl: &Level, geo: &Geo) -> Result<()> {
    let (nx, nz) = (lvl.nx, lvl.nz);
    let f32s = |v: &[u8]| -> Vec<f32> { v.iter().map(|&x| x as f32).collect() };
    let parts: Vec<(&str, Vec<f32>)> = vec![
        ("u", lvl.u.clone()),
        ("w", lvl.w.clone()),
        ("th", lvl.th.clone()),
        ("cell", f32s(&geo.cell)),
        ("tu", f32s(&geo.tu)),
        ("tw", f32s(&geo.tw)),
        ("h", geo.h.clone()),
    ];
    let mut arrays = serde_json::Map::new();
    let mut bytes = Vec::new();
    let mut pos = 0usize;
    for (n, v) in &parts {
        arrays.insert((*n).into(), json!([pos, v.len()]));
        pos += v.len();
        for x in v {
            bytes.extend_from_slice(&x.to_le_bytes());
        }
    }
    let meta = json!({
        "format": "cascade2d-field", "version": 1, "case": wm.case, "source": wm.source,
        "variant": wm.variant, "dx": geo.dx as usize, "dz": geo.dz, "nx": nx, "nz": nz,
        "x0": X_MIN, "z0": geo.z0, "parent_dx": wm.parent_dx, "seed": wm.seed,
        "arrays": arrays, "git": wm.git, "created": crate::util::iso_now(),
    });
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let bp = path.with_extension("bin");
    let (tb, tj) = (
        path.with_extension("bin.tmp"),
        path.with_extension("json.tmp"),
    );
    std::fs::write(&tb, bytes)?;
    std::fs::rename(&tb, &bp)?;
    std::fs::write(&tj, serde_json::to_string_pretty(&meta)?)?;
    std::fs::rename(&tj, path)?;
    Ok(())
}

pub struct Balance {
    pub max_rel: f64,
    pub rms_rel: f64,
}

/// |div| dx / U_ref over air cells (same discretisation as the contract's `div2d`).
pub fn balance(l: &Level, g: &Geo, u_ref: f64) -> Balance {
    let (mut mx, mut s2, mut n) = (0.0f64, 0.0f64, 0usize);
    for k in 0..l.nz {
        for i in 0..l.nx {
            if g.cell[k * l.nx + i] == 0 {
                continue;
            }
            let d = (l.u[k * (l.nx + 1) + i + 1] as f64 - l.u[k * (l.nx + 1) + i] as f64) / g.dx
                + (l.w[(k + 1) * l.nx + i] as f64 - l.w[k * l.nx + i] as f64) / g.dz;
            let r = d.abs() * g.dx / u_ref;
            mx = mx.max(r);
            s2 += r * r;
            n += 1;
        }
    }
    Balance {
        max_rel: mx,
        rms_rel: if n > 0 { (s2 / n as f64).sqrt() } else { 0.0 },
    }
}

/// U_ref of M1 taken from the parent: |u| on the x face at x = -4800 m, 100 m above the ground
/// (linear in z between face centres).
pub fn u_ref(l: &Level, g: &Geo) -> f64 {
    let i = (((-4800.0 - X_MIN) / g.dx).round() as usize).min(g.nx);
    let h = {
        let (a, b) = (i.saturating_sub(1).min(g.nx - 1), i.min(g.nx - 1));
        0.5 * (g.h[a] as f64 + g.h[b] as f64)
    };
    let zt = h + 100.0;
    let zc = |k: usize| g.z0 + (k as f64 + 0.5) * g.dz;
    let mut best = None;
    for k in 0..l.nz.saturating_sub(1) {
        if zc(k) <= zt && zt <= zc(k + 1) {
            let (a, b) = (
                l.u[k * (l.nx + 1) + i].abs() as f64,
                l.u[(k + 1) * (l.nx + 1) + i].abs() as f64,
            );
            let t = (zt - zc(k)) / g.dz;
            best = Some(a + t * (b - a));
            break;
        }
    }
    best.unwrap_or(1.0).max(1e-3)
}
