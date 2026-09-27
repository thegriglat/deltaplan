class_name WorldTiles
extends RefCounted
## Общие помощники объектов мира: ключ тайла, загрузка меша из модели с заглушкой,
## MultiMesh по тайлам с дальностью видимости.


static func key(x: float, z: float, tile_m: float) -> Vector2i:
	return Vector2i(floori(x / tile_m), floori(z / tile_m))


static func center(k: Vector2i, tile_m: float) -> Vector3:
	return Vector3((k.x + 0.5) * tile_m, 0.0, (k.y + 0.5) * tile_m)


## Дальность видимости тайла: visibility_range считается от начала координат ноды (центра тайла),
## поэтому добавляем полудиагональ тайла.
static func tile_range(range_m: float, tile_m: float) -> float:
	return range_m + tile_m * 0.7072


## Меш модели (glb/tscn) вместе с материалами: нода mesh_name (например LOD0) или первый меш.
## Нет файла — fallback и предупреждение.
static func load_mesh(path: String, fallback: Mesh, mesh_name: String = "") -> Mesh:
	if path != "" and ResourceLoader.exists(path):
		var ps := load(path) as PackedScene
		if ps != null:
			var inst := ps.instantiate()
			var mi: MeshInstance3D = null
			if mesh_name != "":
				mi = inst.find_child(mesh_name, true, false) as MeshInstance3D
			if mi == null:
				var all := inst.find_children("*", "MeshInstance3D", true, false)
				mi = inst as MeshInstance3D if inst is MeshInstance3D else null
				if mi == null and not all.is_empty():
					mi = all.front()
			var mesh: Mesh = mi.mesh if mi != null else null
			inst.free()
			if mesh != null:
				return mesh
	push_warning("WorldObjects: нет модели '%s' — заглушка" % path)
	return fallback


## MultiMeshInstance3D в центре тайла; transforms — в мире (сдвигаются к центру тайла).
static func multimesh_node(
	mesh: Mesh,
	transforms: Array[Transform3D],
	colors: PackedColorArray,
	origin: Vector3,
	range_m: float,
	shadows: bool
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		var t := transforms[i]
		t.origin -= origin
		mm.set_instance_transform(i, t)
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.position = origin
	node.visibility_range_end = range_m
	if not shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## Цвет из конфига [r, g, b] (sRGB 0..1) в линейный — для цвета вершин/экземпляров.
static func linear_color(rgb: Array, alpha: float = 1.0) -> Color:
	return Color(float(rgb[0]), float(rgb[1]), float(rgb[2]), alpha).srgb_to_linear()


## Детерминированное «случайное» 0..1 по целому (без глобального RNG).
static func hash01(i: int) -> float:
	var h := (i * 73856093) ^ (i * 19349663 + 83492791)
	return float(absi(h) % 10007) / 10007.0
