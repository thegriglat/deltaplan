extends TestCase
## Контракт К15 (docs/contracts/easter-eggs.md): модель брелока-чайки assets/easter_eggs/bar_charm/gull_charm.glb.

const GLB := "res://assets/easter_eggs/bar_charm/gull_charm.glb"


func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null


func test_gull_charm_model() -> void:
	var ps := load(GLB) as PackedScene
	check(ps != null, "gull_charm.glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var mi := _first_mesh(root)
	check(mi != null, "в сцене есть MeshInstance3D")
	if mi == null:
		root.free()
		return
	var mesh := mi.mesh
	check(mesh.get_surface_count() == 1, "одна поверхность: %d" % mesh.get_surface_count())
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var tris := (idx.size() if idx.size() > 0 else verts.size()) / 3
	check(tris <= 300, "треугольников %d ≤ 300" % tris)
	var aabb := mesh.get_aabb()
	check(absf(aabb.size.x - 0.06) <= 0.006, "размах по x %.4f = 0,06 ± 10 %%" % aabb.size.x)
	check(aabb.size.z >= 0.03 and aabb.size.z <= 0.05, "длина по z %.4f в 3–5 см" % aabb.size.z)
	check(absf(aabb.end.y) <= 0.003, "max y %.4f ≈ 0 (± 3 мм)" % aabb.end.y)
	check(aabb.position.y < -0.005, "фигурка ниже точки подвеса: min y %.4f" % aabb.position.y)
	check(absf(aabb.position.x + aabb.size.x * 0.5) <= 0.005, "центр AABB по x у оси подвеса")
	check(absf(aabb.position.z + aabb.size.z * 0.5) <= 0.005, "центр AABB по z у оси подвеса")
	check(aabb.position.z <= -aabb.end.z + 0.001, "клюв вперёд (−Z): хвост %.4f, клюв %.4f" % [aabb.end.z, aabb.position.z])
	check(arr[Mesh.ARRAY_COLOR] != null, "цвета вершин есть")
	root.free()
