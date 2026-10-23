extends TestCase
## Погода из прогноза (WeatherModel, FR-16; docs/archive/plan/weather-by-temperature.md, карточка 1):
## опорные прогнозы дают эталоны configs/weather/*, монотонность по температуре и ветру,
## голубой день, весна, волна выключена, детерминизм и скорость.

const PRESET_KEYS: Array[String] = [
	"wind_speed_kmh", "wind_from_deg", "cloudbase_agl_m", "thermal_strength_ms",
	"thermal_radius_m", "thermal_spacing_m", "thermal_duty", "background_sink_ms",
	"convective_turbulence_ms", "cloud_min_strength_ms", "cloud_depth_m", "street_strength",
	"overdevelopment_chance", "cloud_size_factor", "cirrus_cover", "cb_chance",
	"cb_top_above_base_m", "wave_strength", "stability_n_per_s", "lens_level_above_crest_m",
	"dry_thermal_fraction", "thermal_extreme_chance", "thermal_extreme_ms", "dust_devil_chance",
]
## Опорные прогнозы эталонов configs/weather/<id>: [температура °C, ветер км/ч], ветер с 270°, 15 июля, Алтай.
## Климат ERA5 влажнее прежней таблицы: Td июля в опорном месте (ClimateGrid.place, долина 304 м) — 14,3 °C среднесуточная,
## 11,1 °C в ясный день (td_day), прежняя таблица — 9 °C. Поэтому прежние +26/+31 °C дают грозовые дни:
## тот же по силе день — средний на 2 °C прохладнее (+24), сильный на 2 °C жарче (+33); под данные правим температуру, не данные.
const REFERENCE_FORECASTS := {
	"weak": [20.0, 7.0], "medium": [24.0, 11.0], "strong": [33.0, 18.0], "storm": [34.0, 14.0],
}


func _derive(t: float, wind_kmh: float, month := 7, cfg: Dictionary = {}) -> Dictionary:
	var c := cfg if not cfg.is_empty() else WeatherModel.config()
	var ctx := WeatherModel.reference_context(c)
	ctx.month = month
	return WeatherModel.derive(
		{"temperature_c": t, "wind_speed_kmh": wind_kmh, "wind_from_deg": 270.0}, ctx, c
	)


func _rel(a: float, b: float) -> float:
	return absf(a - b) / maxf(absf(b), 1.0e-6)


func test_reference_forecasts_match_presets() -> void:
	for id: String in REFERENCE_FORECASTS:
		var f: Array = REFERENCE_FORECASTS[id]
		var w := _derive(f[0], f[1])
		var p: Dictionary = Config.get_config("weather/" + id)
		var tag := "%s (%+.0f °C): " % [id, f[0]]
		check(
			_rel(w.thermal_strength_ms[1], p.thermal_strength_ms[1]) <= 0.2,
			tag + "сила макс %.2f против %.2f" % [w.thermal_strength_ms[1], p.thermal_strength_ms[1]]
		)
		if id == "storm":
			check(w.cb_chance >= 0.2 and w.cb_chance <= 0.45, tag + "cb %.2f" % w.cb_chance)
			continue
		check(
			_rel(w.thermal_strength_ms[0], p.thermal_strength_ms[0]) <= 0.2,
			tag + "сила мин %.2f против %.2f" % [w.thermal_strength_ms[0], p.thermal_strength_ms[0]]
		)
		check(
			_rel(w.cloudbase_agl_m, p.cloudbase_agl_m) <= 0.2,
			tag + "кромка %.0f против %.0f" % [w.cloudbase_agl_m, p.cloudbase_agl_m]
		)
		approx(w.dry_thermal_fraction, p.dry_thermal_fraction, 0.12, tag + "доля сухих")
		approx(w.background_sink_ms, p.background_sink_ms, 0.15, tag + "фон")
		if id == "strong":
			check(
				w.thermal_extreme_chance >= 0.02 and w.thermal_extreme_chance <= 0.06,
				tag + "extreme %.3f" % w.thermal_extreme_chance
			)
		else:
			approx(w.cb_chance, 0.0, 1.0e-6, tag + "cb")
			approx(w.thermal_extreme_chance, 0.0, 1.0e-6, tag + "extreme")


func test_monotonic_in_temperature() -> void:
	var prev := _derive(10.0, 11.0)
	for t in range(11, 35):
		var w := _derive(float(t), 11.0)
		check(
			w.cloudbase_agl_m >= prev.cloudbase_agl_m - 1.0e-3,
			"кромка убыла при %+d °C: %.0f < %.0f" % [t, w.cloudbase_agl_m, prev.cloudbase_agl_m]
		)
		check(
			w.thermal_strength_ms[1] >= prev.thermal_strength_ms[1] - 1.0e-3,
			"сила убыла при %+d °C" % t
		)
		prev = w


func test_wind_weakens_thermals_and_blows_dust_away() -> void:
	var prev := _derive(28.0, 0.0)
	for u in range(0, 46, 3):
		var w := _derive(28.0, float(u))
		check(
			w.thermal_strength_ms[1] <= prev.thermal_strength_ms[1] + 1.0e-4,
			"сила выросла при ветре %d км/ч" % u
		)
		if u >= 30:
			approx(w.dust_devil_chance, 0.0, 1.0e-6, "пылевые вихри при %d км/ч" % u)
		prev = w
	check(_derive(28.0, 0.0).dust_devil_chance > 0.0, "в штиль в жару пылевые вихри есть")


func test_blue_and_dead_days() -> void:
	var w16 := _derive(16.0, 7.0)
	check(w16.cloud_min_strength_ms >= 50.0, "+16 июль — голубой (%.1f)" % w16.cloud_min_strength_ms)
	approx(w16.dry_thermal_fraction, 1.0, 1.0e-6, "+16 — все термики сухие")
	var w12 := _derive(12.0, 7.0)
	approx(w12.cloudbase_agl_m, 300.0, 1.0e-3, "+12 — кромка на минимуме")


func test_spring_air_is_livelier() -> void:
	var apr := _derive(15.0, 7.0, 4)
	var jul := _derive(15.0, 7.0, 7)
	check(
		apr.cloudbase_agl_m > jul.cloudbase_agl_m + 300.0,
		"апрель +15 (%.0f) выше июля +15 (%.0f)" % [apr.cloudbase_agl_m, jul.cloudbase_agl_m]
	)
	check(apr.thermal_strength_ms[1] > jul.thermal_strength_ms[1], "апрель +15 сильнее июля")


func test_wave_off_by_default() -> void:
	for t in [-5.0, 10.0, 18.0, 26.0, 38.0]:
		for u in [0.0, 20.0, 36.0, 43.0]:
			approx(_derive(t, u).wave_strength, 0.0, 1.0e-9, "волна при %+.0f/%.0f" % [t, u])
	var cfg: Dictionary = WeatherModel.config().duplicate(true)
	cfg.wave.enabled = true
	check(_derive(18.0, 36.0, 7, cfg).wave_strength > 0.0, "волна включается конфигом")


func test_deterministic_and_complete() -> void:
	var a := _derive(26.0, 11.0)
	var b := _derive(26.0, 11.0)
	check(a == b, "одни входы — один день")
	for k in PRESET_KEYS:
		check(a.has(k), "нет ключа %s" % k)
		var v: Variant = a.get(k)
		if v is Array:
			for e: Variant in v:
				check(e is float and is_finite(e), "%s — не число" % k)
		else:
			check(v is float and is_finite(v), "%s — не число" % k)


func test_typical_max() -> void:
	approx(WeatherModel.typical_max_c(7, 15), 26.0, 1.0e-6, "обычно в июле +26")
	approx(WeatherModel.typical_max_c(1, 15), 0.0, 1.0e-6, "зимой — не ниже 0 (снег не рисуем)")


## HH-4b: климат места из сеток — Tx, амплитуда, тропопауза, перистые, рост ветра берутся из ClimateGrid.place.
func test_place_climate_wired() -> void:
	ClimateGrid.set_paths({})
	var c := WeatherModel.config()
	var cairns := {"lat": -16.9, "lon": 145.8, "month": 1, "day": 15, "valley_msl_m": 0.0}
	var cp := ClimateGrid.place(cairns)
	approx(WeatherModel.typical_max_c(1, 15, c, cairns), clampf(cp.tx_c, float(c.ui.temperature_c[0]), float(c.ui.temperature_c[1])), 1.0e-9, "Tx места")
	approx(WeatherModel.diurnal_range_k(cairns, c), cp.dtr_k, 1.0e-9, "амплитуда места")
	var ctx := cairns.duplicate()
	ctx.mean_msl_m = 0.0
	var w := WeatherModel.derive(
		{"temperature_c": 33.0, "wind_speed_kmh": 10.0, "wind_from_deg": 270.0, "sky": "clear"}, ctx, c
	)
	approx(w._derived.trop_msl_m, cp.trop_m, 1.0e-6, "тропопауза места в derive")
	approx(w._derived.gain_per_km, cp.gain_per_km, 1.0e-9, "рост ветра места в derive")
	if cp.src.hh6 != "none":
		var k_clear := WeatherModel.cirrus_base_cover(cp, "clear", ctx, c)
		var k_over := WeatherModel.cirrus_base_cover(cp, "overcast", ctx, c)
		check(k_over > k_clear, "перистые: пасмурный день гуще ясного (%.2f > %.2f)" % [k_over, k_clear])
		approx(k_clear, cp.hcc * c.hcc_sky.k_sky.clear[0][2], 1.0e-9, "ясно, пояс 0–20°, январь юга = ИИА: HCC × k_sky")
	# Без места (ctx без lat/lon) — таблицы-запас
	approx(WeatherModel.diurnal_range_k({"month": 7, "day": 15}, c), c.diurnal.range_k[6], 1.0e-9, "амплитуда без места")
	# Td: β-член от Tx места — в день с Tmax = Tx места поправки на температуру нет
	var tx := float(cp.tx_c)  # без зажима меню (typical_max_c режет до диапазона)
	var td0 := WeatherModel.td_day({"temperature_c": tx, "sky": "clear"}, cp, cairns, c)
	var td1 := WeatherModel.td_day({"temperature_c": tx + 5.0, "sky": "clear"}, cp, cairns, c)
	var tdc: Dictionary = c.td_day
	var b := ClimateGrid.band_index(cairns.lat, tdc.bands_abs_lat)
	var sn := ClimateGrid.season_index(1, cairns.lat)
	var beta := float(tdc.sky.clear.beta[b][sn])
	approx(td1 - td0, beta * 5.0, 0.1, "сдвиг Td при Tmax = Tx + 5 К равен β·5")
	var mu := float(tdc.sky.clear.mu_sigma[b][sn])
	var rho := float(tdc.sky.clear.res_ratio[b][sn])
	var r := clampf(WeatherModel.td_noise(1, 15, cairns.lat, cairns.lon), -float(c.climate.r_clamp), float(c.climate.r_clamp))
	approx(td0, cp.td_c + (mu + r * rho) * cp.td_sd_k, 0.1, "при Tmax = Tx места Td = климат + μσ + rρσ")
	# Без valley_msl_m поправки на высоту нет (HH7): значения на средней высоте ячейки
	var nov := {"lat": 51.9, "lon": 85.9, "month": 7, "day": 15}
	var p0 := ClimateGrid.place(nov)
	var p1 := ClimateGrid.at(51.9, 85.9, 7, 15)
	approx(p0.tx_c, p1.tx_c, 1.0e-9, "без valley_msl_m Tx = на высоте ячейки")
	approx(p0.td_c, p1.td_c, 1.0e-9, "без valley_msl_m Td = на высоте ячейки")
	nov["valley_msl_m"] = NAN
	approx(ClimateGrid.place(nov).tx_c, p1.tx_c, 1.0e-9, "valley NAN — без поправки")


func test_speed() -> void:
	var ctx := WeatherModel.reference_context()
	var cfg := WeatherModel.config()
	var t0 := Time.get_ticks_usec()
	for i in 100:
		WeatherModel.derive(
			{"temperature_c": 20.0 + i * 0.1, "wind_speed_kmh": 11.0, "wind_from_deg": 270.0},
			ctx,
			cfg
		)
	var per := (Time.get_ticks_usec() - t0) / 100.0 / 1000.0
	check(per < 1.0, "derive %.3f мс ≥ 1 мс" % per)
	var hfn := func(x: float, z: float) -> float: return 500.0 + 0.01 * x + 0.02 * z
	t0 = Time.get_ticks_usec()
	var gc := WeatherModel.ground_context(hfn, 10000.0, 15, 0.1)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(ms < 20.0, "ground_context %.1f мс ≥ 20 мс" % ms)
	check(gc.valley_msl_m < gc.mean_msl_m, "долина ниже средней")
	approx(gc.mean_msl_m, 500.0, 5.0, "средняя высота наклонной плоскости")


func _at(t: float, hour: float, wind_kmh := 11.0, sky := "clear") -> Dictionary:
	var ctx := WeatherModel.reference_context()
	return WeatherModel.derive(
		{"temperature_c": t, "wind_speed_kmh": wind_kmh, "wind_from_deg": 270.0, "sky": sky},
		ctx,
		WeatherModel.config(),
		hour
	)


func test_day_course() -> void:
	# Утро мягче и ниже полудня, кромка растёт до пика, вечером термиков меньше и они мягче.
	var m9 := _at(26.0, 9.0)
	var m14 := _at(26.0, 14.0)
	var m19 := _at(26.0, 19.0)
	check(m9._derived.temperature_c < m14._derived.temperature_c - 2.0, "утром прохладнее")
	check(m9.thermal_strength_ms[1] < m14.thermal_strength_ms[1] * 0.7, "утром слабее")
	check(m9.cloudbase_agl_m < m14.cloudbase_agl_m - 500.0, "утром кромка ниже")
	approx(m9.dry_thermal_fraction, 1.0, 0.05, "в 9 ч облаков почти нет")
	var prev := -1.0
	for h in [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0]:
		var cb: float = _at(26.0, h).cloudbase_agl_m
		check(cb >= prev - 1.0, "кромка поднимается до пика (%.0f ч: %.0f)" % [h, cb])
		prev = cb
	check(_at(26.0, 12.0).dry_thermal_fraction < 0.5, "к полудню кучевые")
	check(m19.thermal_duty < m14.thermal_duty * 0.6, "вечером термиков меньше")
	check(m19.thermal_radius_m[1] > m14.thermal_radius_m[1], "вечером шире (мягче)")
	check(m19.thermal_edge_k < m14.thermal_edge_k, "вечером край мягче")
	check(_at(26.0, 20.0).mech_turbulence_k < 0.9, "к закату приземный слой спокойнее")
	# Полдень ≈ фаза 1 (разгар дня).
	var peak := _derive(26.0, 11.0)
	check(
		_rel(m14.thermal_strength_ms[1], peak.thermal_strength_ms[1]) < 0.1,
		"14 ч ≈ разгар дня"
	)
	# Грозы — во второй половине дня.
	check(_at(34.0, 10.0).cb_chance < 0.05, "утром гроз нет")
	check(_at(34.0, 15.0).cb_chance > 0.2, "днём в жару грозы")


func test_sky_cover() -> void:
	var clear := _at(31.0, 14.0, 11.0, "clear")
	var partly := _at(31.0, 14.0, 11.0, "partly")
	var over := _at(31.0, 14.0, 11.0, "overcast")
	check(partly.thermal_strength_ms[1] < clear.thermal_strength_ms[1], "переменная слабее ясно")
	check(over.thermal_strength_ms[1] < partly.thermal_strength_ms[1], "облачно слабее")
	check(over.thermal_duty < clear.thermal_duty * 0.6, "облачно — термиков мало")
	approx(over.cb_chance, 0.0, 1.0e-6, "под облачностью гроз нет")
	check(over.cirrus_cover >= 0.8, "пелена облачности")
	check(over.thermal_radius_m[1] > clear.thermal_radius_m[1], "облачно — мягкие")
	check(
		_at(31.0, 14.0, 11.0, "nope").thermal_strength_ms == clear.thermal_strength_ms,
		"неизвестная облачность — ясно"
	)


func test_spring_plus15_is_a_thermal_day() -> void:
	# Пилот: «+15 весной — хорошие термики».
	var w := _derive(15.0, 11.0, 4)
	check(w.cloudbase_agl_m > 1200.0, "апрель +15: верх термиков %.0f" % w.cloudbase_agl_m)
	check(w.thermal_strength_ms[1] > 2.5, "апрель +15: сила %.1f" % w.thermal_strength_ms[1])
