class_name ForestImpostors
extends MultiMeshInstance3D
## Средний план леса (≈ 0,4–2 км): билборды из атласа импостеров, всё считает
## forest_impostors.gdshader; скрипт двигает сетку за камерой. Ближе — 3D-модели
## (TerrainTreeModels), дальше — полог в шейдере рельефа. Билборд стоит там, где доля леса по маске
## 10 м ≥ 0,5 и не на воде (канал G < water_max, как у TreePlacer; set_forest_mask, V02), у опушки
## гуще и шире; у outer_m растворяется по одному.
## Параметры — configs/world.json → trees (impostors, species) + configs/vegetation.json → trees.

const SHADER := preload("res://scripts/terrain/forest_impostors.gdshader")

var camera: Camera3D
var material: ShaderMaterial
## SL-К4 v2: кольцо сетки (inner_m, inner_end_m) — за LOD2-крестами (TreeCrosses.set_cross_ring), пока они
## видны; без крестов — прежнее кольцо за моделями (radius_m · fade_start_k … radius_m).
var _grid_cross := Vector2.ZERO
var _grid_legacy := Vector2.ZERO
var _cross_active := false

var _spacing: float = 10.0
## Маска леса и просек на CPU — для present_positions (тесты); шейдер берёт те же из текстур.
var _mask := TreePlacer.new()
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
	cfg = TreePlacer.with_vegetation(cfg)
	var ic: Dictionary = cfg.get("impostors", {})
	var atlas := TerrainRenderer.load_texture(String(ic.get("atlas", "")))
	if atlas == null or not bool(ic.get("enabled", true)):
		return false
	_layer = layer
	_mask.surface = surface
	_mask.water_max = float(cfg.get("water_max", 0.35))
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
	_mask.setup(layer, surface, cfg)
	_grid_legacy = Vector2(r * float(ic.fade_start_k), r)
	m.set_shader_parameter("inner_m", _grid_legacy.x)
	m.set_shader_parameter("inner_end_m", _grid_legacy.y)
	m.set_shader_parameter("outer_m", outer)
	m.set_shader_parameter("dissolve_m", float(ic.get("dissolve_m", 800.0)))
	m.set_shader_parameter("edge_band_m", float(cfg.get("edge_band_m", 16.0)))
	m.set_shader_parameter("edge_density", float(cfg.get("edge_density", 1.0)))
	m.set_shader_parameter("edge_scale_k", float(cfg.get("edge_scale_k", 0.15)))
	m.set_shader_parameter("density", float(ic.density))
	m.set_shader_parameter("seam_density", float(ic.get("seam_density", ic.density)))
	m.set_shader_parameter("seam_size_k", float(ic.get("seam_size_k", 1.0)))
	m.set_shader_parameter("seam_fade_m", maxf(float(ic.get("seam_fade_m", 1000.0)), 1.0))
	m.set_shader_parameter("brightness", float(ic.brightness))
	m.set_shader_parameter("sink_fraction", float(cfg.sink_fraction))
	m.set_shader_parameter("edge_sink_fraction", float(cfg.get("edge_sink_fraction", 0.05)))
	m.set_shader_parameter("edge_probe_m", float(cfg.get("edge_probe_m", 30.0)))
	m.set_shader_parameter("band_blend_m", float(cfg.get("band_blend_m", 200.0)))
	m.set_shader_parameter("water_max", _mask.water_max)
	var sp: Dictionary = cfg.get("species", {})
	var w := PackedFloat32Array()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	var asp := PackedFloat32Array()
	var hts: Array[Vector2] = []
	var gain := PackedFloat32Array()
	for name in TreePlacer.SPECIES:
		var s: Dictionary = sp.get(name, {})
		w.append(float(s.get("weight", 0.0)))
		lo.append(float(s.get("min_m", -1e4)))
		hi.append(float(s.get("max_m", 1e4)))
		asp.append(float(s.get("aspect", 0.0)))
		gain.append(TerrainTreeModels.albedo_gain_for(cfg, name, 2))
		var hr: Array = s.get("height_m", [15.0, 25.0])
		hts.append(Vector2(float(hr[0]), float(hr[1])))
	m.set_shader_parameter("sp_weight", w)
	m.set_shader_parameter("sp_min", lo)
	m.set_shader_parameter("sp_max", hi)
	m.set_shader_parameter("sp_aspect", asp)
	m.set_shader_parameter("sp_gain", gain)
	m.set_shader_parameter("sp_height", hts)
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 100.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 200.0, layer.size_z())
	)
	return true


## SL-К4 v2: кольцо импостеров за крестами [начало, конец] (м): доля билбордов растёт там, где кресты
## уходят по своим k (TreeCrosses); включается сразу.
func set_cross_ring(ring: Vector2) -> void:
	_grid_cross = ring
	set_cross_active(true)


## Кресты видны (true) — кольцо за ними; скрыты (камера выше cross_max_agl_m) — прежнее кольцо.
func set_cross_active(on: bool) -> void:
	_cross_active = on and _grid_cross != Vector2.ZERO
	if material == null:
		return
	var g := _grid_cross if _cross_active else _grid_legacy
	material.set_shader_parameter("inner_m", g.x)
	material.set_shader_parameter("inner_end_m", g.y)


## Кольцо сетки сейчас (inner_m, inner_end_m), м — для тестов.
func grid_ring() -> Vector2:
	return _grid_cross if _cross_active else _grid_legacy


func _materials() -> Array[ShaderMaterial]:
	return [material]


func _set_all(param: StringName, value: Variant) -> void:
	for m in _materials():
		m.set_shader_parameter(param, value)


## scene-look (SL-К1/К2): параметры scene_look и рантайм (широта, день года, солнце, небо) —
## тем же путём, что у рельефа (TerrainRenderer.apply_scene_look_params).
func apply_scene_look(sl: Dictionary) -> void:
	if material == null:
		return
	for m in _materials():
		TerrainRenderer.apply_scene_look_params(m, sl)


## Просеки (маска WorldClearings, 255 — расчищено).
func set_clearings(mask: Image, origin: Vector2, cell_m: float) -> void:
	if material == null:
		return
	_mask.clear_image = mask
	_mask.clear_origin = origin
	_mask.clear_cell = cell_m
	_set_all("clear_tex", ImageTexture.create_from_image(mask))
	_set_all("has_clearings", true)
	_set_all("clear_origin", origin)
	_set_all("clear_cell_m", cell_m)
	_set_all("clear_size", Vector2(mask.get_width(), mask.get_height()))


## Маска леса 10 м (Terrain.get_forest_mask → [image, origin — угол пикселя (0, 0), cell_m]):
## билборды стоят по кромке маски, а не по классу карты 25 м. Текстура — та же, что у рельефа, если
## Terrain-родитель её уже сделал (не держать вторую копию 4001² в видеопамяти).
func set_forest_mask(mask: Image, origin: Vector2, cell_m: float) -> void:
	if material == null or mask == null or mask.is_empty():
		return
	_mask.set_forest_mask(mask, origin, cell_m)
	var tex := _shared_mask_texture(mask)
	if tex == null:
		tex = ImageTexture.create_from_image(mask)
	_set_all("forest_mask_tex", tex)
	_set_all("use_forest_mask", true)
	_set_all("forest_mask_origin", origin + Vector2(0.5, 0.5) * cell_m)
	_set_all("forest_mask_spacing", cell_m)
	_set_all("forest_mask_texels", Vector2(mask.get_width(), mask.get_height()))


func _shared_mask_texture(mask: Image) -> Texture2D:
	var t := get_parent() as Terrain
	if t == null or t.renderer == null:
		return null
	for m in t.renderer.materials():
		if not bool(m.get_shader_parameter("use_forest_mask")):
			continue
		var tex := m.get_shader_parameter("forest_mask_tex") as Texture2D
		if tex != null and tex.get_size() == Vector2(mask.get_size()):
			return tex
	return null


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	visible = p.y - _layer.sample(p.x, p.z) < _max_agl
	var cell := Vector2(floor(p.x / _spacing), floor(p.z / _spacing))
	if cell != _last_cell:
		_last_cell = cell
		_set_all("grid_center_cell", cell)


## Где стоят билборды (центры X/Z) в кольце [r0, r1] вокруг center — повтор правил шейдера
## без случайного прореживания (density, растворение): сетка spacing_m со сдвигом хешем клетки,
## доля леса по маске 10 м ≥ 0,5, не на воде (G < water_max), не на просеке. Для тестов
## (шейдер считает то же на GPU).
func present_positions(center: Vector2, r0: float, r1: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var c0 := Vector2i(floori((center.x - r1) / _spacing), floori((center.y - r1) / _spacing))
	var c1 := Vector2i(ceili((center.x + r1) / _spacing), ceili((center.y + r1) / _spacing))
	for cj in range(c0.y, c1.y + 1):
		for ci in range(c0.x, c1.x + 1):
			var xz := cell_center(Vector2(ci, cj), _spacing)
			var d := xz.distance_to(center)
			if d < r0 or d > r1:
				continue
			if _mask.is_forest(xz.x, xz.y) and not _mask.is_cleared(xz.x, xz.y):
				out.append(xz)
	return out


## Центр билборда клетки (как в forest_impostors.gdshader: клетка + сдвиг ±0,4 шага).
static func cell_center(cell: Vector2, spacing: float) -> Vector2:
	var jit := Vector2(
		hash12(cell * 1.37 + Vector2(3.1, 3.1)), hash12(cell * 0.71 + Vector2(11.3, 11.3))
	)
	return (cell + Vector2(0.5, 0.5) + (jit - Vector2(0.5, 0.5)) * 0.8) * spacing


## hash12 из terrain_common.gdshaderinc (на CPU в double — совпадает с GPU до округления).
static func hash12(p: Vector2) -> float:
	var q := Vector2(fposmod(p.x, 4096.0), fposmod(p.y, 4096.0))
	var p3 := Vector3(q.x, q.y, q.x) * 0.1031
	p3 = p3 - p3.floor()
	p3 += Vector3.ONE * p3.dot(Vector3(p3.y, p3.z, p3.x) + Vector3.ONE * 33.33)
	var h := (p3.x + p3.y) * p3.z
	return h - floorf(h)


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
