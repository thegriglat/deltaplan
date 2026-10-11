extends TestCase
## Контракт К11 (docs/contracts/easter-eggs.md): модель круглого рулона сена
## assets/easter_eggs/hay_bales/hay_bale.glb — первый меш, AABB 1,2 × 1,5 × 1,5 м (ось X), низ в y=0,
## ≤ 200 треугольников, один материал, цвета вершин.

const PATH := "res://assets/easter_eggs/hay_bales/hay_bale.glb"


func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _first_mesh(c)
		if r != null:
			return r
	return null


func test_hay_bale_model() -> void:
	check(ResourceLoader.exists(PATH), "К11: есть " + PATH)
	var ps := load(PATH) as PackedScene
	check(ps != null, "К11: glb грузится")
	if ps == null:
		return
	var inst := ps.instantiate()
	var mi := _first_mesh(inst)
	check(mi != null, "К11: в сцене есть MeshInstance3D")
	if mi == null:
		inst.free()
		return
	var tris := mi.mesh.get_faces().size() / 3
	check(tris <= 200, "К11: треугольников %d > 200" % tris)
	check(mi.mesh.get_surface_count() == 1, "К11: материалов %d, нужен 1" % mi.mesh.get_surface_count())
	var bb: AABB = mi.transform * mi.mesh.get_aabb()
	check(absf(bb.size.x - 1.2) <= 0.06, "К11: ширина по X %.3f" % bb.size.x)
	check(absf(bb.size.y - 1.5) <= 0.075, "К11: высота %.3f" % bb.size.y)
	check(absf(bb.size.z - 1.5) <= 0.075, "К11: глубина по Z %.3f" % bb.size.z)
	check(absf(bb.position.y) <= 0.02, "К11: низ в y=0, min y %.3f" % bb.position.y)
	check(absf(bb.get_center().x) <= 0.02 and absf(bb.get_center().z) <= 0.02, "К11: центр по x и z в 0")
	var arr := mi.mesh.surface_get_arrays(0)
	check(arr[Mesh.ARRAY_COLOR] != null, "К11: есть цвета вершин")
	inst.free()
