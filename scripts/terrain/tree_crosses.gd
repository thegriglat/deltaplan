class_name TreeCrosses
extends MultiMeshInstance3D
## LOD2-кресты деревьев (SL-18, SL-К4 v2, SL-К5): кольцо клеток trees.cell_m вокруг камеры, всё
## остальное (есть ли дерево, где, порода, вариант, высота, поворот, стык форм) — tree_cross.gdshader
## по общему хешу «дерево в клетке» (tree_cell.gdshaderinc ↔ TreeCell). Без CPU-перестройки: скрипт
## двигает только клетку камеры. Ближе r_near·k — модели LOD0/1 (TerrainTreeModels, дополняющая маска в
## tree_model.gdshader), дальше r_far·k — импостеры (ForestImpostors начинают кольцо за крестами).
## Радиус — trees.cross_radius_m (пресеты графики), видны до trees.cross_max_agl_m над землёй.
## Включение — trees.crosses_enabled (пока CPU рисует LOD2 сам — выключено, иначе деревья двоятся).

const SHADER := preload("res://scripts/terrain/tree_cross.gdshader")
## Слоёв массива текстур (порода × вариант) — размер layer_dims в шейдере.
const MAX_LAYERS := 64

var camera: Camera3D
var material: ShaderMaterial
## Модели (ближний стык): их материалам ставится cross_near_m; скрыты — кресты до камеры.
var models: TerrainTreeModels
## Импостеры (дальний стык): кольцо за крестами, пока кресты видны.
var impostors: ForestImpostors

var cell_m: float = 8.0
var r_near: float = 180.0
var r_far: float = 1100.0
var dither: float = 40.0
var k_min: float = 0.75
var k_max: float = 1.2
var instance_total: int = 0
var _max_agl: float = 2000.0
var _layer: HeightLayer
var _last_cell := Vector2i(1 << 30, 1 << 30)
var _near_on := true
var _active := true


## cfg — configs/world.json → trees (с локацией). false — кресты выключены или нет моделей пород.
func setup(
	layer: HeightLayer,
	height_tex: Texture2D,
	surface: SurfaceLayer,
	surface_tex: Texture2D,
	cfg: Dictionary,
	tree_models: TerrainTreeModels = null,
	forest_impostors: ForestImpostors = null
) -> bool:
	cfg = TreePlacer.with_vegetation(cfg)
	if not bool(cfg.get("crosses_enabled", false)):
		return false
	_layer = layer
	models = tree_models
	impostors = forest_impostors
	read_config(cfg)
	_max_agl = float(cfg.get("cross_max_agl_m", 2000.0))
	var nv := maxi(1, int(cfg.get("variants", 8)))
	var tex_dims := _load_layers(cfg.get("models", {}), nv)
	if tex_dims.is_empty():
		return false
	var offs := GrassField.ring_offsets(cell_m, -1.0, outer_m())
	instance_total = offs.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = cross_mesh()
	mm.instance_count = instance_total
	var buf := PackedFloat32Array()
	buf.resize(instance_total * 16)
	for i in instance_total:
		buf[i * 16] = 1.0
		buf[i * 16 + 5] = 1.0
		buf[i * 16 + 10] = 1.0
		buf[i * 16 + 12] = offs[i].x
		buf[i * 16 + 13] = offs[i].y
	mm.buffer = buf
	multimesh = mm
	var m := ShaderMaterial.new()
	m.shader = SHADER
	material = m
	m.set_shader_parameter("cross_tex", tex_dims[0])
	m.set_shader_parameter("layer_dims", tex_dims[1])
	m.set_shader_parameter("variants", nv)
	m.set_shader_parameter("height_tex", height_tex)
	m.set_shader_parameter("layer_origin", Vector2(layer.origin_x, layer.origin_z))
	m.set_shader_parameter("layer_spacing", layer.spacing)
	m.set_shader_parameter("layer_texels", Vector2(layer.width, layer.height))
	TerrainRenderer.set_surface(m, surface, surface_tex)
	m.set_shader_parameter("cell_m", cell_m)
	m.set_shader_parameter("r_near", r_near)
	m.set_shader_parameter("r_far", r_far)
	m.set_shader_parameter("lod_dither_m", dither)
	m.set_shader_parameter("sl_lod_k_range", Vector2(k_min, k_max))
	m.set_shader_parameter("dens8", roundi(clampf(float(cfg.get("density", 0.8)), 0.0, 1.0) * 255.0))
	m.set_shader_parameter("water8", roundi(clampf(float(cfg.get("water_max", 0.35)), 0.0, 1.0) * 255.0))
	m.set_shader_parameter("sink_fraction", float(cfg.get("sink_fraction", 0.4)))
	m.set_shader_parameter("edge_sink_fraction", float(cfg.get("edge_sink_fraction", 0.05)))
	m.set_shader_parameter("edge_probe_m", float(cfg.get("edge_probe_m", 30.0)))
	m.set_shader_parameter("color_variation", float(cfg.get("color_variation", 0.15)))
	m.set_shader_parameter("band_blend_m", maxf(1.0, float(cfg.get("band_blend_m", 200.0))))
	var sp: Dictionary = cfg.get("species", {})
	var w := PackedFloat32Array()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	var asp := PackedFloat32Array()
	var gain := PackedFloat32Array()
	var bl := PackedFloat32Array()
	var hts: Array[Vector2] = []
	for name in TreePlacer.SPECIES:
		var s: Dictionary = sp.get(name, {})
		w.append(float(s.get("weight", 0.0)))
		lo.append(float(s.get("min_m", -1e4)))
		hi.append(float(s.get("max_m", 1e4)))
		asp.append(float(s.get("aspect", 0.0)))
		gain.append(TerrainTreeModels.albedo_gain_for(cfg, name, 1))
		bl.append(TerrainTreeModels.backlight_for(cfg, name))
		var hr: Array = s.get("height_m", [15.0, 25.0])
		hts.append(Vector2(float(hr[0]), float(hr[1])))
	m.set_shader_parameter("sp_weight", w)
	m.set_shader_parameter("sp_min", lo)
	m.set_shader_parameter("sp_max", hi)
	m.set_shader_parameter("sp_aspect", asp)
	m.set_shader_parameter("sp_gain", gain)
	m.set_shader_parameter("sp_backlight", bl)
	m.set_shader_parameter("sp_height", hts)
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(
		Vector3(layer.origin_x, layer.min_h - 100.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 200.0, layer.size_z())
	)
	_set_model_stitch(true)
	if impostors != null:
		impostors.set_cross_ring(Vector2(r_far * k_min - 0.5 * dither, r_far * k_max + 0.5 * dither))
	return true


## Радиусы и стык из конфига (без нод — для тестов).
func read_config(cfg: Dictionary) -> void:
	cell_m = maxf(float(cfg.get("cell_m", 8.0)), 1.0)
	var ld: Array = cfg.get("lod_distances_m", [60.0, 180.0])
	r_near = float(ld[1]) if ld.size() > 1 else 180.0
	r_far = float(cfg.get("cross_radius_m", 1100.0))
	dither = maxf(float(cfg.get("lod_dither_m", 40.0)), 0.01)
	k_max = maxf(float(cfg.get("lod_k_max", 1.2)), 0.1)
	k_min = clampf(float(cfg.get("lod_k_min", 0.75)), 0.1, k_max)


## Дальше этого кресты не рисуются (с запасом на сдвиг дерева в клетке и камеры в своей клетке), м.
func outer_m() -> float:
	return r_far * k_max + 0.5 * dither + 2.0 * cell_m


## Крест единичного размера: две вертикальные карточки x ∈ [−0,5; 0,5] и z ∈ [−0,5; 0,5], y ∈ [0; 1];
## UV и нормали — как у креста LOD2 моделей (build_trees.py: нормали почти вверх, «от центра кроны»).
static func cross_mesh() -> ArrayMesh:
	var v := PackedVector3Array([
		Vector3(-0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(0.5, 0, 0), Vector3(-0.5, 1, 0),
		Vector3(0, 0, -0.5), Vector3(0, 1, 0.5), Vector3(0, 0, 0.5), Vector3(0, 1, -0.5),
	])
	var uv := PackedVector2Array([
		Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0),
		Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0),
	])
	var na := Vector3(0.0, 0.970118, 0.242635)
	var nb := Vector3(-0.242606, 0.970125, 0.0)
	var n := PackedVector3Array([na, na, na, na, nb, nb, nb, nb])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 3, 1, 4, 5, 6, 4, 7, 5])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Текстуры крестов LOD2 всех пород и вариантов → [Texture2DArray, layer_dims (ширина, высота креста,
## высота модели LOD0)]; пусто — нет моделей. Слой — вид * variants + вариант.
func _load_layers(paths: Dictionary, nv: int) -> Array:
	var images: Array[Image] = []
	var dims := PackedVector3Array()
	dims.resize(MAX_LAYERS)
	dims.fill(Vector3(10.0, 20.0, 20.0))
	for k in TreePlacer.SPECIES.size():
		for v in nv:
			var lods := TerrainTreeModels._load_lods(String(paths.get(TreePlacer.SPECIES[k], "")), v)
			if lods.is_empty():
				return []
			var mh := lods[0].get_aabb().end.y
			var cross := lods[2]
			var ab := cross.get_aabb()
			var li := k * nv + v
			if li < MAX_LAYERS:
				dims[li] = Vector3(maxf(ab.size.x, ab.size.z), ab.size.y, mh)
			var std := cross.surface_get_material(0) as BaseMaterial3D
			var img: Image = null
			if std != null and std.albedo_texture != null:
				img = std.albedo_texture.get_image()
			images.append(img)
	return [_texture_array(images), dims]


## Массив текстур из картинок крестов: одинаковые размер и формат — как есть (сжатые, с мипмапами), иначе
## все в RGBA8 по размеру первой; картинок нет (рендер без GPU) — 1×1.
static func _texture_array(images: Array[Image]) -> Texture2DArray:
	var ok := not images.is_empty()
	for im in images:
		ok = ok and im != null and not im.is_empty()
	var arr := Texture2DArray.new()
	if not ok:
		var px := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		px.fill(Color(0.1, 0.2, 0.1, 1.0))
		arr.create_from_images([px])
		return arr
	var first := images[0]
	var same := true
	for im in images:
		same = (
			same
			and im.get_size() == first.get_size()
			and im.get_format() == first.get_format()
			and im.has_mipmaps() == first.has_mipmaps()
		)
	if not same:
		var out: Array[Image] = []
		for im in images:
			var c := im.duplicate() as Image
			if c.is_compressed():
				c.decompress()
			c.convert(Image.FORMAT_RGBA8)
			c.clear_mipmaps()
			if c.get_size() != first.get_size():
				c.resize(first.get_width(), first.get_height(), Image.INTERPOLATE_BILINEAR)
			c.generate_mipmaps()
			out.append(c)
		images = out
	arr.create_from_images(images)
	return arr


## Ближний стык в материалах моделей: on — модель уступает кресту на r_near·k; off — стыка нет.
func _set_model_stitch(on: bool) -> void:
	if models == null:
		return
	for m in models.materials:
		m.set_shader_parameter("cross_near_m", r_near if on else 0.0)
		m.set_shader_parameter("lod_dither_m", dither)
		m.set_shader_parameter("sl_lod_k_range", Vector2(k_min, k_max))


## Просеки (маска WorldClearings, 255 — расчищено).
func set_clearings(mask: Image, origin: Vector2, cell: float) -> void:
	if material == null:
		return
	material.set_shader_parameter("clear_tex", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("has_clearings", true)
	material.set_shader_parameter("clear_origin", origin)
	material.set_shader_parameter("clear_cell_m", cell)
	material.set_shader_parameter("clear_size", Vector2(mask.get_width(), mask.get_height()))


## Маска леса 10 м (Terrain.get_forest_mask → [image, origin — угол пикселя (0, 0), cell_m]); текстура —
## та же, что у рельефа, если есть.
func set_forest_mask(mask: Image, origin: Vector2, cell: float) -> void:
	if material == null or mask == null or mask.is_empty():
		return
	var tex: Texture2D = null
	var t := get_parent() as Terrain
	if t != null and t.renderer != null:
		for m in t.renderer.materials():
			var mt := m.get_shader_parameter("forest_mask_tex") as Texture2D
			if bool(m.get_shader_parameter("use_forest_mask")) and mt != null and mt.get_size() == Vector2(mask.get_size()):
				tex = mt
				break
	if tex == null:
		tex = ImageTexture.create_from_image(mask)
	material.set_shader_parameter("forest_mask_tex", tex)
	material.set_shader_parameter("use_forest_mask", true)
	material.set_shader_parameter("forest_mask_origin", origin + Vector2(0.5, 0.5) * cell)
	material.set_shader_parameter("forest_mask_spacing", cell)
	material.set_shader_parameter("forest_mask_texels", Vector2(mask.get_width(), mask.get_height()))


## scene-look (SL-К1/К2): сезон, альбедо — тем же путём, что у рельефа.
func apply_scene_look(sl: Dictionary) -> void:
	if material != null:
		TerrainRenderer.apply_scene_look_params(material, sl)
		material.set_shader_parameter("sl_lod_k_range", Vector2(k_min, k_max))


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null or material == null:
		return
	var p := cam.global_position
	var on := p.y - _layer.sample(p.x, p.z) < _max_agl
	if on != _active:
		_active = on
		if impostors != null:
			impostors.set_cross_active(on)
	visible = on
	if not on:
		return
	# модели скрыты (выше их max_agl) — кресты до самой камеры
	var near_on := models == null or models.visible
	if near_on != _near_on:
		_near_on = near_on
		material.set_shader_parameter("r_near", r_near if near_on else 0.0)
	var cell := Vector2i(floori(p.x / cell_m), floori(p.z / cell_m))
	if cell != _last_cell:
		_last_cell = cell
		material.set_shader_parameter("grid_center_cell", cell)
