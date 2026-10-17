extends Node
## TI-5: погода из прогноза (WeatherModel.derive, как Game._derive_weather) над учебным островом — перебор
## температуры, неба и часа для старта «Термики». Ничего не меняет, печатает JSON-строки.
##   godot --headless --path . res://tools/terrain/island/weather_sweep.tscn -- --month=7 --day=15 \
##       --temps=20,22,24,26,28,30 --skies=clear,partly --hours=12,15 --wind=2

func _ready() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		var kv := s.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location("training_island"):
		push_error("нет места")
		get_tree().quit(1)
		return
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples), float(wc.valley_percentile))
	var loc: Dictionary = Config.get_config("locations/training_island")
	ctx.merge({"month": int(a.get("month", 7)), "day": int(a.get("day", 15)), "lat": terrain.center_lat,
		"lon": terrain.center_lon, "utc_offset_h": float(loc.get("utc_offset_h", NAN))})
	print("CTX ", JSON.stringify(ctx))
	for t in String(a.get("temps", "24,28,32")).split(","):
		for sky in String(a.get("skies", "clear")).split(","):
			for h in String(a.get("hours", "12")).split(","):
				var f := {"temperature_c": float(t), "wind_speed_kmh": float(a.get("wind", 2.0)) * 3.6,
					"wind_from_deg": 270.0, "sky": sky}
				var w := WeatherModel.derive(f, ctx, {}, float(h))
				var d: Dictionary = w._derived
				print("W ", JSON.stringify({"t_max": float(t), "sky": sky, "hour": float(h),
					"t_now": snappedf(d.temperature_c, 0.1), "z_dry_msl": roundi(d.z_dry_msl_m),
					"z_lcl_msl": roundi(d.z_lcl_msl_m), "top_agl": roundi(d.top_agl_m), "blue": d.blue,
					"strength": [snappedf(w.thermal_strength_ms[0], 0.01), snappedf(w.thermal_strength_ms[1], 0.01)],
					"radius": [roundi(w.thermal_radius_m[0]), roundi(w.thermal_radius_m[1])],
					"spacing": roundi(w.thermal_spacing_m), "duty": snappedf(w.thermal_duty, 0.01),
					"sink": snappedf(w.background_sink_ms, 0.01), "heat": snappedf(d.heat, 0.01),
					"dry_frac": snappedf(w.dry_thermal_fraction, 0.01), "cb": snappedf(w.cb_chance, 0.03)}))
	get_tree().quit(0)
