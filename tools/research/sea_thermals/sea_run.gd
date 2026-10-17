extends Node
## VI-7: сколько источников термиков над водой — главная сцена (--autostart), поле воздуха GPU (окно),
## все источники AirThermals уровня (field.air_src) и живые термики-клетки (аналитика) после перемотки.
## Вода в точке — как Terrain.is_sea / GroundField.is_water: класс WATER или (класс NONE и высота ≤ 0,5 м).
## Аргументы после --:
##   --loc=<место> --site=<старт> | --latlon=<lat,lon>   --out=<json>
##   --hour --temp --sky --wind (м/с) --from (°)  — погода: у старта — подмена набора TI-К2 в памяти,
##   у точки — флаги запуска; --month --day — дата (набор старта или world.json → time в памяти)
##   --advance=<с>  перемотка атмосферы перед подсчётом термиков-клеток (120)

const MAIN_SCENE := preload("res://scenes/main.tscn")
const STEP_DT := 0.5
const SEA_H := 0.5  ## как Terrain.is_sea: не выше 0,5 м и класс NONE/WATER — море
const NONE := 0
const WATER := 6

var _a := {}
var _main: Node
var _game: Node
var _air: Node
var _terrain: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var loc := String(_a.get("loc", ""))
	var args := PackedStringArray(["--autostart", "--location=" + loc, "--bots=0", "--no-overlay"])
	if _a.has("site"):
		var site := String(_a.site)
		args.append("--site=" + site)
		var cfg: Dictionary = Config.get_config("locations/" + loc)
		for st: Dictionary in cfg.get("start_sites", []):
			if String(st.id) != site:
				continue
			var w: Dictionary = st.get("weather", {
				"month": 7, "day": 15, "sky": "clear", "start_hour": 12.0, "temperature_c": 25.0,
				"wind_from_deg": 0.0, "wind_ref": "start", "wind_speed_ms": 2.0})
			for k in [["month", "month"], ["day", "day"], ["hour", "start_hour"], ["sky", "sky"],
					["temp", "temperature_c"], ["wind", "wind_speed_ms"], ["from", "wind_from_deg"]]:
				if _a.has(k[0]):
					w[k[1]] = String(_a[k[0]]) if k[0] == "sky" else float(_a[k[0]])
			for k in ["month", "day"]:
				w[k] = int(w[k])
			st["weather"] = w  # только в памяти этого процесса
	else:
		args.append("--latlon=" + String(_a.get("latlon", "")))
		# дата точки — умолчание автостарта (world.json → time), только в памяти этого процесса
		var t: Dictionary = Config.get_config("world").get("time", {})
		for k in ["month", "day"]:
			if _a.has(k):
				t[k] = int(_a[k])
		for k in ["hour", "temp", "sky", "wind", "from"]:
			if _a.has(k):
				args.append("--%s=%s" % [k, _a[k]])
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	_game = _main.get_node("Game")
	for i in 40000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		push_error("sea_run: полёт не начался")
		get_tree().quit(1)
		return
	await get_tree().create_timer(3.0, true).timeout
	_air = _game.get("air")
	_terrain = _game.get("terrain")
	var settings: Object = _game.get("settings")
	var start: Vector3 = _game.get("_start_pos")
	var field: Object = _air.get("field")
	var res := {
		"cond": {
			"loc": String(_a.get("loc", "")), "site": String(_a.get("site", "")),
			"start": [start.x, start.y, start.z], "wind_kmh": settings.wind_speed_kmh,
			"wind_from": settings.wind_from_deg, "hour": settings.start_hour, "month": settings.month,
			"day": settings.day, "sky": settings.sky, "temp": settings.temperature_c,
		},
		"info": {"load_s": (Time.get_ticks_msec() - t0) / 1000.0,
			"air_field_on": _air.call("is_air_field_on"), "cloudbase_msl": _air.call("get_cloudbase_msl")},
	}
	var rt: Node = null
	for c in _game.get_children():
		if c.get_script() != null and String(c.get_script().resource_path).ends_with("air_runtime.gd"):
			rt = c
	if rt != null:
		var li: Dictionary = rt.get("last_info")
		res.info["air_runtime"] = {}
		for k in ["engine", "inflow_k", "not_converged", "hour", "baked"]:
			res.info.air_runtime[k] = li.get(k)
	# Источники поля — все сразу (весь уровень), не зависят от перемотки.
	var asrc: Object = field.get("air_src")
	var src_rows: Array = []
	if asrc != null:
		var pos: PackedVector3Array = asrc.get("pos")
		var w0: PackedFloat32Array = asrc.get("w0")
		var cols: PackedInt32Array = asrc.get("col")
		var heat: PackedFloat32Array = asrc.get("col_heat")
		res.info["level_dx"] = asrc.get("level").get("dx")
		if "land_ms" in asrc:  # VI-7: доля суши столбцов (время первой сборки; дальше — кеш)
			res.info["land_ms"] = asrc.get("land_ms")
		for s in pos.size():
			var p := pos[s]
			src_rows.append([snappedf(p.x, 0.1), snappedf(p.z, 0.1), snappedf(_h(p.x, p.z), 0.01),
				_cls(p.x, p.z), snappedf(w0[s], 0.001), snappedf(heat[cols[s]], 0.1)])
	res["sources"] = src_rows
	# Термики-клетки (аналитика вне поля) — живые после перемотки вокруг старта.
	get_tree().paused = true
	_air.set("turbulence_enabled", false)
	var n := int(ceil(float(_a.get("advance", "120")) / STEP_DT))
	for i in n:
		_air.call("step", STEP_DT)
		if i % 40 == 39:
			await get_tree().process_frame
	var air_ia := int(field.get_script().get_script_constant_map().get("_AIR_IA", 1 << 19))
	var cell_rows: Array = []
	var ths: Dictionary = field.get("thermals")
	for id: Variant in ths:
		var th: Object = ths[id]
		var cell: Vector2i = th.get("cell")
		if cell.x >= air_ia or bool(th.get("is_static")):
			continue
		var p: Vector3 = th.get("src")
		cell_rows.append([snappedf(p.x, 0.1), snappedf(p.z, 0.1), snappedf(_h(p.x, p.z), 0.01),
			_cls(p.x, p.z), snappedf(float(th.get("strength")), 0.001)])
	res["cells"] = cell_rows
	res.info["wall_s"] = (Time.get_ticks_msec() - t0) / 1000.0
	var out_path := String(_a.get("out", "sea_run.json"))
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var fo := FileAccess.open(out_path, FileAccess.WRITE)
	fo.store_string(JSON.stringify(res))
	fo.close()
	print("sea_run: ", out_path, " sources ", src_rows.size(), " cells ", cell_rows.size())
	get_tree().quit(0)


func _h(x: float, z: float) -> float:
	return float(_terrain.call("height_at", x, z))


func _cls(x: float, z: float) -> int:
	return int(_terrain.call("surface_at", x, z))
