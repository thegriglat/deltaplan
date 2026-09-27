class_name GrassField
extends MultiMeshInstance3D
## Травинки вокруг камеры (VR-17, VR-6): сетка пучков едет за камерой, пучок привязан к мировой
## клетке; всё остальное (есть ли трава, высота, цвет, качание) — в grass.gdshader.
## Видна на старте, при разбеге и посадке (выше max_agl_m — выключена).
## Параметры — configs/world.json → grass.

const SHADER := preload("res://scripts/terrain/grass.gdshader")
## Скошенных мест в шейдере (размер массива mowed).
const MAX_MOWED := 4

var camera: Camera3D
## Нода пилота (приминание травы у ног); null — не приминать.
var pilot: Node3D
var material: ShaderMaterial

var _spacing: float = 0.5
var _max_agl: float = 120.0
var _layer: HeightLayer
var _last_cell := Vector2(INF, INF)


func setup(
	layer: HeightLayer,
	height_tex: Texture2D,
	surface: SurfaceLayer,
	surface_tex: Texture2D,
	look: Dictionary,
	cfg: Dictionary,
	mowed_spots: Array[Vector4]
) -> void:
	_layer = layer
	_spacing = float(cfg.clump_spacing_m)
	_max_agl = float(cfg.get("max_agl_m", 120.0))
	var radius := float(cfg.radius_m)
	var n := int(ceil(2.0 * radius / _spacing)) + 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = clump_mesh(int(cfg.blades_per_clump), float(cfg.blade_width_m), int(cfg.segments))
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
	material.set_shader_parameter("height_tex", height_tex)
	material.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	material.set_shader_parameter("layer_spacing", layer.spacing)
	material.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	TerrainRenderer.apply_look_params(material, look)
	TerrainRenderer.set_surface(material, surface, surface_tex)
	material.set_shader_parameter("grid_n", n)
	material.set_shader_parameter("clump_spacing_m", _spacing)
	material.set_shader_parameter("area_radius_m", radius)
	material.set_shader_parameter("blade_height_m", _v2(cfg.blade_height_m))
	material.set_shader_parameter("crop_height_m", _v2(cfg.crop_height_m))
	material.set_shader_parameter("shrub_density", float(cfg.shrub_density))
	material.set_shader_parameter("color_variation", float(cfg.color_variation))
	material.set_shader_parameter("sway_hz", float(cfg.sway_hz))
	material.set_shader_parameter("sway_amp", float(cfg.sway_amp))
	material.set_shader_parameter("bend_amp", float(cfg.bend_amp))
	material.set_shader_parameter("press_radius_m", float(cfg.press_radius_m))
	var spots := mowed_spots.slice(0, MAX_MOWED)
	while spots.size() < MAX_MOWED:
		spots.append(Vector4(1e9, 1e9, 0.0, 1.0))
	material.set_shader_parameter("mowed", spots)
	material.set_shader_parameter("mowed_count", mini(mowed_spots.size(), MAX_MOWED))
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 10.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 20.0, layer.size_z())
	)


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	visible = p.y - _layer.sample(p.x, p.z) < _max_agl
	if not visible:
		return
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_center_cell", cell)
	if pilot != null and pilot.is_inside_tree():
		material.set_shader_parameter("press_pos", pilot.global_position)


static func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


## Пучок травинок: blades штук в круге ~0,15 м, каждая — полоска из segments отрезков,
## VERTEX.y = t 0..1 (высоту и наклон задаёт шейдер), VERTEX.xz — смещение в метрах.
static func clump_mesh(blades: int, width: float, segments: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for b in blades:
		var base := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 0.15
		var face := Vector2.from_angle(rng.randf() * TAU)
		var side := Vector2(-face.y, face.x)
		var curl := face * rng.randf_range(0.02, 0.08)
		var start := verts.size()
		for s in segments:
			var t := float(s) / segments
			var w := width * (1.0 - t * 0.8) * 0.5
			var c := base + curl * t * t
			verts.append(Vector3(c.x - side.x * w, t, c.y - side.y * w))
			verts.append(Vector3(c.x + side.x * w, t, c.y + side.y * w))
		var tip := base + curl
		verts.append(Vector3(tip.x, 1.0, tip.y))
		for s in segments - 1:
			var a := start + s * 2
			idx.append_array(PackedInt32Array([a, a + 2, a + 1, a + 1, a + 2, a + 3]))
		var last := start + (segments - 1) * 2
		idx.append_array(PackedInt32Array([last, last + 2, last + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
