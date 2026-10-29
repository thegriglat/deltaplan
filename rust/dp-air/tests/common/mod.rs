//! Общее для тестов погоды: сетки климата репозитория (`data/climate/*.bin`, brotli) -> байты
//! без сжатия -> `Weather`. Распаковку делает игра/мост; крейт сжатия не знает.
#![allow(dead_code)]
use dp_air::weather::{ClimateGrids, GRID_NAMES, Weather};
use dp_air::{Configs, Forecast};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

pub const HEADER: usize = 64;

pub fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Секции конфигов погоды (`atmosphere`, `weather_model`, `surface_heat`, `world`).
pub fn cfg_files() -> Vec<(String, String)> {
    ["atmosphere", "weather_model", "surface_heat", "world"]
        .iter()
        .map(|n| {
            (
                n.to_string(),
                std::fs::read_to_string(repo().join("configs").join(format!("{n}.json"))).unwrap(),
            )
        })
        .collect()
}

pub const REAL_FILES: [(&str, &str); 4] = [
    ("hh1", "dew_point_1deg"),
    ("hh2", "upper_air_1deg"),
    ("hh5", "surface_t_1deg"),
    ("hh6", "upper_misc_1deg"),
];

fn u32_at(b: &[u8], o: usize) -> usize {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as usize
}

/// Как игра: файл -> 64 байта заголовка + распакованное тело; не вышло - только заголовок.
pub fn unpack(file: &[u8]) -> Vec<u8> {
    if file.len() < HEADER {
        return file.to_vec();
    }
    let (raw, comp) = (u32_at(file, 48), u32_at(file, 52));
    let head = file[..HEADER].to_vec();
    if file.len() != HEADER + comp {
        return head;
    }
    let mut out = Vec::new();
    let mut body = &file[HEADER..];
    match brotli_decompressor::BrotliDecompress(&mut body, &mut out) {
        Ok(()) if out.len() == raw => {
            let mut v = head;
            v.extend_from_slice(&out);
            v
        }
        _ => head,
    }
}

pub fn real_file(g: &str) -> Vec<u8> {
    let name = REAL_FILES.iter().find(|(k, _)| *k == g).unwrap().1;
    std::fs::read(repo().join("data/climate").join(format!("{name}.bin"))).unwrap()
}

/// Настоящие сетки репозитория, кроме `skip`, распакованные.
pub fn real_grids(skip: &[&str]) -> Vec<(&'static str, Vec<u8>)> {
    GRID_NAMES
        .iter()
        .filter(|g| !skip.contains(g))
        .map(|g| (*g, unpack(&real_file(g))))
        .collect()
}

pub fn weather_of(items: &[(&str, Vec<u8>)]) -> Weather {
    let refs: Vec<(&str, &[u8])> = items.iter().map(|(n, b)| (*n, b.as_slice())).collect();
    Weather::new(&Configs::new(cfg_files()), ClimateGrids::from_bytes(&refs)).unwrap()
}

/// `Weather` с настоящими сетками (общий на тестовый бинарник).
pub fn real_weather() -> Arc<Weather> {
    static W: OnceLock<Arc<Weather>> = OnceLock::new();
    W.get_or_init(|| Arc::new(weather_of(&real_grids(&[]))))
        .clone()
}

/// `Weather` без сеток: везде запасные значения конфига.
pub fn no_grids_weather() -> Arc<Weather> {
    Arc::new(Weather::new(&Configs::new(cfg_files()), ClimateGrids::none()).unwrap())
}

pub fn forecast(t: f64, kmh: f64, from: f64, sky: &str) -> Forecast {
    serde_json::from_value(serde_json::json!({
        "temperature_c": t, "wind_speed_kmh": kmh, "wind_from_deg": from, "sky": sky
    }))
    .unwrap()
}

/// Сетка HH5 (дневной максимум и амплитуда) из констант: `tx` °C и `dtr` К во всех ячейках и
/// месяцах (масштаб 1, смещение 0; целые значения).
pub fn const_hh5(tx: i16, dtr: i16) -> Vec<u8> {
    let n3 = 12 * 180 * 360;
    let mut b = vec![0u8; HEADER];
    b[0..4].copy_from_slice(b"HHST");
    b[4..6].copy_from_slice(&1u16.to_le_bytes());
    b[6..8].copy_from_slice(&1u16.to_le_bytes());
    b[8..10].copy_from_slice(&360u16.to_le_bytes());
    b[10..12].copy_from_slice(&180u16.to_le_bytes());
    b[12..14].copy_from_slice(&12u16.to_le_bytes());
    b[32..36].copy_from_slice(&1.0f32.to_le_bytes());
    b[40..44].copy_from_slice(&1.0f32.to_le_bytes());
    b[48..52].copy_from_slice(&((4 * n3) as u32).to_le_bytes());
    b[56..60].copy_from_slice(&2000u32.to_le_bytes());
    for v in [tx, dtr] {
        for _ in 0..n3 {
            b.extend_from_slice(&v.to_le_bytes());
        }
    }
    b
}

/// `Weather` только с сеткой HH5 из констант (остальные сетки - запасные значения).
pub fn const_hh5_weather(tx: i16, dtr: i16) -> Arc<Weather> {
    Arc::new(weather_of(&[("hh5", const_hh5(tx, dtr))]))
}
