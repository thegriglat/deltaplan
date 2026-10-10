extends Node3D
## Дома OSM (OT-11): Алматы с воздуха на плоской земле (рельефа места в репозитории нет — только дома OSM из
## тайлов). Запуск: godot --path . --resolution 1600x900 res://tools/shots/osm_buildings_shot.tscn -- \
##   --out=<файл.png> [--tiles=<каталог с v1/>] [--lat=43.238] [--lon=76.945]

func _ready() -> void:
	var out := "osm_buildings.png"
	var root := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a"
	var lat := 43.238
	var lon := 76.945
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--tiles="):
			root = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
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
	print("osm_buildings_shot: домов ", d.buildings.size())
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
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
	if node != null:
		add_child(node)
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.fov = 70.0
	add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 700, 1400)
	cam.look_at(Vector3(0, 0, -600), Vector3.UP)
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("osm_buildings_shot: ", out)
	get_tree().quit(0)
