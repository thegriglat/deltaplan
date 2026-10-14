extends Node
## GPU-сверка (tools/gpu_tests.sh --filter=scene_look_ambient): оценка рассеянного света Godot
## TerrainRenderer.scene_look_sky (sl_sky_up, sl_ground_low — для «земли снизу» SL-2) против
## настоящего: белые ламбертовы квадраты с нормалью вверх и вниз под небом SkyEnvironment без
## солнца, тонмаппинг линейный — пиксель = рассеянный свет Godot (линейный после sRGB → linear).

var failures: PackedStringArray = []

const LW := Vector3(0.2126, 0.7152, 0.0722)
const QUAD_SHADER := """
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;
uniform vec3 n_world = vec3(0.0, 1.0, 0.0);
void fragment() {
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
}
"""


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _quad(vp: SubViewport, sh: Shader, n: Vector3, x: float) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	mi.mesh = q
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("n_world", n)
	mi.material_override = m
	mi.position = Vector3(x, 0.0, -3.0)
	vp.add_child(mi)


func test_ambient_estimate() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(200, 100)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var sky := SkyEnvironment.new()
	vp.add_child(sky)
	var env: Environment = sky.world_env.environment
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.glow_enabled = false
	env.adjustment_enabled = false
	env.fog_enabled = false
	env.ssao_enabled = false
	sky.sun.visible = false
	if sky.haze != null:
		sky.haze.visible = false
	if sky.glare != null:
		sky.glare.visible = false
	var cam := Camera3D.new()
	cam.fov = 40.0
	vp.add_child(cam)
	var sh := Shader.new()
	sh.code = QUAD_SHADER
	_quad(vp, sh, Vector3.UP, -0.5)
	_quad(vp, sh, Vector3.DOWN, 0.5)
	for i in 12:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	var up := img.get_pixel(77, 50).srgb_to_linear()
	var down := img.get_pixel(123, 50).srgb_to_linear()
	var est := TerrainRenderer.scene_look_sky(sky.clock.to_sun())
	var e_up: Vector3 = est.sky_up
	var e_low: Vector3 = est.ground_low
	var g_up := Vector3(up.r, up.g, up.b)
	var g_low := Vector3(down.r, down.g, down.b)
	print("         Godot вверх %s (Y %.4f), оценка %s (Y %.4f), отношение %.2f" % [g_up, g_up.dot(LW), e_up, e_up.dot(LW), g_up.dot(LW) / maxf(e_up.dot(LW), 1e-6)])
	print("         Godot вниз  %s (Y %.4f), оценка %s (Y %.4f), отношение %.2f" % [g_low, g_low.dot(LW), e_low, e_low.dot(LW), g_low.dot(LW) / maxf(e_low.dot(LW), 1e-6)])
	vp.queue_free()
	# оценка (с AMBIENT_GODOT_K) — в пределах ±25 % от Godot по яркости вверх и вниз
	for pair in [[g_up, e_up, "вверх"], [g_low, e_low, "вниз"]]:
		var r := (pair[0] as Vector3).dot(LW) / maxf((pair[1] as Vector3).dot(LW), 1e-6)
		check(r > 0.8 and r < 1.25, "рассеянный свет %s: Godot / оценка = %.2f" % [pair[2], r])
