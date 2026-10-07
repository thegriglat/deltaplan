extends Node
## QL-5: замер птиц и признаков термика. Один прогон = одно место и один час.
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
	print("QL5 done ", path)
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
	out["bird"] = _bird_info(air)
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


func _bird_info(air: Atmosphere) -> Dictionary:
	var info := {}
	var path := String(air.cfg.birds.model_path)
	var sc: PackedScene = load(path)
	var root := sc.instantiate()
	var mi := _find_mesh(root)
	var aabb := mi.mesh.get_aabb()
	info["aabb_size_m"] = [aabb.size.x, aabb.size.y, aabb.size.z]
	info["span_m"] = aabb.size.x
	info["node_scale"] = [mi.scale.x, mi.scale.y, mi.scale.z]
	info["root_scale"] = [root.scale.x, root.scale.y, root.scale.z]
	info["span_cfg_m"] = float(air.cfg.birds.span_m)
	root.free()
	return info


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


func _thermal_filter(air: Atmosphere, eye: Vector3) -> Dictionary:
	var bc: Dictionary = air.cfg.birds
	var t := air.time_s
	var n_all := 0
	var n_str := 0
	var n_env := 0
	var n_rad := 0
	var n_rad_any := 0
	var r2 := float(bc.radius_m) * float(bc.radius_m)
	var mins := float(bc.min_strength_ms)
	var strengths := []
	var depth_ok := 0
	var dists := []
	for id in air.field.thermals:
		var th: AtmoThermal = air.field.thermals[id]
		n_all += 1
		var st_ok := th.strength >= mins
		var en_ok := th.envelope(t) >= 0.5
		var a := th.axis_at(clampf(eye.y, th.src.y, th.top))
		var d2 := Vector2(a.x - eye.x, a.y - eye.z).length_squared()
		var rad_ok := d2 < r2
		if rad_ok:
			n_rad_any += 1
		if st_ok:
			n_str += 1
			if en_ok:
				n_env += 1
				if rad_ok:
					n_rad += 1
					strengths.append(th.strength)
					dists.append(sqrt(d2))
					if th.top - th.src.y >= float(bc.altitude_band_m[0]) + float(bc.top_margin_m):
						depth_ok += 1
	return {
		"all": n_all, "strength_ok": n_str, "strength_envelope_ok": n_env,
		"pass_all": n_rad, "radius_only": n_rad_any, "pass_depth_ok": depth_ok,
		"pass_strengths": strengths, "pass_dists_m": dists,
		"direct_near_thermals": BirdFlock.near_thermals(
			air.field.thermals, t, eye, float(bc.radius_m), mins).size(),
	}


func _observe(air: Atmosphere, eye: Vector3, sim_s: float) -> Dictionary:
	var res := {"eye": [eye.x, eye.y, eye.z]}
	res["filter_t0"] = _thermal_filter(air, eye)
	var birds := BirdFlock.new()
	birds.setup(air)
	var dust := DustDevils.new()
	dust.setup(air)
	var cm: CloudModel = air.cloud_phys.model
	var seen_flock := {}
	var flock_spawns := 0
	var prev_ids := {}
	var seen_birds := {}
	var bird_samples := []  # на каждую секунду: расстояния до всех птиц, м
	var pass_series := []
	var dust_ids := {}
	var dust_vis_ids := {}
	var dust_max := 0
	var cloud_ids := {}
	var cloud_max := 0
	var cloud_series := []
	var cloud_big := {}
	var steps := int(sim_s / DT)
	var every := int(SAMPLE_S / DT)
	for i in steps:
		air.step(DT)
		birds._process(DT)
		if i % every != 0:
			continue
		# Птицы.
		var ds := []
		var cur_ids := {}
		for entry in birds._flocks:
			var fid := int(entry[2])
			cur_ids[fid] = true
			if not prev_ids.has(fid):
				flock_spawns += 1
			for b: Dictionary in entry[1]:
				if not b.has("_pid"):
					b["_pid"] = seen_birds.size()
					seen_birds[b["_pid"]] = true
				ds.append(snappedf(eye.distance_to(b.pos), 0.1))
		prev_ids = cur_ids
		bird_samples.append(ds)
		# Фильтр термиков (раз в 10 с).
		if (i / every) % 10 == 0:
			var f := _thermal_filter(air, eye)
			pass_series.append([i / every, f.all, f.pass_all, f.direct_near_thermals])
		# Пылевые вихри (до лимита отрисовки и все).
		var devs: Array[Dictionary] = dust.find(eye)
		dust_max = maxi(dust_max, devs.size())
		for d in devs:
			dust_vis_ids[d.th.id] = true
		var r2 := float(dust.cfg.radius_m) * float(dust.cfg.radius_m)
		var surf := air.wind.vec2_at(float(dust.cfg.drift_height_m))
		var n_all_dev := 0
		for id in air.field.thermals:
			var th: AtmoThermal = air.field.thermals[id]
			var dx := th.src.x - eye.x
			var dz := th.src.z - eye.z
			if dx * dx + dz * dz <= r2 and not dust.model.devil(th, air.time_s, air.ground.surface_fn, surf).is_empty():
				dust_ids[id] = true
				n_all_dev += 1
		# Облака в 5 км.
		var nc := 0
		for id in air.field.thermals:
			var th: AtmoThermal = air.field.thermals[id]
			var st := cm.stage(th, air.time_s)
			if st.x <= 0.0 or cm.life_fade(th, air.time_s) < 0.1:
				continue
			var c := cm.center(th, air.time_s)
			if Vector2(c.x - eye.x, c.y - eye.z).length() <= 5000.0:
				nc += 1
				cloud_ids[id] = true
				var sz := cm.size(th, st)
				if minf(sz.x, sz.y) * 2.0 >= 700.0:
					cloud_big[id] = true
		cloud_max = maxi(cloud_max, nc)
		if (i / every) % 30 == 0:
			cloud_series.append([i / every, nc, n_all_dev])
	res["flock_spawns"] = flock_spawns
	res["unique_birds"] = seen_birds.size()
	res["bird_distances_per_s"] = bird_samples
	res["pass_series"] = pass_series
	res["dust_unique_in_3km"] = dust_ids.size()
	res["dust_unique_visible_cap3"] = dust_vis_ids.size()
	res["dust_max_simult_cap"] = dust_max
	res["cloud_unique_5km"] = cloud_ids.size()
	res["cloud_unique_5km_diam_ge700"] = cloud_big.size()
	res["cloud_max_simult_5km"] = cloud_max
	res["cloud_series"] = cloud_series
	res["thermals_final"] = air.field.thermals.size()
	birds.free()
	dust.free()
	return res
