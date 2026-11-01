extends Node
## GPU-проверка струи винта дельталёта по траве (TKF-К3, tools/gpu_tests.sh --filter=grass_wash): настоящий
## GrassField на ровном лугу, два SubViewport в одном кадре (TIME один): у сцены 1 вызван set_wash, у сцены 0 - нет
## (или тяга 0). Камера смотрит сверху. Диск в начале координат на 1 м над землёй, струя к +Z.
## (1) тяга 0 - кадр совпадает с кадром без вызова; (2) полная тяга: в конусе за винтом (2-10 м по оси, |x| < 1,5 м)
## трава отличается, сбоку (> 6 м) и дальше 25 м - нет.

const W := 256
const H := 256
const CAM_H := 14.0
const TOL := 2
const THRUST_FULL := 2070.0

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


func test_grass_wash_speed_ideal_disc() -> void:
	# идеальный диск: Ø1,8 м, 2070 Н, rho 1,225 -> 2 * 18,4 = 36,8 м/с (записка TKF-3, с точностью до rho)
	var v := GrassField.wash_speed(2070.0, 1.8, 1.225)
	check(absf(v - 36.6) < 0.8, "скорость струи при полной тяге: %.1f" % v)
	check(GrassField.wash_speed(0.0, 1.8, 1.225) == 0.0, "нулевая тяга - нулевая скорость")


func test_grass_wash_zero_thrust_is_identical() -> void:
	_build()
	_fields[1].set_wash(_disc(), Vector3.BACK, 0.0)
	var r := await _frame(6.0)
	print("    grass_wash: тяга 0 - различающихся пикселей %.5f" % r.all)
	check(r.grass > 0.5, "трава в кадре: %.2f" % r.grass)
	check(r.all == 0.0, "тяга 0 = кадр без set_wash: %.5f" % r.all)
	_teardown()


func test_grass_wash_cone_only() -> void:
	_build()
	_fields[1].set_wash(_disc(), Vector3.BACK, THRUST_FULL)
	var r := await _frame(6.0)
	print("    grass_wash: конус %.3f, сбоку %.5f" % [r.cone, r.side])
	check(r.cone > 0.3, "в конусе трава наклонена: %.3f" % r.cone)
	check(r.side == 0.0, "сбоку (> 6 м) не затронута: %.5f" % r.side)
	var far := await _frame(40.0)
	print("    grass_wash: дальше 25 м - различающихся пикселей %.5f" % far.all)
	check(far.all == 0.0, "дальше 25 м не затронута: %.5f" % far.all)
	_teardown()


func test_grass_wash_high_axis_off() -> void:
	_build()
	var p := _disc()
	p.y += 10.0
	_fields[1].set_wash(p, Vector3.BACK, THRUST_FULL)
	var r := await _frame(6.0)
	check(r.all == 0.0, "ось выше max_axis_agl_m - выключено: %.5f" % r.all)
	_teardown()


## Цена (инвариант 3), прикидка в тестовой сцене: GPU-время viewport 1280x720, камера у диска смотрит вдоль струи
## (в кадре весь конус), кадры с set_wash и без чередуются (дрейф тактов не копится). Это не протокол G3 целиком,
## а проверка, что добавка в пределах шума; порог в тесте - 0,3 мс.
func test_grass_wash_cost() -> void:
	_build()
	_views[0].size = Vector2i(1280, 720)
	var vp := _views[0]
	var cam := _cams[0]
	var f := _fields[0]
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	cam.global_transform = Transform3D(Basis.IDENTITY, _disc() + Vector3(0.0, 0.5, -2.0))
	var sum := [0.0, 0.0]
	var n := [0, 0]
	for i in 240:
		var on := i % 2 == 1
		f.set_wash(_disc(), Vector3.BACK, THRUST_FULL if on else 0.0)
		await RenderingServer.frame_post_draw
		if i < 20:
			continue
		sum[int(on)] += RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
		n[int(on)] += 1
	var off_ms: float = sum[0] / maxi(n[0], 1)
	var on_ms: float = sum[1] / maxi(n[1], 1)
	print("    grass_wash: цена GPU viewport, мс: без струи %.3f, со струёй %.3f, разность %.3f" % [off_ms, on_ms, on_ms - off_ms])
	check(on_ms - off_ms < 0.3, "добавка струи %.3f мс" % (on_ms - off_ms))
	_teardown()


func _disc() -> Vector3:
	return Vector3(0.0, _layer.sample(0.0, 0.0) + 1.0, 0.0)


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
		sun.rotation_degrees = Vector3(-40.0, 0.0, 0.0)
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
		_fields.append(g)


func _set_param(i: int, key: String, v: Variant) -> void:
	for m in _fields[i].materials():
		m.set_shader_parameter(key, v)


func _teardown() -> void:
	for vp in _views:
		vp.queue_free()
	_views.clear()
	_cams.clear()
	_fields.clear()


## Кадр сверху с центром на z = cz: доля различающихся пикселей (|Δ| > TOL/255) во всём кадре, в конусе
## (|x| < 1,5 м, z 2..10 м), сбоку (|x| > 6 м) и доля травы (непустой фон).
func _frame(cz: float) -> Dictionary:
	var p := Vector3(0.0, _layer.sample(0.0, cz) + CAM_H, cz)
	var b := Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0), EULER_ORDER_YXZ)
	for i in 2:
		_cams[i].global_transform = Transform3D(b, p)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var a := _views[0].get_texture().get_image()
	var c := _views[1].get_texture().get_image()
	a.convert(Image.FORMAT_RGBA8)
	c.convert(Image.FORMAT_RGBA8)
	var ext := CAM_H * tan(deg_to_rad(37.5))
	var all := [0, 0]
	var cone := [0, 0]
	var side := [0, 0]
	var bg := a.get_pixel(0, 0)
	var grass := 0
	for y in H:
		for x in W:
			var wx := (float(x) + 0.5) / W * 2.0 * ext - ext
			var wz := cz + ((float(y) + 0.5) / H * 2.0 * ext - ext)
			var pa := a.get_pixel(x, y)
			var pc := c.get_pixel(x, y)
			var d := (
				absi(pa.r8 - pc.r8) > TOL or absi(pa.g8 - pc.g8) > TOL or absi(pa.b8 - pc.b8) > TOL
			)
			if absf(pa.r - bg.r) > 0.02 or absf(pa.g - bg.g) > 0.02:
				grass += 1
			all[1] += 1
			all[0] += int(d)
			if absf(wx) < 1.5 and wz > 2.0 and wz < 10.0:
				cone[1] += 1
				cone[0] += int(d)
			if absf(wx) > 6.0:
				side[1] += 1
				side[0] += int(d)
	return {
		"all": float(all[0]) / all[1],
		"cone": float(cone[0]) / maxi(cone[1], 1),
		"side": float(side[0]) / maxi(side[1], 1),
		"grass": float(grass) / (W * H),
	}
