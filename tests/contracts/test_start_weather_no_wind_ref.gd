extends TestCase
## WF-2: набор погоды старта (StartWeather) без опоры ветра: weather.wind_ref снят (ветер условий —
## всегда набегающий поток, WF-К1). Наборы в configs/locations разбираются и без этого ключа;
## устаревший ключ не ломает разбор (игнорируется с предупреждением).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_weather


func _weather(extra: Dictionary = {}) -> Dictionary:
	var w := {
		"wind_from_deg": 270,
		"wind_speed_ms": 6.0,
		"start_hour": float(SunClock.start_hours()[0]),
		"month": 7,
		"day": 15,
		"sky": "clear",
		"temperature_c": 20.0,
	}
	w.merge(extra, true)
	return w


func test_set_without_wind_ref_parses() -> void:
	var p := StartWeather.parse(_weather(), "test")
	check(not p.is_empty(), "набор без wind_ref разобран")
	check(not p.has("wind_ref"), "в разобранном наборе нет wind_ref")
	check(is_equal_approx(float(p.wind_speed_ms), 6.0) and is_equal_approx(float(p.wind_from_deg), 270.0), "ветер набора как задан")


func test_legacy_wind_ref_is_ignored() -> void:
	for v: Variant in ["start", "inflow", "x", 1]:
		var p := StartWeather.parse(_weather({"wind_ref": v}), "test")
		check(not p.is_empty() and not p.has("wind_ref"), "устаревший wind_ref %s игнорируется" % str(v))


func test_location_sets_have_no_wind_ref() -> void:
	var seen := 0
	for id in ["training_island", "volcano_island"]:
		for st: Dictionary in Locations.config(id).get("start_sites", []):
			if not st.has("weather"):
				continue
			seen += 1
			check(not (st.weather as Dictionary).has("wind_ref"), "%s/%s: в конфиге нет weather.wind_ref" % [id, st.get("id", "")])
			check(not StartWeather.parse(st.weather, "%s/%s" % [id, st.get("id", "")]).is_empty(), "%s/%s: набор разбирается" % [id, st.get("id", "")])
	check(seen >= 8, "наборов погоды островов: %d (нужно ≥ 8)" % seen)
