//! R4 v2: snapshot of the Picard state (`<name>.json` + `<name>.bin`), in memory and on disk.
//!
//! The `.bin` is little-endian `float32` back to back; `arrays` in the JSON maps a name to
//! `[offset, length]` in `float32` units. Arrays use the halo layout `(NZ, NY, NX)` of
//! [`crate::solver::Fields`]. Writing goes through temporary files and renames (the JSON is
//! renamed last, so a readable JSON always has its complete `.bin`).

use crate::case::Consts;
use crate::report::{check_json, git_hash};
use crate::solver::{Check, Fields};
use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;

/// Value of `format` in the JSON.
pub const FORMAT: &str = "picard-rs-state";
/// Value of `version` in the JSON.
pub const VERSION: u64 = 2;
/// Arrays that must be present in a file (`thd` is tolerated as missing on read: zeros).
const REQUIRED: [&str; 5] = ["u", "v", "w", "th", "p"];

/// Snapshot of the Picard fields on a grid with halo.
#[derive(Clone, Debug)]
pub struct State {
    /// Case name the snapshot was taken from.
    pub case: String,
    /// Path of the case `.json` it was taken from.
    pub input: String,
    /// Iterations done (0 = initial field).
    pub it: usize,
    /// Dimensions with halo `(nxh, nyh, nzh)`.
    pub dims: [usize; 3],
    /// Halo width (always 1).
    pub halo: usize,
    /// Dimensions without halo `(nx, ny, nz)`.
    pub n: [usize; 3],
    pub u: Vec<f32>,
    pub v: Vec<f32>,
    pub w: Vec<f32>,
    pub th: Vec<f32>,
    pub thd: Vec<f32>,
    pub p: Vec<f32>,
    /// Eddy viscosities: written for analysis, never read at a start.
    pub nu: Option<Vec<f32>>,
    pub nuh: Option<Vec<f32>>,
    /// History record (as in R2) of the iteration `it`, if it was a residual check.
    pub residuals: Option<Value>,
}

impl State {
    /// Snapshot of `f` after `it` iterations on the grid of `k`.
    pub fn capture(
        k: &Consts,
        case: &str,
        input: &str,
        it: usize,
        f: &Fields,
        res: Option<&Check>,
    ) -> Self {
        Self {
            case: case.to_string(),
            input: input.to_string(),
            it,
            dims: [k.nxh, k.nyh, k.nzh],
            halo: 1,
            n: [k.nx, k.ny, k.nz],
            u: f.u.clone(),
            v: f.v.clone(),
            w: f.w.clone(),
            th: f.th.clone(),
            thd: f.thd.clone(),
            p: f.p.clone(),
            nu: Some(f.nu.clone()),
            nuh: Some(f.nuh.clone()),
            residuals: res.map(check_json),
        }
    }

    /// Number of cells with halo.
    pub fn n3(&self) -> usize {
        self.dims.iter().product()
    }

    /// Error unless the snapshot grid is the grid of `k` (no fitting) and all arrays have its size.
    pub fn check_dims(&self, k: &Consts) -> Result<()> {
        let want = ([k.nxh, k.nyh, k.nzh], [k.nx, k.ny, k.nz]);
        if self.dims != want.0 || self.n != want.1 || self.halo != 1 {
            bail!(
                "state grid dims {:?} n {:?} halo {} != case dims {:?} n {:?} halo 1",
                self.dims,
                self.n,
                self.halo,
                want.0,
                want.1
            );
        }
        let n3 = self.n3();
        for (name, a) in self.arrays() {
            if a.len() != n3 {
                bail!("state array {name}: length {} != {n3}", a.len());
            }
        }
        Ok(())
    }

    /// All present arrays in file order.
    fn arrays(&self) -> Vec<(&'static str, &[f32])> {
        let mut a: Vec<(&'static str, &[f32])> = vec![
            ("u", &self.u),
            ("v", &self.v),
            ("w", &self.w),
            ("th", &self.th),
            ("thd", &self.thd),
            ("p", &self.p),
        ];
        if let Some(x) = &self.nu {
            a.push(("nu", x));
        }
        if let Some(x) = &self.nuh {
            a.push(("nuh", x));
        }
        a
    }

    /// Writes `<path>` (`.json`) and `<path with .bin>` through temporary files and renames.
    pub fn write_atomic(&self, path: &Path) -> Result<()> {
        if let Some(d) = path.parent() {
            std::fs::create_dir_all(d)?;
        }
        let bin = path.with_extension("bin");
        let bin_tmp = path.with_extension("bin.tmp");
        let json_tmp = path.with_extension("json.tmp");
        let mut arrays = serde_json::Map::new();
        {
            let mut w = std::io::BufWriter::new(
                std::fs::File::create(&bin_tmp).with_context(|| format!("create {bin_tmp:?}"))?,
            );
            let mut off = 0usize;
            for (name, a) in self.arrays() {
                for x in a {
                    w.write_all(&x.to_le_bytes())?;
                }
                arrays.insert(name.to_string(), json!([off, a.len()]));
                off += a.len();
            }
            w.flush()?;
        }
        let doc = json!({
            "format": FORMAT,
            "version": VERSION,
            "case": self.case,
            "input": self.input,
            "it": self.it,
            "dims": self.dims,
            "halo": self.halo,
            "nx": self.n[0],
            "ny": self.n[1],
            "nz": self.n[2],
            "dtype": "f32",
            "residuals": self.residuals,
            "host": {"git": git_hash()},
            "arrays": arrays,
        });
        std::fs::write(&json_tmp, serde_json::to_string_pretty(&doc)?)?;
        std::fs::rename(&bin_tmp, &bin)?;
        std::fs::rename(&json_tmp, path)?;
        Ok(())
    }

    /// Reads a snapshot `<path>` (`.json`) with its `.bin`. A missing `thd` becomes zeros; a
    /// missing `u, v, w, th, p`, a wrong `format`/`version`/`dtype` or inconsistent sizes is an error.
    pub fn read(path: &Path) -> Result<Self> {
        let txt = std::fs::read_to_string(path).with_context(|| format!("read {path:?}"))?;
        let d: Value = serde_json::from_str(&txt).with_context(|| format!("parse {path:?}"))?;
        if d["format"] != FORMAT || d["version"] != VERSION || d["dtype"] != "f32" {
            bail!(
                "{path:?}: not a {FORMAT} v{VERSION} f32 file (format {}, version {}, dtype {})",
                d["format"],
                d["version"],
                d["dtype"]
            );
        }
        let uint = |v: &Value, what: &str| -> Result<usize> {
            v.as_u64()
                .map(|x| x as usize)
                .ok_or_else(|| anyhow!("{path:?}: {what} must be a non-negative integer"))
        };
        let dims_v = d["dims"]
            .as_array()
            .filter(|a| a.len() == 3)
            .ok_or_else(|| anyhow!("{path:?}: dims must have 3 entries"))?;
        let dims = [
            uint(&dims_v[0], "dims[0]")?,
            uint(&dims_v[1], "dims[1]")?,
            uint(&dims_v[2], "dims[2]")?,
        ];
        let n3: usize = dims.iter().product();
        let bin = std::fs::read(path.with_extension("bin"))
            .with_context(|| format!("read .bin of {path:?}"))?;
        let nf = bin.len() / 4;
        let table = d["arrays"]
            .as_object()
            .ok_or_else(|| anyhow!("{path:?}: no arrays"))?;
        let get = |name: &str| -> Result<Option<Vec<f32>>> {
            let Some(e) = table.get(name) else {
                return Ok(None);
            };
            let off = uint(&e[0], "array offset")?;
            let len = uint(&e[1], "array length")?;
            if len != n3 || off + len > nf {
                bail!("{path:?}: array {name} [{off}, {len}] (cells {n3}, .bin {nf} f32)");
            }
            Ok(Some(
                bin[off * 4..(off + len) * 4]
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect(),
            ))
        };
        for r in REQUIRED {
            if !table.contains_key(r) {
                bail!("{path:?}: required array {r} is missing");
            }
        }
        let req = |name: &str| get(name).map(|o| o.expect("presence checked above"));
        Ok(Self {
            case: d["case"].as_str().unwrap_or_default().to_string(),
            input: d["input"].as_str().unwrap_or_default().to_string(),
            it: uint(&d["it"], "it")?,
            dims,
            halo: uint(&d["halo"], "halo")?,
            n: [
                uint(&d["nx"], "nx")?,
                uint(&d["ny"], "ny")?,
                uint(&d["nz"], "nz")?,
            ],
            u: req("u")?,
            v: req("v")?,
            w: req("w")?,
            th: req("th")?,
            thd: get("thd")?.unwrap_or_else(|| vec![0.0; n3]),
            p: req("p")?,
            nu: get("nu")?,
            nuh: get("nuh")?,
            residuals: d.get("residuals").filter(|v| !v.is_null()).cloned(),
        })
    }
}
