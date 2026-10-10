extends Node3D
## ЛЭП, мачты, башни, трубы OSM в Алматы с моделями OL-2 (OsmPilot над плоской землёй; рельефа места
## в репозитории нет). Запуск: XDG_DATA_HOME=$(mktemp -d) godot --path . --resolution 1600x900 \
##   res://tools/shots/osm_pilot_shot.tscn -- --out=<каталог> [--tiles=<каталог с v1/>] [--lat=] [--lon=] \
##   [--list] [--focus=power|tv|chimney|mast|x,z] [--dist=м] [--name=файл] [--skip=wind] [--bench]
## --list печатает ближайшие объекты; --focus снимает вид на объект; --bench — время кадра без снимка.

func _ready() -> void:
	var out := "/tmp"
	var root := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a"
	var lat := 43.238
	var lon := 76.945
	var focus := "power"
	var dist := 120.0
	var fname := "osm_pilot"
	var list := false
	var bench := false
	var old := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--tiles="):
			root = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
		elif a.begins_with("--focus="):
			focus = a.substr(8)
		elif a.begins_with("--dist="):
			dist = float(a.substr(7))
		elif a.begins_with("--name="):
			fname = a.substr(7)
		elif a == "--list":
			list = true
		elif a == "--bench":
			bench = true
		elif a == "--old":
			old = true
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := root.path_join("v1/%d/%d.dpt" % [t.x, t.y])
		if FileAccess.file_exists(p):
			paths.append(p)
	var tiles: Array = []
	for r: Variant in OsmData.decode_files(paths):
		if r is Dictionary and not (r as Dictionary).is_empty():
			tiles.append(r)
	var d := OsmData.from_tiles_parallel(tiles, lat, lon, 12000.0)
	print("osm_pilot_shot: ЛЭП ", d.power.size(), ", вертикалей ", d.verticals.size())
	var fx := Vector2.ZERO
	var best := 1.0e18
	for v: Dictionary in d.verticals:
		var match_t: bool = (focus == "tv" and String(v.t) == "tower" and float(v.h) >= 150.0) \
			or (focus == "chimney" and v.t == "chimney") or (focus == "mast" and v.t in ["mast", "tower"] and not bool(v.comm))
		if list:
			print("  ", v.t, " comm=", v.comm, " h=", v.h, " x=", int(v.x), " z=", int(v.z))
		if match_t:
			var dd := Vector2(v.x, v.z).length()
			if dd < best:
				best = dd
				fx = Vector2(v.x, v.z)
	if focus == "power":
		var cfgp: Dictionary = WorldObjects.load_config().osm_pilot.power
		var plan := PowerLinePlanner.plan(d.power, cfgp, func(_x: float, _z: float) -> float: return 0.0)
		for s: Dictionary in plan.supports:
			var dd := Vector2(s.position.x, s.position.z).length()
			if s.tower and dd < best:
				best = dd
				fx = Vector2(s.position.x, s.position.z)
	elif focus.contains(","):
		fx = Vector2(float(focus.split(",")[0]), float(focus.split(",")[1]))
	print("osm_pilot_shot: фокус ", fx)
	if list:
		get_tree().quit(0)
		return
	if old:
		for m in ["power_tower", "power_pole", "mast_lattice", "tv_tower", "chimney"]:
			OsmPilot._models[m] = null
	var h_fn := func(_x: float, _z: float) -> float: return 0.0
	var cfg := WorldObjects.load_config()
	var node := OsmPilot.build(d, cfg, h_fn, ObstacleIndex.new())
	print("osm_pilot_shot: stats ", OsmPilot.stats)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.75, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.58, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 40, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60000, 60000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.5, 0.3)
	pm.material = gm
	ground.mesh = pm
	ground.position.y = -0.2
	add_child(ground)
	if node != null:
		add_child(node)
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.fov = 65.0
	add_child(cam)
	cam.current = true
	cam.position = Vector3(fx.x + dist * 0.8, 25.0 + dist * 0.12, fx.y + dist * 0.6)
	cam.look_at(Vector3(fx.x, 18.0 if focus == "power" else dist * 0.3, fx.y), Vector3.UP)
	for i in 8:
		await get_tree().process_frame
	if bench:
		var vp := get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp, true)
		var cpu := 0.0
		var gpu := 0.0
		var n := 0
		for i in 400:
			await get_tree().process_frame
			if i >= 100:
				cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
				n += 1
		print("BENCH %s render_cpu_ms=%.3f render_gpu_ms=%.3f" % ["old" if old else "new", cpu / n, gpu / n])
		get_tree().quit(0)
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, fname])
	print("osm_pilot_shot: ", out, "/", fname)
	get_tree().quit(0)
