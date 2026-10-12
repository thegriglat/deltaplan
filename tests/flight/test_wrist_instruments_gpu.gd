extends Node
## GPU-проверка (tools/gpu_tests.sh): компас и часы на запястье видны со стороны циферблата (−Z
## пустышки): картушка рисуется (светлые риски, красная N) и поворачивается, стрелки часов видны.

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Кадр прибора со стороны циферблата: камера на −Z в 0,2 м, свет из камеры.
func _shot(wi_setup: Callable) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(160, 160)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 25.0
	vp.add_child(cam)
	cam.transform = Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), Vector3(0, 0, -0.2))
	var sun := DirectionalLight3D.new()
	vp.add_child(sun)
	sun.transform = Transform3D(Basis.looking_at(Vector3(0.6, -0.6, 0.5), Vector3.UP), Vector3.ZERO)
	var pm := Node3D.new()
	for n in ["WristL", "WristR"]:
		var w := Node3D.new()
		w.name = n
		pm.add_child(w)
	vp.add_child(pm)
	var wi := WristInstruments.new()
	vp.add_child(wi)
	wi.attach(pm)
	wi_setup.call(wi)
	for i in 6:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


func _count(img: Image, pred: Callable) -> int:
	var n := 0
	for y in range(40, 120):
		for x in range(40, 120):
			if pred.call(img.get_pixel(x, y)):
				n += 1
	return n


func _diff(a: Image, b: Image) -> int:
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			if absf(a.get_pixel(x, y).r - b.get_pixel(x, y).r) > 0.15:
				n += 1
	return n


func test_wrist_compass_card_visible_and_turns_gpu() -> void:
	var a := await _shot(func(wi: WristInstruments) -> void:
		wi.watch.visible = false
		wi.set_process(false)
		wi._card.rotation.z = 0.0)
	var b := await _shot(func(wi: WristInstruments) -> void:
		wi.watch.visible = false
		wi.set_process(false)
		wi._card.rotation.z = PI / 2.0)
	var ink := _count(a, func(c: Color) -> bool: return c.r > 0.6 and c.g > 0.55 and c.b > 0.45)
	var red := _count(a, func(c: Color) -> bool: return c.r > 0.3 and c.r > 2.0 * c.g and c.r > 2.0 * c.b)
	check(ink > 60, "светлые риски и буквы картушки видны: %d px" % ink)
	check(red > 8, "красная N видна: %d px" % red)
	var d := _diff(a, b)
	check(d > 150, "картушка при повороте на 90° меняет кадр: %d px" % d)


func test_wrist_watch_hands_visible_gpu() -> void:
	var a := await _shot(func(wi: WristInstruments) -> void:
		wi.compass.visible = false
		wi.watch.visible = true
		wi.set_hands(3.0))
	var b := await _shot(func(wi: WristInstruments) -> void:
		wi.compass.visible = false
		wi.watch.visible = true
		wi.set_hands(9.0))
	check(_diff(a, b) > 40, "стрелки часов видны и двигаются: %d px" % _diff(a, b))
