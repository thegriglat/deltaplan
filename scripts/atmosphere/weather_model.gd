class_name WeatherModel
extends RefCounted
## Погода из прогноза (FR-16): температура днём + ветер (+ дата и место) → словарь погоды с теми же
## ключами, что у эталонов configs/weather/* (Atmosphere.set_weather принимает словарь).
## Только чистые статические функции. Параметры — configs/weather_model.json, описание —
## docs/atmosphere.md → «Погода из прогноза».
##
##   var ctx := WeatherModel.ground_context(terrain.height_at, 10000.0, 15, 0.1)
##   ctx.merge({"month": 7, "day": 15, "lat": 51.9})
##   air.set_weather(WeatherModel.derive(settings.forecast(), ctx, WeatherModel.config()))

const CONFIG := "weather_model"
## Ускорение свободного падения, м/с² (частота Брента — Вяйсяля для волны).
const G := 9.81


static func config() -> Dictionary:
	return Config.get_config(CONFIG)


## Опорное место без рельефа (тесты, превью): {month, day, lat, valley_msl_m, mean_msl_m}.
static func reference_context(cfg: Dictionary = {}) -> Dictionary:
	var c := cfg if not cfg.is_empty() else config()
	return (c.get("reference_context", {}) as Dictionary).duplicate()


## Обычный дневной максимум для месяца (и дня — между серединами месяцев линейно), °C.
## Зажато в диапазон меню (ui.temperature_c).
static func typical_max_c(month: int, day: int = 15, cfg: Dictionary = {}) -> float:
	var c := cfg if not cfg.is_empty() else config()
	var r: Array = c.get("ui", {}).get("temperature_c", [-50, 60, 1])
	return clampf(monthly(c.get("typical_max_c", [20.0]), month, day), float(r[0]), float(r[1]))


## Высоты рельефа вокруг (0, 0): долина (нижняя доля low_percentile) и средняя, м над морем.
## Сетка samples² в круге radius_m — как GroundField.mean_height (отсчёт кромки).
static func ground_context(
	height_fn: Callable, radius_m: float, samples: int, low_percentile: float
) -> Dictionary:
	var hs: PackedFloat32Array = []
	var n := maxi(samples, 2)
	for j in n:
		for i in n:
			var u := float(i) / (n - 1) * 2.0 - 1.0
			var v := float(j) / (n - 1) * 2.0 - 1.0
			if u * u + v * v > 1.0:
				continue
			hs.append(float(height_fn.call(u * radius_m, v * radius_m)))
	if hs.is_empty():
		return {"valley_msl_m": 0.0, "mean_msl_m": 0.0}
	var sum := 0.0
	for h in hs:
		sum += h
	hs.sort()
	var k := clampi(int(floor(low_percentile * (hs.size() - 1))), 0, hs.size() - 1)
	return {"valley_msl_m": float(hs[k]), "mean_msl_m": sum / hs.size()}


## Прогноз {temperature_c, wind_speed_kmh, wind_from_deg, sky} в месте ctx {month, day, lat,
## valley_msl_m, mean_msl_m} → словарь погоды. hour = NAN — «разгар дня» (температура = максимум);
## иначе — день в этот час (суточный ход, фаза 2). Детерминированно.
static func derive(
	forecast: Dictionary, ctx: Dictionary, cfg: Dictionary = {}, hour: float = NAN
) -> Dictionary:
	var c := cfg if not cfg.is_empty() else config()
	var month := clampi(int(ctx.get("month", 7)), 1, 12)
	var day := int(ctx.get("day", 15))
	var lat := float(ctx.get("lat", 52.0))
	var h_v := float(ctx.get("valley_msl_m", 0.0)) / 1000.0
	var h_m := float(ctx.get("mean_msl_m", 0.0))
	var t_max := float(forecast.get("temperature_c", 20.0))
	var wind_kmh := maxf(float(forecast.get("wind_speed_kmh", 0.0)), 0.0)
	var t := t_max
	var diurnal := {}
	if not is_nan(hour) and bool(c.get("diurnal", {}).get("enabled", false)):
		diurnal = diurnal_state(t_max, hour, ctx, c)
		t = float(diurnal.temperature_c)

	# --- высота термиков и кромка (§2.2), км над морем
	var ua: Dictionary = c.upper_air
	var t_u := monthly(ua.temp_c, month, day)
	var z_u := float(ua.z_msl_m) / 1000.0
	var gam := float(ua.lapse_k_per_km)
	var dry := float(c.get("dry_adiabat_k_per_km", 9.8))
	var td := monthly(c.dew_point_c, month, day)
	td += float(c.get("td_follow_heat", 0.0)) * maxf(t_max - typical_max_c(month, day, c), 0.0)
	td = minf(td, t)
	var excess := float(c.parcel_excess_k)
	var z_dry := h_v + (t + excess - t_u - gam * (z_u - h_v)) / (dry - gam)
	if not diurnal.is_empty() and is_finite(float(diurnal.cap_agl_m)):
		var z_cap := minf(z_dry, h_v + float(diurnal.cap_agl_m) / 1000.0)
		z_dry = lerpf(z_cap, z_dry, float(diurnal["break"]))
	var z_lcl := h_v + float(c.lcl_m_per_k) / 1000.0 * (t - td)
	var margin := (z_dry - z_lcl) * 1000.0
	var z_top := minf(z_dry, z_lcl) * 1000.0
	var cl: Array = c.cloudbase_agl_clamp_m
	var top_agl := clampf(z_top - h_m, float(cl[0]), float(cl[1]))
	var blue := margin < float(c.blue_margin_m)

	# --- сила, размер, частота (§2.3)
	var a := interp_rows(c.anchors_by_top_agl, "top_agl_m", top_agl)
	var sun_el := noon_elevation_deg(lat, month, day)
	var sc: Dictionary = c.sun
	var sun_k := pow(
		maxf(sin(deg_to_rad(sun_el)), 0.0) / sin(deg_to_rad(float(sc.ref_elevation_deg))),
		float(sc.exponent)
	)
	sun_k = clampf(sun_k, float(sc.clamp[0]), float(sc.clamp[1]))
	var wf: Dictionary = c.wind_factors
	var wind_k := lerp_table(wf.wind_kmh, wf.strength, wind_kmh)
	var duty_k := lerp_table(wf.wind_kmh, wf.duty, wind_kmh)
	var dust_wind_k := lerp_table(wf.dust_wind_kmh, wf.dust, wind_kmh)
	var strength_k := sun_k * wind_k
	var duty := float(a.thermal_duty) * sqrt(sun_k) * duty_k

	# --- облака по запасу (§2.4)
	var cloud := interp_rows(c.clouds_by_margin, "margin_m", margin)
	var consts: Dictionary = c.constants
	var dry_frac := float(cloud.dry_thermal_fraction)
	var cloud_min := float(consts.cloud_min_strength_ms)
	var cloud_depth := float(cloud.cloud_depth_m)
	var overdev := float(cloud.overdevelopment_chance)
	var cb := float(cloud.cb_chance)
	var cb_th := float(cloud.get("cb_thermal_chance", cb))
	if blue:
		dry_frac = 1.0
		cloud_min = float(c.get("blue_cloud_min_strength_ms", 99.0))
		overdev = 0.0
		cb = 0.0
		cb_th = 0.0
	var st: Dictionary = c.storm
	var ss: Dictionary = c.street_strength
	var dd: Dictionary = c.dust_by_top_agl
	var dust := lerp_table(dd.top_agl_m, dd.chance, top_agl) * dust_wind_k

	# --- волна (скрыто, §2.8)
	var wv: Dictionary = c.wave
	var wave_strength := 0.0
	if bool(wv.enabled):
		wave_strength = (
			float(wv.max_strength)
			* clampf(
				(wind_kmh - float(wv.min_wind_kmh))
				/ maxf(float(wv.full_wind_kmh) - float(wv.min_wind_kmh), 1.0),
				0.0,
				1.0
			)
			* clampf((float(wv.max_top_agl_m) - top_agl) / float(wv.fade_top_m), 0.0, 1.0)
		)
	var t_k := t + 273.15
	var n_bv := sqrt(G / t_k * (dry - gam) / 1000.0)

	var w := {
		"wind_speed_kmh": wind_kmh,
		"wind_from_deg": float(forecast.get("wind_from_deg", 270.0)),
		"cloudbase_agl_m": top_agl,
		"thermal_strength_ms": _scale2(a.thermal_strength_ms, strength_k),
		"thermal_radius_m": _scale2(a.thermal_radius_m, 1.0),
		"thermal_spacing_m": float(a.thermal_spacing_m) * (1.0 + float(st.spacing_k) * cb),
		"thermal_duty": clampf(duty, 0.0, 1.0),
		"background_sink_ms": float(a.background_sink_ms) + float(st.sink_k) * cb,
		"convective_turbulence_ms": float(a.convective_turbulence_ms) * strength_k,
		"cloud_min_strength_ms": cloud_min,
		"cloud_depth_m": cloud_depth,
		"thermal_mode": "dynamic",
		"static_thermals": [],
		"street_strength": float(ss.blue) if blue else float(ss.cumulus),
		"overdevelopment_chance": overdev,
		"cloud_size_factor": float(a.cloud_size_factor) + float(st.cloud_size_k) * cb,
		"cirrus_cover": clampf(float(c.cirrus_base) + float(st.cirrus_k) * cb, 0.0, 1.0),
		"cb_chance": cb,
		"cb_thermal_chance": cb_th,
		"thermal_edge_k": 1.0,
		"mech_turbulence_k": 1.0,
		"haze_k": 1.0,
		"cb_top_above_base_m": maxf(float(c.tropopause_msl_m) - z_lcl * 1000.0, 1000.0),
		"wave_strength": wave_strength,
		"stability_n_per_s": n_bv,
		"lens_level_above_crest_m": float(consts.lens_level_above_crest_m),
		"dry_thermal_fraction": dry_frac,
		"thermal_extreme_chance": (
			lerp_table(c.extreme_by_top_agl.top_agl_m, c.extreme_by_top_agl.chance, top_agl)
			+ float(st.extreme_k) * cb
		),
		"thermal_extreme_ms": _scale2(consts.thermal_extreme_ms, 1.0),
		"dust_devil_chance": dust,
		"_derived": {
			"temperature_c": t,
			"upper_temp_c": t_u,
			"dew_point_c": td,
			"valley_msl_m": h_v * 1000.0,
			"mean_msl_m": h_m,
			"z_dry_msl_m": z_dry * 1000.0,
			"z_lcl_msl_m": z_lcl * 1000.0,
			"margin_m": margin,
			"top_agl_m": top_agl,
			"blue": blue,
			"sun_noon_deg": sun_el,
			"sun_k": sun_k,
			"wind_k": wind_k,
			"sky": String(forecast.get("sky", "clear")),
		},
	}
	_apply_heat(w, diurnal, sky_params(String(forecast.get("sky", "clear")), c), c)
	return w


## Поправки облачности ("clear" | "partly" | "overcast"; неизвестная — ясно).
static func sky_params(sky: String, cfg: Dictionary = {}) -> Dictionary:
	var c := cfg if not cfg.is_empty() else config()
	var sc: Dictionary = c.get("sky", {})
	return sc.get(sky, sc.get("clear", {}))


## Суточный ход (фаза 2, docs/plan/weather_by_temperature.md §7): по дневному максимуму t_max
## и часу hour (часы места: ctx.utc_offset_h — пояс, NAN — солнечное время) →
## {temperature_c, cap_agl_m (верх утреннего слоя над долиной; INF — инверсия пробита),
## break (0..1 — насколько прогрев пробил инверсию: верх термиков от cap к сухому),
## heat (поток тепла / полуденный, 0..1), soft (мягкость 0..1), mech_k, sunrise_h, sunset_h,
## peak_h}.
static func diurnal_state(
	t_max: float, hour: float, ctx: Dictionary, c: Dictionary
) -> Dictionary:
	var d: Dictionary = c.get("diurnal", {})
	var month := clampi(int(ctx.get("month", 7)), 1, 12)
	var day := int(ctx.get("day", 15))
	var lat := float(ctx.get("lat", 52.0))
	var lon := float(ctx.get("lon", 0.0))
	var utc := float(ctx.get("utc_offset_h", NAN))
	var doy := SunClock.day_of_year(month, day)
	# Истинный полдень по часам места и долгота дня (без уравнения времени — ±15 мин).
	var noon := 12.0 if is_nan(utc) else 12.0 - (4.0 * lon - 60.0 * utc) / 60.0
	var decl := deg_to_rad(23.44) * sin(TAU * (284.0 + doy) / 365.0)
	var cos_h0 := clampf(-tan(deg_to_rad(lat)) * tan(decl), -1.0, 1.0)
	var half := rad_to_deg(acos(cos_h0)) / 15.0
	var sunrise := noon - half
	var sunset := noon + half
	var peak := minf(noon + float(d.get("peak_after_noon_h", 2.5)), sunset - 0.5)
	# Parton–Logan: синус от восхода до пика, спад к закату, ночью — экспонента.
	var fs := float(d.get("sunset_fraction", 0.65))
	var f := 0.0
	if hour <= sunrise:
		f = 0.0
	elif hour <= peak:
		f = sin(PI * 0.5 * (hour - sunrise) / maxf(peak - sunrise, 0.1))
	elif hour <= sunset:
		f = fs + (1.0 - fs) * cos(PI * 0.5 * (hour - peak) / maxf(sunset - peak, 0.1))
	else:
		f = fs * exp(-(hour - sunset) / float(d.get("night_tau_h", 2.0)))
	var amp := monthly(d.get("range_k", [10.0]), month, day)
	var t := t_max - amp * (1.0 - f)
	# Утренняя инверсия: пузырь поднимается только в ней, пока не прогреется выше остывшего
	# за ночь остаточного слоя вчерашнего дня (T + δ ≥ T_max − R).
	var excess := float(c.get("parcel_excess_k", 1.0))
	var t_res := t_max - float(d.get("residual_cooling_k", 2.0))
	var t_min := t_max - amp
	var window := float(d.get("break_window_k", 3.0))
	var cap := INF
	var brk := 1.0
	if hour < peak and t + excess < t_res:
		var t_full := t_res - window
		cap = (
			float(d.get("inversion_depth_m", 500.0))
			* clampf((t + excess - t_min) / maxf(t_full - t_min, 0.5), 0.0, 1.0)
		)
		brk = clampf((t + excess - t_full) / maxf(window, 0.1), 0.0, 1.0)
	# Поток тепла над лугом — высота солнца с запаздыванием, относительно полудня.
	var lag := float(d.get("heat_lag_h", 0.3))
	var el := SunClock.solar_position(lat, lon, doy, hour - lag, utc).y
	var el_noon := SunClock.solar_position(lat, lon, doy, noon, utc).y
	var heat := maxf(sin(deg_to_rad(el)), 0.0) / maxf(sin(deg_to_rad(el_noon)), 0.05)
	heat = clampf(heat, 0.0, 1.0)
	var sd: Dictionary = d.get("soft", {})
	var sharp_min := float(sd.get("sharp_min", 0.5))
	var soft := clampf((1.0 - heat) / maxf(1.0 - sharp_min, 0.01), 0.0, 1.0)
	var calm_h := float(d.get("evening_calm_h", 2.0))
	var calm := clampf((hour - (sunset - calm_h)) / maxf(calm_h, 0.01), 0.0, 1.0)
	var mech_k := lerpf(1.0, float(d.get("evening_mech_k", 0.6)), calm)
	# Дымка копится после пика прогрева к закату.
	var haze_k := lerpf(
		1.0,
		float(d.get("evening_haze_k", 1.0)),
		clampf((hour - peak) / maxf(sunset - peak, 0.1), 0.0, 1.0)
	)
	return {
		"temperature_c": t,
		"cap_agl_m": cap,
		"break": brk,
		"heat": heat,
		"soft": soft,
		"mech_k": mech_k,
		"haze_k": haze_k,
		"sunrise_h": sunrise,
		"sunset_h": sunset,
		"peak_h": peak,
	}


## Прогрев: ход дня (st — diurnal_state или пусто) и облачность (sky): сила, частота, мягкость,
## облака тают вечером, под облачностью нет гроз.
static func _apply_heat(w: Dictionary, st: Dictionary, sky: Dictionary, c: Dictionary) -> void:
	var d: Dictionary = c.get("diurnal", {})
	var sd: Dictionary = d.get("soft", {})
	var heat_d := float(st.get("heat", 1.0))
	var heat := heat_d * float(sky.get("heat", 1.0))
	var soft := maxf(float(st.get("soft", 0.0)), float(sky.get("soft", 0.0)))
	var s_k := pow(heat, float(d.get("heat_strength_exponent", 0.3333)))
	s_k *= 1.0 - float(sd.get("core_k", 0.2)) * soft
	w.thermal_strength_ms = _scale2(w.thermal_strength_ms, s_k)
	w.thermal_radius_m = _scale2(w.thermal_radius_m, 1.0 + float(sd.get("radius_k", 0.3)) * soft)
	w.thermal_duty = clampf(
		(
			float(w.thermal_duty)
			* pow(heat_d, float(d.get("heat_duty_exponent", 1.0)))
			* float(sky.get("duty_k", 1.0))
		),
		0.0,
		1.0
	)
	w.convective_turbulence_ms = float(w.convective_turbulence_ms) * s_k
	var cloudy := (1.0 - float(w.dry_thermal_fraction)) * pow(
		heat_d, float(d.get("heat_cloud_exponent", 0.5))
	)
	w.dry_thermal_fraction = 1.0 - cloudy
	var cb_k := float(sky.get("cb_k", 1.0))
	w.cb_chance = float(w.cb_chance) * cb_k
	w.cb_thermal_chance = float(w.cb_thermal_chance) * cb_k
	w.overdevelopment_chance = float(w.overdevelopment_chance) * cb_k
	w.cirrus_cover = maxf(float(w.cirrus_cover), float(sky.get("cover", 0.0)))
	w.thermal_edge_k = 1.0 - float(sd.get("edge_k", 0.4)) * soft
	w.mech_turbulence_k = float(st.get("mech_k", 1.0))
	w.haze_k = float(st.get("haze_k", 1.0)) * float(sky.get("haze_k", 1.0))
	var dv: Dictionary = w._derived
	dv.merge(st, true)
	dv.heat = heat
	dv.soft = soft


## Высота солнца в истинный полдень, градусы.
static func noon_elevation_deg(lat: float, month: int, day: int) -> float:
	return SunClock.solar_position(lat, 0.0, SunClock.day_of_year(month, day), 12.0).y


## Значение из таблицы по месяцам (12 чисел, середина месяца = 15-е), линейно между месяцами.
static func monthly(arr: Array, month: int, day: int = 15) -> float:
	if arr.is_empty():
		return 0.0
	if arr.size() < 12:
		return float(arr[0])
	var m := clampi(month, 1, 12) - 1
	var dim := float(SunClock.days_in_month(m + 1))
	var f := (float(day) - 15.0) / dim  # доля месяца от середины: −0,5…+0,5
	var j := posmod(m + (1 if f >= 0.0 else -1), 12)
	return lerpf(float(arr[m]), float(arr[j]), absf(f))


## Кусочно-линейная интерполяция таблицы xs → ys (края — зажаты).
static func lerp_table(xs: Array, ys: Array, x: float) -> float:
	return SunClock._lerp_f(xs, ys, x)


## Строки [{key: x, поле: число | [числа]}] → поля, линейно по x (края — зажаты).
static func interp_rows(rows: Array, key: String, x: float) -> Dictionary:
	var n := rows.size()
	if n == 0:
		return {}
	var i := 0
	var f := 0.0
	if x <= float(rows[0][key]):
		i = 0
	elif x >= float(rows[n - 1][key]):
		i = n - 1
	else:
		while i < n - 1 and x > float(rows[i + 1][key]):
			i += 1
		var a := float(rows[i][key])
		var b := float(rows[i + 1][key])
		f = (x - a) / maxf(b - a, 1.0e-6)
	var r0: Dictionary = rows[i]
	var r1: Dictionary = rows[mini(i + 1, n - 1)]
	var out := {}
	for k: String in r0:
		var v0: Variant = r0[k]
		var v1: Variant = r1.get(k, v0)
		if v0 is Array:
			var arr: Array = []
			for e in (v0 as Array).size():
				arr.append(lerpf(float(v0[e]), float(v1[e]), f))
			out[k] = arr
		else:
			out[k] = lerpf(float(v0), float(v1), f)
	return out


static func _scale2(v: Array, k: float) -> Array:
	return [float(v[0]) * k, float(v[1]) * k]
