extends Node3D
## Время кадра над домами Алматы (OL-1): тайлы OSM, плоская земля, камера над городом; средний и 95-й процентиль
## мс кадра за N кадров после прогрева. godot --path . --disable-vsync --resolution 1600x900 \
##   res://tools/shots/osm_frame_bench.tscn -- [--frames=300] [--tiles=<каталог с v1/>]


func _ready() -> void:
	var root := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a"
	var frames := 300
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = int(a.substr(9))
		elif a.begins_with("--tiles="):
			root = a.substr(8)
	var lat := 43.238
	var lon := 76.945
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
	var node := OsmBuildings.build(d, WorldObjects.load_config(), func(_x: float, _z: float) -> float: return 0.0, ObstacleIndex.new())
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	add_child(node)
	var cam := Camera3D.new()
	cam.far = 20000.0
	add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 500, 1500)
	cam.look_at(Vector3(0, 0, -300), Vector3.UP)
	for i in 60:
		await get_tree().process_frame
	var ms: Array[float] = []
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await get_tree().process_frame
		var t1 := Time.get_ticks_usec()
		ms.append((t1 - t0) / 1000.0)
		t0 = t1
	ms.sort()
	var sum := 0.0
	for v in ms:
		sum += v
	print("osm_frame_bench: кадров %d, средний %.2f мс, медиана %.2f, p95 %.2f" % [frames, sum / frames, ms[frames / 2], ms[int(frames * 0.95)]])
	get_tree().quit(0)
