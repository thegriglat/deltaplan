//! Запечённое поле воздуха TI-К3 v3 (RW-6p): разбор, выбор под условия, запись.
//!
//! Перенос `AirBakedField` (формат, `key_diff`, `conditions_diff`, `make_key`) и
//! `AirRuntime.baked_lookup` (GDScript, `scripts/atmosphere/air_model/`). Формат — `docs/contracts/
//! training-island.md`, TI-К3: заголовок json + тело (`zstd` от склейки массивов little-endian;
//! 3D-каналы `f16`, по столбцам `f32`; массив — `[смещение, длина_байт, "f16"|"f32"]`).
//!
//! `parse_baked(header_json, data)` — как `AirBakedField.load_file` без проверки `key` (она — в
//! `baked_lookup`): уровни собираются параллельно (`rayon`), каждый канал распаковывается в
//! готовый `Vec<f32>` кусками `par_chunks_mut`, без промежуточных массивов. `f16 → f32` точен,
//! поэтому поле бит-в-бит как в игре.
//!
//! `baked_lookup(поля, запрос)` — то же решение и те же причины отказа, что `AirRuntime.baked_lookup`:
//! нет набора погоды у старта → нет файла → модель другой версии → условия не как в наборе погоды →
//! `key` не совпал. Данные места (хеш `data_hash`), хеш модели воздуха (`model_hash`) и условия
//! приходят в запросе: крейт не читает файлы игры.
//!
//! Границы модели: `model_hash` — хеш кода GDScript-модели; пока он есть в заголовках, его считает
//! вызывающий (фасад), крейт лишь сравнивает строки. Числа в текстах причин печатаются как
//! `str(float)` Godot (`gd_num`: 14 значащих знаков, хвостовые нули срезаны).
use super::wind_field::{Field, FieldGrid, FieldMeta, Limits, Z0};
use crate::error::Error;
use rayon::prelude::*;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub const FORMAT: &str = "dp-air-baked";
pub const VERSION: i64 = 1;
/// Шаг области решателя, м (`AirRuntime.DX`) — в `key.domain_dx`.
pub const DOMAIN_DX: f64 = 400.0;
/// Допуск смены условий: ветер, м/с; направление, °; температура, °C.
pub const WIND_TOL_MS: f64 = 0.05;
pub const DIR_TOL_DEG: f64 = 1.0;
pub const TMAX_TOL_C: f64 = 0.25;
/// Допуск сравнения чисел `key` (JSON хранит не все разряды double).
pub const KEY_TOL: f64 = 1.0e-6;
/// Округление координат старта в `key`, м; координат центра — градусы.
pub const START_ROUND_M: f64 = 0.01;
pub const LATLON_ROUND: f64 = 1.0e-6;
/// Каталог данных мест в тексте причин (`AirBakedField.baked_root`).
pub const BAKED_ROOT: &str = "res://data/locations";
/// Куски распаковки `par_chunks_mut`, элементов.
const CHUNK: usize = 1 << 14;

/// Запечённое поле старта: заголовок и уровни (от мелкого к грубому).
#[derive(Clone, Debug)]
pub struct BakedField {
    pub location: String,
    pub site: String,
    pub model_hash: String,
    /// `key` заголовка как есть.
    pub key: Value,
    pub levels: Vec<Field>,
    /// Имя уровня (`dx50`, …) и json `meta` уровня (без упакованных массивов), по уровням.
    pub names: Vec<String>,
    pub level_meta: Vec<Map<String, Value>>,
    /// Множитель притока (`meta.inflow_k` первого уровня, 1 — нет).
    pub inflow_k: f64,
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
    Error::bad_input(format!("baked: {}", msg.into()))
}

fn uint(x: f64, what: &str) -> Result<usize, Error> {
    if x.is_finite() && x >= 0.0 && x.fract() == 0.0 && x < 1.0e15 {
        Ok(x as usize)
    } else {
        Err(bad(format!("{what}: не целое неотрицательное число ({x})")))
    }
}

/// Заголовок и тело (`data` — `.bin` целиком, zstd) → поле. Ошибка — BAD_INPUT с причиной.
pub fn parse_baked(header_json: &str, data: &[u8]) -> Result<BakedField, Error> {
    let h: Hdr = serde_json::from_str(header_json)
        .map_err(|e| bad(format!("заголовок не читается: {e}")))?;
    if h.format != FORMAT || h.version != VERSION as f64 {
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
    let inflow_k = level_meta[0]
        .get("inflow_k")
        .and_then(Value::as_f64)
        .unwrap_or(1.0);
    Ok(BakedField {
        location: h.location,
        site: h.site,
        model_hash: h.model_hash,
        key: h.key,
        levels,
        names: h.levels.into_iter().map(|l| l.name).collect(),
        level_meta,
        inflow_k,
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
/// (поля верхнего уровня заголовка: `cache`, `status`, …) — в заголовок. Читается `parse_baked`.
pub fn encode_baked(
    b: &BakedField,
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

/// `snappedf` Godot: ближайшее кратное шагу.
pub fn snapped(x: f64, step: f64) -> f64 {
    (x / step + 0.5).floor() * step
}

/// Число как `str(float)` Godot: `14 − ⌊lg|x|⌋` знаков после точки при |x| > 10 (иначе 14), хвостовые
/// нули срезаны, но один после точки остаётся (`20.0`, `-6749.65`).
pub fn gd_num(x: f64) -> String {
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

/// Текст числа/значения в причине отказа (`str()` GDScript).
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
/// `KEY_TOL`, словари по ключам `a`, затем `b`; `AirBakedField.key_diff`.
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
                format!("{path}: {} ≠ {}", gd_num(x), gd_num(y))
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

/// Условия игры (`AirRuntime.conditions_fn`): час, ветер 10 м, направление «откуда», температура
/// максимума (NaN — нет), небо, опора ветра.
#[derive(Clone, Debug)]
pub struct Cond<'a> {
    pub hour: f64,
    pub u10: f64,
    pub wdir: f64,
    pub t_max: f64,
    pub sky: &'a str,
    pub wind_ref: &'a str,
}

/// Что нужно знать о месте и условиях, чтобы выбрать поле (всё — данными, без файлов игры).
#[derive(Clone, Debug)]
pub struct BakedQuery<'a> {
    pub location: &'a str,
    pub center_lat: f64,
    pub center_lon: f64,
    /// Площадка старта и её точка (x, z мира).
    pub site: &'a str,
    pub start: [f64; 2],
    /// Набор погоды старта (TI-К2) как объект; не объект или пустой — «нет набора погоды».
    pub weather: &'a Value,
    /// Дата места.
    pub month: i64,
    pub day: i64,
    /// Шаги окон `window_levels_m` конфига.
    pub window_dx: &'a [f64],
    /// Хеш данных места (`AirBakedField.place_hash`); `""` — места нет.
    pub data_hash: &'a str,
    /// Хеш модели воздуха сейчас (`AirBakedField.model_hash`); `""` — не узнать, поле не берётся.
    pub model_hash: &'a str,
    pub cond: Cond<'a>,
}

/// Отказ: текст причины, как в логе игры; `warn` — файл есть, а не сошёлся.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reject {
    pub reason: String,
    pub warn: bool,
    /// Путь файла в терминах игры (`res://data/locations/<место>/air/<старт>.json`); пусто — нет старта.
    pub path: String,
}

/// `key` по запросу (`AirBakedField.make_key`).
pub fn make_key(q: &BakedQuery) -> Value {
    json!({
        "location": q.location,
        "site": q.site,
        "weather": q.weather,
        "center": [snapped(q.center_lat, LATLON_ROUND), snapped(q.center_lon, LATLON_ROUND)],
        "start": [snapped(q.start[0], START_ROUND_M), snapped(q.start[1], START_ROUND_M)],
        "domain_dx": DOMAIN_DX,
        "window_dx": q.window_dx,
        "data_hash": q.data_hash,
        "format": VERSION,
    })
}

/// `angle_difference` Godot: кратчайшая разность углов `to − from`, рад, в `[−π, π]`.
fn angle_difference(from: f64, to: f64) -> f64 {
    let tau = std::f64::consts::TAU;
    let d = (to - from) % tau;
    (2.0 * d) % tau - d
}

/// Условия игры против набора погоды старта: `""` — те же, иначе что отличается
/// (`AirBakedField.conditions_diff`). Нет поля набора — `Err(имя)`.
pub fn conditions_diff(weather: &Value, c: &Cond, month: i64, day: i64) -> Result<String, String> {
    let num = |k: &str| {
        weather
            .get(k)
            .and_then(Value::as_f64)
            .ok_or_else(|| k.to_string())
    };
    let hour = num("start_hour")?;
    let u10 = num("wind_speed_ms")?;
    let wdir = num("wind_from_deg")?;
    let t_max = num("temperature_c")?;
    let w_month = num("month")? as i64;
    let w_day = num("day")? as i64;
    let sky = weather
        .get("sky")
        .and_then(Value::as_str)
        .ok_or_else(|| "sky".to_string())?;
    let wind_ref = weather
        .get("wind_ref")
        .and_then(Value::as_str)
        .unwrap_or("start");
    if (c.hour - hour).abs() > 1.0 / 60.0 {
        return Ok(format!("час {:.3} ≠ {:.3}", c.hour, hour));
    }
    if (c.u10 - u10).abs() > WIND_TOL_MS {
        return Ok(format!("ветер {:.2} ≠ {:.2} м/с", c.u10, u10));
    }
    let dd = angle_difference(c.wdir.to_radians(), wdir.to_radians());
    if dd.abs() > DIR_TOL_DEG.to_radians() {
        return Ok(format!("направление {:.1} ≠ {:.1}°", c.wdir, wdir));
    }
    if c.wind_ref != wind_ref {
        return Ok(format!("опора ветра {} ≠ {}", c.wind_ref, wind_ref));
    }
    if (c.t_max - t_max).abs() > TMAX_TOL_C {
        return Ok(format!(
            "температура {} ≠ {}",
            gd_num(c.t_max),
            gd_num(t_max)
        ));
    }
    if c.sky != sky {
        return Ok(format!("небо {} ≠ {}", c.sky, sky));
    }
    if month != w_month || day != w_day {
        return Ok(format!("дата {day}.{month} ≠ {w_day}.{w_month}"));
    }
    Ok(String::new())
}

/// Путь заголовка поля старта в терминах игры.
pub fn path_of(location: &str, site: &str) -> String {
    format!("{BAKED_ROOT}/{location}/air/{site}.json")
}

/// Подходит ли запечённое поле под условия (`AirRuntime.baked_lookup`): поле из `fields` для
/// `(место, старт)` либо причина отказа. Порядок проверок — как в GDScript.
pub fn baked_lookup<'a>(
    fields: &'a [BakedField],
    q: &BakedQuery,
) -> Result<&'a BakedField, Reject> {
    let rej = |reason: String, warn: bool, path: &str| Reject {
        reason,
        warn,
        path: path.to_string(),
    };
    if q.weather.as_object().is_none_or(|m| m.is_empty()) {
        return Err(rej("у старта нет набора погоды".into(), false, ""));
    }
    let path = path_of(q.location, q.site);
    let Some(f) = fields
        .iter()
        .find(|f| f.location == q.location && f.site == q.site)
    else {
        return Err(rej(format!("нет файла {path}"), false, &path));
    };
    if q.model_hash.is_empty() || f.model_hash != q.model_hash {
        let have = if f.model_hash.is_empty() {
            "?"
        } else {
            &f.model_hash
        };
        return Err(rej(
            format!(
                "модель воздуха другой версии (хеш {have} ≠ {})",
                q.model_hash
            ),
            true,
            &path,
        ));
    }
    match conditions_diff(q.weather, &q.cond, q.month, q.day) {
        Ok(d) if d.is_empty() => {}
        Ok(d) => {
            return Err(rej(
                format!("условия не как в наборе погоды старта ({d})"),
                false,
                &path,
            ));
        }
        Err(k) => {
            return Err(rej(format!("в наборе погоды старта нет {k}"), false, &path));
        }
    }
    let d = key_diff(&f.key, &make_key(q));
    if d.is_empty() {
        Ok(f)
    } else {
        Err(rej(d, true, &path))
    }
}
