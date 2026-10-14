extends Node
## GPU-проверка вариантов шейдера рельефа (контракт SL-К6, tools/gpu_tests.sh --filter=terrain_variants):
## каждый закоммиченный вариант (scripts/terrain/terrain.gdshader, scripts/terrain/variants/*.gdshader) и
## каждый «без части X» (одна строка #define T_X_OFF, собирается в памяти, как временные варианты
## tools/terrain/variant_bench.py) компилируется на настоящем GPU без ошибок шейдера и рисует квад
## рельефа (плоский кусок 11×11 узлов: высоты 0, луг). Смена шейдера материала (full → min → full) не
## теряет параметры: картинка та же, что у свежего материала.

var failures: PackedStringArray = []

const MAIN := "res://scripts/terrain/terrain_main.gdshaderinc"
const FULL := "res://scripts/terrain/terrain.gdshader"
const VARIANTS_DIR := "res://scripts/terrain/variants"


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


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Части шейдера: #ifndef T_*_OFF в terrain_main и его include-ах (как variant_bench.py parts).
static func parts() -> PackedStringArray:
	var out: PackedStringArray = []
	var seen: PackedStringArray = []
	var todo: PackedStringArray = [MAIN]
	var inc := RegEx.create_from_string('#include\\s+"(res://[^"]+)"')
	var part := RegEx.create_from_string("#ifndef\\s+(T_[A-Z0-9_]+_OFF)\\b")
	while not todo.is_empty():
		var p: String = todo[0]
		todo.remove_at(0)
		if p in seen:
			continue
		seen.append(p)
		var t := FileAccess.get_file_as_string(p)
		for m in part.search_all(t):
			if not m.get_string(1) in out:
				out.append(m.get_string(1))
		for m in inc.search_all(t):
			todo.append(m.get_string(1))
	return out


static func committed() -> PackedStringArray:
	var out: PackedStringArray = [FULL]
	for f in DirAccess.get_files_at(VARIANTS_DIR):
		if f.ends_with(".gdshader"):
			out.append(VARIANTS_DIR + "/" + f)
	return out


## Шапка варианта (shader_type/render_mode «full») + #define + include тела.
static func bench_code(define: String) -> String:
	var head: PackedStringArray = []
	for ln in FileAccess.get_file_as_string(FULL).split("\n"):
		if ln.begins_with("shader_type") or ln.begins_with("render_mode"):
			head.append(ln)
	return "\n".join(head) + "\n#define %s\n#include \"%s\"\n" % [define, MAIN]


## Плоский кусок рельефа 11×11 узлов (шаг 10 м, высоты 0, всё — луг) и вид из world.json.
func _params() -> Dictionary:
	var n := 11
	var himg := Image.create(n, n, true, Image.FORMAT_RF)
	himg.fill(Color(0, 0, 0))
	himg.generate_mipmaps()
	var htex := ImageTexture.create_from_image(himg)
	var simg := Image.create(n, n, false, Image.FORMAT_R8)
	simg.fill(Color8(2, 0, 0))
	return {
		"height_tex": htex,
		"height_mip_tex": htex,
		"height_mip_max_lod": 3.0,
		"layer_origin": Vector2(-50.0, -50.0),
		"layer_spacing": 10.0,
		"layer_texels": Vector2(n, n),
		"skirt_depth": 0.0,
		"surface_tex": ImageTexture.create_from_image(simg),
		"surface_origin": Vector2(-50.0, -50.0),
		"surface_spacing": 10.0,
		"surface_texels": Vector2(n, n),
		"macro_noise_tex": TerrainRenderer.macro_noise_texture(),
	}


func _material(sh: Shader, params: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	TerrainRenderer.apply_look_params(m, Config.get_config("world").get("terrain_look", {}))
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	return m


func _patch(vp: SubViewport, m: ShaderMaterial, x: float) -> void:
	var mi := MeshInstance3D.new()
	var q := PlaneMesh.new()
	q.size = Vector2(8.0, 8.0)
	mi.mesh = q
	mi.material_override = m
	mi.position = Vector3(x, 0.0, 0.0)
	mi.extra_cull_margin = 100.0
	vp.add_child(mi)


func test_variants_compile_and_draw() -> void:
	OS.add_logger(logger)
	var shaders: Array[Shader] = []
	var names: PackedStringArray = []
	for p in committed():
		var s := load(p) as Shader
		check(s != null, "К6: вариант загружен: %s" % p)
		if s != null:
			shaders.append(s)
			names.append(p.get_file())
	var ps := parts()
	check(ps.size() >= 10, "К6: частей T_*_OFF в шейдере рельефа: %d" % ps.size())
	for d in ps:
		var s2 := Shader.new()
		s2.code = bench_code(d)
		shaders.append(s2)
		names.append("без " + d)
	var params := _params()
	var bad := 0
	# по 8 кусков на кадр: камера сверху, куски в ряд
	var i0 := 0
	while i0 < shaders.size():
		var vp := SubViewport.new()
		vp.size = Vector2i(640, 80)
		vp.own_world_3d = true
		vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 80.0
		cam.position = Vector3(35.0, 50.0, 0.0)
		cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		vp.add_child(cam)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
		vp.add_child(sun)
		var batch := mini(8, shaders.size() - i0)
		for k in batch:
			_patch(vp, _material(shaders[i0 + k], params), 10.0 * k)
		for f in 10:
			await get_tree().process_frame
		var img := vp.get_texture().get_image()
		for k in batch:
			var pc := cam.unproject_position(Vector3(10.0 * k, 0.0, 0.0))
			var c := img.get_pixelv(Vector2i(pc))
			var ok := c.a > 0.5
			if not ok:
				bad += 1
			check(ok, "К6: %s рисует кусок рельефа (альфа %.2f)" % [names[i0 + k], c.a])
		vp.queue_free()
		i0 += batch
	# смена шейдера материала не теряет параметры
	var full := load(FULL) as Shader
	var mn := load(VARIANTS_DIR + "/terrain_min.gdshader") as Shader
	var vp2 := SubViewport.new()
	vp2.size = Vector2i(160, 80)
	vp2.own_world_3d = true
	vp2.transparent_bg = true
	vp2.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp2)
	var cam2 := Camera3D.new()
	cam2.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam2.size = 20.0
	cam2.position = Vector3(5.0, 50.0, 0.0)
	cam2.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	vp2.add_child(cam2)
	var sun2 := DirectionalLight3D.new()
	sun2.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	vp2.add_child(sun2)
	var fresh := _material(full, params)
	var swapped := _material(full, params)
	_patch(vp2, fresh, 0.0)
	_patch(vp2, swapped, 10.0)
	for f in 4:
		await get_tree().process_frame
	swapped.shader = mn
	for f in 4:
		await get_tree().process_frame
	swapped.shader = full
	for f in 8:
		await get_tree().process_frame
	var img2 := vp2.get_texture().get_image()
	var a := img2.get_pixelv(Vector2i(cam2.unproject_position(Vector3(0.0, 0.0, 0.0))))
	var b := img2.get_pixelv(Vector2i(cam2.unproject_position(Vector3(10.0, 0.0, 0.0))))
	check(a.a > 0.5 and b.a > 0.5, "К6: оба куска нарисованы")
	check(
		absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.02,
		"К6: full → min → full: параметры сохранились (%s vs %s)" % [a, b]
	)
	vp2.queue_free()
	OS.remove_logger(logger)
	for e in logger.errors:
		check(false, "К6: ошибка шейдера в логе: " + e)
	print(
		"SL-К6 GPU: вариантов %d (закоммиченных %d, «без X» %d), не рисуют %d, ошибок шейдера %d"
		% [shaders.size(), committed().size(), ps.size(), bad, logger.errors.size()]
	)
