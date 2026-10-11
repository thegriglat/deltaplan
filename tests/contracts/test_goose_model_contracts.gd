extends TestCase
## Контракт К13 (docs/contracts/easter-eggs.md): модель гуся assets/easter_eggs/geese/goose.glb.

const GLB := "res://assets/easter_eggs/geese/goose.glb"


func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null


func test_goose_model() -> void:
	var ps := load(GLB) as PackedScene
	check(ps != null, "goose.glb грузится")
	if ps == null:
		return
	var root := ps.instantiate()
	var mi := _first_mesh(root)
	check(mi != null, "в сцене есть MeshInstance3D")
	if mi == null:
		root.free()
		return
	var mesh := mi.mesh
	check(mesh.get_surface_count() == 1, "один материал/поверхность: %d" % mesh.get_surface_count())
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var tris := (idx.size() if idx.size() > 0 else verts.size()) / 3
	check(tris <= 150, "треугольников %d ≤ 150" % tris)
	var aabb := mesh.get_aabb()
	check(absf(aabb.size.x - 1.6) <= 0.08, "размах по x %.3f = 1,6 ± 5 %%" % aabb.size.x)
	check(aabb.size.z >= 0.75 and aabb.size.z <= 1.05, "длина по z %.3f в 0,75–1,05" % aabb.size.z)
	check(absf(aabb.position.x + aabb.size.x * 0.5) < 0.02, "симметрия по x")
	check(aabb.position.z < 0.0 and aabb.end.z > 0.0 and aabb.position.z < -aabb.end.z, "вперёд −Z (клюв длиннее хвоста от начала)")
	check(absf(aabb.position.y + aabb.size.y * 0.5) < 0.1, "плоскость крыльев y ≈ 0")
	var body := 0
	var wing_x := {}
	for p in verts:
		var ax := absf(p.x)
		if ax <= 0.12:
			body += 1
		else:
			wing_x[snappedf(ax, 0.01)] = true
	check(body > 0, "вершины тела |x| ≤ 0,12 есть: %d" % body)
	check(wing_x.size() >= 3, "у крыльев ≥ 3 различных |x| > 0,12: %d" % wing_x.size())
	check(arr[Mesh.ARRAY_COLOR] != null, "цвета вершин есть")
	root.free()
