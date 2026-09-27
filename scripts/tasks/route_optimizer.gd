class_name RouteOptimizer
extends RefCounted
## Кратчайший маршрут через цилиндры (оптимизированная дистанция, CIVL S7F):
## ломаная из фиксированной точки, касающаяся по очереди каждого круга (или отрезка линии гоула).
## Покоординатный спуск: каждая точка по очереди ставится в лучшее место своей области при
## фиксированных соседях; проходы повторяются, пока длина не перестанет уменьшаться.
## Лучшее место в круге: если отрезок между соседями проходит через круг — точка на отрезке
## (без удлинения), иначе минимум суммы расстояний на дуге окружности (золотое сечение).
## Плоская геометрия в метрах мира (для 40–160 км локации достаточно).

## Золотое сечение (математическая константа).
const GOLDEN := 0.6180339887498949

var max_passes: int = 30
var golden_iterations: int = 24
var epsilon_m: float = 0.05


static func from_settings(settings: Dictionary = {}) -> RouteOptimizer:
	if settings.is_empty():
		settings = Config.get_config("tasks/settings")
	var o := RouteOptimizer.new()
	var c: Dictionary = settings.get("optimizer", {})
	o.max_passes = int(c.get("max_passes", o.max_passes))
	o.golden_iterations = int(c.get("golden_iterations", o.golden_iterations))
	o.epsilon_m = float(c.get("epsilon_m", o.epsilon_m))
	return o


## Цель-круг (центр в XZ, радиус, м).
static func circle(center: Vector2, radius_m: float) -> Dictionary:
	return {"center": center, "radius": maxf(radius_m, 0.0)}


## Цель-отрезок (линия гоула).
static func line(a: Vector2, b: Vector2) -> Dictionary:
	return {"a": a, "b": b}


## Маршрут из origin через цели по порядку. warm — точки прошлого решения (ускоряет).
## Возвращает {distance_m, points: PackedVector2Array (по точке на цель)}.
func solve(
	origin: Vector2, targets: Array[Dictionary], warm: PackedVector2Array = []
) -> Dictionary:
	var n := targets.size()
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		pts[i] = warm[i] if warm.size() == n else _anchor(targets[i])
	var length := _length(origin, pts)
	for _pass in max_passes:
		for i in n:
			var prev := origin if i == 0 else pts[i - 1]
			if i == n - 1:
				pts[i] = _closest(targets[i], prev)
			else:
				pts[i] = _best_between(targets[i], prev, pts[i + 1])
		var new_length := _length(origin, pts)
		var done := absf(length - new_length) < epsilon_m
		length = new_length
		if done:
			break
	return {"distance_m": length, "points": pts}


static func _anchor(t: Dictionary) -> Vector2:
	if t.has("center"):
		return t.center
	return (Vector2(t.a) + Vector2(t.b)) * 0.5


static func _length(origin: Vector2, pts: PackedVector2Array) -> float:
	var s := 0.0
	var prev := origin
	for p in pts:
		s += prev.distance_to(p)
		prev = p
	return s


## Ближайшая к p точка цели.
static func _closest(t: Dictionary, p: Vector2) -> Vector2:
	if t.has("center"):
		var c: Vector2 = t.center
		var r := float(t.radius)
		var d := p - c
		return p if d.length() <= r else c + d.normalized() * r
	return Geometry2D.get_closest_point_to_segment(p, t.a, t.b)


## Точка цели, минимизирующая |a − x| + |x − b|.
func _best_between(t: Dictionary, a: Vector2, b: Vector2) -> Vector2:
	if t.has("center"):
		return _best_on_circle(t.center, float(t.radius), a, b)
	return _best_on_segment(t.a, t.b, a, b)


func _best_on_circle(c: Vector2, r: float, a: Vector2, b: Vector2) -> Vector2:
	var on_ab := Geometry2D.get_closest_point_to_segment(c, a, b)
	if on_ab.distance_to(c) <= r:
		return on_ab  # прямая a→b и так проходит через цилиндр
	# минимум на дуге между направлениями на a и на b (меньшая дуга)
	var ta := (a - c).angle()
	var tb := (b - c).angle()
	var span := wrapf(tb - ta, -PI, PI)
	var f := func(k: float) -> float:
		var x := c + Vector2.from_angle(ta + span * k) * r
		return a.distance_to(x) + x.distance_to(b)
	var k := _golden_min(f)
	return c + Vector2.from_angle(ta + span * k) * r


func _best_on_segment(p: Vector2, q: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var hit: Variant = Geometry2D.segment_intersects_segment(a, b, p, q)
	if hit != null:
		return hit
	var f := func(k: float) -> float:
		var x := p.lerp(q, k)
		return a.distance_to(x) + x.distance_to(b)
	return p.lerp(q, _golden_min(f))


## Минимум унимодальной f на [0, 1].
func _golden_min(f: Callable) -> float:
	var lo := 0.0
	var hi := 1.0
	var x1 := hi - GOLDEN * (hi - lo)
	var x2 := lo + GOLDEN * (hi - lo)
	var f1: float = f.call(x1)
	var f2: float = f.call(x2)
	for _i in golden_iterations:
		if f1 < f2:
			hi = x2
			x2 = x1
			f2 = f1
			x1 = hi - GOLDEN * (hi - lo)
			f1 = f.call(x1)
		else:
			lo = x1
			x1 = x2
			f1 = f2
			x2 = lo + GOLDEN * (hi - lo)
			f2 = f.call(x2)
	return (lo + hi) * 0.5
