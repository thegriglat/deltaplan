extends Node
## GPU-замер (tools/gpu_tests.sh --filter=relief_peak): время кадра рельефа с дальней формой MLK-К2 v2
## (пирамида максимумов, заострение высоких гор) против v1 (use_height_max = false — путь шейдера v1).
## Онгудай, камера 600 м над стартом, взгляд на горизонт, тень солнца (вершинный шейдер и в проходе
## теней). Чередование A/B по 6 раз × 40 кадров, медиана GPU-времени кадра. Печатает
## «RELIEF_PEAK_GPU v1=… v2=… ratio=…»; проверка мягкая (≤ +15 %: шум окна), приёмка — по числам.

const SIZE := Vector2i(1280, 720)
const ROUNDS := 6
const FRAMES := 40

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_relief_peak_gpu_frame_time() -> void:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.7, 0.9)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	vp.add_child(sun)
	var t := Terrain.new()
	t.location_id = ""
	vp.add_child(t)
	check(t.load_location("ongudai"), "место ongudai")
	var cam := Camera3D.new()
	cam.far = 60000.0
	vp.add_child(cam)
	var h0 := t.height_at(0.0, 0.0)
	cam.position = Vector3(0.0, h0 + 600.0, 0.0)
	cam.rotation_degrees = Vector3(-4.0, 30.0, 0.0)
	cam.make_current()
	if t.renderer != null:
		t.renderer.lod_camera = cam
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for i in 30:
		await get_tree().process_frame
	var mats: Array[ShaderMaterial] = t.renderer.materials() if t.renderer != null else []
	check(not mats.is_empty(), "материалы рельефа")
	var a: Array = []
	var b: Array = []
	for r in ROUNDS:
		for v2 in [false, true]:
			for m in mats:
				m.set_shader_parameter("use_height_max", v2)
			for i in 5:
				await get_tree().process_frame
			var acc: Array = []
			for i in FRAMES:
				await get_tree().process_frame
				acc.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
			acc.sort()
			(b if v2 else a).append(float(acc[acc.size() / 2]))
	a.sort()
	b.sort()
	var ma := float(a[a.size() / 2])
	var mb := float(b[b.size() / 2])
	print("RELIEF_PEAK_GPU v1=%.3f мс v2=%.3f мс ratio=%.3f (%dx%d, медианы %s / %s)" % [ma, mb, mb / maxf(ma, 1e-6),
			SIZE.x, SIZE.y, str(a), str(b)])
	check(ma > 0.0, "GPU-время меряется")
	check(mb <= ma * 1.15, "v2 не дороже v1 больше чем на 15 %% (%.3f / %.3f мс)" % [mb, ma])
	vp.queue_free()
