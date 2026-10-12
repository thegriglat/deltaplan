class_name PilotGloveCut
extends RefCounted
## Перчатки без манжеты (краг): в поверхности Glove модели pilot.glb манжета — отдельный остров
## треугольников позади оси запястья. cut() убирает такие острова из копии меша PilotBody и
## возвращает по каждой руке «срез» — открытый край кисти (перчатка полая): куда вплотную ставятся
## ремешок и прибор (WristInstruments). Общий меш модели не трогается.

## Остров целиком позади оси запястья (локальный y кости кисти ниже этого, м) — манжета.
const CUFF_MAX_Y := 0.01
## Сечение запястья для размеров среза: вершины на этом расстоянии от края кисти вдоль оси, м
## (сам край сужен до горловины — по нему размер не снимаем).
const EDGE_FROM := 0.012
const EDGE_TO := 0.032
## Дальше этого от кости кисти (м) вершина к руке не относится.
const HAND_RADIUS := 0.4


## Заменить меш mi на копию без манжет. Возвращает {"L": {...}, "R": {...}}: y — открытый край
## кисти вдоль Y кости (м), center — центр края (Vector3 в осях кости кисти), half — полуоси
## края по X и Z кости (Vector2, м). Рука не найдена — ключа нет; манжет не нашли — меш не меняется.
static func cut(mi: MeshInstance3D, sk: Skeleton3D) -> Dictionary:
	var out := {}
	if mi == null or mi.mesh == null or sk == null:
		return out
	var surf := -1
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		if m != null and m.resource_name.begins_with("Glove"):
			surf = s
	if surf < 0:
		return out
	var frames := {}
	for side: String in ["L", "R"]:
		var i := sk.find_bone("Hand." + side)
		if i < 0:
			i = sk.find_bone("Hand_" + side)
		if i >= 0:
			frames[side] = sk.get_bone_global_rest(i).affine_inverse()
	if frames.is_empty():
		return out
	var arr := mi.mesh.surface_get_arrays(surf)
	var vv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	# острова: вершины с одинаковым положением — одна точка
	var key := {}
	var parent: Array[int] = []
	var vid := PackedInt32Array()
	vid.resize(vv.size())
	for i in vv.size():
		var k := Vector3i((vv[i] * 10000.0).round())
		if not key.has(k):
			key[k] = parent.size()
			parent.append(parent.size())
		vid[i] = key[k]
	for t in idx.size() / 3:
		var a := _root(parent, vid[idx[t * 3]])
		for q in 2:
			var b := _root(parent, vid[idx[t * 3 + 1 + q]])
			if a != b:
				parent[b] = a
	# сторона острова — по ближайшей кости кисти, манжета — остров целиком позади запястья
	var info := {}  # root -> {side, max_y, vertices: PackedInt32Array}
	for i in vv.size():
		var r := _root(parent, vid[i])
		if not info.has(r):
			info[r] = {"side": "", "dist": INF, "max_y": -INF, "min_y": INF, "vs": []}
		var d: Dictionary = info[r]
		for side: String in frames:
			var p: Vector3 = frames[side] * vv[i]
			if p.length() < d.dist:
				d.dist = p.length()
				d.side = side
		d.vs.append(i)
	var drop := {}
	for r in info:
		var d: Dictionary = info[r]
		if d.side == "" or d.dist > HAND_RADIUS:
			continue
		var f: Transform3D = frames[d.side]
		var max_y := -INF
		var min_y := INF
		for i: int in d.vs:
			var y := (f * vv[i]).y
			max_y = maxf(max_y, y)
			min_y = minf(min_y, y)
		if max_y < CUFF_MAX_Y:
			drop[r] = true
		elif not out.has(d.side) or min_y < out[d.side].y:
			out[d.side] = {"y": min_y, "vs": d.vs}
	# срез: вершины острова кисти у её края
	for side: String in out.keys():
		var f: Transform3D = frames[side]
		var y0: float = out[side].y
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for i: int in out[side].vs:
			var p: Vector3 = f * vv[i]
			if p.y > y0 + EDGE_FROM and p.y < y0 + EDGE_TO:
				mn = mn.min(Vector2(p.x, p.z))
				mx = mx.max(Vector2(p.x, p.z))
		var c2 := (mn + mx) * 0.5
		out[side] = {"y": y0, "center": Vector3(c2.x, y0, c2.y), "half": (mx - mn) * 0.5}
	if drop.is_empty():
		return out
	var keep := PackedInt32Array()
	for t in idx.size() / 3:
		if not drop.has(_root(parent, vid[idx[t * 3]])):
			keep.append(idx[t * 3])
			keep.append(idx[t * 3 + 1])
			keep.append(idx[t * 3 + 2])
	print("GLOVECUT drop ", drop.size(), " keep ", keep.size(), " of ", idx.size(), " out ", out)
	arr[Mesh.ARRAY_INDEX] = keep
	var nm := ArrayMesh.new()
	for s in mi.mesh.get_surface_count():
		var a := arr if s == surf else mi.mesh.surface_get_arrays(s)
		var flags := 0
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES]
		if not bones.is_empty() and bones.size() == 8 * (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			flags = Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		nm.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(s), a, [], {}, flags)
		nm.surface_set_name(s, mi.mesh.surface_get_name(s))
		nm.surface_set_material(s, mi.mesh.surface_get_material(s))
	mi.mesh = nm
	return out


static func _root(parent: Array[int], x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x
