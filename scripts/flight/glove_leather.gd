class_name GloveLeather
extends RefCounted
## Кожаный материал перчаток и краг пилота: шейдер assets/shaders/glove/glove_leather.gdshader
## (Leather037, ambientCG, CC0) подменяет материалы Glove* в PilotBody (и в копии «hands»).

const SHADER := preload("res://assets/shaders/glove/glove_leather.gdshader")
const ALBEDO := preload("res://assets/textures/glove/leather037_color.jpg")
const NORMAL := preload("res://assets/textures/glove/leather037_normal.jpg")
const ROUGH := preload("res://assets/textures/glove/leather037_roughness.jpg")

static var _mat: ShaderMaterial


static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.resource_name = "GloveLeather"
		_mat.shader = SHADER
		_mat.set_shader_parameter("albedo_tex", ALBEDO)
		_mat.set_shader_parameter("normal_tex", NORMAL)
		_mat.set_shader_parameter("rough_tex", ROUGH)
	return _mat


## Подменить материалы Glove* (поверхности меша, имя материала в glb) на кожу.
static func apply(mi: MeshInstance3D) -> int:
	var n := 0
	if mi == null or mi.mesh == null:
		return n
	for i in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(i)
		if m != null and m.resource_name.begins_with("Glove"):
			mi.set_surface_override_material(i, material())
			n += 1
	return n
