class_name TerrainTreeModels
extends Node3D
## Деревья-модели вокруг камеры (VR-6, FR-19): 5 пород × 3 LOD из assets/models/trees/*.glb
## (пути — configs/world.json → trees.models). Расстановку считает TreePlacer в рабочем потоке,
## когда камера сдвинулась на rebuild_step_m; здесь — только MultiMesh'и и материалы моделей.
## Деревья стоят там, где доля леса по маске 10 м ≥ 0,5 (set_forest_mask, V02; без маски — на классе
## «лес» карты поверхности 25 м), у опушки гуще и раскидистее. Нет файла модели — setup() вернёт
## false, и Terrain поставит процедурные деревья TerrainTrees (запасной вариант).

const SHADER := preload("res://scripts/terrain/tree_model.gdshader")

var camera: Camera3D
var placer := TreePlacer.new()
## Материалы деревьев (качание от ветра, tree_model.gdshader) — TerrainWind передаёт им ветер.
var materials: Array[ShaderMaterial] = []

## _mmis[вид * 3 + lod]
var _mmis: Array[MultiMeshInstance3D] = []
var _rebuild_step: float = 16.0
var _max_agl: float = 900.0
var _last_center := Vector2(INF, INF)
var _task: int = -1
var _pending_center := Vector2.ZERO


## Загрузить модели и подготовить MultiMesh'и. false — нет моделей (нужен запасной вариант).
func setup(layer: HeightLayer, surface: SurfaceLayer, cfg: Dictionary) -> bool:
	cfg = TreePlacer.with_vegetation(cfg)
	var models: Dictionary = cfg.get("models", {})
	var meshes: Array[Array] = []
	for k in TreePlacer.SPECIES.size():
		var sp := TreePlacer.SPECIES[k]
		var lods := _load_lods(String(models.get(sp, "")))
		if lods.is_empty():
			push_warning("TerrainTreeModels: нет модели %s — процедурные деревья" % sp)
			return false
		meshes.append(lods)
	placer.setup(layer, surface, cfg)
	for k in TreePlacer.SPECIES.size():
		placer.model_height[k] = (meshes[k][0] as Mesh).get_aabb().end.y
		var cache := {}
		for lod in 3:
			meshes[k][lod] = _with_sway(meshes[k][lod], placer.model_height[k], cfg, cache)
	_rebuild_step = float(cfg.get("rebuild_step_m", 16.0))
	_max_agl = float(cfg.get("max_agl_m", 900.0))
	var shadows := bool(cfg.get("cast_shadows", true))
	var aabb := AABB(
		Vector3(layer.origin_x, layer.min_h - 100.0, layer.origin_z),
		Vector3(layer.size_x(), layer.max_h - layer.min_h + 200.0, layer.size_z())
	)
	for k in TreePlacer.SPECIES.size():
		for lod in 3:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = meshes[k][lod]
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_LOD%d" % [TreePlacer.SPECIES[k], lod]
			mmi.multimesh = mm
			mmi.custom_aabb = aabb
			mmi.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if shadows and lod < 2
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(mmi)
			_mmis.append(mmi)
	return true


func _process(_delta: float) -> void:
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply()
		_last_center = _pending_center
	var agl := p.y - placer.layer.sample(p.x, p.z)
	visible = agl < _max_agl
	if not visible:
		return
	var c := Vector2(p.x, p.z)
	if c.distance_to(_last_center) >= _rebuild_step:
		_pending_center = c
		_task = WorkerThreadPool.add_task(placer.build.bind(c))


## Просеки (маска WorldClearings: 255 — расчищено): деревья там не ставятся.
func set_clearings(mask: Image, origin: Vector2, cell_m: float) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	placer.clear_image = mask
	placer.clear_origin = origin
	placer.clear_cell = cell_m
	_last_center = Vector2(INF, INF)


## Маска леса 10 м (Terrain.get_forest_mask → [image, origin, cell_m]; вызывает Terrain после
## создания деревьев): деревья стоят по кромке маски, а не по классу карты 25 м.
func set_forest_mask(mask: Image, origin: Vector2, cell_m: float) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	placer.set_forest_mask(mask, origin, cell_m)
	_last_center = Vector2(INF, INF)


## Расставить сразу (без потока) — для тестов и скриншотов.
func rebuild_now(center: Vector2) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	placer.build(center)
	_apply()
	_last_center = center


## Сколько деревьев сейчас на каждом LOD: [LOD0, LOD1, LOD2].
func lod_counts() -> PackedInt32Array:
	var out := PackedInt32Array([0, 0, 0])
	for b in placer.counts.size():
		out[b % 3] += placer.counts[b]
	return out


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _apply() -> void:
	for b in _mmis.size():
		var mm := _mmis[b].multimesh
		mm.instance_count = placer.counts[b]
		if placer.counts[b] > 0:
			mm.buffer = placer.buffers[b]


## Копия меша, где материалы .glb заменены на tree_model.gdshader (те же текстуры + качание).
## cache — материалы по имени исходного (общие для LOD одной породы).
func _with_sway(src: Mesh, height: float, cfg: Dictionary, cache: Dictionary) -> Mesh:
	var mesh := src.duplicate() as Mesh
	for s in mesh.get_surface_count():
		var std := mesh.surface_get_material(s) as BaseMaterial3D
		if std == null:
			continue
		if not cache.has(std.resource_name):
			var m := ShaderMaterial.new()
			m.shader = SHADER
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
			m.set_shader_parameter("albedo_color", std.albedo_color)
			m.set_shader_parameter(
				"alpha_clip", std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			)
			m.set_shader_parameter("alpha_threshold", std.alpha_scissor_threshold)
			m.set_shader_parameter("roughness_value", std.roughness)
			m.set_shader_parameter("model_height", height)
			m.set_shader_parameter("sway_top_m", float(cfg.get("sway_top_m", 0.6)))
			m.set_shader_parameter("sway_hz", float(cfg.get("sway_hz", 0.25)))
			cache[std.resource_name] = m
			materials.append(m)
		mesh.surface_set_material(s, cache[std.resource_name])
	return mesh


## Меши LOD0, LOD1, LOD2 из .glb (материалы — как в модели).
static func _load_lods(path: String) -> Array[Mesh]:
	var out: Array[Mesh] = []
	if path == "" or not ResourceLoader.exists(path):
		return out
	var ps := load(path) as PackedScene
	if ps == null:
		return out
	var root := ps.instantiate()
	for lod_name in ["LOD0", "LOD1", "LOD2"]:
		var mi := root.find_child(lod_name, true, false) as MeshInstance3D
		if mi == null or mi.mesh == null:
			out.clear()
			break
		out.append(mi.mesh)
	root.free()
	return out
