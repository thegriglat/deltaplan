//! Место (W5): заголовок json + растры одной сетки.
use crate::error::Error;
use serde::Deserialize;
use std::collections::BTreeMap;

/// Климат у центра места (W5 v3, `ClimateGrid.place`): ячейка ERA5 на `month/day`.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
pub struct LocClimate {
    /// Дневной максимум HH5, °C.
    pub tx_c: f64,
    /// Суточная амплитуда, К.
    pub dtr_k: f64,
    /// Средняя высота ячейки HH1, м (0 — нет).
    pub z_cell_m: f64,
    pub has_hh1: bool,
    pub has_hh5: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Loc {
    pub id: String,
    pub center_lat: f64,
    pub center_lon: f64,
    pub utc_offset_h: f64,
    pub month: u32,
    pub day: u32,
    /// Нет ключа — запасные таблицы `weather_model.json`.
    #[serde(default)]
    pub climate: Option<LocClimate>,
    /// W5 v7: климат той же ячейки на дату `month/day − round(water.lag_days)`; нужен для
    /// температуры воды. Обязателен, если есть `climate` (пара считается фасадом вместе).
    #[serde(default)]
    pub climate_lag: Option<LocClimate>,
    /// W5 v8: сырая ячейка климата `ClimateGrid.at(center_lat, center_lon, month, day)` как json
    /// (`td_c, td_sd_k, z_cell_m, t700_c, z700_m, tx_c, dtr_k, wr, trop_m, hcc, src{hh1,hh2,hh5,hh6}`);
    /// поправки на высоту места считает крейт (`weather::climate_place`). Нет ключа — запасные
    /// значения `weather_model.json`. Ключи только парой с `climate_cell_lag`.
    #[serde(default)]
    pub climate_cell: Option<serde_json::Value>,
    /// W5 v8: то же на дату `month/day − round(water.lag_days)`.
    #[serde(default)]
    pub climate_cell_lag: Option<serde_json::Value>,
}

/// Сетка W1: узлы, `origin_*` — координаты узла (0, 0).
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Grid {
    pub origin_x: f64,
    pub origin_z: f64,
    pub spacing: f64,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct StartSite {
    pub x: f64,
    pub z: f64,
    pub h_msl: f64,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct PlaceHeader {
    pub version: u32,
    pub loc: Loc,
    pub grid: Grid,
    pub surface_classes: BTreeMap<String, u8>,
    pub start_sites: Vec<StartSite>,
    /// Хеш кода модели воздуха игры (W5 v5, v9): кеш полей берётся, только если он совпал со
    /// своим в файле; пусто (нет ключа) — кеш не используется.
    #[serde(default)]
    pub model_hash: String,
}

impl PlaceHeader {
    /// Разбор json заголовка с проверкой значений; неверное — BAD_INPUT.
    pub fn from_json(text: &str) -> Result<Self, Error> {
        let h: PlaceHeader = serde_json::from_str(text)
            .map_err(|e| Error::bad_input(format!("place header: {e}")))?;
        h.validate()?;
        Ok(h)
    }

    fn validate(&self) -> Result<(), Error> {
        let bad = |m: &str| Err(Error::bad_input(format!("place header: {m}")));
        if self.version != 1 {
            return bad("version must be 1");
        }
        let l = &self.loc;
        if !(l.center_lat.is_finite() && l.center_lon.is_finite() && l.utc_offset_h.is_finite()) {
            return bad("loc: non-finite number");
        }
        if !(1..=12).contains(&l.month) || !(1..=31).contains(&l.day) {
            return bad("loc: month/day out of range");
        }
        if l.climate.is_some() && l.climate_lag.is_none() {
            return bad("loc.climate_lag is required with loc.climate");
        }
        if l.climate_cell.is_some() != l.climate_cell_lag.is_some() {
            return bad(if l.climate_cell.is_some() {
                "loc.climate_cell_lag is required with loc.climate_cell"
            } else {
                "loc.climate_cell is required with loc.climate_cell_lag"
            });
        }
        let g = &self.grid;
        if !(g.origin_x.is_finite() && g.origin_z.is_finite()) {
            return bad("grid: non-finite origin");
        }
        if !(g.spacing.is_finite() && g.spacing > 0.0) {
            return bad("grid.spacing must be > 0");
        }
        if g.width == 0 || g.height == 0 {
            return bad("grid size must be > 0");
        }
        if (g.width as u64) * (g.height as u64) > (u32::MAX as u64) {
            return bad("grid too large");
        }
        if self
            .start_sites
            .iter()
            .any(|s| !(s.x.is_finite() && s.z.is_finite() && s.h_msl.is_finite()))
        {
            return bad("start_sites: non-finite number");
        }
        Ok(())
    }

    /// Число узлов сетки.
    pub fn cells(&self) -> usize {
        self.grid.width as usize * self.grid.height as usize
    }
}

/// Место: заголовок и растры (`width × height`, индекс `j * width + i`).
#[derive(Clone, Debug, PartialEq)]
pub struct Place {
    header: PlaceHeader,
    heights: Vec<f32>,
    water: Vec<u8>,
    cls: Vec<u8>,
    moist: Vec<f32>,
}

impl Place {
    /// Проверяет заголовок, длины растров, конечность высот и влажности, воду 0/1.
    pub fn new(
        header: PlaceHeader,
        heights: Vec<f32>,
        water: Vec<u8>,
        cls: Vec<u8>,
        moist: Vec<f32>,
    ) -> Result<Self, Error> {
        header.validate()?;
        let n = header.cells();
        for (name, len) in [
            ("heights", heights.len()),
            ("water", water.len()),
            ("surface_cls", cls.len()),
            ("surface_moist", moist.len()),
        ] {
            if len != n {
                return Err(Error::bad_input(format!(
                    "place: {name} has {len} values, grid needs {n}"
                )));
            }
        }
        if heights.iter().any(|v| !v.is_finite()) {
            return Err(Error::bad_input("place: heights contain NaN/inf"));
        }
        if moist.iter().any(|v| !v.is_finite()) {
            return Err(Error::bad_input("place: surface_moist contains NaN/inf"));
        }
        if water.iter().any(|&v| v > 1) {
            return Err(Error::bad_input("place: water must be 0/1"));
        }
        Ok(Place {
            header,
            heights,
            water,
            cls,
            moist,
        })
    }

    pub fn header(&self) -> &PlaceHeader {
        &self.header
    }
    pub fn heights(&self) -> &[f32] {
        &self.heights
    }
    pub fn water(&self) -> &[u8] {
        &self.water
    }
    pub fn cls(&self) -> &[u8] {
        &self.cls
    }
    pub fn moist(&self) -> &[f32] {
        &self.moist
    }
}
