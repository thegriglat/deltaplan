//! RW-14h: утверждения GD-тестов погоды, перенесённые в cargo над `dp_air::weather` и
//! `dp_air::field::surface_heat`. Источники (GD, читать, не менять - удалит RW-14g):
//! `tests/atmosphere/test_surface_heat.gd` (9), `test_surface_heating.gd` (2), `test_storm_rarity.gd`
//! (`test_chance_grows_with_heat`), `tests/contracts/test_haze_humidity_contracts.gd` (HH7, часть
//! ClimateGrid), `test_air_place_climate_lag.gd`. Пороги и допуски - как в GD. Сетки климата -
//! `data/climate/*.bin`, распаковка в `common` (brotli).
//!
//! Не перенесено (GD-механика или нет аналога в крейте) - в отчёте задачи.
mod common;

use common::{
    HEADER, cfg_files, forecast, no_grids_weather, real_file, real_weather, repo, unpack,
};
use dp_air::Configs;
use dp_air::field::sun::{day_of_year, days_in_month};
use dp_air::field::surface_heat::{
    self as sh, CLASS_COUNT, CLASS_NAMES, Night, Sky, SurfaceHeatCfg, SurfaceHeating, WaterIn,
};
use dp_air::field::weather_core::{belt_gradient, season_index};
use dp_air::weather::{ClimateGrids, GRID_NAMES, PlaceCtx, Weather, interp_rows};
use serde_json::Value;
use std::sync::Arc;

const GRASS: usize = 2;
const BARE: usize = 5;
const WATER: usize = sh::WATER;

fn near(a: f64, b: f64, tol: f64, what: &str) {
    assert!((a - b).abs() <= tol, "{what}: {a} != {b} (±{tol})");
}

fn raw_cfg(name: &str) -> Value {
    let (_, t) = cfg_files().into_iter().find(|(n, _)| n == name).unwrap();
    serde_json::from_str(&t).unwrap()
}

fn heat() -> SurfaceHeatCfg {
    SurfaceHeatCfg::from_value(&raw_cfg("surface_heat")).unwrap()
}

fn fnum(v: &Value, path: &str) -> f64 {
    v.pointer(path)
        .and_then(Value::as_f64)
        .unwrap_or_else(|| panic!("нет числа {path}"))
}

/// `WeatherModel.reference_context()` с поясом +7 (как `_ctx` в GD-тесте).
fn ref_ctx(w: &Weather) -> PlaceCtx {
    PlaceCtx {
        utc_offset_h: 7.0,
        ..w.reference_context()
    }
}

// ---------------------------------------------------------------- SurfaceHeat (SH2)

#[test]
fn shortwave_monotone_and_night() {
    let cfg = heat();
    let mut prev = -1.0;
    for i in 0..11 {
        let k = sh::shortwave(i as f64 / 10.0, 0.8, 0.0, &cfg);
        assert!(k >= prev, "K↓ не убывает по cos_inc");
        prev = k;
    }
    assert_eq!(sh::shortwave(1.0, 0.0, 0.0, &cfg), 0.0, "sin_el = 0 → 0");
    assert_eq!(
        sh::shortwave(0.5, -0.2, 0.0, &cfg),
        0.0,
        "солнце под горизонтом → 0"
    );
    assert!(
        sh::shortwave(-0.5, 0.8, 0.0, &cfg) > 0.0,
        "тень склона: рассеянная остаётся"
    );
    near(
        sh::shortwave(1.0, 1.0, 0.0, &cfg),
        1088.8,
        0.01,
        "зенит, ясно: 1361·0,8",
    );
}

#[test]
fn cloud_shortwave() {
    let cfg = heat();
    let sn = 0.8;
    let clear = sh::shortwave(sn, sn, 0.0, &cfg);
    let cloudy = sh::shortwave(sn, sn, 0.85, &cfg);
    assert!(cloudy < clear * 0.5, "cover 0,85: {cloudy} < {clear}");
    near(
        cloudy / clear,
        1.0 - 0.7 * 0.85,
        1e-9,
        "множитель Stull (1 − 0,7·cover)",
    );
    // GD: «sky_heat не используется» - в Rust аргумента sky_heat у shortwave нет вовсе.
    let tc = 0.6 + 0.2 * sn;
    let f = cfg.diffuse_frac;
    assert!(
        sh::diffuse_fraction(tc * (1.0 - 0.7 * 0.85), f) > sh::diffuse_fraction(tc, f) + 0.5,
        "доля рассеянной растёт с облачностью"
    );
    near(
        sh::diffuse_fraction(tc, f),
        0.165,
        0.05,
        "ясно: доля рассеянной ≈ 0,165",
    );
    assert!(
        sh::shortwave(-0.3, sn, 0.85, &cfg) > 0.0,
        "от солнца, пасмурно: K > 0"
    );
    near(
        clear,
        cfg.s0_wm2 * tc * sn,
        1e-6,
        "горизонталь = S₀·T_r·sinψ",
    );
}

#[test]
fn water_height() {
    let cfg = heat();
    let h0 = sh::water_flux(15.0, 10.0, 3.0, &cfg, 0.0);
    let h1 = sh::water_flux(15.0, 10.0, 3.0, &cfg, 1000.0);
    near(h1 / h0, (-1000.0f64 / 8400.0).exp(), 1e-9, "ρ по высоте");
    assert!(h1 < h0 && h1 / h0 > 0.88 && h1 / h0 < 0.9, "≈ ×0,89 на км");
    let mut fw = [0.0f32; CLASS_COUNT];
    fw[WATER] = 1.0;
    let wd = WaterIn {
        t_water_c: 12.0,
        t_air_c: 17.0,
        u_ms: 3.0,
        z_m: 1000.0,
    };
    let sky = Sky {
        cover: 0.0,
        sky_heat: 1.0,
        night: None,
    };
    near(
        sh::mix_flux(&fw, [0.0, 1.0, 0.0], &[], 0.5, &sky, Some(&wd), &cfg),
        sh::water_flux(12.0, 17.0, 3.0, &cfg, 1000.0),
        1e-9,
        "z_m в данных воды",
    );
}

#[test]
fn bowen() {
    let cfg = heat();
    let raw = raw_cfg("surface_heat");
    let (m_norm, m_dry, m_wet) = (
        fnum(&raw, "/moisture/m_norm"),
        fnum(&raw, "/moisture/m_dry"),
        fnum(&raw, "/moisture/m_wet"),
    );
    for (c, name) in CLASS_NAMES.iter().enumerate() {
        let k = |key: &str| fnum(&raw, &format!("/classes/{name}/{key}"));
        near(sh::bowen(c, m_norm, &cfg), k("bowen"), 1e-9, "β(m_norm)");
        near(sh::bowen(c, m_dry, &cfg), k("bowen_max"), 1e-9, "β(m_dry)");
        near(sh::bowen(c, 0.0, &cfg), k("bowen_max"), 1e-9, "β(0)");
        near(sh::bowen(c, m_wet, &cfg), k("bowen_min"), 1e-9, "β(m_wet)");
        near(sh::bowen(c, 1.0, &cfg), k("bowen_min"), 1e-9, "β(1)");
        let mut prev = f64::INFINITY;
        for i in 0..21 {
            let b = sh::bowen(c, i as f64 / 20.0, &cfg);
            assert!(
                b >= k("bowen_min") - 1e-9 && b <= k("bowen_max") + 1e-9,
                "β в границах"
            );
            assert!(b <= prev + 1e-12, "β не растёт по m");
            prev = b;
        }
    }
}

#[test]
fn land_flux() {
    let cfg = heat();
    for c in (0..CLASS_COUNT).filter(|&c| c != WATER) {
        let mut prev = f64::INFINITY;
        for i in 0..11 {
            let h = sh::land_flux(c, 800.0, 0.0, i as f64 / 10.0, &cfg);
            assert!(h <= prev + 1e-9, "H не растёт по m (Rn − G > 0), класс {c}");
            prev = h;
        }
        assert!(
            sh::land_flux(c, 0.0, 0.0, 0.5, &cfg) < 0.0,
            "ночью H < 0, класс {c}"
        );
        assert!(
            sh::land_flux(c, 900.0, 0.0, 0.5, &cfg) > sh::land_flux(c, 300.0, 0.0, 0.5, &cfg),
            "H растёт с K↓"
        );
        assert!(
            sh::land_flux(c, 0.0, 1.0, 0.5, &cfg) > sh::land_flux(c, 0.0, 0.0, 0.5, &cfg),
            "облака ослабляют ночное выхолаживание"
        );
    }
}

#[test]
fn href_consistent() {
    let cfg = heat();
    let raw = raw_cfg("surface_heat");
    let k = sh::shortwave(1.0, 1.0, 0.0, &cfg);
    let h = sh::land_flux(sh::NONE + 5, k, 0.0, cfg.m_norm, &cfg); // 5 = bare
    let h_ref = fnum(&raw, "/thermal/h_ref_wm2");
    near(h, h_ref, 1.0, "h_ref_wm2 = H скалы в зените");
    let (s0, a, b) = (
        fnum(&raw, "/radiation/s0_wm2"),
        fnum(&raw, "/radiation/tk_a"),
        fnum(&raw, "/radiation/tk_b"),
    );
    let rn = (1.0 - 0.25) * s0 * (a + b) - fnum(&raw, "/radiation/l_star_wm2");
    let bw = fnum(&raw, "/classes/bare/bowen");
    near(
        rn * (1.0 - 0.25) * bw / (1.0 + bw),
        h_ref,
        1.0,
        "h_ref_wm2 по формуле §9.6",
    );
}

#[test]
fn water_and_air_temperature() {
    let w = real_weather();
    let cfg = heat();
    assert!(
        sh::water_flux(10.0, 15.0, 3.0, &cfg, 0.0) < 0.0,
        "вода холоднее воздуха → H < 0"
    );
    assert!(
        sh::water_flux(15.0, 10.0, 3.0, &cfg, 0.0) > 0.0,
        "вода теплее → H > 0"
    );
    assert_eq!(sh::water_flux(10.0, 10.0, 3.0, &cfg, 0.0), 0.0, "равны → 0");
    near(
        sh::water_flux(0.0, 5.0, 0.0, &cfg, 0.0),
        -1206.0 * 1.4e-3 * 1.0 * 5.0,
        1e-6,
        "u_min",
    );
    let ctx = ref_ctx(&w);
    let valley = ctx.valley_msl_m;
    let tw = w.water_temp_c(7, 15, valley, &ctx);
    assert!(tw >= 0.0, "T_w ≥ 0");
    let tmax = w.typical_max_c(7, 15, f64::NAN, f64::NAN, f64::NAN);
    let t_air = w.air_temp_c(14.0, tmax, valley, &ctx);
    assert!(
        tw < t_air && tw > 5.0,
        "летом вода теплее 5 °C и холоднее дневного воздуха: {tw}"
    );
    assert_eq!(w.water_temp_c(1, 15, valley, &ctx), 0.0, "январь: лёд (0)");
    let hi = w.water_temp_c(7, 15, valley + 1000.0, &ctx);
    near(tw - hi, 6.5, 1e-6, "поправка на высоту 6,5 К/км");
    near(
        w.air_temp_c(14.0, 25.0, valley + 1000.0, &ctx),
        w.air_temp_c(14.0, 25.0, valley, &ctx) - 6.5,
        1e-9,
        "air_temp_c: высота",
    );
}

fn fr(c: usize) -> [f32; CLASS_COUNT] {
    let mut f = [0.0; CLASS_COUNT];
    f[c] = 1.0;
    f
}

fn sun_of(el_deg: f64) -> Vec<[f64; 3]> {
    let v = if el_deg > 0.0 {
        [0.0, el_deg.to_radians().sin(), el_deg.to_radians().cos()]
    } else {
        [0.0; 3]
    };
    vec![v; CLASS_COUNT]
}

#[test]
fn mix_flux() {
    let cfg = heat();
    let up = [0.0, 1.0, 0.0];
    let sky = Sky {
        cover: 0.0,
        sky_heat: 1.0,
        night: None,
    };
    let sun = sun_of(60.0);
    let s60 = 60f64.to_radians().sin();
    let k = sh::shortwave(s60, s60, 0.0, &cfg);
    let mix = |f: &[f32], n: [f64; 3], s: &[[f64; 3]], wd: Option<&WaterIn>| {
        sh::mix_flux(f, n, s, 0.5, &sky, wd, &cfg)
    };
    // Один класс = land_flux.
    near(
        mix(&fr(GRASS), up, &sun, None),
        sh::land_flux(GRASS, k, 0.0, 0.5, &cfg),
        1e-3,
        "один класс",
    );
    // Смесь 50/50 и ненормированные веса.
    let mut f = [0.0f32; CLASS_COUNT];
    f[GRASS] = 2.0;
    f[BARE] = 2.0;
    near(
        mix(&f, up, &sun, None),
        0.5 * (sh::land_flux(GRASS, k, 0.0, 0.5, &cfg) + sh::land_flux(BARE, k, 0.0, 0.5, &cfg)),
        1e-3,
        "смесь",
    );
    // Сумма 0 → NONE.
    near(
        mix(&[0.0; CLASS_COUNT], up, &sun, None),
        sh::land_flux(sh::NONE, k, 0.0, 0.5, &cfg),
        1e-3,
        "сумма 0 → NONE",
    );
    // Ночь: H < 0.
    assert!(
        mix(&fr(GRASS), up, &sun_of(-10.0), None) < 0.0,
        "ночью H < 0"
    );
    // Вода: тёплая - по water_flux, нет данных воды - 0, лёд - как снег.
    let wd = WaterIn {
        t_water_c: 12.0,
        t_air_c: 17.0,
        u_ms: 3.0,
        z_m: 0.0,
    };
    near(
        mix(&fr(WATER), up, &sun, Some(&wd)),
        sh::water_flux(12.0, 17.0, 3.0, &cfg, 0.0),
        1e-3,
        "вода",
    );
    assert_eq!(mix(&fr(WATER), up, &sun, None), 0.0, "нет данных воды → 0");
    let ice = WaterIn {
        t_water_c: 0.0,
        t_air_c: 5.0,
        u_ms: 3.0,
        z_m: 0.0,
    };
    near(
        mix(&fr(WATER), up, &sun, Some(&ice)),
        sh::land_flux(sh::SNOW, k, 0.0, 0.5, &cfg),
        1e-3,
        "лёд = снег",
    );
    // Наклон: к солнцу > ровно > от солнца.
    let ht = mix(&fr(2), [0.0, 1.0, 0.5], &sun, None);
    let hp = mix(&fr(2), up, &sun, None);
    let hw = mix(&fr(2), [0.0, 1.0, -0.5], &sun, None);
    assert!(ht > hp && hp > hw, "к солнцу > ровно > от солнца");
    // Застройка ночью - отдельная ветка: пол + остаток заката (built_night_flux), не суша.
    let night = Sky {
        night: Some(Night {
            sin_s: 0.2,
            dt_h: 1.0,
        }),
        ..sky
    };
    let hb = sh::mix_flux(&fr(sh::BUILT), up, &sun_of(-10.0), 0.5, &night, None, &cfg);
    near(
        hb,
        sh::built_night_flux(
            &Night {
                sin_s: 0.2,
                dt_h: 1.0,
            },
            0.0,
            0.5,
            &cfg,
        ),
        1e-9,
        "застройка ночью",
    );
}

#[test]
fn deterministic() {
    let cfg = heat();
    let run = || sh::land_flux(2, sh::shortwave(0.7, 0.7, 0.3, &cfg), 0.3, 0.42, &cfg);
    assert_eq!(run().to_bits(), run().to_bits(), "побитно");
}

// ---------------------------------------------------------------- SurfaceHeating

fn heating_of(w: &Weather, enabled: Option<bool>) -> SurfaceHeating {
    let mut h = w.configs().wm.raw["heating"].clone();
    if let Some(e) = enabled {
        h["enabled"] = Value::Bool(e);
    }
    SurfaceHeating::new(51.87, 85.87, 7, 15, 7.0, &h)
}

#[test]
fn rocks_lag_behind_meadow() {
    let w = real_weather();
    let h = heating_of(&w, None);
    let d19 = h.directions(19.5).expect("включено");
    assert_eq!(d19.len(), CLASS_COUNT, "по направлению на класс");
    let (meadow, rock, built) = (d19[GRASS][1], d19[BARE][1], d19[sh::BUILT][1]);
    assert!(rock > meadow, "вечером камни «видят» солнце выше, чем луг");
    assert!(built > rock, "деревня - ещё дольше");
    // Утром наоборот: камни ещё холодные.
    let d8 = h.directions(8.0).unwrap();
    assert!(d8[BARE][1] < d8[GRASS][1], "утром камни отстают");
    // Ночью - ноль.
    assert_eq!(
        h.directions(2.0).unwrap()[GRASS],
        [0.0; 3],
        "ночью не греет"
    );
}

#[test]
fn disabled_returns_none() {
    let w = real_weather();
    // GD: `directions().is_empty()` - «выключено - текущее солнце»; в крейте - `None`.
    assert!(heating_of(&w, Some(false)).directions(13.0).is_none());
}

// ---------------------------------------------------------------- грозы редкие (шанс по запасу)

fn row_chance(w: &Weather, margin: f64) -> f64 {
    let rows = w.configs().wm.raw["clouds_by_margin"].as_array().unwrap();
    interp_rows(rows, "margin_m", margin)["cb_thermal_chance"]
        .as_f64()
        .unwrap()
}

fn chance(w: &Weather, temp: f64, hour: f64, sky: &str) -> f64 {
    let d = w.derive(
        &forecast(temp, 11.0, 270.0, sky),
        &w.reference_context(),
        hour,
    );
    d.get("cb_thermal_chance")
        .and_then(Value::as_f64)
        .unwrap_or(0.0)
}

#[test]
fn chance_grows_with_heat() {
    let w = real_weather();
    // Запас в Онгудае: +24 → ~550–590 м, +26 → 650–690, +30 → 850–890, +34 → 1050–1090.
    assert_eq!(row_chance(&w, 600.0), 0.0, "до +25 гроз нет");
    assert!(row_chance(&w, 690.0) <= 1.0e-4, "+26 - почти без гроз");
    assert!(
        row_chance(&w, 870.0) > row_chance(&w, 690.0) * 10.0,
        "+30 - заметно чаще +26"
    );
    assert!(
        row_chance(&w, 1070.0) > row_chance(&w, 870.0),
        "+34 - ещё чаще"
    );
    let mut prev = 0.0;
    for m in (0..1500).step_by(50) {
        let c = row_chance(&w, m as f64);
        assert!(c >= prev, "доля Cb растёт с запасом ({m} м)");
        prev = c;
    }
    assert_eq!(chance(&w, 38.0, 10.0, "clear"), 0.0, "утром гроз нет");
    assert!(chance(&w, 38.0, 15.0, "clear") > 0.0, "днём в жару есть");
    assert!(
        chance(&w, 38.0, 15.0, "partly") < chance(&w, 38.0, 15.0, "clear"),
        "переменная - реже"
    );
    assert_eq!(
        chance(&w, 38.0, 15.0, "overcast"),
        0.0,
        "облачно - без гроз"
    );
}

// ---------------------------------------------------------------- HH7: ClimateGrid

const AT_KEYS: usize = 10;

#[test]
fn climate_grid_keys() {
    let w = real_weather();
    let r = w.climate_at(51.9, 85.9, 7, 15);
    let vals = [
        r.td_c, r.td_sd_k, r.z_cell_m, r.t700_c, r.z700_m, r.tx_c, r.dtr_k, r.wr, r.trop_m, r.hcc,
    ];
    assert_eq!(vals.len(), AT_KEYS);
    assert!(
        vals.iter().all(|v| v.is_finite()),
        "at: все ключи - конечные числа"
    );
    for s in [&r.src.hh1, &r.src.hh2, &r.src.hh5, &r.src.hh6] {
        assert!(["data", "stub", "none"].contains(&s.as_str()), "src {s}");
    }
    let ctx = PlaceCtx {
        month: 7,
        day: 15,
        lat: 51.9,
        lon: 85.9,
        utc_offset_h: f64::NAN,
        valley_msl_m: 304.0,
        mean_msl_m: f64::NAN,
        start_msl_m: f64::NAN,
    };
    let p = w.climate_place(&ctx);
    assert!(p.gain_per_km > 0.0, "place: gain_per_km > 0");
    assert!(
        p.t700_c == r.t700_c && p.hcc == r.hcc,
        "place: 700 гПа и hcc без поправки"
    );
    assert_eq!(p, w.climate_place(&ctx), "place детерминирован");
}

#[test]
fn climate_grid_altai_raw() {
    let w = real_weather();
    let r = w.climate_at(51.9, 85.9, 7, 15);
    if r.src.hh1 != "data" {
        return;
    }
    // независимый разбор: распаковка и билинейно по 4 ячейкам июля
    let b = unpack(&real_file("hh1"));
    assert!(b.len() > HEADER);
    let sc = f32::from_le_bytes(b[32..36].try_into().unwrap()) as f64;
    let off = f32::from_le_bytes(b[36..40].try_into().unwrap()) as f64;
    let body = &b[HEADER..];
    let (x, y): (f64, f64) = (85.9 + 179.5, 51.9 + 89.5);
    let (i0, j0) = (x.floor() as usize, y.floor() as usize);
    let (fi, fj) = (x - x.floor(), y - y.floor());
    let mut acc = 0.0;
    for dj in 0..2 {
        for di in 0..2 {
            let o = 2 * ((6 * 180 + j0 + dj) * 360 + i0 + di);
            let v = i16::from_le_bytes([body[o], body[o + 1]]) as f64;
            acc += (v * sc + off)
                * (if di == 1 { fi } else { 1.0 - fi })
                * (if dj == 1 { fj } else { 1.0 - fj });
        }
    }
    near(r.td_c, acc, 0.05, "Алтай, июль: td_c по сырым байтам");
}

#[test]
fn climate_grid_bilinear_and_wrap() {
    let w = real_weather();
    let a = w.climate_at(51.5, 85.5, 7, 15);
    let b = w.climate_at(51.51, 85.51, 7, 15);
    near(a.td_c, b.td_c, 0.1, "в пределах 0.01° значение почти то же");
    let (we, ea) = (
        w.climate_at(10.0, 179.99, 7, 15),
        w.climate_at(10.0, -179.99, 7, 15),
    );
    near(we.td_c, ea.td_c, 0.5, "±180°: нет разрыва по Td");
    assert_eq!(
        w.climate_at(10.0, 540.0, 7, 15).td_c,
        w.climate_at(10.0, 180.0, 7, 15).td_c,
        "долгота по кругу"
    );
}

#[test]
fn climate_grid_month_continuity() {
    let w = real_weather();
    let (d31, j1) = (
        w.climate_at(51.9, 85.9, 12, 31),
        w.climate_at(51.9, 85.9, 1, 1),
    );
    near(d31.td_c, j1.td_c, 0.6, "декабрь ↔ январь непрерывно (Td)");
    near(d31.tx_c, j1.tx_c, 1.0, "декабрь ↔ январь непрерывно (Tx)");
    let (m, n) = (
        w.climate_at(51.9, 85.9, 7, 15),
        w.climate_at(51.9, 85.9, 7, 16),
    );
    near(m.td_c, n.td_c, 0.5, "день за днём - плавно");
}

fn check_fallback(w: &Weather) {
    let cfg = raw_cfg("weather_model");
    let r = w.climate_at(51.9, 85.9, 7, 15);
    for s in [&r.src.hh1, &r.src.hh2, &r.src.hh5, &r.src.hh6] {
        assert_eq!(s, "none", "нет файла: src = none");
    }
    near(
        r.td_c,
        fnum(&cfg, "/climate/fallback/td_c/6"),
        1e-6,
        "td_c из конфига",
    );
    near(
        r.td_sd_k,
        fnum(&cfg, "/climate/td_sd_fallback_k"),
        1e-6,
        "σ из конфига",
    );
    near(
        r.t700_c,
        fnum(&cfg, "/upper_air/temp_c/6"),
        1e-6,
        "t700 из upper_air",
    );
    near(
        r.z700_m,
        fnum(&cfg, "/upper_air/z_msl_m"),
        1e-6,
        "z700 из upper_air",
    );
    near(
        r.tx_c,
        fnum(&cfg, "/typical_max_c/6"),
        1e-6,
        "tx из typical_max_c",
    );
    near(
        r.dtr_k,
        fnum(&cfg, "/diurnal/range_k/6"),
        1e-6,
        "dtr из diurnal.range_k",
    );
    near(
        r.trop_m,
        fnum(&cfg, "/tropopause_msl_m"),
        1e-6,
        "тропопауза из конфига",
    );
}

#[test]
fn climate_grid_no_file() {
    // сеток нет вообще
    check_fallback(&no_grids_weather());
    // GD `set_paths` на несуществующие файлы: игра не отдаёт крейту байт - то же, что пустые байты
    let empty: Vec<(&str, &[u8])> = GRID_NAMES.iter().map(|g| (*g, &[][..])).collect();
    let w = Weather::new(&Configs::new(cfg_files()), ClimateGrids::from_bytes(&empty)).unwrap();
    check_fallback(&w);
}

#[test]
fn climate_grid_speed() {
    let w = real_weather();
    w.climate_at(40.0, 30.0, 7, 15);
    let n = 500;
    let t0 = std::time::Instant::now();
    for k in 0..n {
        let k = k as f64;
        w.climate_at(
            40.0 + k * 0.01,
            30.0 + k * 0.013,
            1 + (k as i64) % 12,
            1 + (k as i64) % 28,
        );
    }
    let us = t0.elapsed().as_secs_f64() * 1e6 / n as f64;
    // GD: PERF_LIMIT_US = 300; тестовый профиль без оптимизации медленнее в разы.
    let limit = if cfg!(debug_assertions) {
        3000.0
    } else {
        300.0
    };
    assert!(us < limit, "at() {us:.1} мкс < {limit}");
}

fn gradient_table<'a>(cfg: &'a Value, key: &str) -> Option<&'a Value> {
    cfg.pointer(&format!("/climate/{key}"))
}

#[test]
fn climate_grid_belt_gradients() {
    let cfg = raw_cfg("weather_model");
    let tx = gradient_table(&cfg, "tx_gradient_k_per_km");
    let dtr = gradient_table(&cfg, "dtr_gradient_k_per_km");
    near(
        belt_gradient(52.0, 1, tx, 0.0),
        -7.83,
        1e-9,
        "Tx 30–60°, МАМ",
    );
    near(belt_gradient(-17.0, 0, tx, 0.0), -5.47, 1e-9, "Tx тропики");
    near(belt_gradient(25.0, 0, dtr, 0.0), -0.48, 1e-9, "DTR прочее");
    near(
        belt_gradient(52.0, 0, None, -6.3),
        -6.3,
        1e-9,
        "нет таблицы - по умолчанию",
    );
}

/// HH-4c: градиенты в конфиге = pooled по поясам из `gradient.json` (исследовательские данные).
#[test]
fn belt_gradients_match_research() {
    let p = repo().join("tools/research/haze_humidity/surface_t/gradient.json");
    let Ok(text) = std::fs::read_to_string(p) else {
        return; // исследовательских данных нет в сборке
    };
    let gj: Value = serde_json::from_str(&text).unwrap();
    let cfg = raw_cfg("weather_model");
    for (src_key, cfg_key) in [
        ("tx", "tx_gradient_k_per_km"),
        ("dtr", "dtr_gradient_k_per_km"),
    ] {
        let c = gradient_table(&cfg, cfg_key).unwrap();
        for (s, key) in ["DJF", "MAM", "JJA", "SON"].iter().enumerate() {
            near(
                fnum(c, &format!("/mid/{s}")),
                fnum(
                    &gj,
                    &format!("/{src_key}/land_30_60N/{key}/pooled_k_per_km"),
                ),
                0.0051,
                &format!("{src_key} 30–60°, {key}"),
            );
        }
        near(
            fnum(c, "/tropics"),
            fnum(
                &gj,
                &format!("/{src_key}/land_tropics_20S_20N/year/pooled_k_per_km"),
            ),
            0.0051,
            &format!("{src_key} тропики"),
        );
        near(
            fnum(c, "/other"),
            fnum(&gj, &format!("/{src_key}/land_global/year/pooled_k_per_km")),
            0.0051,
            &format!("{src_key} прочее"),
        );
    }
    // физические границы: Tx падает с высотой, не быстрее сухоадиабатического 9,8 К/км
    for g in cfg
        .pointer("/climate/tx_gradient_k_per_km/mid")
        .unwrap()
        .as_array()
        .unwrap()
    {
        let g = g.as_f64().unwrap();
        assert!(g < 0.0 && g > -9.8, "Tx 30–60°: {g} К/км в (−9,8; 0)");
    }
}

fn place_ctx(lat: f64, lon: f64, month: i64, valley: f64, start: f64) -> PlaceCtx {
    PlaceCtx {
        month,
        day: 15,
        lat,
        lon,
        utc_offset_h: f64::NAN,
        valley_msl_m: valley,
        mean_msl_m: f64::NAN,
        start_msl_m: start,
    }
}

/// HH-4c: юг - те же пояса и значения, сезон сдвинут на полгода; поправка Tx на высоту долины
/// идёт по этому сезону.
#[test]
fn southern_belt_gradients_season_shift() {
    let w = real_weather();
    let cfg = raw_cfg("weather_model");
    let tx = gradient_table(&cfg, "tx_gradient_k_per_km");
    let dtr = gradient_table(&cfg, "dtr_gradient_k_per_km");
    let mid = |t: Option<&Value>, i: usize| fnum(t.unwrap(), &format!("/mid/{i}"));
    near(
        belt_gradient(-45.0, season_index(1, -45.0), tx, 0.0),
        mid(tx, 2),
        1e-9,
        "Tx 45° ю. ш., январь = ИИА",
    );
    near(
        belt_gradient(-45.0, season_index(7, -45.0), dtr, 0.0),
        mid(dtr, 0),
        1e-9,
        "DTR 45° ю. ш., июль = ДЯФ",
    );
    near(
        belt_gradient(-30.0, 0, tx, 0.0),
        mid(tx, 0),
        1e-9,
        "граница 30° ю. ш. - пояс",
    );
    near(
        belt_gradient(-60.0, 0, tx, 0.0),
        mid(tx, 0),
        1e-9,
        "граница 60° ю. ш. - пояс",
    );
    near(
        belt_gradient(-61.0, 0, tx, 0.0),
        fnum(tx.unwrap(), "/other"),
        1e-9,
        "за 60° - прочее",
    );
    // целиком через climate_place: Южные Анды (−38°, −71°)
    for month in [1, 7] {
        let p0 = w.climate_place(&place_ctx(-38.0, -71.0, month, f64::NAN, f64::NAN));
        if p0.src.hh5 == "none" || p0.src.hh1 == "none" {
            return; // нет сеток - только конфиг (выше)
        }
        let p1 = w.climate_place(&place_ctx(
            -38.0,
            -71.0,
            month,
            p0.z_cell_m + 1000.0,
            f64::NAN,
        ));
        let s = season_index(month, -38.0);
        near(
            p1.tx_c - p0.tx_c,
            mid(tx, s),
            1e-6,
            &format!("Tx +1 км, мес. {month} (юг)"),
        );
        let d = p1.dtr_k - p0.dtr_k;
        assert!(
            (d <= 0.0 && d >= mid(dtr, s) - 1e-6) || p0.dtr_k + mid(dtr, s) < 0.0,
            "DTR +1 км не растёт (мес. {month}, {d:.2})"
        );
    }
}

/// HH-4c: нет HH1 (Z ячейки неизвестна, 0), HH6 есть: рост ветра - от высоты долины места.
#[test]
fn gain_without_hh1_uses_valley() {
    let w = Arc::new(common::weather_of(&common::real_grids(&["hh1"])));
    let p0 = w.climate_place(&place_ctx(51.9, 85.9, 7, f64::NAN, f64::NAN));
    if p0.src.hh6 == "none" {
        return;
    }
    assert_eq!(p0.src.hh1, "none", "HH1 нет");
    near(
        p0.gain_per_km,
        (p0.wr - 1.0) * 1000.0 / p0.z700_m.max(500.0),
        1e-9,
        "без высоты места - от уровня моря",
    );
    let p1 = w.climate_place(&place_ctx(51.9, 85.9, 7, 1500.0, f64::NAN));
    near(
        p1.gain_per_km,
        (p1.wr - 1.0) * 1000.0 / (p1.z700_m - 1500.0).max(500.0),
        1e-9,
        "от высоты долины",
    );
    assert!(
        p1.gain_per_km.abs() > p0.gain_per_km.abs(),
        "выше место - тоньше слой - больше рост ветра на км"
    );
    near(
        p1.td_c,
        p0.td_c,
        1e-9,
        "без HH1 поправки на высоту к Td нет",
    );
}

/// HH-4e (HH7 v2): рост ветра от ветра на высоте старта; профиль линейный V10→V700.
#[test]
fn gain_from_start_height() {
    let w = real_weather();
    let q = |start: f64| w.climate_place(&place_ctx(51.9, 85.9, 7, 304.0, start));
    let p0 = q(f64::NAN);
    if p0.src.hh6 == "none" || p0.src.hh1 == "none" {
        return;
    }
    let zc = p0.z_cell_m;
    let d = (p0.z700_m - zc).max(500.0);
    let wm1 = p0.wr - 1.0;
    let p1 = q(zc + 0.5 * d);
    near(
        p1.gain_per_km,
        wm1 * 1000.0 / (d * (1.0 + wm1 * 0.5)),
        1e-9,
        "f = 0,5",
    );
    assert!(
        p1.gain_per_km.abs() < p0.gain_per_km.abs(),
        "старт выше - рост на км меньше (wr > 1)"
    );
    let vs = 1.0 + wm1 * 0.5;
    near(
        1.0 + p1.gain_per_km * (p1.z700_m - (zc + 0.5 * d)) / 1000.0,
        p1.wr / vs,
        1e-9,
        "V700/Vs",
    );
    near(
        q(zc + 5.0 * d).gain_per_km,
        wm1 * 1000.0 / (d * (1.0 + wm1 * 0.9)),
        1e-9,
        "f ≤ 0,9",
    );
    near(q(zc - 500.0).gain_per_km, wm1 * 1000.0 / d, 1e-9, "f ≥ 0");
}

// ---------------------------------------------------------------- климат со сдвигом (RW-6v)

/// Месяц и день по номеру дня года (365 дней), как сдвиг даты на `lag_days` с переходом года.
fn month_day(mut doy: i64) -> (i64, i64) {
    for m in 1..=12 {
        let dim = days_in_month(m);
        if doy <= dim {
            return (m, doy);
        }
        doy -= dim;
    }
    (12, 31)
}

fn lag_days(w: &Weather) -> i64 {
    w.configs().sh.water.lag_days.round() as i64
}

fn lag_case(tag: &str, lat: f64, lon: f64, m: i64, d: i64, want: [f64; 2], want_lag: [f64; 2]) {
    let w = real_weather();
    let mut doy = day_of_year(m, d) - lag_days(&w);
    if doy < 1 {
        doy += 365;
    }
    let (m2, d2) = month_day(doy);
    // плоское место на нулевой высоте: долина 0
    let at = |mm, dd| {
        w.climate_place(&PlaceCtx {
            month: mm,
            day: dd,
            ..place_ctx(lat, lon, mm, 0.0, f64::NAN)
        })
    };
    let (c, l) = (at(m, d), at(m2, d2));
    if c.src.hh5 == "none" {
        return; // нет сеток климата
    }
    let (d_tx, d_dtr) = (l.tx_c - c.tx_c, l.dtr_k - c.dtr_k);
    assert!(
        (d_tx - (want_lag[0] - want[0])).abs() <= 0.002
            && (d_dtr - (want_lag[1] - want[1])).abs() <= 0.002,
        "{tag}: lag − {d}.{m:02} = ({d_tx}, {d_dtr}), ждали ({}, {})",
        want_lag[0] - want[0],
        want_lag[1] - want[1]
    );
    near(c.tx_c, want[0], 0.2, &format!("{tag}: tx_c"));
    near(l.tx_c, want_lag[0], 0.2, &format!("{tag}: tx_c со сдвигом"));
}

#[test]
fn training_island_lag_is_a_month_back() {
    lag_case(
        "учебный",
        43.2,
        34.0,
        7,
        15,
        [24.839, 1.385],
        [22.228, 1.436],
    );
}

#[test]
fn volcano_island_lag_crosses_the_year() {
    lag_case(
        "вулканический",
        -27.1,
        -109.35,
        1,
        15,
        [23.579, 0.945],
        [22.361, 0.968],
    );
}

#[test]
fn month_day_wraps_the_year() {
    assert_eq!(month_day(day_of_year(3, 10) - 30), (2, 8));
    assert_eq!(month_day(day_of_year(1, 15) - 30 + 365), (12, 16));
}

/// Температура воды берёт воздух на дату со сдвигом `lag_days` (в GD - `loc.climate_lag`, W5 v7;
/// теперь внутри крейта): среднесуточный воздух на сдвинутую дату и амплитуду того же дня.
#[test]
fn water_temp_follows_the_shifted_date() {
    let w = real_weather();
    let ctx = PlaceCtx {
        utc_offset_h: 0.0,
        ..place_ctx(51.5, 86.5, 3, 0.0, f64::NAN)
    };
    let mut doy = day_of_year(3, 10) - lag_days(&w);
    if doy < 1 {
        doy += 365;
    }
    let (m2, d2) = month_day(doy);
    let c2 = PlaceCtx {
        month: m2,
        day: d2,
        ..ctx
    };
    let t_max = w.typical_max_c(m2, d2, ctx.lat, ctx.lon, ctx.valley_msl_m);
    let mean: f64 = (0..24)
        .map(|i| w.diurnal_state(t_max, i as f64 + 0.5, &c2).temperature_c)
        .sum::<f64>()
        / 24.0;
    near(
        w.water_temp_c(3, 10, 0.0, &ctx),
        mean.max(0.0),
        1e-9,
        "water_temp_c = среднесуточный воздух на дату − lag_days",
    );
}

// ---------------------------------------------------------------- рост ветра без места/Weather (ревью RW-14c)

fn gain_conditions(gain: Option<f64>) -> dp_air::Conditions {
    let mut wr = serde_json::json!({"ref_msl": 800.0});
    if let Some(g) = gain {
        wr["gain_per_km"] = g.into();
    }
    dp_air::Conditions::from_json(
        &serde_json::json!({
            "forecast": {"temperature_c": 24.0, "wind_speed_kmh": 12.0, "wind_from_deg": 151.0, "sky": "clear"},
            "wind_ref": wr, "start_hour": 12.0, "speed": 1.0, "quantum_h": 0.1,
        })
        .to_string(),
    )
    .unwrap()
}

/// Рост ветра на км, как его видит профиль: `altitude_factor(ref + 1 км) − 1`.
fn terms_gain(t: &dp_air::terms::Terms) -> f64 {
    t.wind.altitude_factor(1800.0) - 1.0
}

/// Условия без `wind_ref.gain_per_km` и без `Weather` (и без места): рост ветра - запасной климат
/// (`climate.fallback`: `altitude_gain_per_km` конфига), а не остаток от прошлых условий.
#[test]
fn gain_without_weather_is_climate_fallback() {
    let mut t = dp_air::terms::Terms::default();
    t.configure(&Arc::new(Configs::new(cfg_files())), 1);
    let fallback = raw_cfg("atmosphere")["wind"]["altitude_gain_per_km"]
        .as_f64()
        .unwrap();
    t.set_conditions(&gain_conditions(Some(0.1)));
    near(terms_gain(&t), 0.1, 1e-12, "явный рост");
    t.set_conditions(&gain_conditions(None));
    near(
        terms_gain(&t),
        fallback,
        1e-12,
        "нет gain_per_km и Weather: запасной рост",
    );
}

/// С `Weather`, но без места: рост - климат опорной точки (52°/0°) на высоте старта.
#[test]
fn gain_with_weather_without_place_comes_from_climate() {
    let w = real_weather();
    let mut t = dp_air::terms::Terms::default();
    t.configure(&Arc::new(Configs::new(cfg_files())), 1);
    t.set_weather(w.clone());
    t.set_conditions(&gain_conditions(Some(0.1)));
    t.set_conditions(&gain_conditions(None));
    let want = w
        .climate_place(&PlaceCtx {
            month: 7,
            day: 15,
            lat: f64::NAN,
            lon: f64::NAN,
            utc_offset_h: f64::NAN,
            valley_msl_m: f64::NAN,
            mean_msl_m: f64::NAN,
            start_msl_m: 800.0,
        })
        .gain_per_km;
    near(terms_gain(&t), want, 1e-12, "рост из климата без места");
    assert!((terms_gain(&t) - 0.1).abs() > 1e-6, "не прежний рост");
}
