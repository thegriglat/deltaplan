extends Node
## TW-1: пульсации ветра у старта. Мир как в e2e (меню → первый старт, сид) или test_matrix
## (--tw-flow=matrix --tw-wind=<км/ч>); пилот стоит (автопилота нет), Game.tick(1/120) T секунд.
## В точках «старт» и «30 м по курсу» на высотах 1,6 / 4 / 10 м над землёй каждые 1/30 с —
## air_velocity_at и mean_wind_at. Итог: <out>/turb.jsonl — строка на (место, сид, точка, высота):
## средние и σ составляющих (по курсу u, поперёк v, вертикаль w), mean_wind_at, σ/U,
## время корреляции u и w (до первого нуля автокорреляции), а также для пары точек на
## ±0,4 размаха (9,3 м · 0,8 / 2) — σ разности w на концах консолей.
## godot --headless --path . res://tools/research/takeoff_wind/TW-1/turb.tscn -- \
##   --tw-locs=training_island --tw-seeds=1,2 --tw-out=<dir> [--tw-T=60]

const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 1.0 / 120.0
const HEIGHTS := [1.6, 4.0, 10.0]
const DISTS := [0.0, 30.0]
const HALF_TIPS := 3.72

var locs: PackedStringArray = []
var seeds: Array[int] = []
var out_dir := ""
var flow := "e2e"
var wind_kmh := 18.0
var dur := 60.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--tw-"):
			continue
		var kv := a.substr(5).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"locs": locs = v.split(",", false)
			"seeds":
				for s in v.split(",", false):
					if s.contains(".."):
						var p := s.split("..")
						for k in range(int(p[0]), int(p[1]) + 1):
							seeds.append(k)
					else:
						seeds.append(int(s))
			"out": out_dir = v
			"flow": flow = v
			"wind": wind_kmh = float(v)
			"T": dur = float(v)
	if seeds.is_empty():
		seeds = [1]
	if not out_dir.begins_with("/"):
		out_dir = ProjectSettings.globalize_path("res://") + out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	var f := FileAccess.open(out_dir + "/turb.jsonl", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(out_dir + "/turb.jsonl", FileAccess.WRITE)
	f.seek_end()
	for loc in locs:
		for sd in seeds:
			for r: Dictionary in await _one(loc, sd):
				f.store_line(JSON.stringify(r))
				f.flush()
	f.close()
	get_tree().quit(0)


func _one(loc_id: String, seed_v: int) -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var opts: LaunchOptions = main.get("opts")
	opts.seed = seed_v
	if flow == "matrix":
		await main.call("load_menu_world")
		opts.autostart = true
		var s := FlightSettings.new()
		s.location_id = loc_id
		s.wing = "wings/training"
		s.temperature_c = 31.0
		s.wind_speed_kmh = wind_kmh
		game.world_seed = seed_v
		await main.call("_fly", s)
	else:
		var menu: StartMenu = main.get_node("UI/StartMenu")
		for i in 600:
			if menu.visible:
				break
			await get_tree().process_frame
		var fss: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
		menu.setup_requested.emit()
		var place := {}
		for p: Dictionary in (fss.get("_places_catalog") as Dictionary).get("takeoffs", []):
			if String(p.get("location", "")) == loc_id:
				place = p
				break
		if Locations.is_training_only(loc_id):
			var st0: Dictionary = (Locations.config(loc_id).get("start_sites", []) as Array)[0]
			place = {"id": "builtin/%s/%s" % [loc_id, st0.id], "lat": st0.lat, "lon": st0.lon, "country": "",
				"location": loc_id, "site": st0.id, "heading_deg": st0.heading_deg}
		fss.call("_on_place_chosen", place)
		(fss.get("_done_btn") as Button).emit_signal("pressed")
		(menu.get("_fly_btn") as Button).emit_signal("pressed")
	for i in 3000:
		if int(main.get("state")) == 2:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var tel := game.glider.get_telemetry()
	var p0 := tel.position
	var h := deg_to_rad(tel.heading_deg)
	var fwd := Vector3(sin(h), 0.0, -cos(h))
	var right := Vector3(cos(h), 0.0, sin(h))
	var air: Node = game.air
	var pts: Array = []  # [d, z, pos]
	for d: float in DISTS:
		var p := p0 + fwd * d
		var gh: float = game.terrain.height_at(p.x, p.z)
		for z: float in HEIGHTS:
			pts.append([d, z, Vector3(p.x, gh + z, p.z)])
	var series: Array = []  # на точку: [us, vs, ws, dws]
	for _p in pts:
		series.append([[], [], [], []])
	var means: Array = []
	for pp: Array in pts:
		means.append(air.call("mean_wind_at", pp[2]))
	var n := int(dur / DT)
	for k in n:
		game.tick(DT)
		if k % 4 != 0:
			continue
		for i in pts.size():
			var q: Vector3 = pts[i][2]
			var a: Vector3 = air.call("air_velocity_at", q)
			var s: Array = series[i]
			(s[0] as Array).append(-a.dot(fwd))
			(s[1] as Array).append(a.dot(right))
			(s[2] as Array).append(a.y)
			var wl: Vector3 = air.call("air_velocity_at", q - right * HALF_TIPS)
			var wr: Vector3 = air.call("air_velocity_at", q + right * HALF_TIPS)
			(s[3] as Array).append(wl.y - wr.y)
	var out: Array = []
	for i in pts.size():
		var s: Array = series[i]
		var mw: Vector3 = means[i]
		var um := _mean(s[0])
		out.append({"loc": loc_id, "seed": seed_v, "flow": flow, "wind_kmh": wind_kmh if flow == "matrix" else -1.0,
			"d": pts[i][0], "z": pts[i][1], "T": dur,
			"u_mean": snappedf(um, 0.01), "v_mean": snappedf(_mean(s[1]), 0.01), "w_mean": snappedf(_mean(s[2]), 0.01),
			"su": snappedf(_sd(s[0]), 0.01), "sv": snappedf(_sd(s[1]), 0.01), "sw": snappedf(_sd(s[2]), 0.01),
			"s_dw_tips": snappedf(_sd(s[3]), 0.01), "dw_tips_absmax": snappedf(_absmax(s[3]), 0.01),
			"u_min": snappedf((s[0] as Array).min(), 0.01), "u_max": snappedf((s[0] as Array).max(), 0.01),
			"w_min": snappedf((s[2] as Array).min(), 0.01), "w_max": snappedf((s[2] as Array).max(), 0.01),
			"mean_u_fwd": snappedf(-mw.dot(fwd), 0.01), "mean_w": snappedf(mw.y, 0.01),
			"Iu": snappedf(_sd(s[0]) / maxf(absf(um), 0.1), 0.001),
			"Tu_s": snappedf(_tcorr(s[0], 1.0 / 30.0), 0.01), "Tw_s": snappedf(_tcorr(s[2], 1.0 / 30.0), 0.01)})
		print("TURB %s" % JSON.stringify(out[-1]))
	main.queue_free()
	for i in 3:
		await get_tree().process_frame
	get_tree().paused = false
	return out


static func _mean(a: Array) -> float:
	var s := 0.0
	for x: float in a:
		s += x
	return s / maxf(a.size(), 1.0)


static func _sd(a: Array) -> float:
	var m := _mean(a)
	var s := 0.0
	for x: float in a:
		s += (x - m) * (x - m)
	return sqrt(s / maxf(a.size() - 1.0, 1.0))


static func _absmax(a: Array) -> float:
	var m := 0.0
	for x: float in a:
		m = maxf(m, absf(x))
	return m


## Время корреляции: интеграл автокорреляции до первого нуля, с.
static func _tcorr(a: Array, dt: float) -> float:
	var m := _mean(a)
	var n := a.size()
	var v := 0.0
	for x: float in a:
		v += (x - m) * (x - m)
	if v <= 0.0:
		return 0.0
	var t := 0.0
	for lag in range(1, n / 2):
		var c := 0.0
		for i in n - lag:
			c += (float(a[i]) - m) * (float(a[i + lag]) - m)
		c /= v
		if c <= 0.0:
			break
		t += c * dt
	return t
