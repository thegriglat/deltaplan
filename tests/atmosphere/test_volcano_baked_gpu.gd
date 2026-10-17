extends TestCase
## Запечённые поля всех стартов вулканического острова (VI-5, контракты TI-К3 v3, VI-К3): для каждого старта с weather
## key файла совпадает с текущими конфигом и данными места, AirRuntime берёт поле из файла (baked_ready, без
## «Рассчитываем ветер»), сразу не пересчитывается. tools/gpu_tests.sh --filter=volcano_baked. Замеры — в вывод.

const AR := preload("res://tests/atmosphere/test_air_runtime_gpu.gd")
const ID := "volcano_island"


func needs_gpu() -> bool:
	return true


func _weather_of(site_id: String) -> Dictionary:
	for st: Dictionary in Locations.config(ID).get("start_sites", []):
		if String(st.id) == site_id:
			return st.get("weather", {})
	return {}


func _sites() -> Array[String]:
	var out: Array[String] = []
	for st: Dictionary in Locations.config(ID).get("start_sites", []):
		out.append(String(st.id))
	return out


func test_volcano_baked_every_start() -> void:
	await Engine.get_main_loop().process_frame
	var root := (Engine.get_main_loop() as SceneTree).root
	var terrain := Terrain.new()
	root.add_child(terrain)
	check(terrain.load_location(ID), "остров загрузился")
	var sites := _sites()
	check(sites.size() >= 3, "старты места: %s" % [sites])
	var total := 0.0
	var dh := AirBakedField.place_hash(Locations.data_dir(ID))
	var wl: Array = Config.get_config("atmosphere").air_model.get("window_levels_m", [])
	for sid: String in sites:
		var weather := _weather_of(sid)
		check(not weather.is_empty(), "%s: набор погоды в конфиге" % sid)
		var site := {}
		for s: Dictionary in terrain.get_start_sites():
			if String(s.id) == sid:
				site = s
		check(not site.is_empty(), "%s: старт в местности" % sid)
		if weather.is_empty() or site.is_empty():
			continue
		var path := AirBakedField.path_of(ID, sid)
		var h := AirBakedField.read_header(path)
		check(not h.is_empty(), "%s: файл есть" % sid)
		if h.is_empty():
			continue
		var key := AirBakedField.make_key(
			ID, terrain.center_lat, terrain.center_lon, sid, weather, site.position, dh, wl
		)
		check(AirBakedField.key_diff(h.get("key"), key) == "", "%s: key совпадает (%s)" % [sid, AirBakedField.key_diff(h.get("key"), key)])
		var mb := FileAccess.get_file_as_bytes(path.trim_suffix(".json") + ".bin").size() / 1.0e6
		total += mb
		# TI-9b: старт с wind_ref inflow запечён с притоком k = 1 (как считает игра), не с подгонкой под ветер
		if String(weather.get("wind_ref", "start")) == "inflow":
			var rx := RegEx.create_from_string("\"inflow_k\":\\s*([0-9.eE+-]+)")
			var ms := rx.search_all(FileAccess.get_file_as_string(path))
			check(not ms.is_empty(), "%s: в файле есть inflow_k" % sid)
			for m in ms:
				check(is_equal_approx(float(m.get_string(1)), 1.0), "%s: inflow_k = 1 (%s)" % [sid, m.get_string(1)])
		# AirRuntime берёт поле из файла
		var c := AirBakedField.conditions_of(weather)
		var atmo := AR._atmo(terrain.layers[0] if terrain.layers[0].id == "detail" else terrain.layers[1])
		atmo.field.air_async = false
		var rt := AirRuntime.new()
		root.add_child(rt)
		var cond := c
		rt.setup(atmo, AirRuntime.place_of(terrain, float(Locations.config(ID).get("utc_offset_h", 0.0)), int(weather.month), int(weather.day)), func() -> Dictionary: return cond)
		var sp: Vector3 = site.position
		rt.set_focus(null, sp)
		check(rt.baked_ready(), "%s: baked_ready" % sid)
		var t0 := Time.get_ticks_usec()
		var ok: bool = await rt.load_field()
		var load_s := (Time.get_ticks_usec() - t0) / 1e6
		check(ok and rt.last_info.get("baked", false) == true, "%s: поле из файла (%s)" % [sid, rt.last_error])
		check(not rt.busy(), "%s: после загрузки расчёт не идёт" % sid)
		print("  %s: %.2f МБ, загрузка из файла %.2f с" % [sid, mb, load_s])
		rt.queue_free()
		atmo.free()
	print("  всего %.2f МБ" % total)
	terrain.queue_free()
