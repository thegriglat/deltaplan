extends Node
## Кадр гор Словении с подписями вершин (OT-10): фикстура tests/fixtures/osm_tiles → OsmData →
## OsmPilot над синтетическим рельефом (конусы вершин по высотам OSM). Запуск:
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/osm_peaks_shot.tscn -- --out=<каталог>

const FIX := "res://tests/fixtures/osm_tiles"
var _peaks: Array = []


func _h(x: float, z: float) -> float:
	var h := 500.0
	for p: Dictionary in _peaks:
		var dx: float = p.x - x
		var dz: float = p.z - z
		var d2 := dx * dx + dz * dz
		if d2 < 9.0e6:
			h = maxf(h, 500.0 + (float(p.ele) - 500.0) * (1.0 - sqrt(d2) / 3000.0))
	return h


func _ready() -> void:
	var out := "/tmp"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "/fixture.json"))
	OsmTilesStage.cache_root_override = "user://shot_osm_peaks/v1"
	var ctx := LocationBuildContext.new()
	ctx.center_lat = float(fx.center_lat)
	ctx.center_lon = float(fx.center_lon)
	ctx.host = self
	ctx.dir = "user://shot_osm_peaks/place"
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	var st := OsmTilesStage.new()
	st.cfg_override = {"base_url": ProjectSettings.globalize_path(FIX)}
	await st.run(ctx)
	var d := OsmData.load_for(ctx.dir, ctx.center_lat, ctx.center_lon, 20000.0)
	var focus: Dictionary = {}
	for p: Dictionary in d.peaks:
		if String(p.name) != "" and not is_nan(float(p.ele)):
			_peaks.append(p)
			if focus.is_empty() or float(p.ele) > float(focus.ele):
				focus = p
	print("shot: вершин с именем ", _peaks.size(), ", главная ", focus.name, " ", focus.ele)
	var fx0: float = focus.x
	var fz0: float = focus.z
	# рельеф вокруг
	var n := 120
	var half := 14000.0
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in n + 1:
		for i in n + 1:
			var x := fx0 - half + 2.0 * half * i / n
			var z := fz0 - half + 2.0 * half * j / n
			verts.append(Vector3(x, _h(x, z), z))
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			idx.append_array(PackedInt32Array([a, a + 1, a + n + 1, a + 1, a + n + 2, a + n + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var gen := SurfaceTool.new()
	gen.create_from(mesh, 0)
	gen.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = gen.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.5, 0.36)
	mi.material_override = mat
	add_child(mi)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 40, 0)
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.76, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.75, 0.8)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var layer := OsmLayer.new()
	add_child(layer)
	layer.build(d, WorldObjects.load_config(), _h, ObstacleIndex.new())
	print("shot: ", OsmPilot.stats)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 60000.0
	add_child(cam)
	cam.make_current()
	cam.global_position = Vector3(fx0 + 1500.0, float(focus.ele) + 600.0, fz0 + 7500.0)
	cam.look_at(Vector3(fx0, float(focus.ele) - 300.0, fz0), Vector3.UP)
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join("osm_peaks.png"))
	LocationCache.remove_dir("user://shot_osm_peaks")
	get_tree().quit(0)
