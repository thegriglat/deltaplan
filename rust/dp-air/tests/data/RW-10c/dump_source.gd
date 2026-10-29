extends Node
## Дамп силы источников термиков из GDScript для rust/dp-air/tests/terms_thermal_src.rs (RW-10c).
## Эталон: опорная ревизия c591b1026 (W8), не эта копия. Запуск (из корня копии с опорной ревизией,
## dump_source.gd и dump_source.tscn скопированы в корень; Godot — под замком cpu, временный профиль):
##   godot --headless --path . res://dump_source.tscn -- --out=<каталог>  (dump_source.tscn рядом, Node со скриптом)
## На каждое место (сетка точек шаг 50 м вокруг первого старта, со сдвигом от узлов растра 25 м):
##   <место>.src.f32  — AirPlaceData.source_at (растровый путь без рельефа игры), n значений;
##   для мест с рельефом игры ещё Terrain.thermal_source_strength_water на каждый час манифеста
##   (n значений на час), <место>.edge.f32 — Terrain._edge_proximity (n), <место>.cls.u8 —
##   Terrain.surface_at (n). Всё f32 LE, строка j (z) к +Z, индекс j * nx + i.
## manifest.json — ревизия, сетки, входы на час (направления солнца по классам, вода, ночь).

const FIX := "res://tests/fixtures/wind"
const STEP := 50.0
const HALF := 4000.0
const OFFSET := Vector2(12.5, 7.5)
const HOURS := [6.0, 9.0, 12.0, 15.0, 18.0, 21.5]
const FORECAST_T_MAX := 24.0
const FORECAST_WIND_KMH := 10.0
const PLACES := ["ongudai", "training_island", "volcano_island", "synthetic"]

var _out := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	Locations.fixtures_root = "res://tests/fixtures/locations"
	_run.call_deferred()


func _run() -> void:
	await get_tree().process_frame
	var rev: Array = []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "HEAD"], rev)
	var manifest := {
		revision = String(rev[0]).strip_edges() if not rev.is_empty() else "",
		godot = Engine.get_version_info().string,
		step_m = STEP, half_m = HALF, offset = [OFFSET.x, OFFSET.y],
		forecast = {t_max_c = FORECAST_T_MAX, wind_kmh = FORECAST_WIND_KMH},
		places = [],
	}
	for name in PLACES:
		var e := await _place(String(name))
		if e.is_empty():
			get_tree().quit(1)
			return
		manifest.places.append(e)
	var f := FileAccess.open(_out.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, "\t", true))
	f.close()
	get_tree().quit(0)


func _load_data(name: String) -> AirPlaceData:
	var head: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/places/%s.json" % [FIX, name]))
	var bin := FileAccess.get_file_as_bytes("%s/places/%s.bin" % [FIX, name])
	var n := int(head.grid.width) * int(head.grid.height)
	var hs := PackedFloat32Array()
	hs.resize(n)
	var h_off := float(head.h_offset)
	var h_scale := float(head.h_scale)
	for k in n:
		hs[k] = h_off + bin.decode_s16(2 * k) * h_scale
	var moist := PackedFloat32Array()
	moist.resize(n)
	for k in n:
		moist[k] = bin[4 * n + k] / 255.0
	var p := AirPlaceData.from_arrays(head, hs, bin.slice(2 * n, 3 * n), bin.slice(3 * n, 4 * n), moist)
	return p


func _place(name: String) -> Dictionary:
	var pd := _load_data(name)
	var head: Dictionary = pd.header
	var site: Dictionary = head.start_sites[0]
	var x0 := roundf(float(site.x) / STEP) * STEP - HALF + OFFSET.x
	var z0 := roundf(float(site.z) / STEP) * STEP - HALF + OFFSET.y
	var nn := int(2.0 * HALF / STEP) + 1
	var src := PackedFloat32Array()
	src.resize(nn * nn)
	for j in nn:
		for i in nn:
			src[j * nn + i] = pd.source_at(x0 + i * STEP, z0 + j * STEP)
	_write(name + ".src.f32", src.to_byte_array())
	var entry := {name = name, x0 = x0, z0 = z0, nx = nn, nz = nn, hours = [], terrain = false}
	if name == "synthetic":
		return entry
	# --- рельеф игры
	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location(name):
		push_error("dump_source: %s не загрузился" % name)
		return {}
	terrain.wait_relief()
	var loc: Dictionary = head.loc
	var month := int(loc.month)
	var day := int(loc.day)
	var utc := float(loc.utc_offset_h)
	var lat := float(loc.center_lat)
	var lon := float(loc.center_lon)
	var heating := SurfaceHeating.new()
	heating.setup(lat, lon, month, day, utc)
	var wcfg := WeatherModel.config()
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples), float(wcfg.valley_percentile)
	)
	wctx.merge({month = month, day = day, lat = lat, lon = lon, utc_offset_h = utc})
	var wcf: Dictionary = SurfaceHeat.config().water
	var z := float(wctx.get("valley_msl_m", 0.0))
	entry.terrain = true
	entry.valley_msl_m = z
	entry.rock_slope_deg = float(Config.value("world", "terrain_look.rock_slope_deg", 90.0))
	var edge := PackedFloat32Array()
	edge.resize(nn * nn)
	var cls := PackedByteArray()
	cls.resize(nn * nn)
	for j in nn:
		for i in nn:
			var x := x0 + i * STEP
			var zz := z0 + j * STEP
			edge[j * nn + i] = terrain._edge_proximity(x, zz)
			cls[j * nn + i] = terrain.surface_at(x, zz)
	_write(name + ".edge.f32", edge.to_byte_array())
	_write(name + ".cls.u8", cls)
	for hour: float in HOURS:
		var dirs := heating.directions(hour)
		var to_sun := AtmoDay.sun_direction(hour, lat, lon, month, day, utc)
		var water := {
			"t_water_c": SurfaceHeat.water_temp_c(month, day, z, wctx, wcf),
			"t_air_c": SurfaceHeat.air_temp_c(hour, FORECAST_T_MAX, z, wctx, wcf),
			"u_ms": FORECAST_WIND_KMH / 3.6,
			"z_m": z,
		}
		var night := heating.built_night(hour)
		var vals := PackedFloat32Array()
		vals.resize(nn * nn)
		for j in nn:
			for i in nn:
				vals[j * nn + i] = terrain.thermal_source_strength_water(
					x0 + i * STEP, z0 + j * STEP, dirs, to_sun, water, night
				)
		_write("%s.h%s.f32" % [name, str(hour).replace(".", "_")], vals.to_byte_array())
		var ds: Array = []
		for d in dirs:
			ds.append([d.x, d.y, d.z])
		entry.hours.append({
			hour = hour, class_sun = ds, to_sun = [to_sun.x, to_sun.y, to_sun.z],
			water = water, night = night,
		})
	terrain.queue_free()
	return entry


func _write(file: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(_out.path_join(file), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
