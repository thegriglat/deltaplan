//! `WeatherModel.derive`: прогноз + место + час -> словарь погоды с `_derived`.
use serde_json::{Map, Value, json};

use super::climate::{ClimatePlace, PlaceCtx};
use super::noise::{band_index, td_day};
use super::tables::{interp_rows, lerp_table, num, num_value, nums};
use crate::Forecast;
use crate::field::sun::{day_of_year, lerp};
use crate::field::weather_core::{
    Ctx, DiurnalState, WeatherModelCfg, season_index, sun_elevation_deg,
};

/// Ускорение свободного падения, м/с² (частота Брента — Вяйсяля).
const G: f64 = 9.81;

fn n(x: f64) -> Value {
    num_value(x)
}

fn n2(v: &Value, k: f64) -> Value {
    let a = nums(Some(v));
    Value::Array(vec![n(a[0] * k), n(a[1] * k)])
}

fn get(m: &Map<String, Value>, k: &str) -> f64 {
    m.get(k).and_then(Value::as_f64).unwrap_or(0.0)
}

/// Давление насыщенного пара над водой, гПа (Магнус, Alduchov — Eskridge 1996).
fn e_s(x_c: f64) -> f64 {
    6.1094 * (17.625 * x_c / (x_c + 243.04)).exp()
}

/// Относительная влажность 0..1 (до зажима): `e_s(Td) / e_s(T)`; `Td > T` — 1.
fn rh(t_c: f64, td_c: f64) -> f64 {
    (e_s(td_c.min(t_c)) / e_s(t_c)).min(1.0)
}

/// Густота дымки по влажности (HH3): `((1 − RH_c)/(1 − rh_dry))^(−gamma)`, `RH_c` в `[rh_dry, rh_max]`.
pub fn haze_k_rh(t_c: f64, td_c: f64, cfg: &WeatherModelCfg) -> f64 {
    let h = |k: &str, def: f64| num(&cfg.raw, &["haze_humidity", k], def);
    let dry = h("rh_dry", 0.40);
    let r = rh(t_c, td_c).clamp(dry, h("rh_max", 0.95));
    ((1.0 - r) / (1.0 - dry)).powf(-h("gamma", 0.6))
}

/// Доля перистых (0..1) на небе дня: HCC места × `k_sky(пояс, сезон, облачность)`; нет сетки HH6 —
/// `cirrus_base` (`WeatherModel.cirrus_base_cover`).
pub fn cirrus_base_cover(
    cp: &ClimatePlace,
    sky: &str,
    ctx: &PlaceCtx,
    cfg: &WeatherModelCfg,
) -> f64 {
    let c = &cfg.raw;
    let hs = c
        .get("hcc_sky")
        .filter(|v| v.as_object().is_some_and(|o| !o.is_empty()));
    let Some(hs) = hs.filter(|_| cp.src.hh6 != "none") else {
        return num(c, &["cirrus_base"], 0.1);
    };
    let ks = hs.get("k_sky");
    let tab = ks
        .and_then(|k| k.get(sky))
        .or_else(|| ks.and_then(|k| k.get("clear")))
        .and_then(Value::as_array)
        .filter(|t| !t.is_empty());
    let Some(tab) = tab else {
        return cp.hcc;
    };
    let bounds = hs
        .get("bands_abs_lat")
        .map_or_else(|| vec![20.0, 40.0, 60.0, 75.0], |b| nums(Some(b)));
    let b = band_index(ctx.lat, &bounds);
    let sn = season_index(ctx.month.clamp(1, 12), ctx.lat);
    let k = tab
        .get(b)
        .map(|r| nums(Some(r)))
        .and_then(|r| r.get(sn).copied())
        .unwrap_or(0.0);
    (cp.hcc * k).clamp(0.0, 1.0)
}

/// Покрытие пелены, которое ещё гасит солнце источникам термиков: пелена сверх облачности неба
/// прогноза (`WeatherModel.sun_block_cover`).
pub fn sun_block_cover(w: &Map<String, Value>) -> f64 {
    (get(w, "cirrus_cover") - get(w, "sky_cover")).clamp(0.0, 1.0)
}

fn sky_get(sky: &Value, k: &str, def: f64) -> f64 {
    sky.get(k).and_then(Value::as_f64).unwrap_or(def)
}

/// Прогрев: ход дня и облачность -> сила, частота, мягкость, облака, дымка (`WeatherModel._apply_heat`).
fn apply_heat(
    w: &mut Map<String, Value>,
    st: Option<&DiurnalState>,
    sky: &Value,
    cfg: &WeatherModelCfg,
) {
    let c = &cfg.raw;
    let dn = |k: &str, def: f64| num(c, &["diurnal", k], def);
    let sd = |k: &str, def: f64| num(c, &["diurnal", "soft", k], def);
    let heat_d = st.map_or(1.0, |s| s.heat);
    let heat = heat_d * sky_get(sky, "heat", 1.0);
    let soft = st.map_or(0.0, |s| s.soft).max(sky_get(sky, "soft", 0.0));
    let mut s_k = heat.powf(dn("heat_strength_exponent", 0.3333));
    s_k *= 1.0 - sd("core_k", 0.2) * soft;
    let ts = n2(&w["thermal_strength_ms"], s_k);
    w.insert("thermal_strength_ms".into(), ts);
    let tr = n2(&w["thermal_radius_m"], 1.0 + sd("radius_k", 0.3) * soft);
    w.insert("thermal_radius_m".into(), tr);
    let duty = (get(w, "thermal_duty")
        * heat_d.powf(dn("heat_duty_exponent", 1.0))
        * sky_get(sky, "duty_k", 1.0))
    .clamp(0.0, 1.0);
    w.insert("thermal_duty".into(), n(duty));
    let ct = get(w, "convective_turbulence_ms") * s_k;
    w.insert("convective_turbulence_ms".into(), n(ct));
    let cloudy =
        (1.0 - get(w, "dry_thermal_fraction")) * heat_d.powf(dn("heat_cloud_exponent", 0.5));
    w.insert("dry_thermal_fraction".into(), n(1.0 - cloudy));
    let cb_k = sky_get(sky, "cb_k", 1.0);
    for k in ["cb_chance", "cb_thermal_chance", "overdevelopment_chance"] {
        let v = get(w, k) * cb_k;
        w.insert(k.into(), n(v));
    }
    let cirrus = get(w, "cirrus_cover").max(sky_get(sky, "cover", 0.0));
    w.insert("cirrus_cover".into(), n(cirrus));
    w.insert("sky_cover".into(), n(sky_get(sky, "cover", 0.0)));
    w.insert("sky_duty_k".into(), n(sky_get(sky, "duty_k", 1.0)));
    w.insert("thermal_edge_k".into(), n(1.0 - sd("edge_k", 0.4) * soft));
    w.insert("mech_turbulence_k".into(), n(st.map_or(1.0, |s| s.mech_k)));
    let dv = w
        .get_mut("_derived")
        .and_then(Value::as_object_mut)
        .expect("_derived");
    if let Some(s) = st {
        for (k, v) in [
            ("temperature_c", s.temperature_c),
            ("cap_agl_m", s.cap_agl_m),
            ("break", s.brk),
            ("heat", s.heat),
            ("soft", s.soft),
            ("mech_k", s.mech_k),
            ("sunrise_h", s.sunrise_h),
            ("sunset_h", s.sunset_h),
            ("peak_h", s.peak_h),
        ] {
            dv.insert(k.into(), n(v));
        }
    }
    let t_c = get(dv, "temperature_c");
    let td_c = get(dv, "dew_point_c");
    dv.insert("rh".into(), n(rh(t_c, td_c)));
    let haze = haze_k_rh(t_c, td_c, cfg);
    dv.insert("heat".into(), n(heat));
    dv.insert("soft".into(), n(soft));
    w.insert("haze_k".into(), n(haze));
}

/// Прогноз в месте `ctx` в час `hour` (часы места; NaN — «разгар дня», температура = максимум) ->
/// словарь погоды с теми же ключами, что у `WeatherModel.derive`, и вложенным `_derived`. `climate` —
/// [`climate_place`](super::climate_place) для этого места и даты (без `start_msl_m`, как внутри GD
/// `derive`). Нечисла (inf) на выходе — `null`. Детерминированно.
pub fn derive(
    forecast: &Forecast,
    ctx: &PlaceCtx,
    hour: f64,
    climate: &ClimatePlace,
    cfg: &WeatherModelCfg,
) -> Map<String, Value> {
    let c = &cfg.raw;
    let cp = climate;
    let month = ctx.month.clamp(1, 12);
    let day = ctx.day;
    let lat = ctx.lat;
    let h_v = ctx.valley_msl_m / 1000.0;
    let h_m = ctx.mean_msl_m;
    let t_max = forecast.temperature_c;
    let wind_kmh = forecast.wind_speed_kmh.max(0.0);
    let sky_name = forecast.sky.as_str();
    let mut t = t_max;
    let mut diurnal: Option<DiurnalState> = None;
    if !hour.is_nan() && c.pointer("/diurnal/enabled").and_then(Value::as_bool) == Some(true) {
        let wctx = Ctx {
            month,
            day,
            lat,
            lon: ctx.lon,
            utc_offset_h: ctx.utc_offset_h,
            valley_msl_m: ctx.valley_msl_m,
            mean_msl_m: ctx.mean_msl_m,
        };
        let d = cfg.diurnal_state_amp(t_max, hour, &wctx, cp.dtr_k);
        t = d.temperature_c;
        diurnal = Some(d);
    }

    // высота термиков и кромка (§2.2), км над морем
    let t_u = cp.t700_c;
    let z_u = cp.z700_m / 1000.0;
    let gam = num(c, &["upper_air", "lapse_k_per_km"], 4.0);
    let dry = num(c, &["dry_adiabat_k_per_km"], 9.8);
    let td = td_day(t_max, sky_name, cp, ctx, cfg).min(t);
    let excess = num(c, &["parcel_excess_k"], 1.0);
    let mut z_dry = h_v + (t + excess - t_u - gam * (z_u - h_v)) / (dry - gam);
    if let Some(d) = diurnal.filter(|d| d.cap_agl_m.is_finite()) {
        let z_cap = z_dry.min(h_v + d.cap_agl_m / 1000.0);
        z_dry = lerp(z_cap, z_dry, d.brk);
    }
    let z_lcl = h_v + num(c, &["lcl_m_per_k"], 122.0) / 1000.0 * (t - td);
    let margin = (z_dry - z_lcl) * 1000.0;
    let z_top = z_dry.min(z_lcl) * 1000.0;
    let cl = nums(c.get("cloudbase_agl_clamp_m"));
    let top_agl = z_top - h_m;
    let top_agl = top_agl.clamp(cl[0], cl[1]);
    let blue = margin < num(c, &["blue_margin_m"], -100.0);

    // сила, размер, частота (§2.3)
    let rows = |k: &str| {
        c.get(k)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    };
    let a = interp_rows(&rows("anchors_by_top_agl"), "top_agl_m", top_agl);
    let doy = day_of_year(month, day);
    let sun_el = sun_elevation_deg(lat, 0.0, doy, 12.0, f64::NAN);
    let sun = |k: &str, def: f64| num(c, &["sun", k], def);
    let clamp_sun = nums(c.pointer("/sun/clamp"));
    let mut sun_k = (sun_el.to_radians().sin().max(0.0)
        / sun("ref_elevation_deg", 59.5).to_radians().sin())
    .powf(sun("exponent", 0.5));
    sun_k = sun_k.clamp(clamp_sun[0], clamp_sun[1]);
    let wf = |k: &str| nums(c.pointer(&format!("/wind_factors/{k}")));
    let wind_k = lerp_table(&wf("wind_kmh"), &wf("strength"), wind_kmh);
    let duty_k = lerp_table(&wf("wind_kmh"), &wf("duty"), wind_kmh);
    let dust_wind_k = lerp_table(&wf("dust_wind_kmh"), &wf("dust"), wind_kmh);
    let strength_k = sun_k * wind_k;
    let duty = get(&a, "thermal_duty") * sun_k.sqrt() * duty_k;

    // облака по запасу (§2.4)
    let cloud = interp_rows(&rows("clouds_by_margin"), "margin_m", margin);
    let cn = |k: &str, def: f64| num(c, &["constants", k], def);
    let mut dry_frac = get(&cloud, "dry_thermal_fraction");
    let mut cloud_min = cn("cloud_min_strength_ms", 1.0);
    let cloud_depth = get(&cloud, "cloud_depth_m");
    let mut overdev = get(&cloud, "overdevelopment_chance");
    let mut cb = get(&cloud, "cb_chance");
    let mut cb_th = cloud
        .get("cb_thermal_chance")
        .map_or(cb, |v| v.as_f64().unwrap_or(0.0));
    if blue {
        dry_frac = 1.0;
        cloud_min = num(c, &["blue_cloud_min_strength_ms"], 99.0);
        overdev = 0.0;
        cb = 0.0;
        cb_th = 0.0;
    }
    let st = |k: &str| num(c, &["storm", k], 0.0);
    let street = if blue {
        num(c, &["street_strength", "blue"], 0.0)
    } else {
        num(c, &["street_strength", "cumulus"], 0.0)
    };
    let dust = lerp_table(
        &nums(c.pointer("/dust_by_top_agl/top_agl_m")),
        &nums(c.pointer("/dust_by_top_agl/chance")),
        top_agl,
    ) * dust_wind_k;

    // волна (скрыто, §2.8)
    let wv = |k: &str| num(c, &["wave", k], 0.0);
    let mut wave_strength = 0.0;
    if c.pointer("/wave/enabled").and_then(Value::as_bool) == Some(true) {
        wave_strength = wv("max_strength")
            * ((wind_kmh - wv("min_wind_kmh"))
                / (wv("full_wind_kmh") - wv("min_wind_kmh")).max(1.0))
            .clamp(0.0, 1.0)
            * ((wv("max_top_agl_m") - top_agl) / wv("fade_top_m")).clamp(0.0, 1.0);
    }
    let t_k = t + 273.15;
    let n_bv = (G / t_k * (dry - gam) / 1000.0).sqrt();

    let cirrus = (cirrus_base_cover(cp, sky_name, ctx, cfg) + st("cirrus_k") * cb).clamp(0.0, 1.0);
    let extreme = lerp_table(
        &nums(c.pointer("/extreme_by_top_agl/top_agl_m")),
        &nums(c.pointer("/extreme_by_top_agl/chance")),
        top_agl,
    ) + st("extreme_k") * cb;
    let sun_noon = sun_el;
    let sun_elev = if hour.is_nan() {
        sun_noon
    } else {
        sun_elevation_deg(lat, ctx.lon, doy, hour, ctx.utc_offset_h)
    };
    let av = |k: &str| a.get(k).cloned().unwrap_or(Value::Null);

    let mut w = Map::new();
    let mut put = |k: &str, v: Value| {
        w.insert(k.to_string(), v);
    };
    put("wind_speed_kmh", n(wind_kmh));
    put("wind_from_deg", n(forecast.wind_from_deg));
    put("cloudbase_agl_m", n(top_agl));
    put(
        "thermal_strength_ms",
        n2(&av("thermal_strength_ms"), strength_k),
    );
    put("thermal_radius_m", n2(&av("thermal_radius_m"), 1.0));
    put(
        "thermal_spacing_m",
        n(get(&a, "thermal_spacing_m") * (1.0 + st("spacing_k") * cb)),
    );
    put("thermal_duty", n(duty.clamp(0.0, 1.0)));
    put(
        "background_sink_ms",
        n(get(&a, "background_sink_ms") + st("sink_k") * cb),
    );
    put(
        "convective_turbulence_ms",
        n(get(&a, "convective_turbulence_ms") * strength_k),
    );
    put("cloud_min_strength_ms", n(cloud_min));
    put("cloud_depth_m", n(cloud_depth));
    put("thermal_mode", json!("dynamic"));
    put("static_thermals", json!([]));
    put("street_strength", n(street));
    put("overdevelopment_chance", n(overdev));
    put(
        "cloud_size_factor",
        n(get(&a, "cloud_size_factor") + st("cloud_size_k") * cb),
    );
    put("cirrus_cover", n(cirrus));
    put("cb_chance", n(cb));
    put("cb_thermal_chance", n(cb_th));
    put("thermal_edge_k", n(1.0));
    put("mech_turbulence_k", n(1.0));
    put("haze_k", n(1.0));
    put(
        "cb_top_above_base_m",
        n((cp.trop_m - z_lcl * 1000.0).max(1000.0)),
    );
    put("wave_strength", n(wave_strength));
    put("stability_n_per_s", n(n_bv));
    put(
        "lens_level_above_crest_m",
        n(cn("lens_level_above_crest_m", 2200.0)),
    );
    put("dry_thermal_fraction", n(dry_frac));
    put("thermal_extreme_chance", n(extreme));
    let ext = c
        .pointer("/constants/thermal_extreme_ms")
        .cloned()
        .unwrap_or(Value::Null);
    put("thermal_extreme_ms", n2(&ext, 1.0));
    put("dust_devil_chance", n(dust));
    put(
        "_derived",
        json!({
            "temperature_c": n(t),
            "upper_temp_c": n(t_u),
            "dew_point_c": n(td),
            "td_climate_c": n(cp.td_c),
            "tx_climate_c": n(cp.tx_c),
            "dtr_k": n(cp.dtr_k),
            "trop_msl_m": n(cp.trop_m),
            "gain_per_km": n(cp.gain_per_km),
            "climate_src": {"hh1": cp.src.hh1, "hh2": cp.src.hh2, "hh5": cp.src.hh5, "hh6": cp.src.hh6},
            "valley_msl_m": n(h_v * 1000.0),
            "mean_msl_m": n(h_m),
            "z_dry_msl_m": n(z_dry * 1000.0),
            "z_lcl_msl_m": n(z_lcl * 1000.0),
            "margin_m": n(margin),
            "top_agl_m": n(top_agl),
            "blue": blue,
            "sun_noon_deg": n(sun_noon),
            "sun_elev_deg": n(sun_elev),
            "sun_k": n(sun_k),
            "wind_k": n(wind_k),
            "sky": sky_name,
        }),
    );
    let skies = c.get("sky");
    let sky_p = skies
        .and_then(|s| s.get(sky_name))
        .or_else(|| skies.and_then(|s| s.get("clear")))
        .cloned()
        .unwrap_or_else(|| json!({}));
    apply_heat(&mut w, diurnal.as_ref(), &sky_p, cfg);
    w
}
