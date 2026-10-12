extends TestCase
## Контракт SC-K3 (docs/contracts/start-camp.md): assets/models/world/start_gear.glb — варианты вещей у
## старта, ноды <вариант>_LOD0/_LOD1 на верхнем уровне, оси (длина вдоль Z, низ y=0), размеры ±10 %
## по AABB, бюджеты треугольников, имена материалов, нет цветов вершин, файл ≤ 250 КБ.

const PATH := "res://assets/models/world/start_gear.glb"
const MATS := ["Fabric", "FabricDark", "Webbing", "Shell", "Fitting", "Steel", "Bottle", "Cap"]
# вариант: [размер x, y, z (Godot: ширина, высота, длина), бюджет LOD0, бюджет LOD1]
const VARIANTS := {
	"wing_bag_long": [0.34, 0.28, 5.6, 700, 60],
	"wing_bag_short": [0.34, 0.28, 4.2, 600, 60],
	"harness_pack": [0.45, 0.32, 0.85, 500, 40],
	"harness_open": [0.6, 0.15, 1.9, 700, 40],
	"helmet": [0.23, 0.20, 0.29, 400, 30],
	"bottle": [0.09, 0.09, 0.33, 150, 16],
}


func _mesh(root: Node, nm: String) -> MeshInstance3D:
	var n := root.get_node_or_null(nm)
	return n as MeshInstance3D


func test_start_gear_model() -> void:
	check(ResourceLoader.exists(PATH), "SC-K3: есть " + PATH)
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f != null:
		check(f.get_length() <= 250 * 1024, "SC-K3: glb %d КБ > 250" % (f.get_length() / 1024))
		f.close()
	var ps := load(PATH) as PackedScene
	check(ps != null, "SC-K3: glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var used := {}
	for v in VARIANTS:
		var spec: Array = VARIANTS[v]
		for lod in 2:
			var nm := "%s_LOD%d" % [v, lod]
			var mi := _mesh(root, nm)
			check(mi != null, "SC-K3: нода %s на верхнем уровне" % nm)
			if mi == null:
				continue
			var tris: int = mi.mesh.get_faces().size() / 3
			check(tris <= int(spec[3 + lod]), "SC-K3: %s треугольников %d > %d" % [nm, tris, spec[3 + lod]])
			var bb: AABB = mi.transform * mi.mesh.get_aabb()
			check(absf(bb.position.y) <= 0.02, "SC-K3: %s низ y=0, min y %.3f" % [nm, bb.position.y])
			check(absf(bb.get_center().x) <= 0.03 and absf(bb.get_center().z) <= 0.03,
				"SC-K3: %s центр пятна (%.3f, %.3f)" % [nm, bb.get_center().x, bb.get_center().z])
			if lod == 0:
				for k in 3:
					var want: float = spec[k]
					var got := [bb.size.x, bb.size.y, bb.size.z][k] as float
					check(absf(got - want) <= 0.1 * want, "SC-K3: %s размер[%d] %.3f, нужно %.3f ±10 %%" % [nm, k, got, want])
			for s in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(s)
				var mn := m.resource_name if m != null else ""
				check(mn in MATS, "SC-K3: %s материал «%s» не из контракта" % [nm, mn])
				used[mn] = true
				check(mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR] == null, "SC-K3: %s без цветов вершин" % nm)
	for mn in ["Fabric", "FabricDark", "Webbing", "Shell", "Fitting", "Steel", "Bottle", "Cap"]:
		check(used.has(mn), "SC-K3: материал %s используется" % mn)
	root.free()
