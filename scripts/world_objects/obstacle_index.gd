class_name ObstacleIndex
extends RefCounted
## Препятствия мира для столкновений (VR-10, VR-12): провода (капсулы вдоль отрезков цепной линии),
## деревья и опоры (вертикальные цилиндры), здания и заборы (повёрнутые коробки).
## Сетка по XZ; запрос — отрезок пути за шаг физики: hit(a, b) → {kind, point} или {}.
## Без нод, тестируется headless.

var cell_m: float = 64.0

var _grid: Dictionary = {}
var _kinds: PackedStringArray = []
## Тип фигуры: 0 — капсула, 1 — цилиндр, 2 — коробка.
var _types: PackedByteArray = []
## Капсула: a, b, (r, 0, 0); цилиндр: (x, y0, z), (r, y1, 0), —; коробка: центр (x, y0, z),
## (hx, y1, hz), (угол, 0, 0).
var _p0: PackedVector3Array = []
var _p1: PackedVector3Array = []
var _p2: PackedVector3Array = []


func _init(cell: float = 64.0) -> void:
	cell_m = cell


func size() -> int:
	return _types.size()


func add_capsule(a: Vector3, b: Vector3, radius: float, kind: String) -> void:
	var lo := Vector2(minf(a.x, b.x), minf(a.z, b.z)) - Vector2.ONE * radius
	var hi := Vector2(maxf(a.x, b.x), maxf(a.z, b.z)) + Vector2.ONE * radius
	_add(0, kind, a, b, Vector3(radius, 0.0, 0.0), lo, hi)


func add_cylinder(x: float, z: float, radius: float, y0: float, y1: float, kind: String) -> void:
	var c := Vector2(x, z)
	_add(
		1,
		kind,
		Vector3(x, y0, z),
		Vector3(radius, y1, 0.0),
		Vector3.ZERO,
		c - Vector2.ONE * radius,
		c + Vector2.ONE * radius
	)


## Коробка: центр основания (x, z), полуразмеры по своим осям,
## угол поворота (рад, ось X к оси Z мира
## — как atan2(dz, dx)), низ и верх.
func add_box(
	x: float, z: float, hx: float, hz: float, angle: float, y0: float, y1: float, kind: String
) -> void:
	var r := Vector2(hx, hz).length()
	var c := Vector2(x, z)
	_add(
		2,
		kind,
		Vector3(x, y0, z),
		Vector3(hx, y1, hz),
		Vector3(angle, 0.0, 0.0),
		c - Vector2.ONE * r,
		c + Vector2.ONE * r
	)


## Убрать все препятствия вида kind (лагерь палаток на новом старте той же локации).
func remove_kind(kind: String) -> void:
	if not kind in _kinds:
		return
	var old := [_types, _kinds, _p0, _p1, _p2]
	_grid.clear()
	_types = PackedByteArray()
	_kinds = PackedStringArray()
	_p0 = PackedVector3Array()
	_p1 = PackedVector3Array()
	_p2 = PackedVector3Array()
	var types: PackedByteArray = old[0]
	var kinds: PackedStringArray = old[1]
	var p0: PackedVector3Array = old[2]
	var p1: PackedVector3Array = old[3]
	var p2: PackedVector3Array = old[4]
	for i in types.size():
		if kinds[i] == kind:
			continue
		var lo: Vector2
		var hi: Vector2
		match types[i]:
			0:
				var r := p2[i].x
				lo = Vector2(minf(p0[i].x, p1[i].x), minf(p0[i].z, p1[i].z)) - Vector2.ONE * r
				hi = Vector2(maxf(p0[i].x, p1[i].x), maxf(p0[i].z, p1[i].z)) + Vector2.ONE * r
			1:
				lo = Vector2(p0[i].x, p0[i].z) - Vector2.ONE * p1[i].x
				hi = Vector2(p0[i].x, p0[i].z) + Vector2.ONE * p1[i].x
			_:
				var r := Vector2(p1[i].x, p1[i].z).length()
				lo = Vector2(p0[i].x, p0[i].z) - Vector2.ONE * r
				hi = Vector2(p0[i].x, p0[i].z) + Vector2.ONE * r
		_add(types[i], kinds[i], p0[i], p1[i], p2[i], lo, hi)


## Первое препятствие на отрезке a→b: {kind, point} или {}
## (point — ближайшая к препятствию точка пути).
func hit(a: Vector3, b: Vector3, kind_filter: String = "") -> Dictionary:
	var best := {}
	var best_t := INF
	for i in _candidates(a, b):
		if kind_filter != "" and _kinds[i] != kind_filter:
			continue
		var t := _test(i, a, b)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = {"kind": _kinds[i], "point": a.lerp(b, t)}
	return best


func _add(
	type: int, kind: String, p0: Vector3, p1: Vector3, p2: Vector3, lo: Vector2, hi: Vector2
) -> void:
	var idx := _types.size()
	_types.append(type)
	_kinds.append(kind)
	_p0.append(p0)
	_p1.append(p1)
	_p2.append(p2)
	for cx in range(floori(lo.x / cell_m), floori(hi.x / cell_m) + 1):
		for cz in range(floori(lo.y / cell_m), floori(hi.y / cell_m) + 1):
			var key := Vector2i(cx, cz)
			var arr: Array = _grid.get(key, [])
			if arr.is_empty():
				_grid[key] = arr
			arr.append(idx)


func _candidates(a: Vector3, b: Vector3) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	for cx in range(floori(minf(a.x, b.x) / cell_m), floori(maxf(a.x, b.x) / cell_m) + 1):
		for cz in range(floori(minf(a.z, b.z) / cell_m), floori(maxf(a.z, b.z) / cell_m) + 1):
			var key := Vector2i(cx, cz)
			if not _grid.has(key):
				continue
			for i in _grid[key]:
				if not seen.has(i):
					seen[i] = true
					out.append(i)
	return out


## Параметр t ∈ [0, 1] точки попадания на отрезке или −1.
func _test(i: int, a: Vector3, b: Vector3) -> float:
	match _types[i]:
		0:
			return ObstacleIndex.segment_capsule(a, b, _p0[i], _p1[i], _p2[i].x)
		1:
			return _test_cylinder(i, a, b)
		_:
			return _test_box(i, a, b)


func _test_cylinder(i: int, a: Vector3, b: Vector3) -> float:
	var c := Vector2(_p0[i].x, _p0[i].z)
	var a2 := Vector2(a.x, a.z)
	var d2 := Vector2(b.x, b.z) - a2
	var t := 0.0
	if d2.length_squared() > 1.0e-9:
		t = clampf((c - a2).dot(d2) / d2.length_squared(), 0.0, 1.0)
	var p := a.lerp(b, t)
	if Vector2(p.x, p.z).distance_to(c) > _p1[i].x:
		return -1.0
	return t if p.y >= _p0[i].y and p.y <= _p1[i].y else -1.0


func _test_box(i: int, a: Vector3, b: Vector3) -> float:
	var ang := _p2[i].x
	var c := _p0[i]
	var la := _to_box(a - c, ang)
	var lb := _to_box(b - c, ang)
	var lo := Vector3(-_p1[i].x, 0.0, -_p1[i].z)
	var hi := Vector3(_p1[i].x, _p1[i].y - c.y, _p1[i].z)
	var t0 := 0.0
	var t1 := 1.0
	var d := lb - la
	for k in 3:
		if absf(d[k]) < 1.0e-9:
			if la[k] < lo[k] or la[k] > hi[k]:
				return -1.0
			continue
		var ta := (lo[k] - la[k]) / d[k]
		var tb := (hi[k] - la[k]) / d[k]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return -1.0
	return t0


static func _to_box(v: Vector3, ang: float) -> Vector3:
	var c := cos(ang)
	var s := sin(ang)
	return Vector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)


## Отрезок пути a→b против капсулы p→q радиуса r: параметр t на a→b или −1.
static func segment_capsule(a: Vector3, b: Vector3, p: Vector3, q: Vector3, r: float) -> float:
	var st := closest_params(a, b, p, q)
	var pa := a.lerp(b, st.x)
	var pb := p.lerp(q, st.y)
	return st.x if pa.distance_to(pb) <= r else -1.0


## Параметры (s на a→b, t на p→q) ближайших точек двух отрезков (Ericson, RTCD 5.1.9).
static func closest_params(a: Vector3, b: Vector3, p: Vector3, q: Vector3) -> Vector2:
	var d1 := b - a
	var d2 := q - p
	var r := a - p
	var aa := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if aa <= 1.0e-12 and e <= 1.0e-12:
		return Vector2.ZERO
	if aa <= 1.0e-12:
		return Vector2(0.0, clampf(f / e, 0.0, 1.0))
	var c := d1.dot(r)
	if e <= 1.0e-12:
		return Vector2(clampf(-c / aa, 0.0, 1.0), 0.0)
	var bb := d1.dot(d2)
	var denom := aa * e - bb * bb
	if denom > 1.0e-12:
		s = clampf((bb * f - c * e) / denom, 0.0, 1.0)
	t = (bb * s + f) / e
	if t < 0.0:
		t = 0.0
		s = clampf(-c / aa, 0.0, 1.0)
	elif t > 1.0:
		t = 1.0
		s = clampf((bb - c) / aa, 0.0, 1.0)
	return Vector2(s, t)
