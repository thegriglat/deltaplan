extends Node
## GPU-сверка сезона (tools/gpu_tests.sh --filter=season): sl_season из scene_look.gdshaderinc против
## CPU-зеркала SeasonLook.state (контракт SL-К2) на наборе (день, широта, высота); заодно шейдеры
## рельефа, травы, импостеров и моделей деревьев компилируются на настоящем GPU (ошибки шейдера
## выводятся в лог — tools/gpu_tests.sh … | grep -i "shader error").

var failures: PackedStringArray = []


## Ловит ошибки компиляции шейдеров (terrain, grass, forest_impostors не рисуют квад без данных
## рельефа, поэтому по пикселю их не проверить): любой «SHADER ERROR»/«Shader compilation failed».
class ShaderErrors:
	extends Logger
	var errors: PackedStringArray = []

	func _log_error(
		_function: String, _file: String, _line: int, code: String, rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		var t := code + " " + rationale
		if t.contains("hader") and (t.contains("ompil") or t.contains("rror")):
			errors.append(t.strip_edges())


var logger := ShaderErrors.new()

const PROBE := """
shader_type spatial;
render_mode unshaded, cull_disabled;
#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc"
uniform vec3 args = vec3(196.0, 51.0, 0.0);
uniform vec4 pre = vec4(196.0, 196.0, 0.0, 1.0);
uniform bool second = false;
void fragment() {
	float rel;
	vec4 s = sl_season_f(pre.x, pre.z, pre.w, args.z, rel);
	ALBEDO = second ? vec3(s.w) : s.xyz;
}
"""
const CASES := [
	[196.0, 51.0, 0.0], [274.0, 51.0, 1000.0], [260.0, 56.8, 300.0], [120.0, 45.0, 800.0],
	[15.0, 51.0, 0.0], [300.0, -35.0, 500.0], [100.0, 5.0, 0.0], [235.0, 51.0, 300.0],
	[270.0, 43.0, 2200.0], [140.0, 60.0, 100.0],
]


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _quad(vp: SubViewport, sh: Shader, x: float, y: float, params: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.4, 0.4)
	mi.mesh = q
	var m := ShaderMaterial.new()
	m.shader = sh
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	mi.material_override = m
	mi.position = Vector3(x, y, -3.0)
	vp.add_child(mi)


func test_season_mirror_and_compile() -> void:
	OS.add_logger(logger)
	var vp := SubViewport.new()
	vp.size = Vector2i(400, 160)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 40.0
	vp.add_child(cam)
	var sh := Shader.new()
	sh.code = PROBE
	var look: Dictionary = Config.get_config("world").get("scene_look", {})
	var p := {"sl_season_enabled": true}
	for i in CASES.size():
		var c: Array = CASES[i]
		var col := i % 5
		var row := i / 5
		var x := -0.8 + 0.4 * col
		var args := Vector3(c[0], c[1], c[2])
		_quad(vp, sh, x, 0.45 - 0.45 * row, {"args": args, "pre": SeasonLook.pre(c[0], c[1], look)}.merged(p))
	# вторая пачка: канал bare отдельными квадратами ниже
	for i in CASES.size():
		var c2: Array = CASES[i]
		_quad(vp, sh, -0.8 + 0.4 * (i % 5), -0.45 - 0.45 * (i / 5),
				{"args": Vector3(c2[0], c2[1], c2[2]), "second": true,
				"pre": SeasonLook.pre(c2[0], c2[1], look)}.merged(p))
	# остальные шейдеры сезона — просто на экран (компиляция)
	var others: Array[String] = [
		"res://scripts/terrain/terrain.gdshader", "res://scripts/terrain/grass.gdshader",
		"res://scripts/terrain/forest_impostors.gdshader", "res://scripts/terrain/tree_model.gdshader",
	]
	for i in others.size():
		var s2 := load(others[i]) as Shader
		check(s2 != null, "шейдер загружен: %s" % others[i])
		if s2 != null:
			_quad(vp, s2, 1.1, 0.6 - 0.4 * i, {"sl_season_enabled": true})
	for i in 12:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	for i in CASES.size():
		var c3: Array = CASES[i]
		var col3 := i % 5
		var row3 := i / 5
		var s := SeasonLook.state(c3[0], c3[1], c3[2], look)
		var p1 := cam.unproject_position(Vector3(-0.8 + 0.4 * col3, 0.45 - 0.45 * row3, -3.0))
		var p2 := cam.unproject_position(Vector3(-0.8 + 0.4 * col3, -0.45 - 0.45 * row3, -3.0))
		var a := img.get_pixelv(Vector2i(p1)).srgb_to_linear()
		var b := img.get_pixelv(Vector2i(p2)).srgb_to_linear()
		var tag := "doy %.0f φ %.1f h %.0f" % [c3[0], c3[1], c3[2]]
		check(absf(a.r - float(s.green)) < 0.02, "green %s: gpu %.3f cpu %.3f" % [tag, a.r, float(s.green)])
		check(absf(a.g - float(s.dry)) < 0.02, "dry %s: gpu %.3f cpu %.3f" % [tag, a.g, float(s.dry)])
		check(absf(a.b - float(s.autumn)) < 0.02, "autumn %s: gpu %.3f cpu %.3f" % [tag, a.b, float(s.autumn)])
		check(absf(b.r - float(s.bare)) < 0.02, "bare %s: gpu %.3f cpu %.3f" % [tag, b.r, float(s.bare)])
	# tree_model рисует квад без данных рельефа: не скомпилировался бы — пусто (прозрачный фон)
	var pc := cam.unproject_position(Vector3(1.1, 0.6 - 0.4 * 3, -3.0))
	check(img.get_pixelv(Vector2i(pc)).a > 0.01, "tree_model рисует (компилируется)")
	OS.remove_logger(logger)
	for e in logger.errors:
		check(false, "ошибка шейдера в логе: " + e)
