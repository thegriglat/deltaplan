extends Node
## GPU-проверка раннего выхода травы вне поля зрения (GR-3, tools/gpu_tests.sh --filter=grass_cull):
## две одинаковые сцены (свой мир у каждого SubViewport, настоящий GrassField на наклонном рельефе
## с буграми, луг/нива/лес, ветер с порывами и термиком, приминание у камеры) рисуются в одном
## кадре — TIME один, качание одинаковое; у одной материалы травы с cull_enabled = false. Кадры
## должны совпасть: пикселей с |Δ| > 2/255 не больше 0,01 %.

const SIZE_H := 144
const ASPECTS := {"16:9": 256, "21:9": 336, "4:3": 192}
const FOVS := [40.0, 75.0, 100.0]
const YAWS_STEP := 30
const PITCHES := [-70.0, -20.0, 0.0, 15.0]
const EYE_M := 1.5
const MAX_SHARE := 0.0001
const TOL := 2

var failures: PackedStringArray = []
var _layer: HeightLayer
var _views: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _fields: Array[GrassField] = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_cull_frames_match_without_cull() -> void:
	_build()
	var frames := 0
	var worst := 0.0
	var worst_name := ""
	for asp: String in ASPECTS:
		_set_size(Vector2i(ASPECTS[asp], SIZE_H))
		for fov: float in FOVS:
			for yaw in range(0, 360, YAWS_STEP):
				for pitch: float in PITCHES:
					var name := "%s fov %d yaw %d pitch %d" % [asp, int(fov), yaw, int(pitch)]
					var share := await _frame(Vector2.ZERO, EYE_M, float(yaw), pitch, fov)
					frames += 1
					if share > worst:
						worst = share
						worst_name = name
					check(share <= MAX_SHARE, "%s: отличается %.4f %% пикселей" % [name, share * 100.0])
	# быстрый поворот: 35° за кадр × 12 кадров, глаз у самой травы и на 2 м
	_set_size(Vector2i(256, SIZE_H))
	for eye: float in [0.3, 2.0]:
		for k in 12:
			var yaw := 35.0 * k
			var share := await _frame(Vector2(3.0, -2.0), eye, yaw, -10.0, 75.0, false)
			frames += 1
			check(share <= MAX_SHARE, "поворот, глаз %.1f м, yaw %d: %.4f %%" % [eye, int(yaw), share * 100.0])
	print("    grass_cull: кадров %d, худший %s: %.4f %%" % [frames, worst_name, worst * 100.0])
	_teardown()


## В кадре есть трава (иначе сравнение пустое), и доля отсечённых пучков ближнего слоя в типичном
## кадре (16:9, FOV 75°, взгляд на 20° вниз, глаз 1,5 м) — по той же формуле на CPU, для отчёта.
func test_grass_cull_frame_has_grass_and_share() -> void:
	_build()
	_set_size(Vector2i(256, SIZE_H))
	await _frame(Vector2.ZERO, EYE_M, 40.0, -20.0, 75.0)
	var img := _views[0].get_texture().get_image()
	var bg := img.get_pixel(0, 0)
	var grass := 0
	for y in range(SIZE_H / 2, SIZE_H):
		for x in img.get_width():
			if not img.get_pixel(x, y).is_equal_approx(bg):
				grass += 1
	var share := float(grass) / (img.get_width() * SIZE_H / 2)
	check(share > 0.3, "трава в нижней половине кадра: %.2f" % share)
	var culled := _cpu_cull_share(_fields[0], _cams[0])
	print("    grass_cull: ближний слой — отсечено %.0f %% пучков в кадре" % (culled * 100.0))
	check(culled > 0.4, "в типичном кадре отсекается заметная доля: %.2f" % culled)
	_teardown()


func _build() -> void:
	var n := 160
	var step := 2.0
	var o := -float(n) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for j in n:
		for i in n:
			var x := o + i * step
			var z := o + j * step
			var h := 100.0 + 0.12 * x - 0.05 * z + 2.5 * sin(x / 11.0) * cos(z / 13.0)
			hs[j * n + i] = h
			img.set_pixel(i, j, Color(h, 0, 0))
	_layer = HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var htex := ImageTexture.create_from_image(img)
	var sn := 80
	var ss := 4.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	for j in sn:
		for i in sn:
			var c := SurfaceLayer.GRASS
			if i > sn / 2 + 2:
				c = SurfaceLayer.CROP
			elif j > sn / 2 + 3:
				c = SurfaceLayer.FOREST
			cls[j * sn + i] = c
			simg.set_pixel(i, j, Color(c / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	for k in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.5, 0.6, 0.8)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.6, 0.65, 0.7)
		var we := WorldEnvironment.new()
		we.environment = env
		vp.add_child(we)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-40, 30, 0)
		vp.add_child(sun)
		var cam := Camera3D.new()
		cam.far = 500.0
		vp.add_child(cam)
		var g := GrassField.new()
		g.camera = cam
		vp.add_child(g)
		var spots: Array[Vector4] = [Vector4(-6.0, 6.0, 3.0, 0.3)]
		g.setup(_layer, htex, surf, stex, look, cfg, spots)
		for m in g.materials():
			m.set_shader_parameter("wind_vec", Vector2(5.0, 2.0))
			m.set_shader_parameter("wind_gust_ms", 2.0)
			m.set_shader_parameter("wind_thermals", [Vector4(8.0, -6.0, 15.0, 1.0)])
			m.set_shader_parameter("wind_thermal_count", 1)
			m.set_shader_parameter("cull_enabled", k == 0)
		_views.append(vp)
		_cams.append(cam)
		_fields.append(g)


func _teardown() -> void:
	for vp in _views:
		vp.queue_free()
	_views.clear()
	_cams.clear()
	_fields.clear()


func _set_size(s: Vector2i) -> void:
	for vp in _views:
		vp.size = s


## Обе камеры в одно положение, кадр, доля пикселей с |Δ| > TOL/255 (любой канал).
## settle — подождать лишний кадр (смена размера/FOV); в серии поворота — ровно кадр на шаг.
func _frame(xz: Vector2, eye: float, yaw: float, pitch: float, fov: float, settle: bool = true) -> float:
	var p := Vector3(xz.x, _layer.sample(xz.x, xz.y) + eye, xz.y)
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), EULER_ORDER_YXZ)
	for i in 2:
		_cams[i].fov = fov
		_cams[i].global_transform = Transform3D(b, p)
		for m in _fields[i].materials():
			m.set_shader_parameter("press_pos", p + Vector3(0.0, -eye, -0.8))
	if settle:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var a := _views[0].get_texture().get_image()
	var c := _views[1].get_texture().get_image()
	if a.get_format() != c.get_format():
		c.convert(a.get_format())
	var da := a.get_data()
	var dc := c.get_data()
	if da == dc:
		return 0.0
	var bpp := da.size() / (a.get_width() * a.get_height())
	var bad := 0
	for px in a.get_width() * a.get_height():
		for ch in mini(bpp, 3):
			if absi(int(da[px * bpp + ch]) - int(dc[px * bpp + ch])) > TOL:
				bad += 1
				break
	return float(bad) / (a.get_width() * a.get_height())


## Доля пучков ближнего слоя, которые отсекает шейдер (та же проверка столбика против плоскостей
## проекции, высота в центре пучка — по HeightLayer; прореживание вдали не учитывается).
func _cpu_cull_share(g: GrassField, cam: Camera3D) -> float:
	var m: ShaderMaterial = g.material
	var spacing: float = m.get_shader_parameter("clump_spacing_m")
	var radius: float = m.get_shader_parameter("area_radius_m")
	var reach0: float = m.get_shader_parameter("clump_reach_m")
	var cfg: Dictionary = Config.get_config("vegetation").grass
	var h_max := maxf(maxf(float(cfg.blade_height_m[1]), float(cfg.crop_height_m[1])), float(cfg.forest_height_m[1]))
	var lean := maxf((1.0 + 0.6) * float(cfg.bend_amp) + 0.15 + float(cfg.sway_amp), 1.5)
	var view := cam.global_transform.affine_inverse()
	var proj := cam.get_camera_projection()
	var rows: Array[Vector4] = []
	for r in 4:
		rows.append(Vector4(proj.x[r], proj.y[r], proj.z[r], proj.w[r]))
	var planes: Array[Vector4] = [rows[3] + rows[0], rows[3] - rows[0], rows[3] + rows[1], rows[3] - rows[1]]
	var cp := cam.global_position
	var center := Vector2(floor(cp.x / spacing), floor(cp.z / spacing))
	var total := 0
	var culled := 0
	for off in GrassField.ring_offsets(spacing, -1.0, radius):
		var xz := (center + off + Vector2(0.5, 0.5)) * spacing
		var d := xz.distance_to(Vector2(cp.x, cp.z))
		if d > radius:
			continue
		total += 1
		if d < 2.0:
			continue
		var h := _layer.sample(xz.x, xz.y)
		var reach := reach0 * GrassField.far_width_scale(d, radius, float(cfg.far_width_k), float(cfg.thin_start_k), float(cfg.thin_end_k)) + lean * h_max
		var a := view * Vector3(xz.x, h - 0.02, xz.y)
		var b := view * Vector3(xz.x, h + h_max, xz.y)
		var out := minf(a.z, b.z) > reach
		for pl in planes:
			var n := Vector3(pl.x, pl.y, pl.z)
			if maxf(n.dot(a) + pl.w, n.dot(b) + pl.w) / n.length() < -reach:
				out = true
		if out:
			culled += 1
	return float(culled) / maxi(total, 1)
