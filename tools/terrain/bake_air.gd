extends Node
## Запекание поля ветра старта (TI-4, контракт TI-К3): считает поле AirRuntime для набора погоды старта
## (ключ start_sites[].weather конфига места, TI-К2) и пишет файлы res://data/locations/<id>/air/<старт>.json/.bin.
## Поле считается на GPU — запуск в окне, не headless:
##   DISPLAY=:0 godot --path . --audio-driver Dummy --disable-vsync res://tools/terrain/bake_air.tscn -- --id=<место> --site=<старт> [--out=<папка>]
##   (пачка — под .dpcli/dpcli lock gpu bake -- …)
## Проверка свежести (без GPU, можно headless): … -- --check [--id=<место> [--site=<старт>]] [--dir=<корень>]
##   сравнивает key и model_hash файлов с текущими данными места и исходниками модели; код 1 — устарело
##   (перепечь). Без --id проверяются все файлы корня (res://data/locations).
## Прочее: --fixtures — места из tests/fixtures/locations (отладка на ongudai); --weather=<json> — набор
## погоды вместо конфига (отладка места без weather; в key попадает как есть).

var _a := {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if _a.has("fixtures"):
		Locations.fixtures_root = "res://tests/fixtures/locations"
	await get_tree().process_frame
	var code := 0
	if _a.has("check"):
		code = _check()
	else:
		code = await _bake()
	get_tree().quit(code)


func _out_root() -> String:
	return String(_a.get("dir", AirBakedField.baked_root))


## Набор погоды старта: --weather, иначе конфиг места. {} — нет.
func _weather_of(id: String, site_id: String) -> Dictionary:
	if _a.has("weather"):
		var w: Variant = JSON.parse_string(String(_a.weather))
		return w if w is Dictionary else {}
	for st: Dictionary in Locations.config(id).get("start_sites", []):
		if String(st.get("id", "")) == site_id and st.get("weather") is Dictionary:
			return st.weather
	return {}


func _load_terrain(id: String) -> Terrain:
	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location(id):
		push_error("bake_air: место %s не загрузилось" % id)
		terrain.queue_free()
		return null
	return terrain


func _site_of(terrain: Terrain, site_id: String) -> Dictionary:
	for s: Dictionary in terrain.get_start_sites():
		if String(s.id) == site_id:
			return s
	return {}


## key файла для старта — те же слагаемые, что считает AirRuntime.baked_lookup.
func _key_of(terrain: Terrain, id: String, site: Dictionary, weather: Dictionary) -> Dictionary:
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	return AirBakedField.make_key(
		id, terrain.center_lat, terrain.center_lon, String(site.id), weather, site.position,
		AirBakedField.place_hash(Locations.data_dir(id)), ac.get("window_levels_m", [])
	)


func _bake() -> int:
	var id := String(_a.get("id", ""))
	var site_id := String(_a.get("site", ""))
	if id == "" or site_id == "":
		push_error("bake_air: нужны --id=<место> --site=<старт>")
		return 2
	var weather := _weather_of(id, site_id)
	if weather.is_empty():
		push_error("bake_air: у старта %s/%s нет набора погоды weather (TI-К2)" % [id, site_id])
		return 2
	var terrain := _load_terrain(id)
	if terrain == null:
		return 2
	var site := _site_of(terrain, site_id)
	if site.is_empty():
		push_error("bake_air: в месте %s нет старта %s" % [id, site_id])
		return 2
	var t0 := Time.get_ticks_usec()
	var month := int(weather.month)
	var day := int(weather.day)
	var utc := _clock_utc_offset(terrain)
	var sp: Vector3 = site.position
	var c := AirBakedField.conditions_of(weather)
	# Атмосфера нужна расчёту только для замера U над стартом (GroundField) — как у игры, без термиков.
	var atmo := _make_atmosphere(terrain, weather, sp, utc, c)
	var rt := AirRuntime.new()
	add_child(rt)
	await get_tree().process_frame
	rt.baked_enabled = false
	rt.setup(atmo, AirRuntime.place_of(terrain, utc, month, day), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return sp
	var why := rt.unavailable_reason()
	if why != "":
		push_error("bake_air: поле не считается (%s) — запуск в окне, не headless" % why)
		return 2
	var ok: bool = await rt.load_field()
	if not ok:
		push_error("bake_air: расчёт не удался: %s" % rt.last_error)
		return 1
	var calc_s := (Time.get_ticks_usec() - t0) / 1e6
	var header := {
		"location": id,
		"site": site_id,
		"key": _key_of(terrain, id, site, weather),
		"model_hash": AirBakedField.model_hash(),
	}
	var path := AirBakedField.path_of(id, site_id, _out_root())
	if _a.has("out"):
		path = String(_a.out).path_join(site_id + ".json")
	var okw := AirBakedField.save(atmo.air_field, header, path)
	if not okw:
		return 1
	var mb := (
		FileAccess.get_file_as_bytes(path.trim_suffix(".json") + ".bin").size() / 1.0e6
	)
	print(
		"bake_air: %s/%s → %s, %.2f МБ, уровней %d, расчёт %.1f с (проходов %s, k %.3f), model_hash %s"
		% [
			id, site_id, path, mb, atmo.air_field.levels.size(), calc_s,
			rt.last_info.get("passes", "?"), rt.inflow_k, header.model_hash
		]
	)
	rt.stop()
	rt.queue_free()
	atmo.free()
	terrain.queue_free()
	return 0


func _check() -> int:
	var root := _out_root()
	var jobs: Array[Dictionary] = []
	var ids: Array = [String(_a.id)] if _a.has("id") else Array(DirAccess.get_directories_at(root))
	for id: String in ids:
		var air_dir := root.path_join(id).path_join("air")
		var names: Array = [String(_a.site) + ".json"] if _a.has("site") else []
		if names.is_empty():
			for f in DirAccess.get_files_at(air_dir):
				if f.ends_with(".json"):
					names.append(f)
		for n: String in names:
			jobs.append({id = id, site = n.trim_suffix(".json"), path = air_dir.path_join(n)})
	if jobs.is_empty():
		print("bake_air --check: файлов нет в %s" % root)
		return 0
	var stale := 0
	var terrains := {}
	for j in jobs:
		var h := AirBakedField.read_header(j.path)
		var why := ""
		if h.is_empty():
			why = "нет файла или заголовок не читается"
		else:
			if not terrains.has(j.id):
				terrains[j.id] = _load_terrain(j.id)
			var terrain: Terrain = terrains[j.id]
			var site := _site_of(terrain, j.site) if terrain != null else {}
			var weather := _weather_of(j.id, j.site)
			if site.is_empty() or weather.is_empty():
				why = "старт или набор погоды удалены из конфига места"
			else:
				why = AirBakedField.key_diff(h.get("key"), _key_of(terrain, j.id, site, weather))
				if why == "" and not AirBakedField.model_hash_ok(h):
					why = "model_hash: %s ≠ %s (модель воздуха изменилась)" % [h.get("model_hash"), AirBakedField.model_hash()]
		if why == "":
			print("bake_air --check: %s/%s — актуально" % [j.id, j.site])
		else:
			stale += 1
			print("bake_air --check: %s/%s — УСТАРЕЛО: %s" % [j.id, j.site, why])
	return 1 if stale > 0 else 0


## Пояс часов места, как Game._clock_utc_offset.
func _clock_utc_offset(terrain: Terrain) -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)


func _make_atmosphere(
	terrain: Terrain, weather: Dictionary, sp: Vector3, utc: float, c: Dictionary
) -> Atmosphere:
	var fs := FlightSettings.defaults()
	fs.month = int(weather.month)
	fs.day = int(weather.day)
	fs.start_hour = float(weather.start_hour)
	fs.sky = String(weather.sky)
	fs.temperature_c = float(weather.temperature_c)
	fs.wind_from_deg = float(weather.wind_from_deg)
	fs.wind_speed_kmh = float(weather.wind_speed_ms) * 3.6
	fs.wind_into_launch = false
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples), float(wc.valley_percentile)
	)
	ctx.merge(
		{
			"month": fs.month, "day": fs.day, "lat": terrain.center_lat, "lon": terrain.center_lon,
			"utc_offset_h": utc,
		}
	)
	var w := WeatherModel.derive(fs.forecast(), ctx, {}, fs.start_hour)
	w.thermal_mode = "static"
	w.static_thermals = []
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_ground(terrain.height_at, terrain.sun_exposure_at, terrain.surface_at)
	atmo.set_wind(float(c.u10) * 3.6, float(c.wdir), sp.y)
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	return atmo
