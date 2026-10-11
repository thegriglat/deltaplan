extends Node3D
## Машинки OSM (osm-traffic). Запуск (нужен дисплей, напр. xvfb-run -a):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --resolution 1600x900 res://tools/shots/osm_traffic_shot.tscn -- \
##     --out=<каталог> [--mode=models|road] [--tiles=<каталог с v1/>] [--lat= --lon=] [--alt=200] [--sim=60]
## models — три модели крупно в нескольких цветах; road — дорога с машинками сверху (реальные тайлы,
## ровная земля): камера над ближайшей главной дорогой, трафик прокручивается --sim секунд.
## Пишет <out>/traffic_<режим>*.png

const BIG := ["motorway", "trunk", "primary", "secondary"]


func _ready() -> void:
	var out := "/tmp"
	var mode := "models"
	var root := "/home/greg/deltaplan_data/osm_tiles/world/out/v1"
	var lat := 43.25
	var lon := 76.95
	var alt := 200.0
	var sim := 60.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--mode="):
			mode = a.substr(7)
		elif a.begins_with("--tiles="):
			root = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
		elif a.begins_with("--alt="):
			alt = float(a.substr(6))
		elif a.begins_with("--sim="):
			sim = float(a.substr(6))
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.75, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.62, 0.68)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20000, 20000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.5, 0.3)
	pm.material = gm
	ground.mesh = pm
	ground.position.y = -0.2
	add_child(ground)
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.fov = 55.0
	add_child(cam)
	cam.current = true
	var cfg := WorldObjects.load_config()
	if mode == "models":
		await _models(cfg, cam, out)
	else:
		await _road(cfg, cam, out, root, lat, lon, alt, sim)
	get_tree().quit(0)


func _shot(path: String) -> void:
	for i in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("osm_traffic_shot: ", path)


func _models(cfg: Dictionary, cam: Camera3D, out: String) -> void:
	var t := OsmTraffic.new()
	t.setup(cfg.osm_traffic, cfg, func(_x, _z): return 0.0, true)
	add_child(t)
	var x := 0.0
	var views: Array = []
	for i in t.types.size():
		var e: Dictionary = t.types[i]
		var cols: Array = e.cfg.colors
		var len_m := float(e.cfg.length_m)
		var mm: MultiMesh = e.mm
		var row_w := 0.0
		for k in cols.size():
			var b := Basis(Vector3.UP, deg_to_rad(-35))
			var pos := Vector3(float(k) * (len_m * 0.6 + 2.0), 0.0, 0.0)
			mm.set_instance_transform(k, Transform3D(b, pos))
			var c: Array = cols[k]
			mm.set_instance_color(k, Color(c[0], c[1], c[2]).srgb_to_linear())
			row_w = pos.x
		for k in range(cols.size(), mm.instance_count):
			mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
		# каждый тип отдельным кадром: остальные прячем
		views.append([e, row_w, len_m])
	for i in views.size():
		for j in t.types.size():
			(t.types[j].mmi as MultiMeshInstance3D).visible = (i == j)
		var v: Array = views[i]
		var w: float = v[1]
		var lm: float = v[2]
		cam.position = Vector3(w * 0.5 + lm * 0.4, lm * 0.55, lm * 1.6 + w * 0.35)
		cam.look_at(Vector3(w * 0.5, lm * 0.12, 0.0), Vector3.UP)
		await _shot(out.path_join("traffic_%s.png" % v[0].name))


func _road(cfg: Dictionary, cam: Camera3D, out: String, root: String, lat: float, lon: float, alt: float, sim: float) -> void:
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := root.path_join("%d/%d.dpt" % [t.x, t.y])
		if FileAccess.file_exists(p):
			paths.append(p)
	var tiles: Array = []
	for r: Variant in OsmData.decode_files(paths):
		if r is Dictionary and not (r as Dictionary).is_empty():
			tiles.append(r)
	var d := OsmData.from_tiles_parallel(tiles, lat, lon, 20000.0)
	# ближайшая к центру главная дорога длиннее 600 м
	var best := INF
	var mid := Vector2.ZERO
	var dir := Vector2.RIGHT
	for r: Dictionary in d.roads:
		if not String(r.t) in BIG or bool(r.get("tunnel", false)):
			continue
		var pts: PackedVector2Array = r.p
		if pts.size() < 2:
			continue
		var len_m := 0.0
		for i in pts.size() - 1:
			len_m += pts[i].distance_to(pts[i + 1])
		if len_m < 600.0:
			continue
		var m := pts[pts.size() / 2]
		if m.length() < best:
			best = m.length()
			mid = m
			dir = (pts[mini(pts.size() / 2 + 1, pts.size() - 1)] - pts[maxi(pts.size() / 2 - 1, 0)]).normalized()
	print("дорога: ", mid, " расстояние ", best)
	var layer := OsmLayer.new()
	var hf := func(_x: float, _z: float) -> float: return 0.0
	layer.build(d, cfg, hf, ObstacleIndex.new())
	add_child(layer)
	var tr := layer.get_node_or_null("Traffic") as OsmTraffic
	var cpos := Vector3(mid.x, alt, mid.y)
	cam.position = cpos + Vector3(-dir.y, 0.0, dir.x) * alt * 0.35
	cam.look_at(Vector3(mid.x, 0.0, mid.y), Vector3.UP)
	if tr != null:
		tr.wait_net()
		var n := int(sim / 0.05)
		for i in n:
			tr.advance(0.05, cpos)
		print("машин ", tr.active_count(), " шаг средн. ", tr.avg_ms(), " мс")
	await _shot(out.path_join("traffic_road.png"))
