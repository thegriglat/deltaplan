class_name SailMaterial
extends RefCounted
## Материал паруса (docs/models.md → «Шейдер паруса»). Подключение из визуала планера:
##   var mat := SailMaterial.apply(sail_mesh_instance, "glider_sport")   # один раз после загрузки
##   SailMaterial.set_flight(mat, airspeed_ms, stall_amount, turbulence)   # каждый кадр
## Раскраска берётся из исходного материала .glb, карты — assets/shaders/sail/<модель>_*.png,
## параметры — configs/sail.json (через Config). Нет файлов — остаётся исходный материал.

const SHADER_PATH := "res://assets/shaders/sail/sail.gdshader"
const DIR := "res://assets/shaders/sail/"


## Поставить ShaderMaterial паруса на меш Sail. model — имя модели крыла без .glb.
static func apply(sail: MeshInstance3D, model: String) -> ShaderMaterial:
	if sail == null or sail.mesh == null or not ResourceLoader.exists(SHADER_PATH):
		push_warning("SailMaterial: нет меша Sail или шейдера — исходный материал")
		return null
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH) as Shader
	var src := sail.mesh.surface_get_material(0) as BaseMaterial3D
	if src != null:
		mat.set_shader_parameter("albedo_tex", src.albedo_texture)
		mat.set_shader_parameter("albedo_tint", src.albedo_color)
	for map_name: String in ["normal", "trans"]:
		var path := DIR + "%s_%s.png" % [model, map_name]
		if ResourceLoader.exists(path):
			mat.set_shader_parameter(map_name + "_tex", load(path))
		else:
			push_warning("SailMaterial: нет карты " + path)
	var params := _params()
	for key: String in params:
		var v: Variant = params[key]
		if v is Array:
			v = Vector3(float(v[0]), float(v[1]), float(v[2]))
		if key != "cast_shadows":
			mat.set_shader_parameter(key, v)
	# Тень от паруса закрыла бы нижнюю обшивку от солнца (свет сквозь верхнюю обшивку не
	# моделируется), поэтому по умолчанию парус тень не отбрасывает (configs/sail.json).
	if not bool(params.get("cast_shadows", false)):
		sail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sail.material_override = mat
	return mat


## Параметры полёта: воздушная скорость, м/с; сваливание 0..1; турбулентность 0..1.
static func set_flight(mat: ShaderMaterial, airspeed_ms: float, stall_amount: float,
		turbulence: float) -> void:
	if mat == null:
		return
	mat.set_shader_parameter("airspeed_ms", airspeed_ms)
	mat.set_shader_parameter("stall_amount", clampf(stall_amount, 0.0, 1.0))
	mat.set_shader_parameter("turbulence", clampf(turbulence, 0.0, 1.0))


static func _params() -> Dictionary:
	var out := {}
	var data: Dictionary = Config.get_config("sail")
	for key: String in data:
		if not key.begins_with("_") and not key.ends_with("_doc") and key != "turbulence_full_g":
			out[key] = data[key]
	return out
