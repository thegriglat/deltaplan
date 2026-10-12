class_name CampFabric
extends RefCounted
## Ткань лагеря (контракт SC-K5, docs/contracts/start-camp.md): общий шейдер
## assets/shaders/camp/camp_fabric.gdshader, один ShaderMaterial на пресет на всех.
## Тон (sRGB) = base_color × COLOR.rgb (цвет экземпляра MultiMesh) × instance uniform `tint`
## (отдельные MeshInstance3D: set_instance_shader_parameter("tint", Vector3)). fabric_dark тон не берёт.

const SHADER := preload("res://assets/shaders/camp/camp_fabric.gdshader")
const NORMAL := preload("res://assets/textures/camp/fabric_normal.png")

## Пресет → параметры шейдера поверх умолчаний.
const PRESETS := {
	"tent": {},
	"tent_door": {"base_color": Vector3(0.65, 0.65, 0.65), "weave_strength": 0.8},
	"bag": {"weave_strength": 1.3, "tile_m": 0.22, "fold_strength": 0.5, "dirt_amount": 0.7},
	"fabric_dark":
	{
		"use_color": false,
		"base_color": Vector3(0.16, 0.17, 0.18),
		"roughness": 0.9,
		"dirt_amount": 0.35
	},
	"sail": {"roughness": 0.55, "weave_strength": 0.5, "fold_strength": 0.35, "tile_m": 0.4},
	"cloth": {"weave_strength": 0.7, "tile_m": 0.12, "fold_strength": 0.6, "dirt_amount": 0.3},
}

static var _cache: Dictionary = {}


static func presets() -> Array:
	return PRESETS.keys()


## Общий материал пресета (тот же объект при повторном вызове); неизвестный пресет → "tent".
static func material(preset: String) -> ShaderMaterial:
	if not PRESETS.has(preset):
		push_warning("CampFabric: нет пресета %s, беру tent" % preset)
		preset = "tent"
	if _cache.has(preset):
		return _cache[preset]
	var m := ShaderMaterial.new()
	m.resource_name = "CampFabric_" + preset
	m.shader = SHADER
	m.set_shader_parameter("fabric_normal", NORMAL)
	var p: Dictionary = PRESETS[preset]
	for k in p:
		m.set_shader_parameter(k, p[k])
	_cache[preset] = m
	return m
