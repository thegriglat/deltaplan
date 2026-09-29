extends Node
## Кадры смены детализации деревьев (LOD): опушка на плоской земле, камера с луга.
## Деревья ставит настоящий TerrainTreeModels (TreePlacer + tree_model.gdshader) по синтетическому
## слою: лес при x ≥ 0, луг при x < 0; центр расстановки — камера (как в игре сразу после пересчёта).
## Запуск (окно нужно — настоящий рендер; профиль — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy \
##     res://tools/shots/tree_lod_shot.tscn -- --out=build/screenshots/trees_lod --tag=after \
##     [--mode=all|dist|pairs]
## Пишет <out>/<tag>_dist_<D>m.png — опушка с расстояния D (поле зрения подобрано так, что кадр
## охватывает те же ~40 м опушки: меняется только детализация), и <out>/<tag>_pair_<порода>.png —
## LOD0, LOD1, LOD2 одной породы рядом с одного ракурса.
## --mode=bench — замер над настоящим лесом: сцена terrain_preview (её аргументы: --location,
## --site, --agl, --pitch, --yaw, --clearings), --frames кадров с тенями и без: GPU-время кадра,
## отрисовки (draw calls), видимые MultiMesh деревьев, экземпляры по LOD; кадр <tag>_forest.png.

const DISTANCES: PackedFloat32Array = [50, 58, 60, 62, 70, 175, 180, 185]
const HALF_W := 20.0  # полуширина кадра на опушке, м
const SIZE := Vector2i(1280, 720)

var _args: Dictionary = {}
var _cam: Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if String(_args.get("out", "")) == "":
		push_error("tree_lod_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(String(_args.out))
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = SIZE
	if String(_args.get("mode", "")) != "bench":
		_env()
	_run()


func _env() -> void:
	var sky := ProceduralSkyMaterial.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)
	# солнце из-за спины камеры (кадры пар смотрят на +Z, опушка — на +X): кроны освещены
	sun.look_at_from_position(Vector3.ZERO, Vector3(0.5, -0.7, 0.5))
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.32, 0.4, 0.2)
	gm.roughness = 1.0
	ground.material_override = gm
	add_child(ground)
	_cam = Camera3D.new()
	_cam.far = 5000.0
	add_child(_cam)
	_cam.current = true


func _run() -> void:
	var out := String(_args.out)
	var tag := String(_args.get("tag", "shot"))
	var mode := String(_args.get("mode", "all"))
	if mode in ["all", "dist"]:
		await _dist_series(out, tag)
	if mode in ["all", "pairs"]:
		await _pairs(out, tag)
	if mode == "bench":
		await _bench(out, tag)
	print("tree_lod_shot: OK %s" % tag)
	get_tree().quit(0)


## Плоский слой 2×2 км: лес при x ≥ 0.
func _dist_series(out: String, tag: String) -> void:
	var n := 201
	var step := 10.0
	var o := -1000.0
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var cls := PackedByteArray()
	cls.resize(n * n)
	for j in n:
		for i in n:
			cls[j * n + i] = (
				SurfaceLayer.FOREST if o + i * step >= 0.0 else SurfaceLayer.GRASS
			)
	var layer := HeightLayer.from_heights("flat", n, n, step, o, o, hs)
	var surf := SurfaceLayer.from_classes("flat", n, n, step, o, o, cls)
	var cfg: Dictionary = Config.get_config("world").trees.duplicate(true)
	var tm := TerrainTreeModels.new()
	if not tm.setup(layer, surf, cfg):
		push_error("tree_lod_shot: нет моделей деревьев")
		get_tree().quit(1)
		return
	add_child(tm)
	tm.set_process(false)
	tm.camera = _cam
	var z0 := 20.0
	for d in DISTANCES:
		var eye := Vector3(-d, 6.0, z0)
		_cam.fov = rad_to_deg(2.0 * atan(HALF_W * SIZE.y / SIZE.x / d))
		_cam.look_at_from_position(eye, Vector3(0.0, 10.0, z0))
		tm.rebuild_now(Vector2(eye.x, eye.z))
		await _save("%s/%s_dist_%03dm.png" % [out, tag, int(d)])
		print("tree_lod_shot: D=%.0f м, по LOD %s" % [d, tm.lod_counts()])
	tm.queue_free()


## LOD0, LOD1, LOD2 (вариант 0) каждой породы рядом слева направо, одинаковый ракурс.
func _pairs(out: String, tag: String) -> void:
	var cfg: Dictionary = Config.get_config("world").trees
	var models: Dictionary = cfg.get("models", {})
	var helper := TerrainTreeModels.new()
	for sp in TreePlacer.SPECIES:
		var lods := TerrainTreeModels._load_lods(String(models.get(sp, "")))
		if lods.is_empty():
			continue
		var h := lods[0].get_aabb().end.y
		var w := h * 0.75
		var cache := {}
		var nodes: Array[Node3D] = []
		for lod in 3:
			var mi := MeshInstance3D.new()
			mi.mesh = helper._with_sway(lods[lod], h, cfg, cache)
			mi.position = Vector3((1 - lod) * w, 0.0, 500.0)  # взгляд на +Z: +X — слева
			add_child(mi)
			nodes.append(mi)
		var dist := h * 3.2
		_cam.fov = 40.0
		_cam.look_at_from_position(
			Vector3(0.0, h * 0.55, 500.0 - dist), Vector3(0.0, h * 0.5, 500.0)
		)
		await _save("%s/%s_pair_%s.png" % [out, tag, sp])
		for nd in nodes:
			nd.queue_free()
	helper.free()


func _save(path: String) -> void:
	for i in 12:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("tree_lod_shot: %s (%s)" % [path, error_string(img.save_png(path))])


func _bench(out: String, tag: String) -> void:
	var prev: Node = load("res://scenes/terrain/terrain_preview.tscn").instantiate()
	add_child(prev)
	var terrain: Terrain = prev.get_node("Terrain")
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 120:
		await RenderingServer.frame_post_draw
	var tm := terrain.trees as TerrainTreeModels
	var frames := int(_args.get("frames", "300"))
	var res := {"tag": tag}
	for shadows in [true, false]:
		for l in find_children("*", "DirectionalLight3D", true, false):
			(l as DirectionalLight3D).shadow_enabled = shadows
		for i in 20:
			await RenderingServer.frame_post_draw
		var gpu: Array[float] = []
		var draws := 0.0
		for i in frames:
			await RenderingServer.frame_post_draw
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
			draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		gpu.sort()
		var mean := 0.0
		for g in gpu:
			mean += g
		var k := "shadows" if shadows else "no_shadows"
		res[k] = {
			"gpu_ms_mean": snappedf(mean / gpu.size(), 0.01),
			"gpu_ms_p95": snappedf(gpu[int(0.95 * (gpu.size() - 1))], 0.01),
			"draw_calls": roundi(draws / frames),
		}
		if shadows:
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/%s_forest.png" % [out, tag])
	if tm != null:
		var mmi := 0
		var vis := 0
		for c in tm.get_children():
			if c is MultiMeshInstance3D:
				mmi += 1
				if (c as MultiMeshInstance3D).visible and (c as MultiMeshInstance3D).multimesh.instance_count > 0:
					vis += 1
		res["multimesh"] = mmi
		res["multimesh_nonempty"] = vis
		res["lod_counts"] = Array(tm.lod_counts())
	print("TREE_BENCH_JSON:" + JSON.stringify(res))
