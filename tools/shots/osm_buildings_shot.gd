extends Node3D
## Дома OSM (OT-11, OL-1): тайлы OSM вокруг точки, плоская земля — кадры стиля домов (город / село / промзона),
## высоток центра и дыма. Нужно окно (настоящий рендер), профиль временный:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1600x900 --disable-vsync \
##     res://tools/shots/osm_buildings_shot.tscn -- --out=<файл.png> [--tiles=<каталог с v1/>] [--lat=43.238] \
##     [--lon=76.945] [--focus=city|village|industrial|core] [--dist=400] [--alt=250] [--wait=5] [--fov=60] \
##     [--cam=x,y,z --look=x,y,z]
## --focus: камера над самым плотным местом нужного стиля (по BuildingStyle) — город, частный сектор с дымом,
## промзона, ядро с высотками (больше всего домов выше 45 м); без --focus — как раньше, общий вид.
## --wait — секунд симуляции до кадра (дым набирает силу ~10 с).

const CELL := 400.0


func _ready() -> void:
	var out := "osm_buildings.png"
	var root := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a"
	var lat := 43.238
	var lon := 76.945
	var focus := ""
	var dist := 400.0
	var alt := 250.0
	var wait_s := 5.0
	var fov := 60.0
	var cam_s := ""
	var look_s := ""
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				out = v
			"--tiles":
				root = v
			"--lat":
				lat = float(v)
			"--lon":
				lon = float(v)
			"--focus":
				focus = v
			"--dist":
				dist = float(v)
			"--alt":
				alt = float(v)
			"--wait":
				wait_s = float(v)
			"--fov":
				fov = float(v)
			"--cam":
				cam_s = v
			"--look":
				look_s = v
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := root.path_join("v1/%d/%d.dpt" % [t.x, t.y])
		if FileAccess.file_exists(p):
			paths.append(p)
	var tiles: Array = []
	for r: Variant in OsmData.decode_files(paths):
		if r is Dictionary and not (r as Dictionary).is_empty():
			tiles.append(r)
	var d := OsmData.from_tiles_parallel(tiles, lat, lon, 20000.0)
	var cfg := WorldObjects.load_config()
	var node := OsmBuildings.build(d, cfg, func(_x: float, _z: float) -> float: return 0.0, ObstacleIndex.new())
	var hs := [0, 0, 0]
	var hmax := 0.0
	var ring := {}
	for b: Array in d.buildings:
		hmax = maxf(hmax, float(b[5]))
		if float(b[5]) >= 45.0:
			hs[0] += 1
			var rr := int(Vector2(b[0], b[1]).length() / 2000.0)
			ring[rr] = int(ring.get(rr, 0)) + 1
		elif float(b[5]) >= 27.0:
			hs[1] += 1
		else:
			hs[2] += 1
	print("osm_buildings_shot: высот >=45 м: ", hs[0], ", 27..45: ", hs[1], ", ниже: ", hs[2], ", макс ", hmax, ", >=45 по кольцам 2 км: ", ring)
	for b: Array in d.buildings:
		if absf(float(b[0]) - 60.0) < 150.0 and absf(float(b[1]) - 230.0) < 100.0 and float(b[2]) * float(b[3]) > 3000.0:
			print("DUMP ", b)
	var spot := Vector2.ZERO
	if focus != "":
		spot = _find_spot(d, cfg.buildings.style, focus)  # после build: высоты уже с поправкой мегаполиса
	print("osm_buildings_shot: домов ", d.buildings.size(), ", фокус ", focus, " в ", spot)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = "--shadows" in OS.get_cmdline_user_args()
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40000, 40000)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.5, 0.3)
	pm.material = gm
	ground.mesh = pm
	ground.position.y = -0.2
	add_child(ground)
	var layer: Node = null
	if node != null:
		layer = Node3D.new()
		layer.add_child(node)
		add_child(layer)
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.fov = fov
	add_child(cam)
	cam.current = true
	if cam_s != "":
		var c := cam_s.split_floats(",")
		var lk := look_s.split_floats(",") if look_s != "" else PackedFloat64Array([c[0], 0.0, c[2] - 500.0])
		cam.position = Vector3(c[0], c[1], c[2])
		cam.look_at(Vector3(lk[0], lk[1], lk[2]), Vector3.UP)
	elif focus != "":
		cam.position = Vector3(spot.x, alt, spot.y + dist)
		cam.look_at(Vector3(spot.x, 0.0, spot.y), Vector3.UP)
	else:
		cam.position = Vector3(0, 700, 1400)
		cam.look_at(Vector3(0, 0, -600), Vector3.UP)
	var t_end := Time.get_ticks_msec() + int(wait_s * 1000.0)
	var air := func(_p: Vector3) -> Vector3: return Vector3(2.5, 0.0, 1.0)
	while Time.get_ticks_msec() < t_end:
		if layer != null:
			OsmLayer.feed_wind(layer, air, cam.global_position)
		await get_tree().process_frame
	for i in 3:
		await get_tree().process_frame
	if layer != null:
		for sm in layer.find_children("Smoke", "OsmSmoke", true, false):
			print("osm_buildings_shot: дым: труб ", sm.chimney_count(), ", эмиттеров ", sm.emitter_count, ", занято ", sm.active_count, ", опросов ветра ", sm.last_samples)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("osm_buildings_shot: ", out)
	get_tree().quit(0)


## Центр клетки CELL с наибольшим числом домов нужного стиля (core — домов выше 45 м).
func _find_spot(d: OsmData, scfg: Dictionary, focus: String) -> Vector2:
	var st := BuildingStyle.classify(d.buildings, scfg)
	var cnt := {}
	var best := 0
	var best_k := Vector2i.ZERO
	for i in d.buildings.size():
		var b: Array = d.buildings[i]
		var ok := false
		match focus:
			"city":
				ok = st[i] == BuildingStyle.CITY and float(b[5]) < 45.0
			"village":
				ok = st[i] == BuildingStyle.VILLAGE and int(b[6]) == 0
			"industrial":
				ok = st[i] == BuildingStyle.INDUSTRIAL
			"core":
				ok = float(b[5]) >= 45.0
		if not ok:
			continue
		var k := Vector2i(floori(float(b[0]) / CELL), floori(float(b[1]) / CELL))
		cnt[k] = int(cnt.get(k, 0)) + 1
		if cnt[k] > best:
			best = cnt[k]
			best_k = k
	print("osm_buildings_shot: фокус %s: %d домов в клетке %s" % [focus, best, best_k])
	return (Vector2(best_k) + Vector2(0.5, 0.5)) * CELL
