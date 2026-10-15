extends Node
## GPU-проверка вида ближней травы (GR-6, tools/gpu_tests.sh --filter=grass_look): настоящий
## GrassField на ровном лугу, два SubViewport в одном кадре (TIME один) — у одного своя нормаль
## травинки (конфиг), у другого leaf_tilt_deg = 0 (освещение как у земли, как до GR-6).
## Числа, а не подгонка: (1) своя нормаль меняет картинку ближней травы; (2) при угасании нормали
## (blade_normal_fade_m до камеры) кадр совпадает с «как земля» — среднее и дальнее кольца не
## сломаны; (3) трава с солнцем сзади и против солнца отличается сильнее, чем у «как земля»
## (лицо травинки освещено/в тени, просвет), но средняя яркость остаётся в 0,5…1,5 от «как земля».

const W := 256
const H := 144
const EYE_M := 1.5
const TOL := 2

var failures: PackedStringArray = []
var _layer: HeightLayer
var _views: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _suns: Array[DirectionalLight3D] = []
var _fields: Array[GrassField] = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_grass_look_blade_normal_changes_near_grass() -> void:
	_build()
	_set_param(1, "leaf_tilt_deg", 0.0)
	var r := await _frame(0.0, -35.0)
	print("    grass_look: доля различающихся пикселей травы %.3f, Δяркости %.4f" % [r.diff_share, r.dlum])
	check(r.grass_share > 0.5, "трава в кадре: %.2f" % r.grass_share)
	check(r.diff_share > 0.2, "своя нормаль меняет ближнюю траву: %.3f" % r.diff_share)
	_teardown()


func test_grass_look_fade_matches_ground_normal() -> void:
	_build()
	_set_param(0, "blade_normal_fade_m", Vector2(-2.0, -1.0))
	_set_param(1, "leaf_tilt_deg", 0.0)
	var r := await _frame(0.0, -35.0)
	print("    grass_look: нормаль погашена — отличается %.4f %% пикселей" % (r.diff_share * 100.0))
	check(r.diff_share <= 0.0001, "погашенная нормаль = нормаль полога: %.4f" % r.diff_share)
	_teardown()


func test_grass_look_sun_side_contrast_and_brightness() -> void:
	_build()
	_set_param(1, "leaf_tilt_deg", 0.0)
	var front := await _frame(0.0, -35.0)   # солнце за спиной
	var back := await _frame(180.0, -35.0)  # против солнца
	var k_blade := float(front.lum0) / maxf(float(back.lum0), 1e-4)
	var k_ground := float(front.lum1) / maxf(float(back.lum1), 1e-4)
	print(
		(
			"    grass_look: яркость травы (своя нормаль / как земля): солнце сзади %.3f / %.3f, против %.3f / %.3f; "
			+ "сзади/против %.2f / %.2f"
		)
		% [front.lum0, front.lum1, back.lum0, back.lum1, k_blade, k_ground]
	)
	check(k_blade > k_ground + 0.1, "лицо травинки по солнцу: %.2f против %.2f" % [k_blade, k_ground])
	for r: Dictionary in [front, back]:
		var k: float = r.lum0 / maxf(r.lum1, 1e-4)
		check(k > 0.5 and k < 1.5, "яркость относительно «как земля»: %.2f" % k)
	_teardown()


func _build() -> void:
	var n := 96
	var step := 2.0
	var o := -float(n) * step * 0.5
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for j in n:
		for i in n:
			var h := 200.0 + 0.4 * sin(i * 0.7) * cos(j * 0.5)
			hs[j * n + i] = h
			img.set_pixel(i, j, Color(h, 0, 0))
	_layer = HeightLayer.from_heights("t", n, n, step, o, o, hs)
	var htex := ImageTexture.create_from_image(img)
	var sn := 48
	var ss := 4.0
	var cls := PackedByteArray()
	cls.resize(sn * sn)
	cls.fill(SurfaceLayer.GRASS)
	var simg := Image.create(sn, sn, false, Image.FORMAT_R8)
	simg.fill(Color(SurfaceLayer.GRASS / 255.0, 0, 0))
	var surf := SurfaceLayer.from_classes("s", sn, sn, ss, -sn * ss * 0.5, -sn * ss * 0.5, cls)
	var stex := ImageTexture.create_from_image(simg)
	var cfg: Dictionary = (Config.get_config("vegetation").grass as Dictionary).duplicate(true)
	var look: Dictionary = Config.get_config("world").get("terrain_look", {})
	for k in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(W, H)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.5, 0.6, 0.8)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.35, 0.4, 0.45)
		var we := WorldEnvironment.new()
		we.environment = env
		vp.add_child(we)
		var sun := DirectionalLight3D.new()
		vp.add_child(sun)
		var cam := Camera3D.new()
		cam.far = 500.0
		cam.fov = 75.0
		vp.add_child(cam)
		var g := GrassField.new()
		g.camera = cam
		vp.add_child(g)
		var spots: Array[Vector4] = []
		g.setup(_layer, htex, surf, stex, look, cfg, spots)
		_views.append(vp)
		_cams.append(cam)
		_suns.append(sun)
		_fields.append(g)


func _set_param(i: int, key: String, v: Variant) -> void:
	for m in _fields[i].materials():
		m.set_shader_parameter(key, v)


func _teardown() -> void:
	for vp in _views:
		vp.queue_free()
	_views.clear()
	_cams.clear()
	_suns.clear()
	_fields.clear()


## Кадр обеих сцен: камера смотрит на −Z (pitch вниз), солнце на высоте 40° с азимута sun_yaw
## (0 — за спиной камеры). Возвращает долю травы в кадре, долю пикселей травы с |Δ| > TOL/255,
## среднюю яркость травы в обеих сценах (lum0 — своя нормаль, lum1 — вторая) и их разность.
func _frame(sun_yaw: float, pitch: float) -> Dictionary:
	var p := Vector3(0.3, _layer.sample(0.3, 0.2) + EYE_M, 0.2)
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), 0.0, 0.0), EULER_ORDER_YXZ)
	for i in 2:
		_cams[i].global_transform = Transform3D(b, p)
		_suns[i].rotation_degrees = Vector3(-40.0, sun_yaw, 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var a := _views[0].get_texture().get_image()
	var c := _views[1].get_texture().get_image()
	a.convert(Image.FORMAT_RGBA8)
	c.convert(Image.FORMAT_RGBA8)
	var bga := a.get_pixel(0, 0)   # верхняя строка — небо (взгляд вниз на 35°, верх кадра над горизонтом)
	var bgc := c.get_pixel(0, 0)
	var grass := 0
	var diff := 0
	var l0 := 0.0
	var l1 := 0.0
	for y in H:
		for x in W:
			var pa := a.get_pixel(x, y)
			var pc := c.get_pixel(x, y)
			if _near(pa, bga) and _near(pc, bgc):
				continue
			grass += 1
			l0 += pa.get_luminance()
			l1 += pc.get_luminance()
			if (
				absi(pa.r8 - pc.r8) > TOL
				or absi(pa.g8 - pc.g8) > TOL
				or absi(pa.b8 - pc.b8) > TOL
			):
				diff += 1
	var ng := maxi(grass, 1)
	return {
		"grass_share": float(grass) / (W * H),
		"diff_share": float(diff) / ng,
		"lum0": l0 / ng,
		"lum1": l1 / ng,
		"dlum": (l0 - l1) / ng,
	}


func _near(p: Color, q: Color) -> bool:
	return absf(p.r - q.r) < 0.02 and absf(p.g - q.g) < 0.02 and absf(p.b - q.b) < 0.02
