class_name FrameMetal
extends RefCounted
## Металл каркаса крыла: при загрузке модели материалы Tube*/Steel/Fitting/Wire из glb заменяются
## процедурными шейдерами (frame_metal.gdshader, frame_wire.gdshader) с теми же цветом, шероховатостью
## и металличностью как базой. Оси труб и тросов в мешах нет (UV не пишутся) — касательная считается
## здесь по мешу (самое длинное ребро каждого треугольника трубы) и кладётся в цвет вершины.
## Параметры — configs/flight.json → visual.metal. Ручка (Grip) и парус не трогаются.

const METAL_SHADER := preload("res://scripts/flight/frame_metal.gdshader")
const WIRE_SHADER := preload("res://scripts/flight/frame_wire.gdshader")


## wing — корень модели; grips — маркеры хвата (BarGripL/R) или null; cfg — visual.metal.
## Возвращает число заменённых поверхностей.
static func apply(wing: Node3D, cfg: Dictionary) -> int:
	if cfg.is_empty() or not bool(cfg.get("enabled", true)):
		return 0
	var done := 0
	var gl := wing.find_child("BarGripL", true, false) as Node3D
	var gr := wing.find_child("BarGripR", true, false) as Node3D
	for mi: MeshInstance3D in wing.find_children("*", "MeshInstance3D", true, false):
		var src := mi.mesh as ArrayMesh
		if src == null:
			continue
		var kinds: Array[String] = []
		var need := false
		for i in src.get_surface_count():
			var k := kind_of(src.surface_get_material(i))
			kinds.append(k)
			need = need or k != ""
		if not need:
			continue
		var inv := _rel(wing, mi).affine_inverse()
		var mesh := ArrayMesh.new()
		for i in src.get_surface_count():
			var arrays := src.surface_get_arrays(i)
			var old := src.surface_get_material(i)
			var k: String = kinds[i]
			var mat: Material = old
			if k != "":
				if k == "tube" or k == "wire":
					_add_tangents(arrays)
				mat = make_material(k, old as BaseMaterial3D, cfg)
				if mat is ShaderMaterial and gl != null and gr != null:
					(mat as ShaderMaterial).set_shader_parameter("grip_l", inv * _rel(wing, gl).origin)
					(mat as ShaderMaterial).set_shader_parameter("grip_r", inv * _rel(wing, gr).origin)
				done += 1
			mesh.add_surface_from_arrays(src.surface_get_primitive_type(i), arrays)
			mesh.surface_set_material(i, mat)
			mesh.surface_set_name(i, src.surface_get_name(i))
		mi.mesh = mesh
	return done


static func kind_of(m: Material) -> String:
	if m == null:
		return ""
	var n := m.resource_name
	if n.begins_with("Tube"):
		return "tube"
	if n.begins_with("Steel"):
		return "steel"
	if n.begins_with("Fitting"):
		return "fitting"
	if n.begins_with("Wire"):
		return "wire"
	return ""


static func make_material(kind: String, old: BaseMaterial3D, cfg: Dictionary) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.resource_name = old.resource_name if old != null else kind
	sm.shader = WIRE_SHADER if kind == "wire" else METAL_SHADER
	if old != null:
		sm.set_shader_parameter("base_color", old.albedo_color)
		sm.set_shader_parameter("base_rough", old.roughness)
		sm.set_shader_parameter("base_metal", old.metallic)
	# fitting в glb — тёмный пластик (metal 0): делаем воронёную сталь
	var common: Dictionary = cfg.get("common", {})
	for key: String in common:
		if not key.ends_with("_doc"):
			sm.set_shader_parameter(key, common[key])
	var sec: Dictionary = cfg.get(kind, {})
	for key: String in sec:
		if key.ends_with("_doc"):
			continue
		var v = sec[key]
		sm.set_shader_parameter(key, v)
	return sm


static func _rel(root: Node, node: Node3D) -> Transform3D:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x


## Касательная вершины = среднее по самым длинным рёбрам прилегающих треугольников (ребро трубы
## идёт вдоль оси), знак — по доминирующей компоненте. Пишется в ARRAY_COLOR как 0.5 + 0.5·t.
static func _add_tangents(arrays: Array) -> void:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx = arrays[Mesh.ARRAY_INDEX]
	var tri: PackedInt32Array
	if idx == null or (idx as PackedInt32Array).is_empty():
		tri = PackedInt32Array()
		tri.resize(verts.size())
		for i in verts.size():
			tri[i] = i
	else:
		tri = idx
	var acc := PackedVector3Array()
	acc.resize(verts.size())
	for k in range(0, tri.size() - 2, 3):
		var a := tri[k]
		var b := tri[k + 1]
		var c := tri[k + 2]
		var e0 := verts[b] - verts[a]
		var e1 := verts[c] - verts[b]
		var e2 := verts[a] - verts[c]
		var e := e0
		if e1.length_squared() > e.length_squared():
			e = e1
		if e2.length_squared() > e.length_squared():
			e = e2
		var l := e.length()
		if l < 1.0e-9:
			continue
		e /= l
		var ax := e.abs()
		var dom := e.x if ax.x >= ax.y and ax.x >= ax.z else (e.y if ax.y >= ax.z else e.z)
		if dom < 0.0:
			e = -e
		acc[a] += e * l
		acc[b] += e * l
		acc[c] += e * l
	var cols := PackedColorArray()
	cols.resize(verts.size())
	for i in verts.size():
		var t := acc[i].normalized() if acc[i].length_squared() > 1.0e-12 else Vector3.RIGHT
		cols[i] = Color(0.5 + 0.5 * t.x, 0.5 + 0.5 * t.y, 0.5 + 0.5 * t.z, 1.0)
	arrays[Mesh.ARRAY_COLOR] = cols
