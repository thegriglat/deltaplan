class_name CollisionCheck
extends RefCounted
## Столкновения крыла за шаг физики (VR-10, VR-12): провода ЛЭП, опоры, здания, заборы, деревья у
## посадок (WorldObjects.obstacle_hit) и кроны леса (Terrain.forest_at).
## Проверяются не только центр, а несколько точек крыла: пилот, трапеция, килевая труба и концы
## консолей — отрезок движения каждой от прошлого шага к текущему.
## Ниже CHECK_BELOW_AGL_M над землёй — провода и препятствия выше не бывают (экономия CPU).
## Индексы препятствий мира (ObstacleIndex, клетка 64 м) в долинах с ЛЭП дают сотни кандидатов
## на клетку (~0,8 мс на запрос) — поэтому здесь свой кэш: у клетки 64 м, куда залетел планер,
## кандидаты раскладываются по клеткам FINE_M с AABB, за шаг — только те, чей AABB задевает
## охват пути крыла; точная проверка — той же геометрией ObstacleIndex.
##   var cc := CollisionCheck.new()
##   cc.setup(world_objects, terrain.forest_at, span_m, hang_height_m)
##   var hit := cc.check(telemetry)  # {} или {kind, reason, point}

## Выше этой высоты над землёй проверки нет, м.
const CHECK_BELOW_AGL_M := 60.0
## Доля леса, с которой в точке стоят деревья (порог кромки, docs/guide/terrain.md → forest_at).
const FOREST_MIN := 0.5
## Кроны, если в world.json нет пород, м над поверхностью рельефа.
const DEFAULT_CROWN_AGL_M := 7.0
## Точки по вертикали крыла над началом координат планера (ступни), м: пилот, середина трапеции.
## Шаг ≤ 0,8 м (два радиуса капсулы провода) — провод между пилотом и килем не проскочит.
const BODY_POINTS_M: Array[float] = [0.5, 1.25]
## Скачок дальше этого за шаг — телепорт (reset_in_air, «Заново»), а не путь, м.
const TELEPORT_M := 20.0
## Мелкая клетка кэша препятствий, м.
const FINE_M := 8.0
## Столько клеток 64 м держать в кэше (дальше — сброс), шт.
const MAX_CACHED_CELLS := 256

## kind препятствия → finish_reason.
const REASONS := {
	"wire": "crash_wire",
	"tower": "crash_obstacle",
	"building": "crash_obstacle",
	"fence": "crash_obstacle",
	"tree": "crash_trees",
}

## Высота крон леса над поверхностью рельефа, м (рельеф — DSM: кроны утоплены на sink_fraction).
var crown_agl_m: float = DEFAULT_CROWN_AGL_M

var _indexes: Array[FineIndex] = []
var _forest_fn: Callable
## Точки крыла в осях планера (X — вправо, Y — вверх).
var _local: PackedVector3Array = []
var _prev: PackedVector3Array = []
var _cur: PackedVector3Array = []


## objects — WorldObjects (или null), forest_fn(x, z) → 0..1 (или пустой Callable),
## span_m — размах крыла, hang_m — высота подвески (килевой трубы) над ступнями.
func setup(objects: Object, forest_fn: Callable, span_m: float, hang_m: float) -> void:
	_indexes.clear()
	if objects != null:
		var idx: Array = [objects.get("obstacles")]
		var osm: Variant = objects.get("osm_layer")
		if osm is Object:
			idx.append((osm as Object).get("building_obstacles"))
		for o: Variant in idx:
			if o is ObstacleIndex:
				_indexes.append(FineIndex.new(o))
	_forest_fn = forest_fn
	var half := 0.5 * span_m
	_local = PackedVector3Array()
	for y in BODY_POINTS_M:
		_local.append(Vector3(0.0, y, 0.0))
	_local.append(Vector3(0.0, hang_m, 0.0))
	_local.append(Vector3(-half, hang_m, 0.0))
	_local.append(Vector3(half, hang_m, 0.0))
	crown_agl_m = crown_height(Config.get_config("world").get("trees", {}))
	reset()


## Новый полёт или телепорт — прошлого положения нет.
func reset() -> void:
	_prev = PackedVector3Array()


## Высота крон над поверхностью: самое низкое дерево пород × (1 − sink_fraction), м.
static func crown_height(trees: Dictionary) -> float:
	var sp: Dictionary = trees.get("species", {})
	var lo := INF
	for k: String in sp:
		var s: Variant = sp[k]
		if s is Dictionary and (s as Dictionary).has("height_m"):
			lo = minf(lo, float((s as Dictionary).height_m[0]))
	if lo == INF:
		return DEFAULT_CROWN_AGL_M
	return lo * (1.0 - float(trees.get("sink_fraction", 0.5)))


## Столкновение за шаг: {kind, reason, point} или {}. kind — как у obstacle_hit
## (wire | tower | building | tree | fence), reason — crash_wire | crash_obstacle | crash_trees.
func check(t: Telemetry) -> Dictionary:
	var had_prev := not _prev.is_empty()
	# Стоит или идёт пешком — не столкновение (дошёл до забора после посадки).
	var idle := t.on_ground and t.phase != "running"
	if t.altitude_agl >= CHECK_BELOW_AGL_M or idle or _local.is_empty():
		_prev = PackedVector3Array()
		return {}
	var n := _local.size()
	_cur.resize(n)
	for i in n:
		_cur[i] = t.position + t.basis * _local[i]
	var best := {}
	if had_prev and _prev[0].distance_squared_to(_cur[0]) > TELEPORT_M * TELEPORT_M:
		had_prev = false
	if had_prev and not _indexes.is_empty():
		var box := AABB(_cur[0], Vector3.ZERO)
		for i in n:
			box = box.expand(_prev[i]).expand(_cur[i])
		var best_t := INF
		for fi in _indexes:
			var h := fi.hit(box, _prev, _cur)
			if not h.is_empty() and float(h.t) < best_t:
				best_t = float(h.t)
				best = h
	_prev = _cur.duplicate()
	if not best.is_empty():
		return {
			"kind": best.kind,
			"reason": String(REASONS.get(best.kind, "crash_obstacle")),
			"point": best.point
		}
	# Кроны леса: пилот ниже крон там, где стоит лес.
	if not t.on_ground and t.altitude_agl < crown_agl_m and _forest_fn.is_valid():
		var p := t.position
		if float(_forest_fn.call(p.x, p.z)) >= FOREST_MIN:
			return {"kind": "tree", "reason": "crash_trees", "point": p}
	return {}


## Кэш одного ObstacleIndex: кандидаты клетки 64 м по мелким клеткам FINE_M с AABB.
class FineIndex:
	extends RefCounted
	var index: ObstacleIndex
	var _built := {}  ## Vector2i клетки индекса → true
	var _fine := {}  ## Vector2i мелкой клетки → PackedInt32Array
	var _boxes := {}  ## номер препятствия → AABB

	func _init(idx: ObstacleIndex) -> void:
		index = idx

	## Первое попадание отрезков prev[i] → cur[i] (box — их охват): {kind, point, t} или {}.
	func hit(box: AABB, prev: PackedVector3Array, cur: PackedVector3Array) -> Dictionary:
		var best := {}
		var best_t := INF
		var seen := {}
		var lo := Vector2i(floori(box.position.x / FINE_M), floori(box.position.z / FINE_M))
		var e := box.end
		var hi := Vector2i(floori(e.x / FINE_M), floori(e.z / FINE_M))
		for cx in range(lo.x, hi.x + 1):
			for cz in range(lo.y, hi.y + 1):
				var key := Vector2i(cx, cz)
				_ensure(key)
				if not _fine.has(key):
					continue
				for j in _fine[key]:
					if seen.has(j) or not (_boxes[j] as AABB).intersects(box):
						continue
					seen[j] = true
					for i in prev.size():
						var t := index._test(j, prev[i], cur[i])
						if t >= 0.0 and t < best_t:
							best_t = t
							best = {
								"kind": index._kinds[j], "point": prev[i].lerp(cur[i], t), "t": t
							}
		return best

	## Разложить клетку индекса, в которой лежит мелкая клетка key.
	func _ensure(key: Vector2i) -> void:
		var c := index.cell_m
		var ck := Vector2i(floori(key.x * FINE_M / c), floori(key.y * FINE_M / c))
		if _built.has(ck):
			return
		if _built.size() >= MAX_CACHED_CELLS:
			_built.clear()
			_fine.clear()
			_boxes.clear()
		_built[ck] = true
		var cell_lo := Vector2(ck.x * c, ck.y * c)
		var cell_hi := cell_lo + Vector2(c, c)
		for j: int in index._grid.get(ck, []):
			var b := _box(j)
			_boxes[j] = b
			var x0 := maxf(b.position.x, cell_lo.x)
			var z0 := maxf(b.position.z, cell_lo.y)
			var x1 := minf(b.end.x, cell_hi.x - 0.001)
			var z1 := minf(b.end.z, cell_hi.y - 0.001)
			for fx in range(floori(x0 / FINE_M), floori(x1 / FINE_M) + 1):
				for fz in range(floori(z0 / FINE_M), floori(z1 / FINE_M) + 1):
					var fk := Vector2i(fx, fz)
					if not _fine.has(fk):
						_fine[fk] = PackedInt32Array()
					var arr: PackedInt32Array = _fine[fk]
					arr.append(j)
					_fine[fk] = arr

	## AABB препятствия по геометрии ObstacleIndex (капсула, цилиндр, коробка).
	func _box(j: int) -> AABB:
		var p0 := index._p0[j]
		var p1 := index._p1[j]
		match index._types[j]:
			0:
				var r := Vector3.ONE * index._p2[j].x
				return AABB(p0.min(p1) - r, (p0 - p1).abs() + 2.0 * r)
			1:
				var r := p1.x
				return AABB(
					Vector3(p0.x - r, p0.y, p0.z - r), Vector3(2.0 * r, p1.y - p0.y, 2.0 * r)
				)
			_:
				var rr := Vector2(p1.x, p1.z).length()
				return AABB(
					Vector3(p0.x - rr, p0.y, p0.z - rr), Vector3(2.0 * rr, p1.y - p0.y, 2.0 * rr)
				)
