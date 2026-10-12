extends Node
## GPU-проверка (tools/gpu_tests.sh): декаль тени от неба темнит поверхность с шейдером в стиле травы
## (cull_disabled, world_vertex_coords, свой light(), цвет через ALBEDO) — как GrassField. Нужен рендер.

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_sky_shade_grass_gpu_decal_darkens_grass_style_shader() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 5, 0))
	var sh := Shader.new()
	sh.code = (
		"shader_type spatial;\nrender_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;\n"
		+ "void fragment() { ALBEDO = vec3(0.5); ROUGHNESS = 0.9; BACKLIGHT = vec3(0.4); }\n"
	)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var q := QuadMesh.new()
	q.size = Vector2(20, 20)
	q.orientation = PlaneMesh.FACE_Y
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	vp.add_child(mi)
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0.5))
	var d := Decal.new()
	d.size = Vector3(3, 2, 3)
	d.texture_albedo = ImageTexture.create_from_image(img)
	d.position = Vector3(0, 0.3, 0)
	vp.add_child(d)
	for i in 6:
		await get_tree().process_frame
	var out := vp.get_texture().get_image()
	var mid := out.get_pixel(32, 32).r
	var edge := out.get_pixel(2, 2).r
	check(mid < 0.85 * edge, "пятно темнее окрестности на шейдере травы: %.3f vs %.3f" % [mid, edge])
	vp.queue_free()


## Яркость в центре пятна на экране = (1 − darkening(0, h)) от яркости вне пятна (линейный свет,
## допуск 0.04): проверяет, что fade декали в Forward+ не меняет формулу PH-К7.
func test_sky_shade_grass_gpu_matches_darkening_formula() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var ground := StaticBody3D.new()  # только держатель высоты: ground_fn плоская y=0
	vp.add_child(ground)
	var q := QuadMesh.new()
	q.size = Vector2(60, 60)
	q.orientation = PlaneMesh.FACE_Y
	var mi := MeshInstance3D.new()
	mi.mesh = q
	ground.add_child(mi)
	var vis := Node3D.new()
	vp.add_child(vis)
	vis.position = Vector3(0, 3.0, 0)
	var ss := SkyShade.new()
	vis.add_child(ss)
	var cfg: Dictionary = (Config.get_config("flight").visual.sky_shade as Dictionary).duplicate()
	cfg.sky_share = 0.5
	cfg.shift_k = 0.0
	ss.setup(13.5, cfg)
	ss.ground_fn = func(_x: float, _z: float) -> float: return 0.0
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0, 12, 0))
	cam.fov = 70.0
	for i in 8:
		await get_tree().process_frame
	var out := vp.get_texture().get_image()
	var mid := out.get_pixel(32, 32).srgb_to_linear().r
	var far := out.get_pixel(1, 1).srgb_to_linear().r
	var expect := 1.0 - SkyShade.darkening(0.0, ss.last_h, 13.5, cfg)
	check(far > 0.1, "земля освещена: %.3f" % far)
	check(absf(mid / far - expect) < 0.04, "яркость в центре %.3f vs 1−darkening %.3f (h=%.2f)" % [mid / far, expect, ss.last_h])
	vp.queue_free()
