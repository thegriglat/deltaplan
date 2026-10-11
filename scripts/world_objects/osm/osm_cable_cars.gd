class_name OsmCableCars
extends Node3D
## Кабинки канатных дорог OSM (L6, osm-look OL-3): для aerialway cable_car / gondola / mixed_lift кабинки
## едут по тросу — тому же, что рисует OsmPilot (те же опоры и провис), и по второму тросу рядом
## (rope_gap_m; у станций тросы сходятся на turn_m). gondola/mixed_lift — замкнутая петля с равным шагом
## spacing_m и скоростью speed_ms; cable_car — две кабины-маятник (на своём тросе навстречу друг другу, с
## плавным разгоном/торможением и стоянкой dwell_s у станций). Движение — по времени слоя (накопленному в
## step), фаза детерминированная от координат. Кабинки — не препятствия; второй трос — препятствие
## (капсулы), основной уже в OsmPilot. Дальность — osm_pilot.aerialways.visibility_m.
## Настройки — world_objects.json → osm_pilot.aerialways.cabins. Модель — assets/models/osm/cable_cabin.glb
## (начало — зацеп на тросе, ось Z — вдоль троса).

const WIRE_SHADER := preload("res://scripts/world_objects/wire.gdshader")
const CABIN_PATH := "res://assets/models/osm/cable_cabin.glb"
const STEP_M := 20.0   # шаг пересэмплирования линии, м

var _cc: Dictionary = {}
var _vis := 4000.0
var _t := 0.0
var _mesh: Mesh
var _lines: Array[Dictionary] = []
var _cam := Vector3.ZERO
var _has_cam := false


class Line:
	extends RefCounted
	var pts: PackedVector3Array = PackedVector3Array()   # основной трос (как у OsmPilot)
	var side: PackedVector3Array = PackedVector3Array()  # смещение второго троса от основного (по точкам)
	var cum: PackedFloat32Array = PackedFloat32Array()   # длина дуги до точки
	var length := 0.0
	var kind := ""
	var speed := 5.0
	var n := 0
	var spacing := 100.0
	var dwell := 30.0
	var phase := 0.0
	var mm: MultiMesh
	var center := Vector3.ZERO
	var radius := 0.0

	func at(s: float) -> int:
		# индекс сегмента, в котором лежит дуга s
		var lo := 0
		var hi := cum.size() - 1
		while hi - lo > 1:
			var mid := (lo + hi) / 2
			if cum[mid] <= s:
				lo = mid
			else:
				hi = mid
		return lo

	## Точка на тросе (side_b — на втором тросе) и единичное направление вдоль линии.
	func sample(s: float, side_b: bool) -> Array:
		s = clampf(s, 0.0, length)
		var i := at(s)
		var seg := maxf(cum[i + 1] - cum[i], 1e-4)
		var f := (s - cum[i]) / seg
		var p := pts[i].lerp(pts[i + 1], f)
		if side_b:
			p += side[i].lerp(side[i + 1], f)
		var d := (pts[i + 1] - pts[i]).normalized()
		return [p, d]


static func build(data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> Node3D:
	var pc: Dictionary = cfg.get("osm_pilot", {})
	if data == null or pc.is_empty() or not pc.has("aerialways") or not pc.aerialways.has("cabins"):
		return null
	var ac: Dictionary = pc.aerialways
	var cc: Dictionary = ac.cabins
	if not bool(cc.get("enabled", true)) or not bool(ac.get("enabled", true)):
		return null
	var node := OsmCableCars.new()
	node._cc = cc
	node._vis = float(ac.visibility_m)
	if not node._load_mesh():
		node.free()
		return null
	for a: Dictionary in data.aerialways:
		var kind := String(a.t)
		if not (cc.classes as Dictionary).has(kind):
			continue
		var line := node._make_line(a, kind, ac, cc, height_fn)
		if line != null:
			node._add_line(line, cc, ac, obstacles)
	if node._lines.is_empty():
		node.free()
		return null
	return node


func _init() -> void:
	name = "CableCars"


func _load_mesh() -> bool:
	if not ResourceLoader.exists(CABIN_PATH):
		push_warning("OsmCableCars: нет модели " + CABIN_PATH)
		return false
	var ps := load(CABIN_PATH) as PackedScene
	if ps == null:
		return false
	var inst := ps.instantiate()
	var mi := inst.find_child("Cabin", true, false) as MeshInstance3D
	if mi != null:
		_mesh = mi.mesh
	inst.free()
	return _mesh != null


## Основной трос так же, как в OsmPilot._aerialways: опоры, вершины + цепная линия, затем пересэмплирование.
func _make_line(a: Dictionary, kind: String, ac: Dictionary, cc: Dictionary, height_fn: Callable) -> Line:
	var sup := PowerLinePlanner.support_points(a.p, float(ac.min_span_m), float(ac.max_span_m))
	if sup.size() < 2:
		return null
	var ph := float(ac.lift_pole_height_m)
	var tops := PackedVector3Array()
	for q in sup:
		tops.append(Vector3(q.x, float(height_fn.call(q.x, q.y)) + ph, q.y))
	var raw := PackedVector3Array()
	for i in tops.size() - 1:
		var seg := PowerLinePlanner.catenary(tops[i], tops[i + 1], float(ac.sag_ratio), int(ac.wire_segments))
		for k in seg.size():
			if i > 0 and k == 0:
				continue
			raw.append(seg[k])
	# пересэмплирование по дуге с шагом ≤ STEP_M, исходные точки сохраняются как вершины
	var l := Line.new()
	var pts := PackedVector3Array()
	for i in raw.size() - 1:
		var d := raw[i].distance_to(raw[i + 1])
		var n := maxi(1, ceili(d / STEP_M))
		for k in n:
			pts.append(raw[i].lerp(raw[i + 1], float(k) / n))
	pts.append(raw[raw.size() - 1])
	l.pts = pts
	l.cum.resize(pts.size())
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i].distance_to(pts[i - 1])
		l.cum[i] = acc
	l.length = acc
	if l.length < float(cc.min_length_m):
		return null
	var gap := float(cc.rope_gap_m)
	var turn := float(cc.turn_m)
	l.side.resize(pts.size())
	for i in pts.size():
		var d := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)])
		d.y = 0.0
		d = d.normalized() if d.length() > 1e-4 else Vector3.RIGHT
		var near_end := minf(l.cum[i], l.length - l.cum[i])
		l.side[i] = Vector3(-d.z, 0.0, d.x) * gap * smoothstep(0.0, turn, near_end)
	l.kind = kind
	var kc: Dictionary = cc.classes[kind]
	l.speed = float(kc.speed_ms)
	l.spacing = float(kc.get("spacing_m", 100.0))
	l.dwell = float(kc.get("dwell_s", 30.0))
	l.phase = WorldTiles.hash01(int(sup[0].x) + int(sup[0].y) * 31)
	var mid := pts[pts.size() / 2]
	l.center = mid
	l.radius = 0.5 * l.length + 20.0
	return l


func _add_line(l: Line, cc: Dictionary, ac: Dictionary, obstacles: ObstacleIndex) -> void:
	var count := 2
	if l.kind != "cable_car":
		count = maxi(2, int(round(2.0 * l.length / l.spacing)))
		l.spacing = 2.0 * l.length / count
	l.n = count
	l.mm = MultiMesh.new()
	l.mm.transform_format = MultiMesh.TRANSFORM_3D
	l.mm.mesh = _mesh
	l.mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = l.mm
	mi.extra_cull_margin = l.radius
	mi.name = "Line%d" % _lines.size()
	add_child(mi)
	_lines.append({"line": l, "node": mi})
	_second_rope(l, ac, cc, obstacles)
	_write(l)


## Второй трос лентой wire.gdshader + капсулы-препятствия.
func _second_rope(l: Line, ac: Dictionary, cc: Dictionary, obstacles: ObstacleIndex) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WIRE_SHADER
	var vis := float(ac.visibility_m) * 0.1
	mat.set_shader_parameter(&"wire_color", Vector3(0.12, 0.12, 0.12))
	mat.set_shader_parameter(&"wire_width_m", float(ac.wire_width_m))
	mat.set_shader_parameter(&"visibility_boost", 1.5)
	mat.set_shader_parameter(&"fade_start_m", vis * 0.6)
	mat.set_shader_parameter(&"fade_end_m", vis)
	var origin := l.center
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	var hit := float(ac.wire_hit_radius_m)
	for i in l.pts.size() - 1:
		var p0 := l.pts[i] + l.side[i]
		var p1 := l.pts[i + 1] + l.side[i + 1]
		obstacles.add_capsule(p0, p1, hit, "wire")
		var t := (p1 - p0).normalized()
		var base := v.size()
		for p: Vector3 in [p0, p1]:
			for s: float in [-1.0, 1.0]:
				v.append(p - origin)
				nrm.append(t)
				uv.append(Vector2(s, 0.0))
		idx.append_array(PackedInt32Array([base, base + 1, base + 2, base + 1, base + 3, base + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = origin
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = l.radius
	mi.visibility_range_end = vis + l.radius
	add_child(mi)


func cabin_count() -> int:
	var n := 0
	for e: Dictionary in _lines:
		n += (e.line as Line).n
	return n


func line_count() -> int:
	return _lines.size()


## Положение и направление i-й кабины линии l в момент t: [точка зацепа, направление хода] (мир).
func cabin_state(l: Line, i: int, t: float) -> Array:
	if l.kind == "cable_car":
		var T := l.length / l.speed
		var cycle := 2.0 * (T + l.dwell)
		var u := fposmod(t + l.phase * cycle, cycle)
		var s: float
		var dir := 1.0
		if u < T:
			s = smoothstep(0.0, 1.0, u / T) * l.length
		elif u < T + l.dwell:
			s = l.length
		elif u < 2.0 * T + l.dwell:
			s = l.length - smoothstep(0.0, 1.0, (u - T - l.dwell) / T) * l.length
			dir = -1.0
		else:
			s = 0.0
		if i == 1:
			s = l.length - s
			dir = -dir
		var r: Array = l.sample(s, i == 1)
		return [r[0], (r[1] as Vector3) * dir]
	var q := fposmod(t * l.speed + float(i) * l.spacing + l.phase * 2.0 * l.length, 2.0 * l.length)
	if q < l.length:
		return l.sample(q, false)
	var r2: Array = l.sample(2.0 * l.length - q, true)
	return [r2[0], -(r2[1] as Vector3)]


func _write(l: Line) -> void:
	var far := _has_cam and Vector2(l.center.x - _cam.x, l.center.z - _cam.z).length() > _vis + l.radius
	if far:
		return
	var vis2 := _vis * _vis
	for i in l.n:
		var st := cabin_state(l, i, _t)
		var p: Vector3 = st[0]
		var d: Vector3 = st[1]
		var yaw := atan2(d.x, d.z)
		var hide := _has_cam and Vector2(p.x - _cam.x, p.z - _cam.z).length_squared() > vis2
		var b := Basis(Vector3.UP, yaw)
		if hide:
			b = Basis.from_scale(Vector3.ZERO)
		l.mm.set_instance_transform(i, Transform3D(b, p))


func step(dt: float) -> void:
	_t += dt
	for e: Dictionary in _lines:
		_write(e.line)


func _process(dt: float) -> void:
	var vp := get_viewport()
	var cam3d := vp.get_camera_3d() if vp != null else null
	if cam3d != null:
		_cam = cam3d.global_position
		_has_cam = true
	step(dt)
