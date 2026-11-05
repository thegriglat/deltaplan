extends Node
## GPU-проверка (tools/gpu_tests.sh), SLT-5: шейдер паруса читает маску анимации UV2 без переворота V.
## Крыло aeros_discus, без пилота и рамы, камера ортогональная и наклонена (иначе смещение вдоль +Y
## вдоль луча зрения не видно). time_override фиксирован, billow_amp_m = 0,3.
##  1) нижняя обшивка распознаётся: кадры при lower_surface_factor = 1 и 0 различаются на низе;
##  2) смещение у передней кромки ≈ 0 (body = smoothstep по t), в середине хорды — заметно.

var failures: PackedStringArray = []

const VP := 320
const MODEL := "aeros_discus"


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


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
	r.mat.set_shader_parameter("time_override", 0.3)  # фиксированное время: кадры повторяемы
	r.mat.set_shader_parameter("airspeed_ms", 0.0)  # «мягкий» парус: полная амплитуда
	r.mat.set_shader_parameter("billow_amp_m", 0.3)  # крупнее штатной 0,05 — для различимости
	return r



## Наклонный ортогональный вид: снизу (from_above = false) или сверху; луч идёт с отклонением по хорде.
func _look(r: Rig, from_above: bool, size: float, center: Vector3) -> void:
	var dir := Vector3(0.0, -1.0 if from_above else 1.0, 0.7).normalized()
	r.cam.size = size
	r.cam.transform = Transform3D(Basis.looking_at(dir, Vector3.FORWARD), center - dir * 20.0)


func _shot(r: Rig) -> Image:
	for i in 5:
		await get_tree().process_frame
	return r.vp.get_texture().get_image()


func _skin(r: Rig, top: bool) -> PackedVector3Array:
	var verts: PackedVector3Array = r.sail.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var out := PackedVector3Array()
	for i in SailMaterial.skin_indices(r.sail.mesh, top):
		out.append(r.sail.global_transform * verts[i])
	return out


func _centroid(skin: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for v in skin:
		c += v
	return c / maxf(1.0, skin.size())


## Точка обшивки: x, доля хорды f (0 — нос, 1 — хвост) по z-размаху в полосе около x; y — ближайшей вершины.
func _point(skin: PackedVector3Array, x: float, f: float) -> Vector3:
	var zmin := INF
	var zmax := -INF
	for v in skin:
		if absf(v.x - x) < 0.08:
			zmin = minf(zmin, v.z)
			zmax = maxf(zmax, v.z)
	var z := lerpf(zmin, zmax, f)
	var best := INF
	var y := 0.0
	for v in skin:
		var d := Vector2(v.x - x, v.z - z).length()
		if d < best:
			best = d
			y = v.y
	return Vector3(x, y, z)


## Средний |A−B| по окну 7×7 вокруг мировой точки (по каналам RGB, 0..1).
func _patch_diff(r: Rig, a: Image, b: Image, p: Vector3) -> float:
	var s := r.cam.unproject_position(p)
	var acc := 0.0
	var n := 0
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var px := clampi(int(s.x) + dx, 0, VP - 1)
			var py := clampi(int(s.y) + dy, 0, VP - 1)
			var ca := a.get_pixel(px, py)
			var cb := b.get_pixel(px, py)
			acc += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return acc / n


## Средний |A−B| по точкам обшивки в середине размаха и хорды f ∈ [f0, f1].
func _region_diff(r: Rig, a: Image, b: Image, skin: PackedVector3Array, f0: float, f1: float) -> float:
	var acc := 0.0
	var n := 0
	for x in [-2.4, -1.6, -0.8, 0.8, 1.6, 2.4]:
		for k in 5:
			var f := lerpf(f0, f1, k / 4.0)
			acc += _patch_diff(r, a, b, _point(skin, x, f))
			n += 1
	return acc / n


func test_sail_uv2_lower_surface_recognized() -> void:
	var r := _rig(MODEL)
	var bottom := _skin(r, false)
	check(bottom.size() > 100, "есть нижняя обшивка")
	_look(r, false, 12.0, _centroid(bottom))
	r.mat.set_shader_parameter("lower_surface_factor", 1.0)
	var a := await _shot(r)
	r.mat.set_shader_parameter("lower_surface_factor", 0.0)
	var b := await _shot(r)
	var d := _region_diff(r, a, b, bottom, 0.45, 0.9)
	print("sail_uv2_gpu: низ, mean|A−B| = %.5f (%.2f/255)" % [d, d * 255.0])
	check(d > 2.0 / 255.0, "lower_surface_factor действует на нижнюю обшивку: %.2f/255" % (d * 255.0))
	r.vp.queue_free()


func test_sail_uv2_leading_edge_still() -> void:
	var r := _rig(MODEL)
	var top := _skin(r, true)
	_look(r, true, 12.0, _centroid(top))
	r.mat.set_shader_parameter("lower_surface_factor", 1.0)
	var with_billow := await _shot(r)
	r.mat.set_shader_parameter("billow_amp_m", 0.0)
	var without := await _shot(r)
	var edge := _region_diff(r, with_billow, without, top, 0.02, 0.08)
	var mid := _region_diff(r, with_billow, without, top, 0.45, 0.65)
	print("sail_uv2_gpu: верх, у передней кромки %.5f (%.2f/255), середина хорды %.5f (%.2f/255)" % [edge, edge * 255.0, mid, mid * 255.0])
	check(edge < 1.0 / 255.0, "у передней кромки смещения нет: %.2f/255" % (edge * 255.0))
	check(mid > 2.0 / 255.0, "в середине хорды смещение есть: %.2f/255" % (mid * 255.0))
	r.vp.queue_free()
