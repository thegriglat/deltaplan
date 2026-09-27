class_name TerrainTrees
extends MultiMeshInstance3D
## Деревья вокруг камеры (FR-19: чтобы у земли пилот видел масштаб и высоту).
## Всё считается в шейдере trees.gdshader; скрипт только двигает сетку за камерой.
## Параметры — configs/world.json → trees.

const SHADER := preload("res://scripts/terrain/trees.gdshader")

var camera: Camera3D
var _mat: ShaderMaterial
var _spacing: float = 8.0
var _last_cell := Vector2(INF, INF)


func setup(layer: HeightLayer, height_tex: Texture2D, look: Dictionary, cfg: Dictionary) -> void:
	_spacing = float(cfg.spacing_m)
	var radius := float(cfg.radius_m)
	var n := int(ceil(2.0 * radius / _spacing)) + 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _crown_mesh(int(cfg.mesh_segments), int(cfg.mesh_rings))
	mm.instance_count = n * n
	# Трансформы единичные: положение дерева шейдер считает сам по INSTANCE_ID.
	var buf := PackedFloat32Array()
	buf.resize(n * n * 12)
	for i in n * n:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	mm.buffer = buf
	multimesh = mm
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("height_tex", height_tex)
	_mat.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	_mat.set_shader_parameter("layer_spacing", layer.spacing)
	_mat.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	TerrainRenderer.apply_look_params(_mat, look)
	TerrainRenderer.set_water(_mat, layer)
	_mat.set_shader_parameter("grid_n", n)
	_mat.set_shader_parameter("tree_spacing_m", _spacing)
	_mat.set_shader_parameter("area_radius_m", radius)
	_mat.set_shader_parameter("conifer_height_m", _v2(cfg.conifer_height_m))
	_mat.set_shader_parameter("birch_height_m", _v2(cfg.birch_height_m))
	_mat.set_shader_parameter("conifer_radius_ratio", float(cfg.conifer_radius_ratio))
	_mat.set_shader_parameter("birch_radius_ratio", float(cfg.birch_radius_ratio))
	_mat.set_shader_parameter("sink_fraction", float(cfg.sink_fraction))
	_mat.set_shader_parameter("density", float(cfg.density))
	_mat.set_shader_parameter("color_variation", float(cfg.color_variation))
	material_override = _mat
	cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if bool(cfg.cast_shadows)
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	# Границы — вся зона слоя по высоте (реальное положение считает шейдер).
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 100.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 200.0, layer.size_z())
	)
	extra_cull_margin = 0.0


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or _mat == null:
		return
	var p := cam.global_position
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		_mat.set_shader_parameter("grid_center_cell", cell)


static func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


## Крона-«токарка»: кольца по высоте t = 0..1 (VERTEX.y = t, VERTEX.xz — единичное направление)
## + макушка. Форму (конус/овал) и размер задаёт шейдер.
static func _crown_mesh(segments: int, rings: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for r in rings:
		var t := float(r) / rings
		for s in segments:
			var a := TAU * s / segments
			verts.append(Vector3(cos(a), t, sin(a)))
	var tip := verts.size()
	verts.append(Vector3(0.0, 1.0, 0.0))
	for r in rings - 1:
		for s in segments:
			var a := r * segments + s
			var b := r * segments + (s + 1) % segments
			var c := a + segments
			var d := b + segments
			idx.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var top := (rings - 1) * segments
	for s in segments:
		idx.append_array(PackedInt32Array([top + s, tip, top + (s + 1) % segments]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
