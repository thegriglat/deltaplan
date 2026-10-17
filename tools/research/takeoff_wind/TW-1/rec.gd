extends Node
## TW-1: запись разбега и первых секунд полёта (по кадрам) с вариантами автопилота и воздуха.
## Повторяет путь tests/game/test_e2e.gd (меню → «Полёт…» → первый старт → «Лететь», шаг
## Game.tick(1/120) вручную) или tests/stability/test_matrix.gd (main._fly с прогнозом), но
## сид мира задаётся (--tw-seeds), чтобы флейк e2e (новый случайный сид на каждое «Лететь»)
## стал воспроизводимым. Код игры не меняет: автопилот-варианты — подкласс (ap_variants.gd),
## воздух — обёртка над glider.air_fn.
##
## godot --headless --path . res://tools/research/takeoff_wind/TW-1/rec.tscn -- \
##   --tw-flow=e2e --tw-locs=training_island --tw-seeds=1,2,3 --tw-ap=base --tw-air=field \
##   --tw-out=tools/research/takeoff_wind/TW-1/out/x [--tw-trace=1] [--tw-tag=x]
## matrix: --tw-flow=matrix --tw-wing=wings/sport --tw-weather=strong --tw-seeds=-1
## --tw-worldt=T — Game.set_world_time(T) в момент начала разбега (наблюдение 2).
## Итог: <out>/runs.jsonl (строка на прогон), трасса <out>/trace_<loc>_<seed>.csv (30 Гц).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const APV := preload("res://tools/research/takeoff_wind/TW-1/ap_variants.gd")
const MAX_TAKEOFF_S := 15.0
const AIR_WATCH_S := 25.0  ## сколько секунд полёта смотреть после отрыва (взведение/провал)
const MAX_MENU_FRAMES := 600
const MAX_LOAD_FRAMES := 3000
const WEATHERS := {"weak": [20.0, 7.0], "medium": [26.0, 11.0], "strong": [31.0, 18.0]}

var flow := "e2e"
var locs: PackedStringArray = []
var seeds: Array[int] = []
var ap := "base"
var air_mode := "field"
var out_dir := ""
var trace := false
var tag := ""
var wing := "wings/training"
var weather := "strong"
var world_t := -1.0
var _f: FileAccess


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--tw-"):
			continue
		var kv := a.substr(5).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"flow": flow = v
			"locs": locs = v.split(",", false)
			"seeds":
				for s in v.split(",", false):
					if s.contains(".."):
						var p := s.split("..")
						for k in range(int(p[0]), int(p[1]) + 1):
							seeds.append(k)
					else:
						seeds.append(int(s))
			"ap": ap = v
			"air": air_mode = v
			"out": out_dir = v
			"trace": trace = v != "0"
			"tag": tag = v
			"wing": wing = v
			"weather": weather = v
			"worldt": world_t = float(v)
	if seeds.is_empty():
		seeds = [-1]
	if locs.is_empty():
		for l in Config.list_configs("locations"):
			locs.append(l.get_file())
	if out_dir == "":
		push_error("rec: нужен --tw-out")
		get_tree().quit(2)
		return
	if not out_dir.begins_with("/"):
		out_dir = ProjectSettings.globalize_path("res://") + out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	_f = FileAccess.open(out_dir + "/runs.jsonl", FileAccess.READ_WRITE)
	if _f == null:
		_f = FileAccess.open(out_dir + "/runs.jsonl", FileAccess.WRITE)
	_f.seek_end()
	_run_all()


func _run_all() -> void:
	for loc in locs:
		for sd in seeds:
			var r: Dictionary = await _run(loc, sd)
			_f.store_line(JSON.stringify(r))
			_f.flush()
			print("REC %s" % JSON.stringify(r))
	_f.close()
	get_tree().quit(0)


func _run(loc_id: String, seed_v: int) -> Dictionary:
	var res := {"loc": loc_id, "seed": seed_v, "ap": ap, "air": air_mode, "flow": flow, "tag": tag,
		"wing": wing if flow == "matrix" else "", "weather": weather if flow == "matrix" else "",
		"world_t": world_t, "result": "error"}
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var opts: LaunchOptions = main.get("opts")
	opts.seed = seed_v
	if flow == "e2e":
		if not await _fly_e2e(main, game, loc_id):
			await _free(main)
			return res
	else:
		await main.call("load_menu_world")
		opts.autostart = true
		var s := FlightSettings.new()
		s.location_id = loc_id
		s.wing = wing
		s.temperature_c = float(WEATHERS[weather][0])
		s.wind_speed_kmh = float(WEATHERS[weather][1])
		game.world_seed = seed_v
		await main.call("_fly", s)
		if int(main.get("state")) != 2:
			await _free(main)
			return res
	game.autopilot = APV.make(ap)
	if "bar_fn" in game.autopilot:
		var gl := game.glider
		game.autopilot.set("bar_fn", func() -> float: return gl.control.pitch)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	res.merge(await _fly_loop(game, loc_id, seed_v), true)
	game.autopilot.release_all()
	await _free(main)
	return res


func _fly_e2e(main: Node, game: Game, loc_id: String) -> bool:
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in MAX_MENU_FRAMES:
		if menu.visible:
			break
		await get_tree().process_frame
	if not menu.visible:
		return false
	game.autopilot = APV.make(ap)
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
	if place.is_empty():
		return false
	fss.call("_on_place_chosen", place)
	(fss.get("_done_btn") as Button).emit_signal("pressed")
	(menu.get("_fly_btn") as Button).emit_signal("pressed")
	for i in MAX_LOAD_FRAMES:
		if int(main.get("state")) == 2:
			return true
		await get_tree().process_frame
	return false


## Воздух для варианта: field — как есть; mean — mean_wind_at (средний поток поля в точке, без
## термиков и пульсаций, с механической вертикалью поля); steady — постоянный горизонтальный
## вектор mean_wind_at у крыла на старте (w = 0) — «ровный ветер на плоском месте» по воздуху.
func _install_air(game: Game, p0: Vector3) -> Dictionary:
	var base: Callable = game.glider.air_fn
	var air: Node = game.air
	var info := {}
	match air_mode:
		"mean":
			game.glider.set_air_fn(func(p: Vector3) -> Vector3: return air.call("mean_wind_at", p))
		"steady":
			var m: Vector3 = air.call("mean_wind_at", p0)
			var c := Vector3(m.x, 0.0, m.z)
			info["steady_ms"] = snappedf(c.length(), 0.01)
			game.glider.set_air_fn(func(_p: Vector3) -> Vector3: return c)
		"noturb":
			air.set("turbulence_enabled", false)
		_:
			if air_mode.begins_with("turb"):
				# turbK: средний поток + K·(поле − средний) — пульсации (и термики) ×K
				var kk := float(air_mode.substr(4))
				game.glider.set_air_fn(func(p: Vector3) -> Vector3:
					var mw: Vector3 = air.call("mean_wind_at", p)
					return mw + (base.call(p) - mw) * kk)
	info["base_valid"] = base.is_valid()
	return info


func _fly_loop(game: Game, loc_id: String, seed_v: int) -> Dictionary:
	var g := game.glider
	var m = g.model
	var tel0 := g.get_telemetry()
	var wing_h := 1.6
	var p0 := tel0.position + Vector3.UP * wing_h
	var r := _install_air(game, p0)
	r["world_key"] = game.world_key()
	r["pendulum"] = g.is_pendulum()
	var ended: Array = []
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))
	var failed_reason := [""]
	g.takeoff_failed.connect(func(reason: String) -> void: failed_reason[0] = reason)
	var tr: FileAccess = null
	if trace:
		tr = FileAccess.open("%s/trace_%s_%d.csv" % [out_dir, loc_id, seed_v], FileAccess.WRITE)
		tr.store_line("t,phase,ias,gs,alpha_m,alpha_ap,pitch,bank,hdg,agl,wu,wv,ww,dw_tips,on_ground,contact,feet_load,tension,stalled,c_pitch,c_roll,run,armed,dw_tips_mean")
	var t := 0.0
	var t_air := 0.0
	var took_off_at := -1.0
	var run_start := -1.0
	var max_agl := 0.0
	var first_flight_hdg := -1.0
	var lift := {}
	var touch_n := 0
	var was_air := false
	var w_run: Array[float] = []
	var u_run: Array[float] = []
	var max_bank_ground := 0.0
	var max_bank_air15 := 0.0
	var hdg_run0 := -1.0
	var max_hdg_dev := 0.0
	var max_dw := 0.0
	var pitch_min := 999.0
	var pitch_max := -999.0
	var world_t_done := world_t < 0.0
	var k := 0
	var prev_wind := Vector3.INF
	var max_jump := 0.0
	var max_jump_t := -1.0
	var air: Node = game.air
	while ended.is_empty():
		var tel := g.get_telemetry()
		var ph := g.phase()
		if not world_t_done and ph == "running":
			game.set_world_time(world_t)
			world_t_done = true
			r["world_t_at"] = snappedf(t, 0.01)
		game.tick(DT)
		t += DT
		k += 1
		tel = g.get_telemetry()
		ph = g.phase()
		var pos := tel.position
		var wind: Vector3 = g.air_fn.call(pos + Vector3.UP * wing_h) if g.air_fn.is_valid() else Vector3.ZERO
		var right := tel.basis.x
		var half := 0.5 * float(m.span) * 0.8
		var dw := 0.0
		if g.air_fn.is_valid():
			var hub := pos + Vector3.UP * wing_h
			dw = (g.air_fn.call(hub - right * half) as Vector3).y - (g.air_fn.call(hub + right * half) as Vector3).y
		var dw_mean := 0.0
		if air != null and air.has_method("mean_wind_at"):
			var hub2 := pos + Vector3.UP * wing_h
			dw_mean = (air.call("mean_wind_at", hub2 - right * half) as Vector3).y - (air.call("mean_wind_at", hub2 + right * half) as Vector3).y
		if prev_wind != Vector3.INF and (took_off_at < 0.0 or t_air < 15.0):
			var j := (wind - prev_wind).length()
			if j > max_jump:
				max_jump = j
				max_jump_t = t
		prev_wind = wind
		var flow_deg := rad_to_deg(asin(clampf(tel.air_velocity.y / maxf(tel.airspeed, 0.1), -1.0, 1.0)))
		var alpha_ap := tel.pitch_deg - flow_deg
		if ph == "running" and run_start < 0.0:
			run_start = t
			hdg_run0 = tel.heading_deg
		if ph in ["running", "standing", "walking"]:
			max_bank_ground = maxf(max_bank_ground, absf(tel.bank_deg))
			if run_start >= 0.0:
				w_run.append(wind.y)
				u_run.append(Vector2(wind.x, wind.z).length())
				max_dw = maxf(max_dw, absf(dw))
		if hdg_run0 >= 0.0 and took_off_at < 0.0:
			max_hdg_dev = maxf(max_hdg_dev, absf(wrapf(tel.heading_deg - hdg_run0, -180.0, 180.0)))
		if ph == "flying":
			if took_off_at < 0.0:
				took_off_at = t
				first_flight_hdg = tel.heading_deg
				lift = {"t": snappedf(t, 0.01), "ias": snappedf(tel.airspeed, 0.01),
					"gs": snappedf(tel.groundspeed, 0.01), "alpha_m": snappedf(rad_to_deg(m.alpha), 0.1),
					"alpha_ap": snappedf(alpha_ap, 0.1), "pitch": snappedf(tel.pitch_deg, 0.1),
					"bank": snappedf(tel.bank_deg, 0.1), "w": snappedf(wind.y, 0.01),
					"u": snappedf(Vector2(wind.x, wind.z).length(), 0.01),
					"run_s": snappedf(t - run_start, 0.01)}
			t_air += DT
			max_agl = maxf(max_agl, tel.altitude_agl)
			if t_air < 15.0:
				pitch_min = minf(pitch_min, tel.pitch_deg)
				pitch_max = maxf(pitch_max, tel.pitch_deg)
				max_bank_air15 = maxf(max_bank_air15, absf(tel.bank_deg))
			was_air = true
		elif was_air and ph in ["running", "standing", "walking", "landed"]:
			touch_n += 1
			was_air = false
		if tr != null and k % 4 == 0:
			var gnd = m.get("ground")
			tr.store_line("%.3f,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f,%.2f,%.2f,%.2f,%.2f,%.3f,%d,%d,%.3f,%.0f,%d,%.2f,%.2f,%d,%d,%.3f" % [
				t, ph, tel.airspeed, tel.groundspeed, rad_to_deg(m.alpha), alpha_ap, tel.pitch_deg,
				tel.bank_deg, tel.heading_deg, tel.altitude_agl, wind.x, -wind.z, wind.y, dw,
				int(tel.on_ground), int(gnd.contact) if gnd != null else -1,
				float(gnd.feet_load) if gnd != null else -1.0, float(m.get("_tension_avg")) if gnd != null else 0.0,
				int(tel.stalled), g.control.pitch, g.control.roll, int(g.control.run), int(game.stats.armed), dw_mean])
		if took_off_at < 0.0 and t > MAX_TAKEOFF_S:
			break
		if ph in ["failed"]:
			# дать FlightStats/Game выдать итог
			pass
		if game.stats.armed and t_air > 3.0:
			break
		if t_air > AIR_WATCH_S:
			break
		if t > MAX_TAKEOFF_S + AIR_WATCH_S + 10.0:
			break
	if tr != null:
		tr.close()
	var kind := ""
	if not ended.is_empty():
		kind = ended[0][0]
	var result := "ok"
	if took_off_at < 0.0:
		result = "no_takeoff"
	elif kind == "takeoff_failed" or failed_reason[0] != "":
		result = "takeoff_failed"
	elif not game.stats.armed:
		result = "not_armed"
	r["result"] = result
	r["kind"] = kind
	r["fail_reason"] = failed_reason[0]
	r["took_off_at"] = snappedf(took_off_at, 0.01)
	r["run_start"] = snappedf(run_start, 0.01)
	r["t_air"] = snappedf(t_air, 0.01)
	r["max_agl"] = snappedf(max_agl, 0.01)
	r["touches"] = touch_n
	r["liftoff"] = lift
	r["max_bank_ground"] = snappedf(max_bank_ground, 0.1)
	r["max_bank_air15"] = snappedf(max_bank_air15, 0.1)
	r["max_hdg_dev_run"] = snappedf(max_hdg_dev, 0.1)
	r["pitch_air15"] = [snappedf(pitch_min, 0.1), snappedf(pitch_max, 0.1)]
	r["max_dw_tips"] = snappedf(max_dw, 0.01)
	r["max_wind_jump_tick"] = snappedf(max_jump, 0.001)
	r["max_wind_jump_t"] = snappedf(max_jump_t, 0.01)
	r["dist"] = snappedf(game.stats.distance_from_takeoff(g.get_telemetry().position), 0.1) if took_off_at >= 0.0 else 0.0
	if not w_run.is_empty():
		r["w_run"] = [snappedf(_mean(w_run), 0.01), snappedf(w_run.min(), 0.01), snappedf(w_run.max(), 0.01)]
		r["u_run"] = [snappedf(_mean(u_run), 0.01), snappedf(u_run.min(), 0.01), snappedf(u_run.max(), 0.01)]
	return r


static func _mean(a: Array[float]) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1.0)


func _free(main: Node) -> void:
	main.queue_free()
	for i in 3:
		await get_tree().process_frame
	get_tree().paused = false
