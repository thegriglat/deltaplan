//! Сетки климата ERA5 (1°): чтение из распакованных байтов и ячейка на дату (`ClimateGrid.at`).
//!
//! Формат байтов каждой сетки — 64-байтовый заголовок + тело int16 (little endian) **без сжатия**:
//! сжатие снимает вызывающий (эталон/мост), крейт его не знает. Заголовок: `[0..4]` magic, `[4..6]`
//! версия, `[6..8]` кодек (1), `[8..10]` число долгот (360), `[10..12]` широт (180), `[12..14]`
//! месяцев (12), `[32..48]` четыре f32-масштаба (смысл по сетке), `[48..52]` размер тела (байт),
//! `[56..60]` год начала (0 у сетки-заглушки). Тело: блоки `месяцы·широты·долготы`, затем 2D-блоки.
//! Пропуск данных — `-32768`.
//!
//! Состояния сетки: `data` (рабочая), `stub` (заглушка до выгрузки данных: `year0 = 0` у HH2,
//! `stub_mask != 0` у HH6), `none` (нет, короткая, неверный magic/кодек/размер) — тогда значения
//! этой сетки берутся из запасных таблиц конфига (`climate.fallback`, `upper_air`).
use serde_json::Value;

use super::climate::ClimateSrc;
use super::tables::{num, nums};
use crate::field::sun::days_in_month;
use crate::field::weather_core::monthly;

const HEADER: usize = 64;
const NODATA: i16 = -32768;
const NLON: usize = 360;
const NLAT: usize = 180;
const NMONTH: usize = 12;
const SOUTH_CELL_MIN: f64 = -89.5;
const LON0: f64 = -179.5;

/// Климат ячейки на дату без поправки на высоту (результат `ClimateGrid.at`): точка росы и её
/// разброс, высота ячейки, воздух 700 гПа, дневной максимум и амплитуда, рост ветра, тропопауза,
/// перистые. Единицы: °C, К, м.
#[derive(Clone, Debug, PartialEq)]
pub struct ClimateCell {
    pub td_c: f64,
    pub td_sd_k: f64,
    pub z_cell_m: f64,
    pub t700_c: f64,
    pub z700_m: f64,
    pub tx_c: f64,
    pub dtr_k: f64,
    pub wr: f64,
    pub trop_m: f64,
    pub hcc: f64,
    pub src: ClimateSrc,
}

/// Имена сеток (ключи, по которым вызывающий отдаёт байты): `hh1` — точка росы, `hh2` — воздух
/// 700 гПа, `hh5` — Tmax и амплитуда, `hh6` — рост ветра, тропопауза, перистые.
pub const GRID_NAMES: [&str; 4] = ["hh1", "hh2", "hh5", "hh6"];

/// (magic, 3D-блоков, 2D-блоков) по сетке.
fn spec(name: &str) -> Option<(&'static [u8; 4], usize, usize)> {
    match name {
        "hh1" => Some((b"HHTD", 2, 1)),
        "hh2" => Some((b"HHUA", 2, 0)),
        "hh5" => Some((b"HHST", 2, 0)),
        "hh6" => Some((b"HHUM", 3, 0)),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Data,
    Stub,
    None,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Data => "data",
            State::Stub => "stub",
            State::None => "none",
        }
    }
}

#[derive(Clone, Debug)]
struct Grid {
    state: State,
    /// Тело int16 (little endian), байты.
    raw: Vec<u8>,
    /// Число значений в одном 3D-блоке.
    n3: usize,
    /// Масштабы заголовка `[32..48]` (f32 как f64).
    k: [f64; 4],
}

impl Grid {
    fn none() -> Grid {
        Grid {
            state: State::None,
            raw: Vec::new(),
            n3: 0,
            k: [0.0; 4],
        }
    }

    /// Проверка заголовка и размера, как `ClimateGrid._load` (кроме распаковки).
    fn parse(name: &str, bytes: &[u8]) -> Grid {
        let Some((magic, b3, b2)) = spec(name) else {
            return Grid::none();
        };
        if bytes.len() < HEADER || &bytes[0..4] != magic {
            return Grid::none();
        }
        let u16_at = |o: usize| u16::from_le_bytes([bytes[o], bytes[o + 1]]) as usize;
        let u32_at = |o: usize| {
            u32::from_le_bytes([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]) as usize
        };
        let f32_at = |o: usize| {
            f32::from_le_bytes([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]) as f64
        };
        if u16_at(6) != 1 || u16_at(8) != NLON || u16_at(10) != NLAT || u16_at(12) != NMONTH {
            return Grid::none();
        }
        let n3 = NMONTH * NLAT * NLON;
        let n2 = NLAT * NLON;
        let raw_size = u32_at(48);
        if raw_size != 2 * (b3 * n3 + b2 * n2) || bytes.len() != HEADER + raw_size {
            return Grid::none();
        }
        let year0 = u32_at(56);
        let k = [f32_at(32), f32_at(36), f32_at(40), f32_at(44)];
        let stub = match name {
            "hh2" => year0 == 0,
            "hh6" => u32_at(44) != 0,
            _ => false,
        };
        // hh6: масштаб в [44..48] — не f32, а маска заглушки
        let k = if name == "hh6" {
            [k[0], k[1], k[2], 0.0]
        } else {
            k
        };
        Grid {
            state: if stub { State::Stub } else { State::Data },
            raw: bytes[HEADER..].to_vec(),
            n3,
            k,
        }
    }

    #[inline]
    fn v(&self, idx: usize) -> i16 {
        i16::from_le_bytes([self.raw[2 * idx], self.raw[2 * idx + 1]])
    }
}

/// Четыре ячейки пространственной интерполяции: индексы строк, столбцов и веса.
struct Cells {
    j: [usize; 4],
    i: [usize; 4],
    w: [f64; 4],
}

/// Сетки климата четырёх видов (неизменяемые, делятся по `Arc`).
#[derive(Clone, Debug)]
pub struct ClimateGrids {
    hh1: Grid,
    hh2: Grid,
    hh5: Grid,
    hh6: Grid,
}

impl ClimateGrids {
    /// Все сетки в состоянии `none`: везде запасные значения конфига.
    pub fn none() -> ClimateGrids {
        ClimateGrids {
            hh1: Grid::none(),
            hh2: Grid::none(),
            hh5: Grid::none(),
            hh6: Grid::none(),
        }
    }

    /// Сетки из пар (имя, байты) — имена `hh1`, `hh2`, `hh5`, `hh6` (формат — в описании модуля;
    /// байты уже распакованы). Нет пары, неизвестное имя, битый заголовок или неверный размер —
    /// сетка `none` (не ошибка).
    pub fn from_bytes(items: &[(&str, &[u8])]) -> ClimateGrids {
        let of = |name: &str| {
            items
                .iter()
                .rev()
                .find(|(n, _)| *n == name)
                .map_or_else(Grid::none, |(_, b)| Grid::parse(name, b))
        };
        ClimateGrids {
            hh1: of("hh1"),
            hh2: of("hh2"),
            hh5: of("hh5"),
            hh6: of("hh6"),
        }
    }

    /// Состояния сеток.
    pub fn src(&self) -> ClimateSrc {
        ClimateSrc {
            hh1: self.hh1.state.name().into(),
            hh2: self.hh2.state.name().into(),
            hh5: self.hh5.state.name().into(),
            hh6: self.hh6.state.name().into(),
        }
    }

    /// Климат ячейки на дату без поправки на высоту (`ClimateGrid.at`). `cfg` — `weather_model`
    /// (запасные таблицы), `gain_per_km` — запасной рост ветра (`atmosphere.wind.altitude_gain_per_km`).
    /// Нечисловые `lat`/`lon` — все значения запасные (`src` сохраняет состояния сеток).
    pub fn at(
        &self,
        lat: f64,
        lon: f64,
        month: i64,
        day: i64,
        cfg: &Value,
        gain_per_km: f64,
    ) -> ClimateCell {
        let fb = cfg.pointer("/climate/fallback");
        let fb_m = |v: Option<&Value>, def: f64| {
            let a = nums(v);
            let a = if a.is_empty() { vec![def] } else { a };
            monthly(&a, month, day)
        };
        let finite = lat.is_finite() && lon.is_finite();
        let usable = |g: &Grid| g.state != State::None && finite;
        let (m, m2, wt) = month_pair(month, day);
        let cells = if finite { cells_of(lat, lon) } else { None };
        let sample_time = |g: &Grid, block: usize| -> f64 {
            let Some(c) = &cells else { return 0.0 };
            let a = sample(g, block * g.n3 + m * NLAT * NLON, c);
            if wt <= 0.0 {
                return a;
            }
            let b = sample(g, block * g.n3 + m2 * NLAT * NLON, c);
            a + (b - a) * wt
        };
        let mut out = ClimateCell {
            td_c: 0.0,
            td_sd_k: 0.0,
            z_cell_m: 0.0,
            t700_c: 0.0,
            z700_m: 0.0,
            tx_c: 0.0,
            dtr_k: 0.0,
            wr: 1.0,
            trop_m: 0.0,
            hcc: 0.0,
            src: self.src(),
        };
        let g1 = &self.hh1;
        if usable(g1) {
            let td = sample_time(g1, 0);
            let sd = sample_time(g1, 1);
            let z = cells.as_ref().map_or(0.0, |c| sample(g1, 2 * g1.n3, c));
            out.td_c = td * g1.k[0] + g1.k[1];
            out.td_sd_k = (sd * g1.k[2]).max(0.0);
            out.z_cell_m = z * g1.k[3];
        } else {
            out.td_c = fb_m(fb.and_then(|f| f.get("td_c")), 0.0);
            out.td_sd_k = num(cfg, &["climate", "td_sd_fallback_k"], 4.0);
            out.z_cell_m = 0.0;
        }
        let ua = cfg.get("upper_air");
        let g2 = &self.hh2;
        if usable(g2) {
            out.t700_c = sample_time(g2, 0) * g2.k[0] + g2.k[1];
            out.z700_m = sample_time(g2, 1) * g2.k[2] + g2.k[3];
        } else {
            out.t700_c = fb_m(ua.and_then(|u| u.get("temp_c")), 0.0);
            out.z700_m = num(cfg, &["upper_air", "z_msl_m"], 3000.0);
        }
        let g5 = &self.hh5;
        if usable(g5) {
            out.tx_c = sample_time(g5, 0) * g5.k[0] + g5.k[1];
            out.dtr_k = (sample_time(g5, 1) * g5.k[2]).max(0.0);
        } else {
            out.tx_c = fb_m(cfg.get("typical_max_c"), 20.0);
            out.dtr_k = fb_m(cfg.pointer("/diurnal/range_k"), 10.0);
        }
        let g6 = &self.hh6;
        if usable(g6) {
            out.wr = sample_time(g6, 0) * g6.k[0];
            out.trop_m = sample_time(g6, 1) * g6.k[1];
            out.hcc = (sample_time(g6, 2) * g6.k[2]).clamp(0.0, 1.0);
        } else {
            out.wr = (1.0 + gain_per_km * (out.z700_m - out.z_cell_m) / 1000.0).max(0.3);
            out.trop_m = num(cfg, &["tropopause_msl_m"], 11000.0);
            out.hcc = num(cfg, &["cirrus_base"], 0.1);
        }
        out
    }
}

/// Месяц `m` (0..11), соседний `m2` и вес соседа по дню (середина месяца — 15-е).
fn month_pair(month: i64, day: i64) -> (usize, usize, f64) {
    let m = month.clamp(1, 12) - 1;
    let dim = days_in_month(m + 1) as f64;
    let f = (day as f64 - 15.0) / dim;
    let m2 = (m + if f >= 0.0 { 1 } else { -1 }).rem_euclid(12);
    (m as usize, m2 as usize, f.abs())
}

fn cells_of(lat: f64, lon: f64) -> Option<Cells> {
    let x = (lon - LON0).rem_euclid(360.0);
    let i0f = x.floor();
    let fi = x - i0f;
    let i0 = (i0f as i64).rem_euclid(NLON as i64) as usize;
    let i1 = (i0 + 1) % NLON;
    let y = lat.clamp(SOUTH_CELL_MIN, -SOUTH_CELL_MIN) - SOUTH_CELL_MIN;
    let j0 = (y.floor() as usize).min(NLAT - 2);
    let fj = y - j0 as f64;
    let j1 = j0 + 1;
    Some(Cells {
        j: [j0, j0, j1, j1],
        i: [i0, i1, i0, i1],
        w: [
            (1.0 - fi) * (1.0 - fj),
            fi * (1.0 - fj),
            (1.0 - fi) * fj,
            fi * fj,
        ],
    })
}

/// Билинейно по 4 ячейкам блока (начало — индекс int16 `base`). Пропуск (−32768) исключает
/// ячейку, веса перенормируются; все пропущены — ближайшая ячейка с данными в строке первой из
/// ячеек (по кругу, сначала вправо); нет — 0.
fn sample(g: &Grid, base: usize, c: &Cells) -> f64 {
    let (mut s, mut ws) = (0.0, 0.0);
    for k in 0..4 {
        let v = g.v(base + c.j[k] * NLON + c.i[k]);
        if v != NODATA {
            s += v as f64 * c.w[k];
            ws += c.w[k];
        }
    }
    if ws > 1.0e-9 {
        return s / ws;
    }
    let row = base + c.j[0] * NLON;
    for d in 1..=(NLON / 2) {
        for sgn in [1i64, -1] {
            let i = (c.i[0] as i64 + sgn * d as i64).rem_euclid(NLON as i64) as usize;
            let v = g.v(row + i);
            if v != NODATA {
                return v as f64;
            }
        }
    }
    0.0
}
