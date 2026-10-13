extends Node
## GPU-проверка (tools/gpu_tests.sh), SL-7: просвет паруса против солнца. Плоский кусок ткани
## (шейдер паруса), камера снизу смотрит вверх; солнце сзади (за тканью), сбоку и спереди (за камерой).
## Свечение: сзади сильнее, чем сбоку и спереди; forward_gain = 0 — разницы нет; без пересвета
## (линейная яркость ниже 1); латы (маска _trans = 0) гаснут; тень облака (v_cs_sun) — не здесь.

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Средняя линейная яркость центра кадра. sun_up — направление НА солнце (мир); gain — forward_gain;
## trans — значение маски _trans (1 — ткань, 0 — лата).
func _shot(sun_up: Vector3, gain: float, trans: float) -> float:
	var vp := SubViewport.new()
	vp.size = Vector2i(48, 48)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.transform = Transform3D(Basis.looking_at(Vector3.UP, Vector3.FORWARD), Vector3(0, -3, 0))
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.0
	vp.add_child(sun)
	sun.transform = Transform3D(Basis.looking_at(-sun_up.normalized(), Vector3.FORWARD), Vector3.ZERO)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/sail/sail.gdshader") as Shader
	var gray := Image.create(4, 4, false, Image.FORMAT_RGB8)
	gray.fill(Color(0.8, 0.8, 0.8))
	mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(gray))
	var tr := Image.create(4, 4, false, Image.FORMAT_RGB8)
	tr.fill(Color(trans, trans, trans))
	mat.set_shader_parameter("trans_tex", ImageTexture.create_from_image(tr))
	mat.set_shader_parameter("forward_gain", gain)
	var q := QuadMesh.new()
	q.size = Vector2(20, 20)
	q.orientation = PlaneMesh.FACE_Y
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	vp.add_child(mi)
	for i in 6:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	var c := img.get_pixel(24, 24)
	vp.queue_free()
	return (c.r + c.g + c.b) / 3.0


func test_sail_forward_scatter_brightness() -> void:
	var behind := await _shot(Vector3(0.0, 1.0, 0.0), 0.7, 1.0)
	var side := await _shot(Vector3(1.0, 0.15, 0.0), 0.7, 1.0)
	var front := await _shot(Vector3(0.0, -1.0, 0.0), 0.7, 1.0)
	var behind0 := await _shot(Vector3(0.0, 1.0, 0.0), 0.0, 1.0)
	var side0 := await _shot(Vector3(1.0, 0.15, 0.0), 0.0, 1.0)
	var lat := await _shot(Vector3(0.0, 1.0, 0.0), 0.7, 0.0)
	print(
		"sail_forward: behind=%.3f side=%.3f front=%.3f | gain0: behind=%.3f side=%.3f | lat=%.3f"
		% [behind, side, front, behind0, side0, lat]
	)
	check(behind > 1.4 * behind0, "против солнца свечение сильнее, чем без рассеяния вперёд")
	check(behind > 1.4 * side, "против солнца ярче, чем при солнце сбоку")
	check(absf(side - side0) < 0.02, "сбоку рассеяния вперёд нет")
	check(behind < 0.9, "без пересвета (линейная яркость < 0,9): %.3f" % behind)
	check(behind > 0.05, "ткань на просвет светится: %.3f" % behind)
	check(lat < 0.5 * behind, "лата (маска пропускания 0) темнее ткани")
