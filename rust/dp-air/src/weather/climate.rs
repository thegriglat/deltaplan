//! Климат места: `ClimateGrid.place` по сырой ячейке (`ClimateGrid.at`, W5 v8).
use serde_json::Value;

use super::tables::{num, nums};
use crate::field::weather_core::{WeatherModelCfg, belt_gradient, monthly, season_index};

/// Контекст места для погоды (`ctx` GD): дата, положение, пояс, высоты, м над морем.
/// NaN в `valley_msl_m`/`start_msl_m`/`utc_offset_h` — «не задано» (как в GD).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlaceCtx {
    pub month: i64,
    pub day: i64,
    pub lat: f64,
    pub lon: f64,
    pub utc_offset_h: f64,
    pub valley_msl_m: f64,
    pub mean_msl_m: f64,
    /// Высота старта (ветер прогноза задан на ней); NaN — как `valley_msl_m`.
    pub start_msl_m: f64,
}

/// Состояние сеток климата: `"data"`, `"stub"` или `"none"`.
#[derive(Clone, Debug, PartialEq)]
pub struct ClimateSrc {
    pub hh1: String,
    pub hh2: String,
    pub hh5: String,
    pub hh6: String,
}

/// Климат места на дату (результат `ClimateGrid.place`): ячейка с поправками на высоту долины.
#[derive(Clone, Debug, PartialEq)]
pub struct ClimatePlace {
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
    pub gain_per_km: f64,
    pub src: ClimateSrc,
}

fn src_of(cell: &Value, g: &str) -> String {
    cell.pointer(&format!("/src/{g}"))
        .and_then(Value::as_str)
        .unwrap_or("none")
        .to_string()
}

/// Ячейка без сеток (`ClimateGrid.at` при `src.* = none`): запасные значения конфига.
fn fallback_cell(ctx: &PlaceCtx, cfg: &WeatherModelCfg) -> ClimatePlace {
    let c = &cfg.raw;
    let (m, d) = (ctx.month.clamp(1, 12), ctx.day);
    let fb = |v: Option<&Value>, def: f64| {
        let a = nums(v);
        let a = if a.is_empty() { vec![def] } else { a };
        monthly(&a, m, d)
    };
    let z700 = num(c, &["upper_air", "z_msl_m"], 3000.0);
    ClimatePlace {
        td_c: fb(c.pointer("/climate/fallback/td_c"), 0.0),
        td_sd_k: num(c, &["climate", "td_sd_fallback_k"], 4.0),
        z_cell_m: 0.0,
        t700_c: fb(c.pointer("/upper_air/temp_c"), 0.0),
        z700_m: z700,
        tx_c: fb(c.get("typical_max_c"), 20.0),
        dtr_k: fb(c.pointer("/diurnal/range_k"), 10.0),
        wr: (1.0 + cfg.altitude_gain_per_km * (z700 - 0.0) / 1000.0).max(0.3),
        trop_m: num(c, &["tropopause_msl_m"], 11000.0),
        hcc: num(c, &["cirrus_base"], 0.1),
        gain_per_km: 0.0,
        src: ClimateSrc {
            hh1: "none".into(),
            hh2: "none".into(),
            hh5: "none".into(),
            hh6: "none".into(),
        },
    }
}

fn cell_of(cell: &Value, ctx: &PlaceCtx, cfg: &WeatherModelCfg) -> ClimatePlace {
    if !cell.is_object() {
        return fallback_cell(ctx, cfg);
    }
    let g = |k: &str| cell.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    ClimatePlace {
        td_c: g("td_c"),
        td_sd_k: g("td_sd_k"),
        z_cell_m: g("z_cell_m"),
        t700_c: g("t700_c"),
        z700_m: g("z700_m"),
        tx_c: g("tx_c"),
        dtr_k: g("dtr_k"),
        wr: g("wr"),
        trop_m: g("trop_m"),
        hcc: g("hcc"),
        gain_per_km: 0.0,
        src: ClimateSrc {
            hh1: src_of(cell, "hh1"),
            hh2: src_of(cell, "hh2"),
            hh5: src_of(cell, "hh5"),
            hh6: src_of(cell, "hh6"),
        },
    }
}

/// Климат места `ctx` по сырой ячейке `cell` (`ClimateGrid.at` как json: `td_c, td_sd_k, z_cell_m,
/// t700_c, z700_m, tx_c, dtr_k, wr, trop_m, hcc, src{hh1,hh2,hh5,hh6}`; W5 v8 `loc.climate_cell`):
/// поправки Td, Tx, амплитуды на высоту долины и рост ветра `gain_per_km` (`ClimateGrid.place`).
/// `cell` не объект (`null`) — запасные значения `weather_model.json` как `ClimateGrid.at` без сеток.
pub fn climate_place(cell: &Value, ctx: &PlaceCtx, cfg: &WeatherModelCfg) -> ClimatePlace {
    let mut r = cell_of(cell, ctx, cfg);
    let (lat, month) = (ctx.lat, ctx.month.clamp(1, 12));
    let valley_given = ctx.valley_msl_m;
    let z_cell = r.z_cell_m;
    let valley = if r.src.hh1 == "none" || valley_given.is_nan() {
        z_cell
    } else {
        valley_given
    };
    let dz_km = (valley - z_cell) / 1000.0;
    let season = season_index(month, lat);
    let grad = |key: &str, def: f64| belt_gradient(lat, season, cfg.raw.pointer(key), def);
    r.td_c += grad("/climate/td_gradient_k_per_km", -4.0) * dz_km;
    if r.src.hh5 != "none" {
        r.tx_c += grad("/climate/tx_gradient_k_per_km", -6.31) * dz_km;
        r.dtr_k = (r.dtr_k + grad("/climate/dtr_gradient_k_per_km", -0.48) * dz_km).max(0.0);
    }
    if r.src.hh6 == "none" {
        r.gain_per_km = cfg.altitude_gain_per_km;
    } else {
        // Нет HH1: Z ячейки неизвестна, WR относится к земле места — слой до 700 гПа от долины.
        let z_ref = if r.src.hh1 == "none" && !valley_given.is_nan() {
            valley_given
        } else {
            z_cell
        };
        let mut zs = ctx.start_msl_m;
        if zs.is_nan() {
            zs = if valley_given.is_nan() {
                z_ref
            } else {
                valley_given
            };
        }
        let d = (r.z700_m - z_ref).max(500.0);
        let f = ((zs - z_ref) / d).clamp(0.0, 0.9);
        let wm1 = r.wr - 1.0;
        r.gain_per_km = wm1 * 1000.0 / (d * (1.0 + wm1 * f));
    }
    r
}
