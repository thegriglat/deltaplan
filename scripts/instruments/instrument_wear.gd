class_name InstrumentWear
extends RefCounted
## Поношенный вид приборов: шейдер корпуса (assets/shaders/instruments/worn_body.gdshader) на все
## поверхности модели, кроме экрана, и текстура шероховатости стекла (микроцарапины и разводы —
## видны только в блике). Параметры — configs/instruments.json → wear (общий блок на оба прибора).
## Маска износа лежит в цвете вершин моделей (tools/blender/bl_util.py:bake_wear).

const SHADER_PATH := "res://assets/shaders/instruments/worn_body.gdshader"
const GLASS_TEX_SIZE := 256

static var _shader: Shader
static var _glass_tex: Dictionary = {}


## Вид материала по имени материала в .glb: plastic / rubber / metal (по умолчанию plastic).
static func kind_of(mat_name: String) -> String:
	var n := mat_name.to_lower()
	if n.contains("button") or n.contains("key"):
		return "rubber"
	if n.contains("clamp") or n.contains("chrome"):
		return "metal"
	return "plastic"


## Подменить материалы поверхностей model (кроме меша skip) на поношенные.
static func apply(model: Node, skip: MeshInstance3D, cfg: Dictionary) -> void:
	var wear: Dictionary = cfg.get("wear", {})
	if wear.is_empty() or not bool(wear.get("enabled", true)):
		return
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		return
	var common: Dictionary = wear.get("common", {})
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == skip or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if src == null:
				continue
			var kind := kind_of(src.resource_name)
			mi.set_surface_override_material(s, make_material(src, wear.get(kind, {}), common))


static func make_material(src: StandardMaterial3D, params: Dictionary, common: Dictionary) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = _shader
	sm.set_shader_parameter("base_color", src.albedo_color)
	sm.set_shader_parameter("base_rough", src.roughness)
	sm.set_shader_parameter("base_metal", src.metallic)
	for dict in [common, params]:
		for k in dict:
			if String(k).ends_with("_doc") or String(k).begins_with("_"):
				continue
			var v: Variant = dict[k]
			if v is String:
				v = Color(String(v))
			sm.set_shader_parameter(String(k), v)
	return sm


## Стекло/экран: roughness-текстура с микроцарапинами и разводами. Albedo/эмиссию не трогает —
## содержимое экрана не темнеет и не мылится, меняется только форма блика.
static func apply_glass(mat: StandardMaterial3D, cfg: Dictionary) -> void:
	var g: Dictionary = cfg.get("wear", {}).get("glass", {})
	if g.is_empty() or not bool(g.get("enabled", true)):
		return
	var clean := mat.roughness
	var rmax := float(g.get("roughness_max", 0.95))
	if clean >= rmax:
		return
	mat.roughness = rmax
	mat.roughness_texture = glass_texture(clean / rmax, g)
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## Текстура: чистое стекло = clean_level (даёт исходную шероховатость), разводы чуть выше,
## царапины — до 1. Детерминирована (seed).
static func glass_texture(clean_level: float, g: Dictionary) -> ImageTexture:
	var key := int(round(clean_level * 1000.0))
	if _glass_tex.has(key):
		return _glass_tex[key]
	var n := GLASS_TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_L8)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(g.get("seed", 1012))
	var fn := FastNoiseLite.new()
	fn.seed = rng.seed
	fn.frequency = 0.02
	var smudge := float(g.get("smudge", 0.18))
	var buf := PackedFloat32Array()
	buf.resize(n * n)
	for y in n:
		for x in n:
			var v := fn.get_noise_2d(x, y) * 0.5 + 0.5
			buf[y * n + x] = clean_level + smudge * (1.0 - clean_level) * smoothstep(0.45, 0.8, v)
	for i in int(g.get("scratch_count", 45)):
		var p := Vector2(rng.randf() * n, rng.randf() * n)
		var a := rng.randf() * TAU
		var len_px := rng.randf_range(0.06, 0.35) * n
		var d := Vector2(cos(a), sin(a))
		var str_ := rng.randf_range(0.35, 1.0) * float(g.get("scratch_strength", 0.8))
		for t in int(len_px):
			var q := p + d * t
			var ix := posmod(int(q.x), n)
			var iy := posmod(int(q.y), n)
			buf[iy * n + ix] = maxf(buf[iy * n + ix], lerpf(clean_level, 1.0, str_))
	for i in n * n:
		img.set_pixel(i % n, i / n, Color(buf[i], 0, 0))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_glass_tex[key] = tex
	return tex
