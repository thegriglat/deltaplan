//! Поле воздуха в файловом формате (RW-6p): разбор, запись, сравнение `key`. Нужен кешу полей
//! (`field_cache`) и выдаче поля `field_export*`.
//!
//! Формат: заголовок json + тело (`zstd` от склейки массивов little-endian; 3D-каналы `f16`, по
//! столбцам `f32`; массив — `[смещение, длина_байт, "f16"|"f32"]`).
//!
//! `parse_solved(header_json, data)` — разбор без проверки `key`: уровни собираются параллельно
//! (`rayon`), каждый канал распаковывается в готовый `Vec<f32>` кусками `par_chunks_mut`, без
//! промежуточных массивов. `f16 → f32` точен. Числа в текстах причин печатаются с 14 значащими
//! знаками, хвостовые нули срезаны (`num_text`).
use super::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use crate::error::Error;
use rayon::prelude::*;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub const FORMAT: &str = "dp-air-field";
/// Прежнее имя формата в файлах уже снятых полей (данные тестов); читается наравне с `FORMAT`.
pub const LEGACY_FORMAT: &str = "dp-air-baked"; // purity: allow имя формата в старых файлах
pub const VERSION: i64 = 1;
/// Допуск сравнения чисел `key` (JSON хранит не все разряды double).
pub const KEY_TOL: f64 = 1.0e-6;
/// Куски распаковки `par_chunks_mut`, элементов.
const CHUNK: usize = 1 << 14;

/// Решённое поле старта: заголовок и уровни (от мелкого к грубому).
#[derive(Clone, Debug)]
pub struct SolvedField {
    pub location: String,
    pub site: String,
    pub model_hash: String,
    /// `key` заголовка как есть.
    pub key: Value,
    pub levels: Vec<Field>,
    /// Имя уровня (`dx50`, …) и json `meta` уровня (без упакованных массивов), по уровням.
    pub names: Vec<String>,
    pub level_meta: Vec<Map<String, Value>>,
}

#[derive(Deserialize)]
struct Hdr {
    format: String,
    version: f64,
    #[serde(default)]
    location: String,
    #[serde(default)]
    site: String,
    #[serde(default)]
    model_hash: String,
    #[serde(default)]
    key: Value,
    levels: Vec<LevelHdr>,
    compression: String,
    raw_bytes: f64,
}

#[derive(Deserialize)]
struct LevelHdr {
    #[serde(default)]
    name: String,
    grid: BTreeMap<String, f64>,
    #[serde(default)]
    meta: Map<String, Value>,
    arrays: BTreeMap<String, (f64, f64, String)>,
}

fn bad(msg: impl Into<String>) -> Error {
    Error::bad_input(format!("field: {}", msg.into()))
}

fn uint(x: f64, what: &str) -> Result<usize, Error> {
    if x.is_finite() && x >= 0.0 && x.fract() == 0.0 && x < 1.0e15 {
        Ok(x as usize)
    } else {
        Err(bad(format!("{what}: не целое неотрицательное число ({x})")))
    }
}

/// Заголовок и тело (`data` — `.bin` целиком, zstd) → поле. Ошибка — BAD_INPUT с причиной.
pub fn parse_solved(header_json: &str, data: &[u8]) -> Result<SolvedField, Error> {
    let h: Hdr = serde_json::from_str(header_json)
        .map_err(|e| bad(format!("заголовок не читается: {e}")))?;
    if (h.format != FORMAT && h.format != LEGACY_FORMAT) || h.version != VERSION as f64 {
        return Err(bad(format!(
            "чужой формат или версия ({}, {})",
            h.format, h.version
        )));
    }
    if h.compression != "zstd" {
        return Err(bad(format!("сжатие {} не поддержано", h.compression)));
    }
    let raw_n = uint(h.raw_bytes, "raw_bytes")?;
    if raw_n == 0 || h.levels.is_empty() {
        return Err(bad("пустое тело или нет уровней"));
    }
    let body =
        zstd::bulk::decompress(data, raw_n).map_err(|e| bad(format!("не распаковалось: {e}")))?;
    if body.len() != raw_n {
        return Err(bad(format!("тело {} байт, ждали {raw_n}", body.len())));
    }
    let built: Vec<(Field, Map<String, Value>)> = h
        .levels
        .par_iter()
        .map(|lv| {
            build_level(lv, &body).map_err(|e| bad(format!("уровень {}: {}", lv.name, e.msg)))
        })
        .collect::<Result<_, _>>()?;
    let (levels, level_meta): (Vec<_>, Vec<_>) = built.into_iter().unzip();
    Ok(SolvedField {
        location: h.location,
        site: h.site,
        model_hash: h.model_hash,
        key: h.key,
        levels,
        names: h.levels.into_iter().map(|l| l.name).collect(),
        level_meta,
    })
}

fn build_level(lv: &LevelHdr, body: &[u8]) -> Result<(Field, Map<String, Value>), Error> {
    let g = |k: &str| {
        lv.grid
            .get(k)
            .copied()
            .ok_or_else(|| bad(format!("в grid нет {k}")))
    };
    let grid = FieldGrid {
        dx: g("dx")?,
        dz: g("dz")?,
        x0: g("x0")?,
        y0: g("y0")?,
        z_bot: g("z_bot")?,
        nx: uint(g("nx")?, "nx")?,
        ny: uint(g("ny")?, "ny")?,
        nz: uint(g("nz")?, "nz")?,
    };
    let nxy = grid.nx * grid.ny;
    let n = nxy * grid.nz;
    let arr = |name: &str, len: usize| -> Result<Vec<f32>, Error> {
        let ent = lv
            .arrays
            .get(name)
            .ok_or_else(|| bad(format!("нет массива {name}")))?;
        read_array(body, ent, len).map_err(|e| bad(format!("{name}: {}", e.msg)))
    };
    let opt = |name: &str, len: usize| -> Result<Vec<f32>, Error> {
        if lv.arrays.contains_key(name) {
            arr(name, len)
        } else {
            Ok(Vec::new())
        }
    };
    let u = arr("u", n)?;
    let v = arr("v", n)?;
    let w_mech = arr("w_mech", n)?;
    let w_conv = arr("w_conv", n)?;
    let theta = arr("theta", n)?;
    let hc = arr("hc", nxy)?;
    let z0 = if lv.arrays.contains_key("meta.z0") {
        Z0::Map(arr("meta.z0", nxy)?.into_iter().map(f64::from).collect())
    } else {
        Z0::Uniform(lv.meta.get("z0").and_then(Value::as_f64).unwrap_or(0.1))
    };
    let gam = if lv.arrays.contains_key("meta.gam") {
        arr("meta.gam", grid.nz)?
    } else {
        Vec::new()
    };
    let meta = FieldMeta {
        z0,
        gam,
        heat: opt("heat", nxy)?,
        z_i: lv
            .meta
            .get("z_i")
            .and_then(Value::as_f64)
            .unwrap_or(f64::NAN),
        z_i_col: opt("meta.z_i_col", nxy)?,
    };
    let f = Field::from_arrays(
        &grid,
        u,
        v,
        w_mech,
        w_conv,
        theta,
        hc,
        meta,
        Limits::default(),
    )?;
    Ok((f, lv.meta.clone()))
}

/// Массив тела `[смещение, длина_байт, dtype]` → `len` чисел `f32`.
fn read_array(body: &[u8], ent: &(f64, f64, String), len: usize) -> Result<Vec<f32>, Error> {
    let off = uint(ent.0, "смещение")?;
    let nb = uint(ent.1, "длина")?;
    let end = off
        .checked_add(nb)
        .filter(|&e| e <= body.len())
        .ok_or_else(|| bad("за пределами тела"))?;
    let seg = &body[off..end];
    let mut out = vec![0f32; len];
    match ent.2.as_str() {
        "f16" => {
            if nb != len * 2 {
                return Err(bad(format!("{nb} байт f16, ждали {}", len * 2)));
            }
            out.par_chunks_mut(CHUNK)
                .zip(seg.par_chunks(CHUNK * 2))
                .for_each(|(o, s)| {
                    for (x, b) in o.iter_mut().zip(s.chunks_exact(2)) {
                        *x = half::f16::from_bits(u16::from_le_bytes([b[0], b[1]])).to_f32();
                    }
                });
        }
        "f32" => {
            if nb != len * 4 {
                return Err(bad(format!("{nb} байт f32, ждали {}", len * 4)));
            }
            out.par_chunks_mut(CHUNK)
                .zip(seg.par_chunks(CHUNK * 4))
                .for_each(|(o, s)| {
                    for (x, b) in o.iter_mut().zip(s.chunks_exact(4)) {
                        *x = f32::from_le_bytes([b[0], b[1], b[2], b[3]]);
                    }
                });
        }
        other => return Err(bad(format!("dtype {other}"))),
    }
    Ok(out)
}

// ---------------------------------------------------------------- запись (кеш полей)

/// Поле → `(header_json, data)` без потерь: каналы `f32`, `zstd` уровня 3. `key` и `extra`
/// (поля верхнего уровня заголовка: `cache`, `status`, …) — в заголовок. Читается `parse_solved`.
pub fn encode_solved(
    b: &SolvedField,
    key: &Value,
    extra: &Map<String, Value>,
) -> Result<(String, Vec<u8>), Error> {
    let mut body: Vec<u8> = Vec::new();
    let mut levels = Vec::with_capacity(b.levels.len());
    for (idx, f) in b.levels.iter().enumerate() {
        let mut arrays = Map::new();
        let mut put = |name: &str, a: &[f32]| {
            arrays.insert(name.to_string(), json!([body.len(), a.len() * 4, "f32"]));
            body.reserve(a.len() * 4);
            for x in a {
                body.extend_from_slice(&x.to_le_bytes());
            }
        };
        put("u", f.raw_u());
        put("v", f.raw_v());
        put("w_mech", f.raw_w_mech());
        put("w_conv", f.raw_w_conv());
        put("theta", f.raw_theta());
        put("hc", f.raw_hc());
        if !f.heat_flux().is_empty() {
            put("heat", f.heat_flux());
        }
        let g = *f.grid();
        // карта z0 столбцов: значение в центре столбца (ближайший столбец)
        let z0: Vec<f32> = (0..g.nx * g.ny)
            .map(|c| {
                let (i, j) = ((c % g.nx) as f64, (c / g.nx) as f64);
                let p = [
                    (g.x0 + (i + 0.5) * g.dx) as f32,
                    0.0,
                    (-(g.y0 + (j + 0.5) * g.dx)) as f32,
                ];
                f.z0_at(p) as f32
            })
            .collect();
        put("meta.z0", &z0);
        if !f.gam().is_empty() {
            put("meta.gam", f.gam());
        }
        if !f.z_i_col().is_empty() {
            put("meta.z_i_col", f.z_i_col());
        }
        let mut meta = b.level_meta.get(idx).cloned().unwrap_or_default();
        meta.remove("z0");
        match f.z_i() {
            z if z.is_finite() => meta.insert("z_i".into(), json!(z)),
            _ => meta.remove("z_i"),
        };
        levels.push(json!({
            "name": b.names.get(idx).cloned().unwrap_or_else(|| format!("dx{}", g.dx.round())),
            "grid": {"dx": g.dx, "dz": g.dz, "x0": g.x0, "y0": g.y0, "z_bot": g.z_bot,
                      "nx": g.nx, "ny": g.ny, "nz": g.nz},
            "meta": meta,
            "arrays": arrays,
        }));
    }
    let packed = zstd::bulk::compress(&body, 3).map_err(|e| bad(format!("zstd: {e}")))?;
    let mut h = Map::new();
    h.insert("format".into(), json!(FORMAT));
    h.insert("version".into(), json!(VERSION));
    h.insert("location".into(), json!(b.location));
    h.insert("site".into(), json!(b.site));
    h.insert("model_hash".into(), json!(b.model_hash));
    h.insert("key".into(), key.clone());
    h.insert("levels".into(), Value::Array(levels));
    h.insert("compression".into(), json!("zstd"));
    h.insert("raw_bytes".into(), json!(body.len()));
    for (k, v) in extra {
        h.insert(k.clone(), v.clone());
    }
    let text = serde_json::to_string(&Value::Object(h)).map_err(|e| bad(e.to_string()))?;
    Ok((text, packed))
}

// ---------------------------------------------------------------- key и условия

/// Число: `14 − ⌊lg|x|⌋` знаков после точки при |x| > 10 (иначе 14), хвостовые
/// нули срезаны, но один после точки остаётся (`20.0`, `-6749.65`).
pub fn num_text(x: f64) -> String {
    if !x.is_finite() {
        return if x.is_nan() {
            "nan".into()
        } else if x > 0.0 {
            "inf".into()
        } else {
            "-inf".into()
        };
    }
    let mut dec = 14i32;
    if x.abs() > 10.0 {
        dec -= x.abs().log10().floor() as i32;
    }
    let dec = dec.clamp(0, 14) as usize;
    let mut s = format!("{x:.dec$}");
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.push('0');
        }
    } else {
        s.push_str(".0");
    }
    s
}

/// Текст числа/значения в причине отказа .
fn show(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n
            .as_f64()
            .map_or_else(|| n.to_string(), |x| format!("{x:?}")),
        Value::Null => "<null>".into(),
        other => other.to_string(),
    }
}

/// Первое расхождение `a` (файл) и `b` (ожидаемое) — `""`, если равны: числа с допуском
/// `KEY_TOL`, словари по ключам `a`, затем `b`; `AirSolvedField.key_diff`.
pub fn key_diff(a: &Value, b: &Value) -> String {
    key_diff_at(a, b, "key")
}

fn key_diff_at(a: &Value, b: &Value, path: &str) -> String {
    match (a, b) {
        (Value::Null, Value::Null) => String::new(),
        (Value::Null, _) | (_, Value::Null) => format!("{path}: нет значения"),
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (
                x.as_f64().unwrap_or(f64::NAN),
                y.as_f64().unwrap_or(f64::NAN),
            );
            if (x - y).abs() <= KEY_TOL {
                String::new()
            } else {
                format!("{path}: {} ≠ {}", num_text(x), num_text(y))
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            for (k, v) in x {
                match y.get(k) {
                    None => return format!("{path}.{k}: нет в ожидаемом"),
                    Some(w) => {
                        let d = key_diff_at(v, w, &format!("{path}.{k}"));
                        if !d.is_empty() {
                            return d;
                        }
                    }
                }
            }
            for k in y.keys() {
                if !x.contains_key(k) {
                    return format!("{path}.{k}: нет в файле");
                }
            }
            String::new()
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return format!("{path}: длина {} ≠ {}", x.len(), y.len());
            }
            for (i, (p, q)) in x.iter().zip(y).enumerate() {
                let d = key_diff_at(p, q, &format!("{path}[{i}]"));
                if !d.is_empty() {
                    return d;
                }
            }
            String::new()
        }
        _ => {
            if std::mem::discriminant(a) == std::mem::discriminant(b) && a == b {
                String::new()
            } else {
                format!("{path}: {} ≠ {}", show(a), show(b))
            }
        }
    }
}
