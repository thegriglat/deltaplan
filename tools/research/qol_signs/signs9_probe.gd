extends Node
## QL-9: замер признаков ThermalSigns (ласточки, пух) над термиками. Один прогон = одно место и один час.
## Аргументы после `--`: <location_id> <hour> <out.json> [sim_s=600]
## Берёт настоящий путь игры: main._fly(FlightSettings) → поле «фазы + Пикар» (GPU) или аналитика,
## затем шагает только атмосферу (Atmosphere.step) и свои BirdFlock/DustDevils из точки наблюдения.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const DT := 0.2
const SAMPLE_S := 1.0
const FRAME_H := 1080.0

var out := {}


func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var loc := a[0]
	var hour := float(a[1])
	var path := a[2]
	var sim_s := float(a[3]) if a.size() > 3 else 600.0
	await _run(loc, hour, sim_s)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	print("QL9 done ", path)
	get_tree().quit()


func _run(loc: String, hour: float, sim_s: float) -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	var s := FlightSettings.defaults()
	s.location_id = loc
	s.start_hour = hour
	(main.get("opts") as LaunchOptions).autostart = true
	var t_load := Time.get_ticks_msec()
	await main.call("_fly", s)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var air: Atmosphere = game.air
	out["location"] = loc
	out["hour"] = hour
	out["load_s"] = (Time.get_ticks_msec() - t_load) / 1000.0
	out["headless"] = DisplayServer.get_name() == "headless"
	out["air_unavailable_reason"] = game.air_runtime.unavailable_reason()
	out["air_engine"] = game.air_runtime.engine()
	out["air_src"] = air.field.air_src != null
	out["air_on"] = air.get("_air_on")
	out["cloudbase_msl"] = air.get_cloudbase_msl()
	out["weather"] = {
		"temp_c": s.temperature_c, "wind_kmh": air.weather.get("wind_speed_kmh"),
		"cloudbase_agl": air.weather.get("cloudbase_agl_m"),
		"thermal_spacing_m": air.weather.get("thermal_spacing_m"),
	}
	var start: Vector3 = game.get("_start_pos")
	out["start"] = [start.x, start.y, start.z]
	# Долина: самая низкая точка в 4 км от старта.
	var best := Vector3(start.x, start.y, start.z)
	var hmin := 1.0e9
	for ix in range(-16, 17):
		for iz in range(-16, 17):
			var x := start.x + ix * 250.0
			var z := start.z + iz * 250.0
			var h: float = game.terrain.height_at(x, z)
			if h < hmin:
				hmin = h
				best = Vector3(x, h, z)
	var pts := {
		"A_start+300": Vector3(start.x, start.y + 300.0, start.z),
		"B_valley+1000": Vector3(best.x, best.y + 1000.0, best.z),
	}
	out["valley_ground_m"] = hmin
	var t0 := air.time_s
	out["points"] = {}
	var marker := Node3D.new()
	main.add_child(marker)
	for name in pts:
		var p: Vector3 = pts[name]
		marker.global_position = p
		air.focus_node = marker
		air.start_at(t0)
		out["points"][name] = _observe(air, p, sim_s)
	main.queue_free()


func _observe(air: Atmosphere, eye: Vector3, sim_s: float) -> Dictionary:
	var res := {"eye": [eye.x, eye.y, eye.z]}
	var sg := ThermalSigns.new()
	sg.setup(air)
	var minstr := float(sg.cfg.min_strength_ms)
	var hmax := float(sg.cfg.swallow_height_agl_m[1]) + 1.0
	var uniq := {}
	var uniq_kind := {"swallow": {}, "fluff": {}}
	var off_samples := 0
	var samples := 0
	var simult_max := 0
	var dists := []
	var steps := int(sim_s / DT)
	var every := int(SAMPLE_S / DT)
	for i in steps:
		air.step(DT)
		if i % every != 0:
			continue
		sg.refresh(eye)
		var ps := sg.positions(air.time_s)
		simult_max = maxi(simult_max, sg._entries.size())
		for d in ps:
			var th: AtmoThermal = d.th
			uniq["%d_%s" % [d.id, d.kind]] = true
			uniq_kind[d.kind]["%d" % d.id] = true
			samples += 1
			var p: Vector3 = d.pos
			var a := th.axis_at(p.y)
			var agl := p.y - th.src.y
			var ok: bool = air.field.thermals.get(th.id) == th and th.strength >= minstr \
				and Vector2(a.x - p.x, a.y - p.z).length() <= th.radius and agl >= 0.0 and agl <= hmax
			if not ok:
				off_samples += 1
			if samples % 7 == 0:
				dists.append(snappedf(eye.distance_to(p), 1.0))
	res["signs_new_10min"] = uniq.size()
	res["swallow_flocks"] = uniq_kind.swallow.size()
	res["fluff_sources"] = uniq_kind.fluff.size()
	res["samples"] = samples
	res["off_thermal_samples"] = off_samples
	res["entries_max"] = simult_max
	res["dist_samples_m"] = dists
	res["thermals_final"] = air.field.thermals.size()
	sg.free()
	return res
