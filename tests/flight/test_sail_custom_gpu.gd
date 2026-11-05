extends Node
## GPU-проверка (tools/gpu_tests.sh), SLT-К2: своя картинка на парусе читается снаружи и не зеркально.
## Картинка 1:1 из четырёх квадрантов (красный — верх-лево, зелёный — верх-право, синий — низ-лево,
## жёлтый — низ-право). Крыло одно, без пилота и рамы, камера ортогональная, нос (−Z) вверху экрана:
## сверху правая законцовка пилота (+X) справа, снизу — слева (взгляд снизу). Точки выборки заданы
## геометрией меша (x, доля хорды по z), не UV. Вне картинки и на кармане киля — родная текстура.

var failures: PackedStringArray = []

const VP := 320


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _quad_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var left := x < n / 2
			var top := y < n / 2
			var c := Color(1, 0, 0) if (top and left) else Color(0, 1, 0) if top else Color(0, 0, 1) if left else Color(1, 1, 0)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


class Rig:
	var vp: SubViewport
	var cam: Camera3D
	var sail: MeshInstance3D
	var mat: ShaderMaterial


func _rig(model: String) -> Rig:
	var r := Rig.new()
	r.vp = SubViewport.new()
	r.vp.size = Vector2i(VP, VP)
	r.vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(r.vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	r.vp.add_child(we)
	r.cam = Camera3D.new()
	r.cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	r.cam.near = 0.01
	r.cam.far = 100.0
	r.vp.add_child(r.cam)
	var glb := load("res://assets/models/glider_%s.glb" % model) as PackedScene
	var wing := glb.instantiate() as Node3D
	r.vp.add_child(wing)
	r.sail = wing.find_child("Sail", true, false) as MeshInstance3D
	# только парус
	for mi in wing.find_children("*", "MeshInstance3D", true, false):
		if mi != r.sail:
			(mi as MeshInstance3D).visible = false
	r.mat = SailMaterial.apply(r.sail, model)
	r.mat.set_shader_parameter("translucency", 0.0)
	r.mat.set_shader_parameter("forward_gain", 0.0)
	return r


func _look(r: Rig, from_above: bool, size: float, center: Vector3) -> void:
	var up_dir := Vector3.DOWN if from_above else Vector3.UP
	r.cam.size = size
	r.cam.transform = Transform3D(Basis.looking_at(up_dir, Vector3.FORWARD), center - up_dir * 20.0)


func _shot(r: Rig) -> Image:
	for i in 5:
		await get_tree().process_frame
	return r.vp.get_texture().get_image()


## Геометрия обшивки: вершины в мире. top — верх (UV.y > 0.5), без кармана киля.
func _skin(r: Rig, top: bool) -> PackedVector3Array:
	var arr := r.sail.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var out := PackedVector3Array()
	for i in verts.size():
		if (uvs[i].y > 0.5) == top and absf(nrm[i].x) <= 0.7:
			out.append(r.sail.global_transform * verts[i])
	return out


## Точка обшивки: x, доля хорды f (0 — нос, 1 — хвост) по z-размаху обшивки в полосе около x.
func _point(skin: PackedVector3Array, x: float, f: float) -> Vector3:
	var zmin := INF
	var zmax := -INF
	for v in skin:
		if absf(v.x - x) < 0.08:
			zmin = minf(zmin, v.z)
			zmax = maxf(zmax, v.z)
	return Vector3(x, 0.0, lerpf(zmin, zmax, f))


## Средний цвет окна 7×7 вокруг мировой точки.
func _sample(r: Rig, img: Image, p: Vector3) -> Color:
	var s := r.cam.unproject_position(p)
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var px := clampi(int(s.x) + dx, 0, VP - 1)
			var py := clampi(int(s.y) + dy, 0, VP - 1)
			acc += img.get_pixel(px, py)
			n += 1
	return acc / n


func _is(c: Color, want: String) -> bool:
	match want:
		"red":
			return c.r > 0.5 and c.r - c.g > 0.2 and c.r - c.b > 0.2
		"green":
			return c.g > 0.5 and c.g - c.r > 0.2 and c.g - c.b > 0.2
		"blue":
			return c.b > 0.5 and c.b - c.r > 0.2 and c.b - c.g > 0.2
		"yellow":
			return c.r > 0.5 and c.g > 0.5 and c.r - c.b > 0.2 and c.g - c.b > 0.2
	return false


func _same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.06


func _quadrants(r: Rig, skin: PackedVector3Array, img: Image, tag: String) -> void:
	# экран: нос вверху, +X (правое крыло пилота) справа сверху, −X справа снизу — см. _look
	# картинка 1:1 занимает по x долю 1/A размаха (A — аспект обшивки): берём точки в её середине
	var span := 0.0
	for v in skin:
		span = maxf(span, 2.0 * absf(v.x))
	var asp: float = r.mat.get_shader_parameter("custom_aspect_top" if tag.begins_with("top") else "custom_aspect_bottom")
	var dx := 0.5 * (0.5 * span / asp)
	var f_nose := 0.2
	var f_tail := 0.8
	var flip := 1.0 if tag.begins_with("top") else -1.0
	var left_nose := _sample(r, img, _point(skin, -dx, f_nose))
	var right_nose := _sample(r, img, _point(skin, dx, f_nose))
	var left_tail := _sample(r, img, _point(skin, -dx, f_tail))
	var right_tail := _sample(r, img, _point(skin, dx, f_tail))
	# сверху экранная левая — −X; снизу экранная левая — +X
	var screen_left_nose := left_nose if flip > 0.0 else right_nose
	var screen_right_nose := right_nose if flip > 0.0 else left_nose
	var screen_left_tail := left_tail if flip > 0.0 else right_tail
	var screen_right_tail := right_tail if flip > 0.0 else left_tail
	check(_is(screen_left_nose, "red"), "%s: у носа слева красный: %s" % [tag, screen_left_nose])
	check(_is(screen_right_nose, "green"), "%s: у носа справа зелёный: %s" % [tag, screen_right_nose])
	check(_is(screen_left_tail, "blue"), "%s: у хвоста слева синий: %s" % [tag, screen_left_tail])
	check(_is(screen_right_tail, "yellow"), "%s: у хвоста справа жёлтый: %s" % [tag, screen_right_tail])


func _run_model(model: String, with_pocket: bool) -> void:
	var r := _rig(model)
	r.mat.set_shader_parameter("custom_on", 0.0)
	var top := _skin(r, true)
	var bottom := _skin(r, false)
	check(top.size() > 100 and bottom.size() > 100, model + ": есть обшивки")
	var c := Vector3.ZERO
	for v in top:
		c += v
	c /= maxf(1.0, top.size())
	SailMaterial.set_custom(r.mat, _quad_texture())
	# взгляд сверху
	_look(r, true, 12.0, c)
	var img_top := await _shot(r)
	_quadrants(r, top, img_top, "top " + model)
	# взгляд снизу
	_look(r, false, 12.0, c)
	var img_bot := await _shot(r)
	if with_pocket:
		pass  # у моделей с карманом киля нижняя обшивка неполная: снизу в центре видна изнанка верхней (зеркально по К2)
	else:
		_quadrants(r, bottom, img_bot, "bottom " + model)
	# вне картинки (у законцовок) — родная: совпадает с рендером без своей картинки
	SailMaterial.set_custom(r.mat, null)
	_look(r, true, 12.0, c)
	var nat_top := await _shot(r)
	_look(r, false, 12.0, c)
	var nat_bot := await _shot(r)
	for sx in [-3.6, 3.6]:
		for f in [0.3, 0.7]:
			var pt := _point(top, sx, f)
			var a := _sample(r, img_top, pt)
			var b := _sample(r, nat_top, pt)
			check(_same(a, b), "%s: вверху x=%.1f f=%.1f вне картинки — родная: %s / %s" % [model, sx, f, a, b])
			if with_pocket:
				continue
			var pb := _point(bottom, sx, f)
			var ab := _sample(r, img_bot, pb)
			var bb := _sample(r, nat_bot, pb)
			check(_same(ab, bb), "%s: внизу x=%.1f f=%.1f вне картинки — родная: %s / %s" % [model, sx, f, ab, bb])
	check(not _same(_sample(r, img_top, _point(top, -0.3, 0.2)), _sample(r, nat_top, _point(top, -0.3, 0.2))),
			model + ": у картинки есть эффект (контроль)")
	if with_pocket:
		await _pocket(r, model)
	r.vp.queue_free()


## Карман киля (плоскость x = 0): вид с +X, камера у x = 0,3 (всё правее отсечено), цвет — как без картинки.
func _pocket(r: Rig, model: String) -> void:
	var arr := r.sail.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var c := Vector3.ZERO
	var n := 0
	for i in verts.size():
		if absf(nrm[i].x) > 0.7:
			c += r.sail.global_transform * verts[i]
			n += 1
	check(n > 0, model + ": в меше есть карман киля")
	if n == 0:
		return
	c /= n
	r.cam.size = 4.0
	r.cam.transform = Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP), Vector3(0.3, c.y, c.z))
	SailMaterial.set_custom(r.mat, _quad_texture())
	var on := await _shot(r)
	SailMaterial.set_custom(r.mat, null)
	var off := await _shot(r)
	var p := Vector3(0.0, c.y, c.z)
	var a := _sample(r, on, p)
	var b := _sample(r, off, p)
	check(not _same(a, Color(0.5, 0.5, 0.5)), model + ": карман виден (не фон): %s" % a)
	check(_same(a, b), model + ": карман киля — родная текстура: %s / %s" % [a, b])


func test_sail_custom_orientation_discus() -> void:
	await _run_model("aeros_discus", false)


func test_sail_custom_orientation_atlas_pocket() -> void:
	await _run_model("atlas", true)
