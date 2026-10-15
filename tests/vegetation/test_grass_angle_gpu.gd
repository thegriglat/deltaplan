extends Node
## GPU-проверка режима angle средней травы (G4 v4, GR-21, tools/gpu_tests.sh --filter=grass_angle): две
## сцены (свой мир у каждого SubViewport, настоящий GrassField на наклонном рельефе с буграми,
## луг/нива/лес, ветер с порывами и термиком, MSAA 2×) рисуются в одном кадре.
## (а) Ранний выход вне кадра не меняет кадр: у второй сцены cull_enabled = false у всех материалов
##     травы (слои и карточки) — пикселей с |Δ| > 2/255 не больше 0,01 %; 3 соотношения сторон × 3 FOV ×
##     курсы × наклоны, глаз 1,5 м (одни карточки) и 10 м (полоса растворения 17–37 м в кадре) + быстрый
##     поворот.
## (б) Карточки рисуются: у второй сцены средняя трава скрыта — на 16–30 м с глаза 1,5 м кадры заметно
##     отличаются.
## (в) Сверху (α > card_angle_none_deg во всём кольце) кадр angle = кадру shell: карточек нет, слои те же.
## (г) Нет чёрных точек при MSAA 2× и 4×: пикселей темнее 0,35 яркости того же пикселя без средней
##     травы — не больше 0,05 % (корни карточек темнее луга на ~15 %, не в разы).
## Растворение по углу без шва (профиль яркости по кольцам) — test_grass_shell_edge_gpu (angle).

const SIZE_H := 144
const ASPECTS := {"16:9": 256, "21:9": 336, "4:3": 192}
const FOVS: Array[float] = [40.0, 75.0, 100.0]
const PITCHES: Array[float] = [-70.0, -20.0, 0.0, 15.0]
const MAX_SHARE := 0.0001
const TOL := 2
const DARK_K := 0.35
const DARK_MAX := 0.0005

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


func test_grass_angle_cull_matches() -> void:
	_build(["angle", "angle"])
	for f in _fields.slice(1):
		for m in f.materials():
			m.set_shader_parameter("cull_enabled", false)
	var frames := 0
	var worst := 0.0
	var worst_name := ""
	for asp: String in ASPECTS:
		_set_size(Vector2i(ASPECTS[asp], SIZE_H))
		for eye: float in [1.5, 10.0]:
			for fov: float in FOVS:
				for yaw in range(0, 360, 45):
					for pitch: float in PITCHES:
						var name := "%s глаз %d fov %d yaw %d pitch %d" % [asp, int(eye), int(fov), yaw, int(pitch)]
						var share := await _frame(Vector2.ZERO, eye, float(yaw), pitch, fov)
						frames += 1
						if share > worst:
							worst = share
							worst_name = name
						check(share <= MAX_SHARE, "%s: отличается %.4f %%" % [name, share * 100.0])
	# быстрый поворот: 35° за кадр
	_set_size(Vector2i(256, SIZE_H))
	for eye: float in [1.5, 10.0]:
		for k in 12:
			var share := await _frame(Vector2(3.0, -2.0), eye, 35.0 * k, -10.0, 75.0, false)
			frames += 1
			check(share <= MAX_SHARE, "поворот, глаз %.1f м, %d: %.4f %%" % [eye, k, share * 100.0])
	print("    grass_angle: отсечение — кадров %d, худший %s: %.4f %%" % [frames, worst_name, worst * 100.0])
	_teardown()


func test_grass_angle_cards_draw() -> void:
	_build(["angle", "angle"], 0.1)
	_set_size(Vector2i(256, SIZE_H))
	_fields[1].set_mid_visible(false)
	var pitch := -3.0
	var fov := 60.0
	var rows := PackedInt32Array()
	for y in SIZE_H:
		var k := (0.5 - (y + 0.5) / SIZE_H) * 2.0 * tan(deg_to_rad(fov) * 0.5)
		var below := -(deg_to_rad(pitch) + atan(k))
		if below > 0.0:
			var dist := 1.5 / tan(below)
			if dist >= 16.0 and dist <= 30.0:
				rows.append(y)
	check(rows.size() >= 3, "в кадре полоса 16–30 м: %d строк" % rows.size())
	var worst := 1.0
	for yaw in [0.0, 120.0, 240.0]:
		var share := await _frame(Vector2.ZERO, 1.5, yaw, pitch, fov, true, rows)
		worst = minf(worst, share)
		check(share > 0.15, "yaw %d: на 16–30 м карточки меняют %.1f %% пикселей" % [int(yaw), share * 100.0])
	print("    grass_angle: на 16–30 м с глаза 1,5 м средняя трава меняет не меньше %.0f %% пикселей" % (worst * 100.0))
	if OS.has_environment("DP_GRASS_MID_SHOT"):
		_fields[1].set_mid_visible(true)
		_set_size(Vector2i(1280, 720))
		await _frame(Vector2.ZERO, 1.5, 30.0, -6.0, 60.0)
		_views[0].get_texture().get_image().save_png(OS.get_environment("DP_GRASS_MID_SHOT") + "_angle.png")
	_teardown()


## Сверху: глаз 40 и 60 м, взгляд вниз на 60–90°; на рельефе с уклоном 4 % и буграми (наклон до ~8°)
## угол к поверхности в кольце до 40 м не меньше 45° − 8° > 30°.
func test_grass_angle_top_equals_shell() -> void:
	_build(["shell", "angle"])
	_set_size(Vector2i(256, SIZE_H))
	var worst := 0.0
	var frames := 0
	for eye: float in [40.0, 60.0]:
		for yaw in range(0, 360, 60):
			for pitch: float in [-60.0, -75.0, -89.0]:
				var share := await _frame(Vector2.ZERO, eye, float(yaw), pitch, 75.0)
				frames += 1
				worst = maxf(worst, share)
				check(share <= MAX_SHARE, "глаз %d yaw %d pitch %d: angle ≠ shell, %.4f %%" % [int(eye), yaw, int(pitch), share * 100.0])
	print("    grass_angle: сверху angle = shell — кадров %d, худший %.4f %%" % [frames, worst * 100.0])
	_teardown()


func test_grass_angle_no_black_dots_msaa() -> void:
	for msaa in [Viewport.MSAA_2X, Viewport.MSAA_4X]:
		_build(["angle", "angle"], 1.0, msaa)
		_set_size(Vector2i(320, 180))
		_fields[1].set_mid_visible(false)
		var worst := 0.0
		for eye: float in [1.5, 10.0]:
			for yaw in range(0, 360, 90):
				for pitch: float in [-5.0, -25.0]:
					var share := await _dark_share(eye, float(yaw), pitch)
					worst = maxf(worst, share)
					check(share <= DARK_MAX, "MSAA %d×, глаз %d yaw %d pitch %d: тёмных точек %.4f %%" % [1 << msaa, int(eye), yaw, int(pitch), share * 100.0])
		print("    grass_angle: MSAA %d× — тёмных точек не больше %.4f %%" % [1 << msaa, worst * 100.0])
		_teardown()


## Доля пикселей, где кадр с травой темнее DARK_K × кадра без средней травы (среди не тёмных без).
func _dark_share(eye: float, yaw: float, pitch: float) -> float:
	await _frame(Vector2.ZERO, eye, yaw, pitch, 75.0)
	var a := _views[0].get_texture().get_image()
	var b := _views[1].get_texture().get_image()
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var da := a.get_data()
	var db := b.get_data()
	var dark := 0
	var n := 0
	for i in da.size() / 3:
		var lb := 0.2126 * db[i * 3] + 0.7152 * db[i * 3 + 1] + 0.0722 * db[i * 3 + 2]
		if lb < 12.0:
			continue
		n += 1
		var la := 0.2126 * da[i * 3] + 0.7152 * da[i * 3 + 1] + 0.0722 * da[i * 3 + 2]
		if la < DARK_K * lb:
			dark += 1
	return float(dark) / maxf(n, 1.0)


func _set_size(s: Vector2i) -> void:
	for vp in _views:
		vp.size = s


## modes — режим средней травы каждой из двух сцен; relief_k — множитель наклона и бугров рельефа.
func _build(modes: Array, relief_k: float = 1.0, msaa: int = Viewport.MSAA_2X) -> void:
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
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	for k in 2:
		var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
		cfg.mid.mode = modes[k]
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.msaa_3d = msaa
		vp.size = Vector2i(256, SIZE_H)
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


## Земля под травой — сетка высот рельефа, ровный цвет луга.
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
	var h := a.get_height()
	var bpp := da.size() / (w * h)
	var rr := rows.duplicate()
	if rr.is_empty():
		for y in h:
			rr.append(y)
	var bad := 0
	for y in rr:
		for x in w:
			var px := y * w + x
			for ch in mini(bpp, 3):
				if absi(int(da[px * bpp + ch]) - int(dc[px * bpp + ch])) > TOL:
					bad += 1
					break
	return float(bad) / (w * rr.size())
