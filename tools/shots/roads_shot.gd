extends Node
## Кадр OT-9: дороги, реки, ж/д из тайлов OSM с воздуха над Алматы (3x3 тайла) на условном рельефе (подъём к югу).
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1600x900 \
##     res://tools/shots/roads_shot.tscn -- --out=<каталог> [--tiles=<корень с v1/>] [--lat=43.25 --lon=76.95]
## Пишет <out>/roads_almaty_air.png.

const DEFAULT_TILES := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a/v1"


static func _h(x: float, z: float) -> float:
	var south := maxf(z, -3000.0)
	return 700.0 + south * 0.12 + 40.0 * sin(x * 0.0007) * cos(z * 0.0009) + 15.0 * sin(x * 0.004 + z * 0.003)


func _ready() -> void:
	var out := "/tmp"
	var base := DEFAULT_TILES
	var lat := 43.25
	var lon := 76.95
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--tiles="):
			base = a.substr(8)
		elif a.begins_with("--lat="):
			lat = float(a.substr(6))
		elif a.begins_with("--lon="):
			lon = float(a.substr(6))
	DirAccess.make_dir_recursive_absolute(out)
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := "%s/%d/%d.dpt" % [base, t.x, t.y]
		if FileAccess.file_exists(p):
			paths.append(p)
	var data := OsmData.from_tiles_parallel(OsmData.decode_files(paths), lat, lon, 20000.0)
	var cfg := WorldObjects.load_config()
	var node := OsmRoads.build(data, cfg, Callable(self, "_h"), ObstacleIndex.new())
	print("[shot] дорог %d, рек %d, ж/д %d; stats %s" % [data.roads.size(), data.rivers.size(), data.rail.size(), node.get_meta(&"stats") if node else "null"])
	if node != null:
		add_child(node)
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
	cam.far = 60000.0
	add_child(cam)
	cam.position = Vector3(0, _h(0, 4000) + 1800.0, 6000.0)
	cam.look_at(Vector3(0, 900, -1500))
	cam.current = true
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out.path_join("roads_almaty_air.png"))
	print("[shot] сохранено ", img.get_size())
	get_tree().quit(0)


func _ground() -> MeshInstance3D:
	var n := 200
	var half := 20000.0
	var step := 2.0 * half / n
	var v := PackedVector3Array()
	var norm := PackedVector3Array()
	var col := PackedColorArray()
	for j in n + 1:
		for i in n + 1:
			var x := -half + i * step
			var z := -half + j * step
			v.append(Vector3(x, _h(x, z), z))
			norm.append(Vector3.UP)
			col.append(Color(0.30, 0.38, 0.2).lerp(Color(0.5, 0.48, 0.4), clampf((_h(x, z) - 800.0) / 700.0, 0.0, 1.0)))
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var q := j * (n + 1) + i
			idx.append_array(PackedInt32Array([q, q + 1, q + n + 1, q + 1, q + n + 2, q + n + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = norm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	return mi
