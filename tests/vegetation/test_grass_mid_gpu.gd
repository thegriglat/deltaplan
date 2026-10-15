extends Node
## GPU-проверка средней дистанции травы (G4, GR-7, tools/gpu_tests.sh --filter=grass_mid): для режимов
## shell две одинаковые сцены (свой мир у каждого SubViewport, настоящий GrassField на
## наклонном рельефе с буграми, луг/нива/лес, ветер с порывами и термиком, MSAA 2×) рисуются в одном
## кадре. (1) Трава рисуется: у второй сцены узел средней травы скрыт — кадры с видом на луг 16–30 м
## должны заметно отличаться. (2) Ранний выход вне кадра не меняет кадр: у второй сцены
## cull_enabled = false у всех материалов травы — пикселей с |Δ| > 2/255 не больше 0,01 %.

const SIZE := Vector2i(256, 144)
const EYE_M := 1.5
const MAX_SHARE := 0.0001
const TOL := 2
## Полоса проверки «трава рисуется» — внутри кольца, до растворения внешнего края (30–40 м): тон слоёв —
## луг рельефа за ними (GR-8), отличаются только модуляцией ворса (корень темнее, куртины), поэтому
## порог — заметная доля, а не большинство пикселей.
const DRAW_NEAR_M := 16.0
const DRAW_FAR_M := 30.0
const DRAW_MIN_SHARE := 0.15

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


func test_grass_mid_draws_shell() -> void:
	await _draws("shell")


func test_grass_mid_cull_matches_shell() -> void:
	await _cull_matches("shell")


## Взгляд на луг вдаль (луч зрения пересекает землю на 16–30 м): кадр с узлом средней травы и без.
## Рельеф почти ровный (наклон и бугры × 0,1), строки кадра, где луч зрения с глаза 1,5 м падает на землю
## в 16–30 м, — не меньше DRAW_MIN_SHARE их пикселей с травой и без отличаются.
func _draws(mode: String) -> void:
	_build(mode, 0.1)
	_fields[1].mid_layer.visible = false
	var worst := 1.0
	var pitch := -3.0
	var fov := 60.0
	var rows := PackedInt32Array()
	for y in SIZE.y:
		var k := (0.5 - (y + 0.5) / SIZE.y) * 2.0 * tan(deg_to_rad(fov) * 0.5)
		var below := -(deg_to_rad(pitch) + atan(k))
		if below > 0.0:
			var dist := EYE_M / tan(below)
			if dist >= DRAW_NEAR_M and dist <= DRAW_FAR_M:
				rows.append(y)
	check(rows.size() >= 3, "в кадре есть полоса %d–%d м: %d строк" % [int(DRAW_NEAR_M), int(DRAW_FAR_M), rows.size()])
	for yaw in [0.0, 120.0, 240.0]:
		var share := await _frame(Vector2.ZERO, EYE_M, yaw, pitch, fov, true, rows)
		worst = minf(worst, share)
		check(share > DRAW_MIN_SHARE, "%s, yaw %d: на %d–%d м средняя трава меняет %.1f %% пикселей" % [mode, int(yaw), int(DRAW_NEAR_M), int(DRAW_FAR_M), share * 100.0])
	print("    grass_mid %s: на 16–30 м средняя трава меняет не меньше %.0f %% пикселей" % [mode, worst * 100.0])
	if OS.has_environment("DP_GRASS_MID_SHOT"):
		_fields[1].mid_layer.visible = true
		_set_size(Vector2i(1280, 720))
		await _frame(Vector2.ZERO, EYE_M, 30.0, -6.0, 60.0)
		_views[0].get_texture().get_image().save_png(OS.get_environment("DP_GRASS_MID_SHOT") + "_%s.png" % mode)
	_teardown()


func _set_size(s: Vector2i) -> void:
	for vp in _views:
		vp.size = s


func _cull_matches(mode: String) -> void:
	_build(mode)
	for f in _fields.slice(1):
		for m in f.materials():
			m.set_shader_parameter("cull_enabled", false)
	var frames := 0
	var worst := 0.0
	for fov: float in [40.0, 75.0, 100.0]:
		for yaw in range(0, 360, 45):
			for pitch: float in [-60.0, -10.0, 0.0, 15.0]:
				var share := await _frame(Vector2.ZERO, EYE_M, float(yaw), pitch, fov)
				frames += 1
				worst = maxf(worst, share)
				check(
					share <= MAX_SHARE,
					"%s fov %d yaw %d pitch %d: отличается %.4f %%" % [mode, int(fov), yaw, int(pitch), share * 100.0]
				)
	# быстрый поворот: кадр на шаг 35°
	for k in 10:
		var share := await _frame(Vector2(3.0, -2.0), EYE_M, 35.0 * k, -5.0, 75.0, false)
		frames += 1
		worst = maxf(worst, share)
		check(share <= MAX_SHARE, "%s поворот %d: %.4f %%" % [mode, k, share * 100.0])
	print("    grass_mid %s: кадров %d, худший %.4f %%" % [mode, frames, worst * 100.0])
	_teardown()


## relief_k — множитель наклона и бугров рельефа (1 — склон 4 %/3 % с буграми ±1,5 м).
func _build(mode: String, relief_k: float = 1.0) -> void:
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
			var h := 100.0 + relief_k * (0.04 * x - 0.03 * z + 1.5 * sin(x / 11.0) * cos(z / 13.0))
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
			if i > sn / 2 + 6:
				c = SurfaceLayer.CROP
			elif j > sn / 2 + 7:
				c = SurfaceLayer.FOREST
			cls[j * sn + i] = c
			simg.set_pixel(i, j, Color(c / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	cfg.mid.mode = mode
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	for k in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.msaa_3d = Viewport.MSAA_2X
		vp.size = SIZE
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
		vp.add_child(_ground(hs, n, step, o))
		var cam := Camera3D.new()
		cam.far = 500.0
		vp.add_child(cam)
		var g := GrassField.new()
		g.camera = cam
		vp.add_child(g)
		var spots: Array[Vector4] = [Vector4(-16.0, 16.0, 5.0, 0.3)]
		g.setup(_layer, htex, surf, stex, look, cfg, spots)
		for m in g.materials():
			m.set_shader_parameter("wind_vec", Vector2(5.0, 2.0))
			m.set_shader_parameter("wind_gust_ms", 2.0)
			m.set_shader_parameter("wind_thermals", [Vector4(18.0, -16.0, 15.0, 1.0)])
			m.set_shader_parameter("wind_thermal_count", 1)
		_views.append(vp)
		_cams.append(cam)
		_fields.append(g)


## Земля под травой — сетка высот рельефа, ровный цвет луга (кадр «без травы» — земля, не небо).
func _ground(hs: PackedFloat32Array, n: int, step: float, o: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in n - 1:
		for i in n - 1:
			var q: Array[Vector3] = []
			for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				q.append(Vector3(o + (i + c.x) * step, hs[(j + c.y) * n + i + c.x] - 0.01, o + (j + c.y) * step))
			for v in [q[0], q[1], q[2], q[1], q[3], q[2]]:
				st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.2, 0.08)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi


func _teardown() -> void:
	for vp in _views:
		vp.queue_free()
	_views.clear()
	_cams.clear()
	_fields.clear()


## Обе камеры в одно положение, кадр, доля пикселей с |Δ| > TOL/255 (любой канал); rows — только
## эти строки кадра (пусто — весь кадр).
func _frame(
	xz: Vector2, eye: float, yaw: float, pitch: float, fov: float, settle: bool = true,
	rows: PackedInt32Array = PackedInt32Array()
) -> float:
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
	var w := a.get_width()
	var bpp := da.size() / (w * a.get_height())
	if rows.is_empty():
		for y in a.get_height():
			rows.append(y)
	var bad := 0
	for y in rows:
		for x in w:
			var px := y * w + x
			for ch in mini(bpp, 3):
				if absi(int(da[px * bpp + ch]) - int(dc[px * bpp + ch])) > TOL:
					bad += 1
					break
	return float(bad) / (w * rows.size())
