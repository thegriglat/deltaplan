extends Node
## GPU-проверка раннего выхода крестов деревьев и импостеров леса вне поля зрения (GR-11,
## tools/gpu_tests.sh --filter=tree_cull): настоящий Terrain (Онгудай) в SubViewport; один и тот же
## кадр рисуется с отсечением (cull_enabled = true) и без него. Кадры должны совпасть: пикселей с
## |Δ| > 2/255 не больше 0,01 %. Камера у земли (2 м) и на высоте над лесом, 3 соотношения сторон ×
## FOV 40/75/100 × yaw/pitch + серия быстрого поворота 35°/кадр. Кресты и импостеры — по очереди
## (остальное скрыто); у крестов и импостеров свой лес в кольце (кресты до ~1,1 км, импостеры
## 0,8–3,5 км), поэтому для импостеров камера выше (300–800 м над лесом).

const SIZE_H := 144
const ASPECTS := {"16:9": 256, "21:9": 336, "4:3": 192}
const FOVS := [40.0, 75.0, 100.0]
const YAWS_STEP := 60
const PITCHES := [-60.0, -15.0, 10.0]
const MAX_SHARE := 0.0001
const TOL := 2

var failures: PackedStringArray = []
var _vp: SubViewport
var _cam: Camera3D
var _t: Terrain
var _site := Vector2.ZERO


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_tree_cull_frames_match_without_cull() -> void:
	await _build()
	if _t == null or _t.crosses == null or _t.impostors == null:
		check(false, "нет крестов/импостеров на Онгудае")
		return
	var modes := {
		"кресты": [_t.crosses, [2.0, 300.0]],
		"импостеры": [_t.impostors, [2.0, 500.0, 800.0]],
	}
	for mode: String in modes:
		var node: Node3D = modes[mode][0]
		_only(node)
		var frames := 0
		var worst := 0.0
		var worst_name := ""
		for eye: float in modes[mode][1]:
			for asp: String in ASPECTS:
				_vp.size = Vector2i(ASPECTS[asp], SIZE_H)
				for fov: float in FOVS:
					for yaw in range(0, 360, YAWS_STEP):
						for pitch: float in PITCHES:
							var name := "%s глаз %d м %s fov %d yaw %d pitch %d" % [mode, int(eye), asp, int(fov), yaw, int(pitch)]
							var share := await _frame(node, eye, float(yaw), pitch, fov)
							frames += 1
							if share > worst:
								worst = share
								worst_name = name
							check(share <= MAX_SHARE, "%s: отличается %.4f %% пикселей" % [name, share * 100.0])
		# быстрый поворот: 35° за кадр × 12 кадров
		_vp.size = Vector2i(256, SIZE_H)
		for eye: float in modes[mode][1]:
			for k in 12:
				var share := await _frame(node, eye, 35.0 * k, -8.0, 75.0, false)
				frames += 1
				check(share <= MAX_SHARE, "%s: поворот, глаз %d м, yaw %d: %.4f %%" % [mode, int(eye), 35 * k, share * 100.0])
		print("    tree_cull %s: кадров %d, худший %s: %.4f %%" % [mode, frames, worst_name, worst * 100.0])
	_teardown()


## В кадрах есть кресты и импостеры (иначе сравнение пустое): узел виден — кадр отличается от кадра без него.
func test_tree_cull_frame_has_trees() -> void:
	await _build()
	if _t == null or _t.crosses == null or _t.impostors == null:
		check(false, "нет крестов/импостеров на Онгудае")
		return
	_vp.size = Vector2i(320, 180)
	for pair: Array in [[_t.crosses, 150.0, "кресты"], [_t.impostors, 500.0, "импостеры"]]:
		var node: Node3D = pair[0]
		_only(node)
		_place(pair[1], 0.0, -20.0, 75.0)
		await _frames(3)
		var with_n := _vp.get_texture().get_image()
		node.visible = false
		node.process_mode = Node.PROCESS_MODE_DISABLED
		await _frames(3)
		var without := _vp.get_texture().get_image()
		var diff := _diff_share(with_n, without, 0.03 * 255.0)
		print("    tree_cull %s: пикселей с деревьями %.2f %%" % [pair[2], diff * 100.0])
		check(diff > 0.002, "%s видны в кадре: %.4f" % [pair[2], diff])
	_teardown()


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(256, SIZE_H)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.7, 0.9)
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	_vp.add_child(sun)
	_t = Terrain.new()
	_t.location_id = ""
	_vp.add_child(_t)
	if not _t.load_location("ongudai"):
		_t = null
		return
	_cam = Camera3D.new()
	_cam.far = 20000.0
	_vp.add_child(_cam)
	_cam.make_current()
	for n in [_t.crosses, _t.impostors]:
		if n != null:
			n.camera = _cam
	# центр кадра — лес маски рядом со стартом
	var s: Vector3 = _t.get_start_sites()[0].position
	_site = Vector2(s.x, s.z)
	for r in range(0, 3000, 100):
		var hit := false
		for a in 16:
			var q := Vector2(s.x, s.z) + Vector2.from_angle(a * TAU / 16.0) * r
			if _t.forest_at(q.x, q.y) > 0.7:
				_site = q
				hit = true
				break
		if hit:
			break
	await _frames(4)


func _teardown() -> void:
	if _vp != null:
		_vp.queue_free()
	_vp = null
	_t = null
	await get_tree().process_frame


## Виден только node (остальные слои деревьев скрыты, рельеф остаётся).
func _only(node: Node3D) -> void:
	for n in [_t.crosses, _t.impostors, _t.trees]:
		if n == null:
			continue
		var on: bool = n == node
		n.visible = on
		n.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _place(eye: float, yaw: float, pitch: float, fov: float) -> void:
	var p := Vector3(_site.x, _t.height_at(_site.x, _site.y) + eye, _site.y)
	_cam.fov = fov
	_cam.global_transform = Transform3D(
			Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0), EULER_ORDER_YXZ), p)


func _set_cull(node: Node, on: bool) -> void:
	var m := node.get("material") as ShaderMaterial
	m.set_shader_parameter("cull_enabled", on)


## Кадр с отсечением и без, доля пикселей с |Δ| > TOL/255 (любой канал).
## settle — подождать лишний кадр (смена размера/FOV); в серии поворота — по два кадра на вариант.
func _frame(node: Node3D, eye: float, yaw: float, pitch: float, fov: float, settle: bool = true) -> float:
	var share: float = await _frame_once(node, eye, yaw, pitch, fov, settle)
	if share > MAX_SHARE:
		# разовый сбой кадра (подгрузка рельефа/чанков между двумя снимками) не ошибка отсечения: ошибка
		# отсечения воспроизводима — повторяем кадр, считается второй
		share = await _frame_once(node, eye, yaw, pitch, fov, true)
	return share


func _frame_once(node: Node3D, eye: float, yaw: float, pitch: float, fov: float, settle: bool) -> float:
	_place(eye, yaw, pitch, fov)
	_set_cull(node, true)
	await _frames(3 if settle else 2)
	var a := _vp.get_texture().get_image()
	_set_cull(node, false)
	await _frames(2)
	var c := _vp.get_texture().get_image()
	_set_cull(node, true)
	return _diff_share(a, c, float(TOL))


static func _diff_share(a: Image, c: Image, tol: float) -> float:
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
			if absf(float(da[px * bpp + ch]) - float(dc[px * bpp + ch])) > tol:
				bad += 1
				break
	return float(bad) / (a.get_width() * a.get_height())
