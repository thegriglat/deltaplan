extends Node
## Таблица «прогноз → день» (docs/plan/weather_by_temperature.md, карточка 1): для 4 локаций
## замеряет высоту долины и среднюю высоту рельефа (WeatherModel.ground_context) и печатает, что
## выводит модель при разных температуре, ветре и месяце. Та же таблица простым языком — в
## <out> (по умолчанию tmp_weather_table.md) для пилота.
## Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/weather/derive_table.tscn \
##     -- [--out=tmp_weather_table.md] [--hours=9,14,19]

const LOCATIONS: Array[String] = ["altai", "askarovo", "aushkul", "ongudai"]
const TEMPS: Array[float] = [-5.0, 10.0, 15.0, 20.0, 26.0, 31.0, 34.0, 38.0]
const WINDS_MS: Array[float] = [0.0, 3.0, 5.0, 7.0, 10.0]
const MONTHS: Array[int] = [4, 7, 9]


func _ready() -> void:
	var out := "tmp_weather_table.md"
	var hours: Array[float] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--hours="):
			for h in a.substr(8).split(","):
				hours.append(float(h))
	var cfg := WeatherModel.config()
	var g: Dictionary = Config.get_config("atmosphere").ground
	var md: PackedStringArray = [
		"# Какой день получается из прогноза",
		"",
		"Температура — днём (максимум у земли в долине), ветер — по прогнозу у земли.",
		"Кромка — над средней высотой земли вокруг. «Сухие» — доля термиков без облака.",
		"",
	]
	for loc_id in LOCATIONS:
		var terrain := Terrain.new()
		terrain.location_id = ""
		if not terrain.load_location(loc_id):
			push_error("не загрузилась %s" % loc_id)
			terrain.free()
			continue
		var t0 := Time.get_ticks_usec()
		var ctx := WeatherModel.ground_context(
			terrain.height_at,
			float(g.reference_radius_m),
			int(g.reference_samples),
			float(cfg.valley_percentile)
		)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		ctx.lat = terrain.center_lat
		print(
			"\n== %s: долина %.0f м, средняя %.0f м, широта %.2f (ground_context %.1f мс)"
			% [loc_id, ctx.valley_msl_m, ctx.mean_msl_m, ctx.lat, ms]
		)
		md.append("## %s (долина %.0f м, средняя высота %.0f м)" % [
			loc_id, ctx.valley_msl_m, ctx.mean_msl_m])
		for month in MONTHS:
			ctx.month = month
			ctx.day = 15
			md.append("")
			md.append("### Месяц %d (обычно днём %+.0f °C)" % [
				month, WeatherModel.typical_max_c(month, 15, cfg)])
			md.append("")
			md.append(
				"| °C | ветер м/с | кромка над землёй, м | термики, м/с | шаг, м | сухие | термиков в Cb"
				+ " | пыль. вихри |"
			)
			md.append("|---|---|---|---|---|---|---|---|")
			print("  месяц %d" % month)
			print("    T   U  | z_dry z_lcl  m    | кромка сила        шаг  сухие  Cb‰   пыль")
			for t in TEMPS:
				for u in WINDS_MS:
					var f := {"temperature_c": t, "wind_speed_kmh": u * 3.6, "wind_from_deg": 270.0}
					var w := WeatherModel.derive(f, ctx, cfg)
					var d: Dictionary = w._derived
					print(
						"    %+3.0f %2.0f | %5.0f %5.0f %5.0f | %5.0f %.1f–%.1f %5.0f %.2f %.2f %.2f"
						% [t, u, d.z_dry_msl_m, d.z_lcl_msl_m, d.margin_m, w.cloudbase_agl_m,
							w.thermal_strength_ms[0], w.thermal_strength_ms[1],
							w.thermal_spacing_m, w.dry_thermal_fraction, w.cb_thermal_chance * 1000.0,
							w.dust_devil_chance]
					)
					if u == 0.0 or u == 5.0 or u == 10.0:
						md.append("| %+.0f | %.0f | %s | %.1f–%.1f | %.0f | %s | %s | %s |" % [
							t, u,
							("%.0f" % w.cloudbase_agl_m) + (" (голубой)" if d.blue else ""),
							w.thermal_strength_ms[0], w.thermal_strength_ms[1],
							w.thermal_spacing_m,
							"все" if d.blue else "%.0f %%" % (w.dry_thermal_fraction * 100.0),
							(
								"—"
								if w.cb_thermal_chance <= 0.0
								else "%.2f %%" % (w.cb_thermal_chance * 100.0)
							),
							"—" if w.dust_devil_chance <= 0.0 else "%.0f %%" % (
								w.dust_devil_chance * 100.0),
						])
			for h in hours:
				for t in [20.0, 26.0, 31.0]:
					var f := {"temperature_c": t, "wind_speed_kmh": 11.0, "wind_from_deg": 270.0}
					var w := WeatherModel.derive(f, ctx, cfg, h)
					var d: Dictionary = w._derived
					print(
						"    %02.0f ч %+3.0f°: T %.1f кромка %5.0f m %5.0f сила %.1f–%.1f Cb‰ %.2f "
						% [h, t, d.temperature_c, w.cloudbase_agl_m, d.margin_m,
							w.thermal_strength_ms[0], w.thermal_strength_ms[1],
							w.cb_thermal_chance * 1000.0]
						+ str(d.get("heat_k", "-"))
					)
		terrain.free()
		md.append("")
	var fa := FileAccess.open(out, FileAccess.WRITE)
	if fa != null:
		fa.store_string("\n".join(md) + "\n")
		print("\nтаблица для пилота: ", out)
	get_tree().quit(0)
