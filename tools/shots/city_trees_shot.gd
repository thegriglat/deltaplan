extends Node
## Кадры деревьев города (city_trees) над Алматы: как city_look_shot, но деревья расставляются сразу (rebuild_now) и есть --notrees.
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1600x900 \
##     res://tools/shots/city_trees_shot.tscn -- --out=<каталог> --name=<файл> [--view=top|road|track|x,z] \
##     [--tiles=<корень с v1/>] [--lat=43.238 --lon=76.945] [--dist=м] [--bench]
## --view=top — сверху над центром; road — крупно главная дорога; track — крупно грунтовка; x,z — над точкой.

const DEFAULT_TILES := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a/v1"


func _ready() -> void:
	var out := "/tmp"
	var fname := "city"
	var view := "top"
	var base := DEFAULT_TILES
	var lat := 43.238
	var lon := 76.945
	var dist := 0.0
	var bench := false
	var notrees := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--name="):
			fname = a.substr(7)
		elif a.begins_with("--view="):
			view = a.substr(7)
		elif a.begins_with("--tiles="):
			base = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
		elif a.begins_with("--dist="):
			dist = float(a.substr(7))
		elif a == "--bench":
			bench = true
		elif a == "--notrees":
			notrees = true
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := "%s/%d/%d.dpt" % [base, t.x, t.y]
		if FileAccess.file_exists(p):
			paths.append(p)
	var data := OsmData.from_tiles_parallel(OsmData.decode_files(paths), lat, lon, 12000.0)
	var cfg := WorldObjects.load_config()
	if notrees:
		cfg.city_trees.enabled = false
	var layer := OsmLayer.new()
	add_child(layer)
	layer.build(data, cfg, func(_x: float, _z: float) -> float: return 0.0, ObstacleIndex.new())
	if layer.get_node_or_null("CityTrees") != null:
		layer.get_node("CityTrees").set_process(false)
	print("[shot] дорог %d, домов %d; layer %s" % [data.roads.size(), data.buildings.size(), layer.stats])
	var focus := Vector3.ZERO
	var cam_pos := Vector3(0, 2600, 1800)
	if view == "top":
		cam_pos = Vector3(0, 3200 if dist == 0.0 else dist, 2200)
	elif view == "road" or view == "track":
		var best := _pick(data, view == "track")
		focus = Vector3(best.x, 0, best.y)
		var d := 60.0 if dist == 0.0 else dist
		cam_pos = focus + Vector3(d * 0.25, d * 0.7, d * 0.5)
	elif view.contains(","):
		focus = Vector3(float(view.split(",")[0]), 0, float(view.split(",")[1]))
		var d2 := 400.0 if dist == 0.0 else dist
		cam_pos = focus + Vector3(0, d2, d2 * 0.6)
	add_child(_ground())
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.75, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.75, 0.8)
	add_child(env)
	var cam := Camera3D.new()
	cam.far = 30000.0
	cam.fov = 60.0
	add_child(cam)
	cam.position = cam_pos
	cam.look_at(focus, Vector3.UP)
	cam.current = true
	for i in 12:
		await get_tree().process_frame
	var ct := layer.get_node_or_null("CityTrees") as CityTrees
	if ct != null:
		var t0 := Time.get_ticks_usec()
		ct.rebuild_now(Vector2(focus.x, focus.z))
		print("[shot] деревья: %s за %.2f с" % [ct.stats, (Time.get_ticks_usec() - t0) / 1.0e6])
		ct.set_process(false)
		ct.visible = true
		for i in 3:
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
		print("BENCH %s render_cpu_ms=%.3f render_gpu_ms=%.3f" % [fname, cpu / n, gpu / n])
		get_tree().quit(0)
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png(out.path_join(fname + ".png"))
	print("[shot] ", out.path_join(fname + ".png"))
	get_tree().quit(0)


## Ближайшая к центру подходящая дорога: главная (trunk/primary/secondary) или грунтовка (track), середина ломаной.
func _pick(data: OsmData, track: bool) -> Vector2:
	var want: Array = ["track"] if track else ["trunk", "primary", "secondary"]
	var best := Vector2.ZERO
	var bd := 1.0e18
	for r: Dictionary in data.roads:
		if String(r.t) in want and not bool(r.get("tunnel", false)):
			var pts: PackedVector2Array = r.p
			var m := pts[pts.size() / 2]
			var d := m.length()
			if d < bd and (not track or d > 1500.0):
				bd = d
				best = m
	return best


func _ground() -> MeshInstance3D:
	var pm := PlaneMesh.new()
	pm.size = Vector2(60000, 60000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.34, 0.14)
	gm.roughness = 1.0
	pm.material = gm
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position.y = -0.2
	return mi
