class_name ShipLayer
extends Node3D
## Слой судов (SEA-4): записи ShipPlacer (S3) → на судно по MeshInstance3D на LOD модели S4 с
## visibility_range_begin/end (движок сам выбирает LOD и отсекает по дальности и пирамиде видимости; судов
## ≤ ~100 на квадрат far — узлов ≤ 300, MultiMesh не нужен: его рамка — весь квадрат, отсечения по судну нет).
## Ватерлиния — y записи (S3 v2: уровень воды L), нос модели к −Z, курс по часовой от севера → rotation.y = −heading.
## Тени — только LOD0 (render.cast_shadow_lod0; дальше их всё равно режет sun.shadow_max_distance_m).
## Без _process: после build() слой ничего не считает. Вид без .glb пропускается.
## Параметры — configs/sea_ships.json → render.

const MODEL_PATH := "res://assets/models/ships/ship_%s.glb"
const LODS := 3

## Сколько судов на сцене (видов с моделью).
var ship_count: int = 0
## Сколько записей пропущено — нет модели вида.
var skipped: int = 0


## Параметры render с запасными значениями; lod_end_m — конец видимости каждого LOD, м
## (последний — дальняя плоскость камеры world.json → rendering.camera_far_m, если в render не задан).
static func render_params() -> Dictionary:
	var r: Dictionary = {"lod_m": [6000.0, 25000.0], "cast_shadow_lod0": true, "roughness": 0.6}
	var c: Variant = Config.get_config("sea_ships").get("render", {})
	if c is Dictionary:
		r.merge(c, true)
	return r


## Конец видимости LOD k, м: lod_m[k], последний LOD — до camera_far.
static func lod_end(rp: Dictionary, k: int) -> float:
	var lm: Array = rp.get("lod_m", [])
	if k < lm.size():
		return float(lm[k])
	return float(Config.value("world", "rendering.camera_far_m", 110000.0))


## Материал судна: вершинные цвета как альбедо (импортёр glTF сам этого не включает), без текстур.
static func make_material(roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color.WHITE
	m.roughness = roughness
	m.metallic = 0.0
	return m


## Сетки LOD вида из ship_<вид>.glb: [Mesh LOD0, LOD1, LOD2] или [] — нет модели/узла.
static func load_meshes(kind: String) -> Array:
	var path := MODEL_PATH % kind
	if not ResourceLoader.exists(path):
		return []
	var ps := load(path) as PackedScene
	if ps == null:
		return []
	var root := ps.instantiate()
	var out: Array = []
	for k in LODS:
		var mi := root.find_child("%s_LOD%d" % [kind, k], true, false) as MeshInstance3D
		if mi == null or mi.mesh == null:
			out = []
			break
		out.append(mi.mesh)
	root.free()
	return out


## Построить узлы по записям ShipPlacer.ships_for. Пусто — ни одного узла.
func build(ships: Array, rp: Dictionary = {}) -> void:
	for c in get_children():
		c.queue_free()
	ship_count = 0
	skipped = 0
	set_process(false)
	set_physics_process(false)
	if ships.is_empty():
		return
	if rp.is_empty():
		rp = render_params()
	var mat := make_material(float(rp.get("roughness", 0.6)))
	var shadow0 := bool(rp.get("cast_shadow_lod0", true))
	var ends := PackedFloat32Array()
	for k in LODS:
		ends.append(lod_end(rp, k))
	var meshes := {}
	for s: Dictionary in ships:
		var kind := String(s.type)
		if not meshes.has(kind):
			meshes[kind] = load_meshes(kind)
		var ms: Array = meshes[kind]
		if ms.is_empty():
			skipped += 1
			continue
		var xf := Transform3D(Basis(Vector3.UP, -float(s.heading_rad)), Vector3(float(s.x), float(s.get("y", 0.0)), float(s.z)))
		var begin := 0.0
		for k in LODS:
			var mi := MeshInstance3D.new()
			mi.name = "Ship%d_LOD%d" % [ship_count, k]
			mi.mesh = ms[k]
			mi.material_override = mat
			mi.transform = xf
			mi.visibility_range_begin = begin
			mi.visibility_range_end = ends[k]
			mi.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if k == 0 and shadow0
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(mi)
			begin = ends[k]
		ship_count += 1
