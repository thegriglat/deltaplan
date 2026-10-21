extends TestCase
## Контракт TW-К8 (docs/contracts/tow.md): модели лебёдки и отцепа с уздечкой.
## Узлы по именам, бюджет треугольников, вершинные цвета, ≤ 3 материалов, без текстур.

const WINCH := "res://assets/models/world/tow_winch.glb"
const RELEASE := "res://assets/models/world/tow_release.glb"


func _load(path: String) -> Node:
	check(ResourceLoader.exists(path), "TW-К8: есть " + path)
	var ps := load(path) as PackedScene
	check(ps != null, "TW-К8: грузится " + path)
	return ps.instantiate() if ps != null else null


func _tris(n: Node) -> int:
	return (n as MeshInstance3D).mesh.get_faces().size() / 3


func _check_lods(root: Node, prefix: String, budgets: Array) -> void:
	for i in budgets.size():
		var nm := "%s_LOD%d" % [prefix, i]
		var n := root.find_child(nm, true, false)
		check(n is MeshInstance3D, "TW-К8: узел %s" % nm)
		if not (n is MeshInstance3D):
			continue
		var t := _tris(n)
		check(t > 0 and t <= int(budgets[i]), "TW-К8: %s: %d треугольников, бюджет %d" % [nm, t, budgets[i]])
		var mesh: Mesh = (n as MeshInstance3D).mesh
		var mats := {}
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s)
			check(not (m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null), "TW-К8: %s без текстур" % nm)
			if m != null:
				mats[m.resource_name] = true
			check(mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR] != null, "TW-К8: %s: вершинные цвета" % nm)
		check(mesh.get_surface_count() <= 3, "TW-К8: %s: материалов %d > 3" % [nm, mesh.get_surface_count()])


func test_winch_model() -> void:
	var root := _load(WINCH)
	if root == null:
		return
	_check_lods(root, "tow_winch", [1500, 200, 40])
	var out := root.find_child("tow_winch_rope_out", true, false) as Node3D
	check(out != null, "TW-К8: узел tow_winch_rope_out")
	if out != null:
		var p := out.global_transform.origin if out.is_inside_tree() else out.transform.origin
		check(p.z < 0.0 and p.y > 0.5, "TW-К8: rope_out впереди (−Z) и над землёй: %s" % p)
	var bb: AABB = (root.find_child("tow_winch_LOD0", true, false) as MeshInstance3D).get_aabb()
	check(absf(bb.position.y) < 0.05, "TW-К8: низ рамы на земле, min y %.3f" % bb.position.y)
	root.free()


func test_release_model() -> void:
	var root := _load(RELEASE)
	if root == null:
		return
	_check_lods(root, "tow_release", [300, 40])
	for nm in ["tow_release_attach", "tow_release_rope"]:
		check(root.find_child(nm, true, false) is Node3D, "TW-К8: узел " + nm)
	var a := root.find_child("tow_release_attach", true, false) as Node3D
	var r := root.find_child("tow_release_rope", true, false) as Node3D
	if a != null and r != null:
		var d := r.transform.origin - a.transform.origin
		check(d.z < -0.2 and d.length() < 1.0, "TW-К8: трос впереди (−Z) от точки подвески, масштаб метры: %s" % d)
	root.free()


func test_drogue_model() -> void:
	var root := _load("res://assets/models/world/tow_drogue.glb")
	if root == null:
		return
	_check_lods(root, "tow_drogue", [150, 60, 16])
	var a := root.find_child("tow_drogue_attach", true, false) as Node3D
	check(a != null, "TW-К8: узел tow_drogue_attach")
	if a != null:
		check(a.transform.origin.length() < 0.001, "TW-К8: attach в начале координат: %s" % a.transform.origin)
	var bb: AABB = (root.find_child("tow_drogue_LOD0", true, false) as MeshInstance3D).get_aabb()
	check(bb.end.z > 0.5 and bb.position.z > -0.1, "TW-К8: купол по +Z от attach: %s" % bb)
	root.free()


func test_dolly_model() -> void:
	var root := _load("res://assets/models/world/tow_dolly.glb")
	if root == null:
		return
	_check_lods(root, "tow_dolly", [800, 200, 40])
	var keel := root.find_child("tow_dolly_keel", true, false) as Node3D
	var bar := root.find_child("tow_dolly_bar", true, false) as Node3D
	check(keel != null, "TW-К8: узел tow_dolly_keel")
	check(bar != null, "TW-К8: узел tow_dolly_bar")
	var bb: AABB = (root.find_child("tow_dolly_LOD0", true, false) as MeshInstance3D).get_aabb()
	check(absf(bb.position.y) < 0.02, "TW-К8: колёса на земле, min y %.3f" % bb.position.y)
	if bar != null:
		check(bar.transform.origin.y < 0.45 and bar.transform.origin.y > 0.05, "TW-К8: перекладина ниже 45 см: %s" % bar.transform.origin)
	if keel != null and bar != null:
		check(keel.transform.origin.y > bar.transform.origin.y, "TW-К8: опора киля выше перекладины")
		check(keel.transform.origin.z > bar.transform.origin.z, "TW-К8: киль позади перекладины (+Z), тележка идёт в −Z")
	root.free()
