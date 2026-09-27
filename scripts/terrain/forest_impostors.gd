class_name ForestImpostors
extends MultiMeshInstance3D
## Средний план леса (≈ 0,4–2 км): билборды из атласа импостеров, всё считает
## forest_impostors.gdshader; скрипт двигает сетку за камерой. Ближе — 3D-модели
## (TerrainTreeModels), дальше — полог в шейдере рельефа. Параметры — configs/world.json → trees
## (раздел impostors и species).

const SHADER := preload("res://scripts/terrain/forest_impostors.gdshader")

var camera: Camera3D
var material: ShaderMaterial

var _spacing: float = 10.0
var _max_agl: float = 5000.0
var _layer: HeightLayer
var _last_cell := Vector2(INF, INF)


## false — нет атласа (средний план не рисуется).
func setup(
	layer: HeightLayer,
	height_tex: Texture2D,
	surface: SurfaceLayer,
	surface_tex: Texture2D,
	cfg: Dictionary
) -> bool:
	var ic: Dictionary = cfg.get("impostors", {})
	var atlas := TerrainRenderer.load_texture(String(ic.get("atlas", "")))
	if atlas == null or not bool(ic.get("enabled", true)):
		return false
	_layer = layer
	_spacing = float(ic.spacing_m)
	_max_agl = float(ic.get("max_agl_m", 5000.0))
	var outer := float(ic.outer_m)
	var n := int(ceil(2.0 * outer / _spacing)) + 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _quad()
	mm.instance_count = n * n
	var buf := PackedFloat32Array()
	buf.resize(n * n * 12)
	for i in n * n:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	mm.buffer = buf
	multimesh = mm
	material = ShaderMaterial.new()
	material.shader = SHADER
	var m := material
	m.set_shader_parameter("height_tex", height_tex)
	m.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	m.set_shader_parameter("layer_spacing", layer.spacing)
	m.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	TerrainRenderer.set_surface(m, surface, surface_tex)
	m.set_shader_parameter("atlas", atlas)
	m.set_shader_parameter("atlas_cells", Vector2(ic.atlas_cells[0], ic.atlas_cells[1]))
	m.set_shader_parameter("grid_n", n)
	m.set_shader_parameter("spacing_m", _spacing)
	var r := float(cfg.radius_m)
	m.set_shader_parameter("inner_m", r * float(ic.fade_start_k))
	m.set_shader_parameter("inner_end_m", r)
	m.set_shader_parameter("outer_m", outer)
	m.set_shader_parameter("density", float(ic.density))
	m.set_shader_parameter("brightness", float(ic.brightness))
	m.set_shader_parameter("sink_fraction", float(cfg.sink_fraction))
	m.set_shader_parameter("edge_sink_fraction", float(cfg.get("edge_sink_fraction", 0.05)))
	m.set_shader_parameter("edge_probe_m", float(cfg.get("edge_probe_m", 30.0)))
	m.set_shader_parameter("band_blend_m", float(cfg.get("band_blend_m", 200.0)))
	var sp: Dictionary = cfg.get("species", {})
	var w := PackedFloat32Array()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	var asp := PackedFloat32Array()
	var hts: Array[Vector2] = []
	for name in TreePlacer.SPECIES:
		var s: Dictionary = sp.get(name, {})
		w.append(float(s.get("weight", 0.0)))
		lo.append(float(s.get("min_m", -1e4)))
		hi.append(float(s.get("max_m", 1e4)))
		asp.append(float(s.get("aspect", 0.0)))
		var hr: Array = s.get("height_m", [15.0, 25.0])
		hts.append(Vector2(float(hr[0]), float(hr[1])))
	m.set_shader_parameter("sp_weight", w)
	m.set_shader_parameter("sp_min", lo)
	m.set_shader_parameter("sp_max", hi)
	m.set_shader_parameter("sp_aspect", asp)
	m.set_shader_parameter("sp_height", hts)
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 100.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 200.0, layer.size_z())
	)
	return true


## Просеки (маска WorldClearings, 255 — расчищено).
func set_clearings(mask: Image, origin: Vector2, cell_m: float) -> void:
	if material == null:
		return
	material.set_shader_parameter("clear_tex", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("has_clearings", true)
	material.set_shader_parameter("clear_origin", origin)
	material.set_shader_parameter("clear_cell_m", cell_m)
	material.set_shader_parameter("clear_size", Vector2(mask.get_width(), mask.get_height()))


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	visible = p.y - _layer.sample(p.x, p.z) < _max_agl
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_center_cell", cell)


## Квад x ∈ [−0.5, 0.5], y ∈ [0, 1]; UV.y = 0 наверху (как в атласе).
static func _quad() -> ArrayMesh:
	var verts := PackedVector3Array(
		[Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)]
	)
	var uvs := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
