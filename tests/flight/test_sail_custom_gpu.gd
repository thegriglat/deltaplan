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


## Геометрия обшивки: вершины в мире (SailMaterial.skin_indices — по треугольникам, без кармана киля).
func _skin(r: Rig, top: bool) -> PackedVector3Array:
	var verts: PackedVector3Array = r.sail.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var out := PackedVector3Array()
	for i in SailMaterial.skin_indices(r.sail.mesh, top):
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


func _centroid(skin: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for v in skin:
		c += v
	return c / maxf(1.0, skin.size())


## Снимок с картинкой (img_on) и без (img_off) одним и тем же видом.
func _pair(r: Rig, above: bool, size: float, center: Vector3) -> Array[Image]:
	_look(r, above, size, center)
	var tex := _quad_texture()
	SailMaterial.set_custom(r.mat, tex)
	var on := await _shot(r)
	SailMaterial.set_custom(r.mat, null)
	var off := await _shot(r)
	SailMaterial.set_custom(r.mat, tex)
	return [on, off]


## Вне картинки (у законцовок) — родная: совпадает с рендером без своей картинки.
func _outside_native(r: Rig, skin: PackedVector3Array, on: Image, off: Image, tag: String) -> void:
	for sx in [-3.6, 3.6]:
		for f in [0.3, 0.7]:
			var pt := _point(skin, sx, f)
			var a := _sample(r, on, pt)
			var b := _sample(r, off, pt)
			check(_same(a, b), "%s: x=%.1f f=%.1f вне картинки — родная: %s / %s" % [tag, sx, f, a, b])


func _run_model(model: String, with_pocket: bool) -> void:
	var r := _rig(model)
	var top := _skin(r, true)
	var bottom := _skin(r, false)
	check(top.size() > 100 and bottom.size() > 100, model + ": есть обшивки")
	var ct := _centroid(top)
	var a_bot: float = r.mat.get_shader_parameter("custom_aspect_bottom")
	# взгляд сверху
	var p_top := await _pair(r, true, 12.0, ct)
	_quadrants(r, top, p_top[0], "top " + model)
	_outside_native(r, top, p_top[0], p_top[1], "top " + model)
	check(not _same(_sample(r, p_top[0], _point(top, -0.3, 0.2)), _sample(r, p_top[1], _point(top, -0.3, 0.2))),
			model + ": у картинки есть эффект (контроль)")
	# взгляд снизу, общий план
	var p_bot := await _pair(r, false, 12.0, ct)
	_outside_native(r, bottom, p_bot[0], p_bot[1], "bottom " + model)
	if with_pocket:
		_underside_of_top(r, top, bottom, p_bot[0], model)
	# нижняя обшивка: узкая (короткая по хорде) — крупным планом, точки только на ней
	if a_bot > 8.0:
		var p_zoom := await _pair(r, false, 4.0, _centroid(bottom))
		_quadrants(r, bottom, p_zoom[0], "bottom " + model)
	else:
		_quadrants(r, bottom, p_bot[0], "bottom " + model)
	if with_pocket:
		await _pocket(r, model)
	r.vp.queue_free()


## К2 v2: там, где нижней обшивки по хорде нет, снизу видна изнанка верхней — раскладка верха как есть
## (зеркально): цвет из картинки верха, не родной.
func _underside_of_top(r: Rig, top: PackedVector3Array, bottom: PackedVector3Array, img: Image, model: String) -> void:
	var span := 0.0
	for v in top:
		span = maxf(span, 2.0 * absf(v.x))
	var a_top: float = r.mat.get_shader_parameter("custom_aspect_top")
	var dx := 0.25 * span / a_top
	var zb := _point(bottom, dx, 1.0).z  # задний край нижней обшивки
	var zt0 := _point(top, dx, 0.0).z
	var zt1 := _point(top, dx, 1.0).z
	var z := zt1 - 0.15 * (zt1 - zt0)  # f = 0,85 верха: задняя половина картинки
	check(z > zb + 0.1, "%s: есть зона без нижней обшивки (z=%.2f, край низа %.2f)" % [model, z, zb])
	# верх: a = s, b = q (>0,5): x = +dx (s > 0,5) — жёлтый, x = −dx — синий
	var cp := _sample(r, img, Vector3(dx, 0.0, z))
	var cm := _sample(r, img, Vector3(-dx, 0.0, z))
	check(_is(cp, "yellow"), "%s: изнанка верха у +X — жёлтый (раскладка верха): %s" % [model, cp])
	check(_is(cm, "blue"), "%s: изнанка верха у −X — синий: %s" % [model, cm])


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
