extends TestCase
## Контракт SC-K3 v1 (docs/contracts/start-camp.md), часть SC-7: assets/models/world/glider_kit.glb —
## ноды kit_bundle_LOD0/1 и kit_frame_LOD0/1 на верхнем уровне, оси (вперёд −Z, низ y = 0, центр в 0),
## размеры ±10 % по AABB, бюджеты треугольников, имена материалов, цветов вершин нет, файл ≤ 250 КБ.

const PATH := "res://assets/models/world/glider_kit.glb"
const ALLOWED := ["Fabric", "FabricDark", "Sail", "Webbing", "Tube", "Fitting", "Steel", "Tire"]
# вариант → [длина по Z, ширина по X, макс. высота, бюджет LOD0, бюджет LOD1, обязательные материалы]
const VARIANTS := {
	"kit_bundle": [5.6, 0.9, 0.45, 2500, 150, ["Fabric", "Sail", "Tube"]],
	"kit_frame": [1.75, 1.6, 0.25, 2000, 100, ["Tube", "Tire"]],
}


func _tris(mi: MeshInstance3D) -> int:
	var n := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return n


func test_kit_model() -> void:
	check(ResourceLoader.exists(PATH), "K3: есть " + PATH)
	var ps := load(PATH) as PackedScene
	check(ps != null, "K3: glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f != null:
		check(f.get_length() <= 250 * 1024, "K3: glb %d КБ > 250" % (f.get_length() / 1024))
	for v in VARIANTS:
		var spec: Array = VARIANTS[v]
		for lod in 2:
			var nm := "%s_LOD%d" % [v, lod]
			var mi := root.get_node_or_null(nm) as MeshInstance3D
			check(mi != null, "K3: нода %s на верхнем уровне" % nm)
			if mi == null:
				continue
			var tris := _tris(mi)
			var budget: int = spec[3 + lod]
			check(tris > 0 and tris <= budget, "K3: %s %d треугольников, бюджет %d" % [nm, tris, budget])
			var bb: AABB = mi.transform * mi.mesh.get_aabb()
			check(absf(bb.size.z - spec[0]) <= spec[0] * 0.1, "K3: %s длина по Z %.3f (ждём %.2f)" % [nm, bb.size.z, spec[0]])
			check(absf(bb.size.x - spec[1]) <= spec[1] * 0.1, "K3: %s ширина по X %.3f (ждём %.2f)" % [nm, bb.size.x, spec[1]])
			check(bb.size.y > 0.05 and bb.size.y <= spec[2], "K3: %s высота %.3f" % [nm, bb.size.y])
			check(bb.position.y >= -0.02 and bb.position.y <= 0.02, "K3: %s низ y=%.3f" % [nm, bb.position.y])
			check(absf(bb.get_center().x) <= 0.1 and absf(bb.get_center().z) <= 0.15, "K3: %s центр (%.2f, %.2f)" % [nm, bb.get_center().x, bb.get_center().z])
			var names := []
			for s in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(s)
				var mn := m.resource_name if m != null else ""
				names.append(mn)
				check(mn in ALLOWED, "K3: %s материал «%s» не из контракта" % [nm, mn])
				check(mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR] == null, "K3: %s без цветов вершин" % nm)
			if lod == 0:
				for need in spec[5]:
					check(need in names, "K3: %s материал %s есть (есть %s)" % [nm, need, names])
	# kit_frame: вершина к −Z (центр масс стоек впереди — вершина у AABB-минимума z уже по оси; проверка по трубам)
	var fr := root.get_node_or_null("kit_frame_LOD0") as MeshInstance3D
	if fr != null:
		var bb: AABB = fr.transform * fr.mesh.get_aabb()
		check(bb.get_center().z < 0.1, "K3: kit_frame вершина к −Z")
	root.free()
