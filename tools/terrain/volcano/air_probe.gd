extends Node
## Быстрая проверка воздуха вулканического острова (VI-1, для шлюза — не подбор погоды): поле GPU как в игре
## (AirRuntime.load_field: область + окна у старта), выборка в заданных точках.
## Основа — tools/research/wind_compare/dump_wind.gd (настройка атмосферы и поля), плюс выбор старта,
## дата (месяц, день), t_max и выдача w_conv поля и силы источника термиков.
## Запуск — из air_quick.py (окно, DISPLAY=:0). Аргументы после --:
##   --site=<id старта> --wind=<м/с на 10 м> --from=<°> --hour=<ч> --loc=<id места> --month=1 --day=15 --tmax=<°C|nan>
##   --sky=clear|partly|overcast --points=<json: [[x, z, agl], …] мира> --out=<json>
## Выход: cond, info (поле: solver_ok, blend_fraction…), rows: [x, z, agl, ground_h, класс, сила источника,
##   u_восток, u_север, w (air_velocity_at), w_mean (mean_wind_at), w_conv, доля поля].

var _a: Dictionary = {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var loc_id := String(_a.get("loc", "volcano_island"))
	var wind_ms := float(_a.get("wind", 6.0))
	var wdir := float(_a.get("from", 270.0))
	var hour := float(_a.get("hour", 12.0))
	var month := int(_a.get("month", 1))
	var day := int(_a.get("day", 15))
	var t_max := float(_a.get("tmax", "nan")) if String(_a.get("tmax", "nan")) != "nan" else NAN
	var sky := String(_a.get("sky", "partly"))
	var out_path := String(_a.get("out", "out/probe.json"))
	var pts: Variant = JSON.parse_string(FileAccess.get_file_as_string(String(_a.get("points", ""))))
	if not pts is Array:
		push_error("нет точек")
		return

	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location(loc_id):
		push_error("нет места")
		return
	while terrain.has_method("relief_busy") and terrain.relief_busy():
		await get_tree().process_frame
	var cfg: Dictionary = Config.get_config("locations/" + loc_id)
	var site: Dictionary = cfg.start_sites[0]
	for s: Dictionary in cfg.start_sites:
		if String(s.id) == String(_a.get("site", "")):
			site = s
	var s2 := terrain.latlon_to_local(float(site.lat), float(site.lon))
	var sx := s2.x
	var sz := s2.y
	var s_h := terrain.height_at(sx, sz)

	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = wind_ms * 3.6
	w.wind_from_deg = wdir
	w.thermal_mode = "static"
	w.static_thermals = []
	var atmo = Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.seed_value = 20261016
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	atmo.set_wind(wind_ms * 3.6, wdir, s_h)
	atmo.turbulence_enabled = false
	atmo.wave.enabled = false
	atmo.time_s = hour * 3600.0
	atmo.set_focus(Vector3(sx, s_h, sz))
	atmo.step(0.01)

	var info := {}
	var rt: Node = load("res://scripts/atmosphere/air_model/air_runtime.gd").new()
	add_child(rt)
	await get_tree().process_frame
	var c := {hour = hour, u10 = wind_ms, wdir = wdir, t_max = t_max, sky = sky}
	rt.setup(atmo, rt.get_script().place_of(terrain, float(cfg.utc_offset_h), month, day), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return Vector3(sx, s_h, sz)
	info["unavailable"] = rt.unavailable_reason()
	if info.unavailable == "":
		var t0 := Time.get_ticks_msec()
		info["solver_ok"] = await rt.load_field()
		info["solver_wall_s"] = (Time.get_ticks_msec() - t0) / 1000.0
		info["solver_err"] = rt.last_error
		info["solver_info"] = rt.last_info
	for i in 600:
		await get_tree().process_frame
		if not rt.busy() and i > 30:
			break
	var af: Object = atmo.get("air_field")
	for i in 200:
		atmo.step(0.5)
		atmo.time_s = hour * 3600.0
		if af.call("blend_fraction") >= 1.0:
			break
	info["blend_fraction"] = af.call("blend_fraction")
	var lv: Array = []
	for f in af.get("levels"):
		lv.append({"dx": f.dx, "nx": f.nx, "ny": f.ny, "x0": f.x0, "y0": f.y0})
	info["levels"] = lv
	rt.queue_free()
	atmo.time_s = hour * 3600.0
	atmo.set_focus(Vector3(sx, s_h, sz))
	atmo.step(0.0)
	atmo.time_s = hour * 3600.0

	var rows: Array = []
	for p: Array in pts:
		var x := float(p[0])
		var z := float(p[1])
		var gh := terrain.height_at(x, z)
		var q := Vector3(x, gh + float(p[2]), z)
		var v: Vector3 = atmo.air_velocity_at(q)
		var m: Vector3 = atmo.mean_wind_at(q)
		var wc: Vector2 = af.call("sample_w_conv", q, gh)
		rows.append([
			x, z, float(p[2]), snappedf(gh, 0.01), terrain.surface_at(x, z),
			snappedf(terrain.thermal_source_strength_at(x, z), 0.001),
			snappedf(v.x, 0.001), snappedf(-v.z, 0.001), snappedf(v.y, 0.001), snappedf(m.y, 0.001),
			snappedf(wc.x / wc.y if wc.y > 0.0 else 0.0, 0.001), snappedf(wc.y, 0.001),
		])
	var res := {
		"cond": {
			"loc": loc_id, "site": site.id, "start_world": [sx, sz], "start_h": s_h, "hour": hour,
			"month": month, "day": day, "wind_ms_10m": wind_ms, "wind_from": wdir, "t_max": t_max if not is_nan(t_max) else null,
			"sky": sky, "weather": "weather/medium", "turbulence": false, "thermals_bubbles": false,
		},
		"info": info, "rows": rows,
	}
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var fo := FileAccess.open(out_path, FileAccess.WRITE)
	fo.store_string(JSON.stringify(res))
	fo.close()
	print("air_probe: ", out_path, " ", JSON.stringify(info).left(300))
