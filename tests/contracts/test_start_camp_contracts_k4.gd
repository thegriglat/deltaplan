extends TestCase
## Контракт SC-K4 (docs/contracts/start-camp.md): модель человечка camp_person.glb — пять мешей-частей,
## начала в шарнирах, рост 1,75 м, бюджет треугольников, материалы.

const GLB := "res://assets/models/world/camp_person.glb"
## имя → [шарнир (Godot), макс. треугольников]
const PARTS := {
	"Legs": [Vector3(0, 0, 0), 900],
	"Torso": [Vector3(0, 0.95, 0), 900],
	"Head": [Vector3(0, 1.50, 0), 250],
	"ArmR": [Vector3(0.22, 1.42, 0), 100],
	"ArmL": [Vector3(-0.22, 1.42, 0), 100],
}
const TOL := 0.02


func _tris(mi: MeshInstance3D) -> int:
	var n := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return n


func _mats(mi: MeshInstance3D) -> Array:
	var r := []
	for s in mi.mesh.get_surface_count():
		r.append(mi.mesh.surface_get_material(s).resource_name)
	return r


func test_person() -> void:
	var ps := load(GLB) as PackedScene
	check(ps != null, "camp_person.glb загружается")
	if ps == null:
		return
	var root := ps.instantiate()
	var total := 0
	var top := -INF
	var tint_ok := true
	for nm in PARTS:
		var mi := root.get_node_or_null(nm) as MeshInstance3D
		check(mi != null, "%s: меш на верхнем уровне" % nm)
		if mi == null:
			continue
		var joint: Vector3 = PARTS[nm][0]
		check(mi.position.distance_to(joint) <= TOL, "%s: шарнир %s, есть %s" % [nm, joint, mi.position])
		var t := _tris(mi)
		total += t
		check(t <= PARTS[nm][1], "%s: %d треугольников ≤ %d" % [nm, t, PARTS[nm][1]])
		top = maxf(top, mi.position.y + mi.get_aabb().end.y)
		var mats := _mats(mi)
		var tinted := 0
		for m in mats:
			check(m in ["Cloth", "SkinTint", "Skin", "Hair", "Shoes"], "%s: материал %s из контракта" % [nm, m])
			if m in ["Cloth", "SkinTint"]:
				tinted += 1
		check(tinted <= 1, "%s: не больше одного тонируемого материала (%s)" % [nm, mats])
		match nm:
			"Legs":
				check("Cloth" in mats and "Shoes" in mats, "Legs: Cloth + Shoes")
				check(absf(mi.get_aabb().position.y) <= TOL, "Legs: подошвы на земле")
			"Torso":
				check("Cloth" in mats, "Torso: Cloth")
			"Head":
				check("SkinTint" in mats and "Hair" in mats, "Head: SkinTint + Hair")
			_:
				check("Cloth" in mats and "Skin" in mats, "%s: Cloth + Skin" % nm)
				check(absf(mi.get_aabb().position.y + 0.62) <= TOL, "%s: пальцы на 0,62 м от плеча" % nm)
	check(total <= 900, "всего %d треугольников ≤ 900" % total)
	check(absf(top - 1.75) <= TOL, "рост %.3f м ≈ 1,75" % top)
	root.free()
