extends Node
## TW-1: test_matrix с записью разбега — тот же порядок и та же последовательность полётов в одном
## main (tests/stability/test_matrix.gd: load_menu_world, autostart, _fly(s) на каждое сочетание,
## 300 с полёта, сид — atmosphere.json), но на каждое сочетание — строка итога и трасса разбега
## (30 Гц, до 25 с после отрыва). Варианты автопилота и воздуха — как rec.gd (--tw-ap, --tw-air).
## godot --headless --path . res://tools/research/takeoff_wind/TW-1/rec_seq.tscn -- \
##   --tw-out=<dir> [--tw-ap=base] [--tw-air=field] [--tw-only=altai,aushkul] [--tw-flight=300]

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const APV := preload("res://tools/research/takeoff_wind/TW-1/ap_variants.gd")
const MAX_GROUND_S := 20.0
const WINGS := ["wings/training", "wings/sport", "wings/laminar"]
const WEATHERS := {"weak": [20.0, 7.0], "medium": [26.0, 11.0], "strong": [31.0, 18.0]}
const TRACE_AIR_S := 25.0

var out_dir := ""
var ap := "base"
var air_mode := "field"
var only: PackedStringArray = []
var flight_s := 300.0
var _f: FileAccess


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--tw-"):
			continue
		var kv := a.substr(5).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out": out_dir = v
			"ap": ap = v
			"air": air_mode = v
			"only": only = v.split(",", false)
			"flight": flight_s = float(v)
	if not out_dir.begins_with("/"):
		out_dir = ProjectSettings.globalize_path("res://") + out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	_f = FileAccess.open(out_dir + "/runs.jsonl", FileAccess.WRITE)
	_run()


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.autopilot = APV.make(ap)
	(main.get("opts") as LaunchOptions).autostart = true
	game.process_mode = Node.PROCESS_MODE_DISABLED
	for loc_name in Config.list_configs("locations"):
		var loc_id: String = loc_name.get_file()
		for wing in WINGS:
			for weather in WEATHERS:
				var r: Dictionary = await _combo(main, game, loc_id, wing, weather)
				_f.store_line(JSON.stringify(r))
				_f.flush()
				print("SEQ %s" % JSON.stringify(r))
	_f.close()
	main.queue_free()
	get_tree().paused = false
	for i in 3:
		await get_tree().process_frame
	get_tree().quit(0)


func _combo(main: Node, game: Game, loc_id: String, wing: String, weather: String) -> Dictionary:
	var s := FlightSettings.new()
	s.location_id = loc_id
	s.wing = wing
	s.temperature_c = float(WEATHERS[weather][0])
	s.wind_speed_kmh = float(WEATHERS[weather][1])
	await main.call("_fly", s)
	var r := {"loc": loc_id, "wing": wing, "weather": weather, "ap": ap, "air": air_mode, "flow": "mseq",
		"seed": -1, "tag": "mseq_%s_%s" % [ap, air_mode], "result": "error"}
	if int(main.get("state")) != 2:
		return r
	game.autopilot = APV.make(ap)
	if "bar_fn" in game.autopilot:
		var gl0 := game.glider
		game.autopilot.set("bar_fn", func() -> float: return gl0.control.pitch)
	var g := game.glider
	var m = g.model
	var air: Node = game.air
	var tel0 := g.get_telemetry()
	if air_mode == "steady":
		var mw: Vector3 = air.call("mean_wind_at", tel0.position + Vector3.UP * 1.6)
		var c := Vector3(mw.x, 0.0, mw.z)
		g.set_air_fn(func(_p: Vector3) -> Vector3: return c)
	elif air_mode == "mean":
		g.set_air_fn(func(p: Vector3) -> Vector3: return air.call("mean_wind_at", p))
	air.set("turbulence_enabled", air_mode != "noturb")
	r["hour"] = snappedf(float(game.sky.clock.hour), 0.001)
	r["world_key"] = game.world_key()
	var ended: Array = []
	var conn := func(k: String, info: Dictionary) -> void: ended.append([k, info])
	game.flight_ended.connect(conn)
	var fr := [""]
	var conn2 := func(reason: String) -> void: fr[0] = reason
	g.takeoff_failed.connect(conn2)
	var tr := FileAccess.open("%s/trace_%s_%s_%s.csv" % [out_dir, loc_id, wing.get_file(), weather], FileAccess.WRITE)
	tr.store_line("t,phase,ias,gs,alpha_m,pitch,bank,hdg,agl,wu,wv,ww,dw_tips,feet_load,c_pitch,c_roll,roll_rate")
	var t := 0.0
	var t_air := 0.0
	var took := -1.0
	var max_bank_g := 0.0
	var max_hdg := 0.0
	var hdg0 := -1.0
	var max_bank_a := 0.0
	var max_dw := 0.0
	var k := 0
	var prev_bank := 0.0
	while t < MAX_GROUND_S + flight_s + 5.0 and ended.is_empty():
		game.tick(DT)
		t += DT
		k += 1
		var tel := g.get_telemetry()
		var ph := g.phase()
		var pos := tel.position
		var hub := pos + Vector3.UP * 1.6
		var wind: Vector3 = g.air_fn.call(hub)
		var right := tel.basis.x
		var half := 0.4 * float(m.span)
		var dw: float = (g.air_fn.call(hub - right * half) as Vector3).y - (g.air_fn.call(hub + right * half) as Vector3).y
		var rate := (tel.bank_deg - prev_bank) / DT
		prev_bank = tel.bank_deg
		if hdg0 < 0.0 and ph == "running":
			hdg0 = tel.heading_deg
		if ph != "flying" and took < 0.0:
			max_bank_g = maxf(max_bank_g, absf(tel.bank_deg))
			max_dw = maxf(max_dw, absf(dw))
			if hdg0 >= 0.0:
				max_hdg = maxf(max_hdg, absf(wrapf(tel.heading_deg - hdg0, -180.0, 180.0)))
		if ph == "flying":
			if took < 0.0:
				took = t
				r["liftoff"] = {"ias": snappedf(tel.airspeed, 0.01), "alpha_m": snappedf(rad_to_deg(m.alpha), 0.1),
					"bank": snappedf(tel.bank_deg, 0.1), "w": snappedf(wind.y, 0.01), "u": snappedf(Vector2(wind.x, wind.z).length(), 0.01)}
			t_air += DT
			if t_air < 15.0:
				max_bank_a = maxf(max_bank_a, absf(tel.bank_deg))
			if t_air >= flight_s:
				break
		elif t > MAX_GROUND_S and t_air == 0.0:
			break
		if k % 4 == 0 and (took < 0.0 or t_air < TRACE_AIR_S):
			var gnd = m.get("ground")
			tr.store_line("%.3f,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%.2f,%.2f,%.1f" % [
				t, ph, tel.airspeed, tel.groundspeed, rad_to_deg(m.alpha), tel.pitch_deg, tel.bank_deg,
				tel.heading_deg, tel.altitude_agl, wind.x, -wind.z, wind.y, dw,
				float(gnd.feet_load) if gnd != null else -1.0, g.control.pitch, g.control.roll, rate])
	tr.close()
	game.flight_ended.disconnect(conn)
	g.takeoff_failed.disconnect(conn2)
	game.autopilot.release_all()
	var kind: String = ended[0][0] if not ended.is_empty() else ""
	var result := "ok"
	if took < 0.0:
		result = "no_takeoff"
	elif kind == "takeoff_failed":
		result = "takeoff_failed"
	r["result"] = result
	r["kind"] = kind
	r["fail_reason"] = fr[0]
	r["took_off_at"] = snappedf(took, 0.01)
	r["t_air"] = snappedf(t_air, 0.01)
	r["max_bank_ground"] = snappedf(max_bank_g, 0.1)
	r["max_hdg_dev_run"] = snappedf(max_hdg, 0.1)
	r["max_bank_air15"] = snappedf(max_bank_a, 0.1)
	r["max_dw_tips"] = snappedf(max_dw, 0.01)
	await get_tree().process_frame
	return r
