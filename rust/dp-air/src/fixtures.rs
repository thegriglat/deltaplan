//! Читалка фикстур W8 (`docs/contracts/rust-wind/fixtures-tolerances.md`): места, случаи, данные
//! и описания. Только чтение; неверная длина или версия — `Err` с текстом, не паника.
//!
//! Раскладка: `places/<имя>.json` + `.bin`; `cases/<имя>.json` + `.bin` + `.desc.json`.
//! Заголовок места — заголовок W5 плюс `h_offset` и `h_scale` (высота = `h_offset + int16 * h_scale`).
//! `.desc.json` — массив по моментам `times_s` (или объект с ключом `frames`); элемент —
//! `{cores, clouds, crests, cloudbase_msl}`, строки описаний — массивы полей W6 (`null` — NaN),
//! допускается и плоский массив с шагом W6.
use crate::{Cloud, Conditions, Core, Crest, Error, Focus, Place, PlaceHeader, SampleMode};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Версия формата случаев и описаний.
pub const FIXTURE_VERSION: u64 = 1;

fn io_err(path: &Path, e: std::io::Error) -> Error {
    Error::bad_input(format!("fixture '{}': {e}", path.display()))
}

/// `a/b.json` -> `a/b.<ext>` (точки в имени сохраняются).
pub fn sibling(json_path: &Path, ext: &str) -> PathBuf {
    let s = json_path.to_string_lossy();
    let stem = s.strip_suffix(".json").unwrap_or(&s);
    PathBuf::from(format!("{stem}.{ext}"))
}

fn read_text(path: &Path) -> Result<String, Error> {
    std::fs::read_to_string(path).map_err(|e| io_err(path, e))
}

fn read_bytes(path: &Path) -> Result<Vec<u8>, Error> {
    std::fs::read(path).map_err(|e| io_err(path, e))
}

fn f32s(chunk: &[u8]) -> f32 {
    f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
}

// ---------------------------------------------------------------- место

/// Разбор места из текста заголовка и содержимого `.bin`.
pub fn parse_place(header_text: &str, bin: &[u8]) -> Result<Place, Error> {
    let bad = |m: String| Error::bad_input(format!("place fixture: {m}"));
    let header = PlaceHeader::from_json(header_text)?;
    let raw: Value = serde_json::from_str(header_text).map_err(|e| bad(e.to_string()))?;
    let num = |k: &str| {
        raw.get(k)
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite())
            .ok_or_else(|| bad(format!("missing or bad '{k}'")))
    };
    let (h_offset, h_scale) = (num("h_offset")?, num("h_scale")?);
    if h_scale <= 0.0 {
        return Err(bad("h_scale must be > 0".into()));
    }
    let n = header.cells();
    if bin.len() != 5 * n {
        return Err(bad(format!(
            ".bin has {} bytes, grid {}x{} needs {} (heights i16, water, cls, moist u8)",
            bin.len(),
            header.grid.width,
            header.grid.height,
            5 * n
        )));
    }
    let (hb, rest) = bin.split_at(2 * n);
    let (water, rest) = rest.split_at(n);
    let (cls, moist) = rest.split_at(n);
    let heights = hb
        .chunks_exact(2)
        .map(|c| (h_offset + i16::from_le_bytes([c[0], c[1]]) as f64 * h_scale) as f32)
        .collect();
    let moist = moist.iter().map(|&m| m as f32 / 255.0).collect();
    Place::new(header, heights, water.to_vec(), cls.to_vec(), moist)
}

/// Читает `places/<имя>.json` и рядом `.bin`.
pub fn read_place(json_path: &Path) -> Result<Place, Error> {
    let text = read_text(json_path)?;
    let bin = read_bytes(&sibling(json_path, "bin"))?;
    parse_place(&text, &bin)
}

// ---------------------------------------------------------------- случай

/// `cases/<имя>.json`.
#[derive(Clone, Debug)]
pub struct Case {
    pub place: String,
    pub conditions: Conditions,
    pub seed: u64,
    pub static_thermals: Vec<[f32; 4]>,
    pub static_mode: u8,
    pub configs_sha1: BTreeMap<String, String>,
    pub times_s: Vec<f64>,
    pub focuses: Vec<Focus>,
    pub points: Vec<[f32; 3]>,
    pub point_tags: Vec<String>,
    pub terms: Option<Vec<String>>,
    pub generator: String,
}

fn arr<'a>(v: &'a Value, k: &str) -> Result<&'a Vec<Value>, Error> {
    v.get(k)
        .and_then(Value::as_array)
        .ok_or_else(|| Error::bad_input(format!("case: missing or bad array '{k}'")))
}

fn fixed<const N: usize>(v: &Value, what: &str) -> Result<[f32; N], Error> {
    let bad = || Error::bad_input(format!("case: {what} must be an array of {N} numbers"));
    let a = v.as_array().filter(|a| a.len() == N).ok_or_else(bad)?;
    let mut out = [0.0f32; N];
    for (o, x) in out.iter_mut().zip(a) {
        let x = x.as_f64().filter(|x| x.is_finite()).ok_or_else(bad)?;
        *o = x as f32;
    }
    Ok(out)
}

/// Разбор `cases/<имя>.json`.
pub fn parse_case(text: &str) -> Result<Case, Error> {
    let bad = |m: String| Error::bad_input(format!("case: {m}"));
    let v: Value = serde_json::from_str(text).map_err(|e| bad(e.to_string()))?;
    match v.get("version").and_then(Value::as_u64) {
        Some(FIXTURE_VERSION) => {}
        other => {
            return Err(bad(format!(
                "version must be {FIXTURE_VERSION}, got {other:?}"
            )));
        }
    }
    let place = v
        .get("place")
        .and_then(Value::as_str)
        .ok_or_else(|| bad("missing 'place'".into()))?
        .to_string();
    let cond = v
        .get("conditions")
        .ok_or_else(|| bad("missing 'conditions'".into()))?;
    let conditions = Conditions::from_json(&cond.to_string())?;
    let seed = v
        .get("seed")
        .and_then(Value::as_u64)
        .ok_or_else(|| bad("missing or bad 'seed'".into()))?;

    // static_thermals: массив [x,y,z,w] или {list, mode}.
    let st = v
        .get("static_thermals")
        .ok_or_else(|| bad("missing 'static_thermals'".into()))?;
    let (st_list, static_mode) = match st {
        Value::Array(a) => (a, 0u8),
        Value::Object(_) => (
            arr(st, "list")?,
            st.get("mode").and_then(Value::as_u64).unwrap_or(0) as u8,
        ),
        _ => return Err(bad("'static_thermals' must be an array".into())),
    };
    let static_thermals = st_list
        .iter()
        .map(|x| fixed::<4>(x, "static_thermals item"))
        .collect::<Result<Vec<_>, _>>()?;

    let configs_sha1 = match v.get("configs_sha1") {
        Some(Value::Object(m)) => m
            .iter()
            .map(|(k, s)| {
                s.as_str()
                    .map(|s| (k.clone(), s.to_string()))
                    .ok_or_else(|| bad(format!("configs_sha1['{k}'] must be a string")))
            })
            .collect::<Result<_, _>>()?,
        _ => return Err(bad("missing 'configs_sha1'".into())),
    };
    let times_s = arr(&v, "times_s")?
        .iter()
        .map(|t| {
            t.as_f64()
                .filter(|t| t.is_finite() && *t >= 0.0)
                .ok_or_else(|| bad("times_s: number >= 0 expected".into()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if times_s.is_empty() {
        return Err(bad("times_s is empty".into()));
    }
    let focuses = arr(&v, "focuses")?
        .iter()
        .map(|x| {
            fixed::<4>(x, "focus").map(|a| Focus {
                pos: [a[0], a[1], a[2]],
                weight: a[3],
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let points = arr(&v, "points")?
        .iter()
        .map(|x| fixed::<3>(x, "point"))
        .collect::<Result<Vec<_>, _>>()?;
    let point_tags = arr(&v, "point_tags")?
        .iter()
        .map(|t| {
            t.as_str()
                .map(str::to_string)
                .ok_or_else(|| bad("point_tags: string expected".into()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if point_tags.len() != points.len() {
        return Err(bad(format!(
            "point_tags has {} items, points has {}",
            point_tags.len(),
            points.len()
        )));
    }
    let terms = match v.get("terms") {
        None | Some(Value::Null) => None,
        Some(Value::Array(a)) => Some(
            a.iter()
                .map(|t| {
                    t.as_str()
                        .map(str::to_string)
                        .ok_or_else(|| bad("terms: string expected".into()))
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => return Err(bad("'terms' must be an array or null".into())),
    };
    let generator = v
        .get("generator")
        .and_then(Value::as_str)
        .ok_or_else(|| bad("missing 'generator'".into()))?
        .to_string();
    Ok(Case {
        place,
        conditions,
        seed,
        static_thermals,
        static_mode,
        configs_sha1,
        times_s,
        focuses,
        points,
        point_tags,
        terms,
        generator,
    })
}

impl Case {
    /// Число срезов `k` в `.bin`: 0 FULL, 1 MEAN, далее слагаемые.
    pub fn n_k(&self) -> usize {
        2 + self.terms.as_ref().map_or(0, Vec::len)
    }

    /// Путь к месту относительно `cases/<имя>.json`: `../places/<place>.json`.
    pub fn place_path(&self, case_path: &Path) -> PathBuf {
        let root = case_path
            .parent()
            .and_then(Path::parent)
            .unwrap_or_else(|| Path::new("."));
        root.join("places").join(format!("{}.json", self.place))
    }
}

/// Читает `cases/<имя>.json`.
pub fn read_case(path: &Path) -> Result<Case, Error> {
    parse_case(&read_text(path)?)
}

// ---------------------------------------------------------------- данные

/// `cases/<имя>.bin`: `[time][point][k][4]` f32 LE, плоско.
#[derive(Clone, Debug)]
pub struct CaseData {
    pub n_t: usize,
    pub n_p: usize,
    pub n_k: usize,
    pub values: Vec<f32>,
}

impl CaseData {
    /// Срез `k` одного момента: `n_p` четвёрок `(vx, vy, vz, σ)`.
    pub fn slab(&self, t: usize, k: usize) -> impl Iterator<Item = [f32; 4]> + '_ {
        let stride = self.n_k * 4;
        (0..self.n_p).map(move |p| {
            let o = (t * self.n_p + p) * stride + k * 4;
            [
                self.values[o],
                self.values[o + 1],
                self.values[o + 2],
                self.values[o + 3],
            ]
        })
    }
}

/// Разбор `.bin` случая; длина обязана точно сойтись с `times × points × k × 16`.
pub fn parse_case_data(case: &Case, bin: &[u8]) -> Result<CaseData, Error> {
    let (n_t, n_p, n_k) = (case.times_s.len(), case.points.len(), case.n_k());
    let need = n_t * n_p * n_k * 16;
    if bin.len() != need {
        return Err(Error::bad_input(format!(
            "case .bin has {} bytes, {n_t} times x {n_p} points x {n_k} k x 16 needs {need}",
            bin.len()
        )));
    }
    let values: Vec<f32> = bin.chunks_exact(4).map(f32s).collect();
    Ok(CaseData {
        n_t,
        n_p,
        n_k,
        values,
    })
}

pub fn read_case_data(case: &Case, case_path: &Path) -> Result<CaseData, Error> {
    parse_case_data(case, &read_bytes(&sibling(case_path, "bin"))?)
}

// ---------------------------------------------------------------- описания

/// Описания W6 на один момент.
#[derive(Clone, Debug, Default)]
pub struct Frame {
    pub cores: Vec<Core>,
    pub clouds: Vec<Cloud>,
    pub crests: Vec<Crest>,
    pub cloudbase_msl: f32,
}

fn num(v: &Value, what: &str) -> Result<f32, Error> {
    match v {
        Value::Null => Ok(f32::NAN),
        Value::Number(n) => Ok(n.as_f64().unwrap_or(f64::NAN) as f32),
        _ => Err(Error::bad_input(format!("desc: {what}: number expected"))),
    }
}

/// Строки по `stride` полей: массив массивов или плоский массив.
fn rows(v: Option<&Value>, stride: usize, what: &str) -> Result<Vec<Vec<f32>>, Error> {
    let a = match v {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Array(a)) => a,
        Some(_) => return Err(Error::bad_input(format!("desc: '{what}' must be an array"))),
    };
    let nested = a.first().is_some_and(Value::is_array);
    let flat: Vec<f32> = if nested {
        let mut out = Vec::with_capacity(a.len() * stride);
        for r in a {
            let r = r.as_array().filter(|r| r.len() == stride).ok_or_else(|| {
                Error::bad_input(format!("desc: '{what}' row must have {stride} fields"))
            })?;
            for x in r {
                out.push(num(x, what)?);
            }
        }
        out
    } else {
        a.iter().map(|x| num(x, what)).collect::<Result<_, _>>()?
    };
    if !flat.len().is_multiple_of(stride) {
        return Err(Error::bad_input(format!(
            "desc: '{what}' has {} numbers, not a multiple of {stride}",
            flat.len()
        )));
    }
    Ok(flat.chunks_exact(stride).map(<[f32]>::to_vec).collect())
}

fn core_of(r: &[f32]) -> Core {
    Core {
        id: r[0],
        flags: r[1],
        x: r[2],
        z: r[3],
        y_src: r[4],
        top: r[5],
        w: r[6],
        radius: r[7],
        lean_x: r[8],
        lean_z: r[9],
        age_s: r[10],
        life_s: r[11],
        stage: r[12],
        vis_seed: r[13],
        storm: r[14],
    }
}

fn cloud_of(r: &[f32]) -> Cloud {
    Cloud {
        id: r[0],
        core_id: r[1],
        x: r[2],
        z: r[3],
        base_msl: r[4],
        top_msl: r[5],
        radius: r[6],
        growth: r[7],
        decay: r[8],
        flags: r[9],
    }
}

/// Разбор `.desc.json`; число моментов обязано равняться `n_times`.
pub fn parse_desc(text: &str, n_times: usize) -> Result<Vec<Frame>, Error> {
    let v: Value =
        serde_json::from_str(text).map_err(|e| Error::bad_input(format!("desc: {e}")))?;
    let list = match &v {
        Value::Array(a) => a,
        Value::Object(_) => arr(&v, "frames")?,
        _ => return Err(Error::bad_input("desc: array of frames expected")),
    };
    if list.len() != n_times {
        return Err(Error::bad_input(format!(
            "desc has {} frames, case has {n_times} times",
            list.len()
        )));
    }
    list.iter()
        .map(|f| {
            Ok(Frame {
                cores: rows(f.get("cores"), 15, "cores")?
                    .iter()
                    .map(|r| core_of(r))
                    .collect(),
                clouds: rows(f.get("clouds"), 10, "clouds")?
                    .iter()
                    .map(|r| cloud_of(r))
                    .collect(),
                crests: rows(f.get("crests"), 4, "crests")?
                    .iter()
                    .map(|r| Crest {
                        x: r[0],
                        z: r[1],
                        eta: r[2],
                        crest: r[3],
                    })
                    .collect(),
                cloudbase_msl: num(
                    f.get("cloudbase_msl").unwrap_or(&Value::Null),
                    "cloudbase_msl",
                )?,
            })
        })
        .collect()
}

pub fn read_desc(case: &Case, case_path: &Path) -> Result<Vec<Frame>, Error> {
    let p = sibling(case_path, "desc.json");
    parse_desc(&read_text(&p)?, case.times_s.len())
}

/// Режим выборки по номеру среза `k` (0 FULL, 1 MEAN).
pub fn mode_of(k: usize) -> Option<SampleMode> {
    match k {
        0 => Some(SampleMode::Full),
        1 => Some(SampleMode::Mean),
        _ => None,
    }
}
