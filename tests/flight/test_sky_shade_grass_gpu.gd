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
