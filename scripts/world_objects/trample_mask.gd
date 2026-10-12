class_name TrampleMask
extends RefCounted
## Маска примятой травы вокруг старта игрока (SC-K6, T-22/T-23): картинка R8 (0 — нетронута, 255 —
## примята до земли), которую GrassField.set_trample_mask кладёт в шейдер травы. Строится на CPU
## раз при place_camp и только по ограничивающим прямоугольникам пятен (палатки с кольцом спада,
## тропинки палатка -> старт, пятна вещей SC-K2, круг разбега у старта, тропа StartTracks);
## значения пятен складываются максимумом. Чистая функция, без нод.
##   var m := TrampleMask.build(start, camp, gear, tracks, tents_cfg, trample_cfg)
##   grass.set_trample_mask(m.image, m.origin, m.cell_m)


## Параметры по умолчанию (configs/world_objects.json → trample).
const DEFAULTS := {
	"size_m": 256.0,
	"cell_m": 0.5,
	"tent_value": 0.9,
	"tent_ring_m": 1.5,
	"path_width_m": 0.8,
	"path_value": 0.6,
	"gear_margin_m": 0.5,
	"gear_value": 0.7,
	"run_radius_m": 6.0,
	"run_value": 0.5,
	"run_fade_m": 1.5,
	"track_value": 0.5,
	"track_width_m": 1.75,
	"track_fade_m": 0.6,
}


## start — старт игрока (Vector3); camp — WorldObjects.camp; gear — пятна вещей одного старта
## (Array[Dictionary] SC-K2, можно пустой); tracks — Array[PackedVector2Array] (StartTracks.plan,
## все старты — берётся тропа этого); tents_cfg — world_objects.json → tents (types); tcfg — trample.
## Возвращает {image: Image (R8), origin: Vector2, cell_m: float}.
static func build(
	start: Vector3,
	camp: Array,
	gear: Array,
	tracks: Array,
	tents_cfg: Dictionary,
	tcfg: Dictionary = {}
) -> Dictionary:
	var c: Dictionary = DEFAULTS.duplicate()
	c.merge(tcfg, true)
	var cell := float(c.cell_m)
	var n := maxi(int(round(float(c.size_m) / cell)), 1)
	var origin := Vector2(start.x, start.z) - Vector2(n, n) * cell * 0.5
	var buf := PackedByteArray()
	buf.resize(n * n)
	var s2 := Vector2(start.x, start.z)
	# трава у старта: круг разбега/ожидания
	_circle(buf, n, origin, cell, s2, float(c.run_radius_m), float(c.run_fade_m), float(c.run_value))
	# тропа к старту (T-23)
	var best := PackedVector2Array()
	var best_d := 25.0
	for t in tracks:
		var pts: PackedVector2Array = t
		if pts.size() >= 2 and pts[0].distance_to(s2) < best_d:
			best_d = pts[0].distance_to(s2)
			best = pts
	for i in best.size() - 1:
		_capsule(
			buf, n, origin, cell, best[i], best[i + 1],
			float(c.track_width_m) * 0.5, float(c.track_fade_m), float(c.track_value)
		)
	# пятна вещей
	for g in gear:
		var p: Vector3 = g.position
		_circle(
			buf, n, origin, cell, Vector2(p.x, p.z), float(g.get("radius_m", 0.5)),
			float(c.gear_margin_m), float(c.gear_value)
		)
	# палатки и тропинки к старту
	var types: Dictionary = tents_cfg.get("types", {})
	for t in camp:
		var p: Vector3 = t.position
		var p2 := Vector2(p.x, p.z)
		_capsule(
			buf, n, origin, cell, p2, s2, float(c.path_width_m) * 0.5,
			float(c.path_width_m) * 0.5, float(c.path_value)
		)
		var half := Vector2(1.0, 1.0)
		var ty: Dictionary = types.get(t.type, {})
		if ty.has("half_size_m"):
			half = Vector2(float(ty.half_size_m[0]), float(ty.half_size_m[1]))
		var basis: Basis = t.get("basis", Basis(Vector3.UP, float(t.get("yaw", 0.0))))
		_box(buf, n, origin, cell, p2, half, basis, float(c.tent_ring_m), float(c.tent_value))
	return {
		"image": Image.create_from_data(n, n, false, Image.FORMAT_R8, buf),
		"origin": origin,
		"cell_m": cell,
	}


static func _put(buf: PackedByteArray, idx: int, v: float) -> void:
	var b := int(round(clampf(v, 0.0, 1.0) * 255.0))
	if b > buf[idx]:
		buf[idx] = b


## Рамка пикселей, покрывающая прямоугольник мира [lo, hi]; (i0, j0, i1, j1) включительно или пусто.
static func _span(n: int, origin: Vector2, cell: float, lo: Vector2, hi: Vector2) -> Array:
	var i0 := maxi(int(floor((lo.x - origin.x) / cell)), 0)
	var j0 := maxi(int(floor((lo.y - origin.y) / cell)), 0)
	var i1 := mini(int(floor((hi.x - origin.x) / cell)), n - 1)
	var j1 := mini(int(floor((hi.y - origin.y) / cell)), n - 1)
	if i1 < i0 or j1 < j0:
		return []
	return [i0, j0, i1, j1]


## Спад от краю: 1 внутри (d <= 0), к 0 за fade метров (гладко).
static func _falloff(d: float, fade: float) -> float:
	if d <= 0.0:
		return 1.0
	if d >= fade:
		return 0.0
	return 1.0 - smoothstep(0.0, fade, d)


static func _circle(
	buf: PackedByteArray, n: int, origin: Vector2, cell: float, c: Vector2, r: float, fade: float,
	value: float
) -> void:
	var rr := Vector2(r + fade, r + fade)
	var sp := _span(n, origin, cell, c - rr, c + rr)
	if sp.is_empty():
		return
	for j in range(sp[1], sp[3] + 1):
		var z := origin.y + (j + 0.5) * cell
		for i in range(sp[0], sp[2] + 1):
			var x := origin.x + (i + 0.5) * cell
			var d := Vector2(x, z).distance_to(c) - r
			var f := _falloff(d, fade)
			if f > 0.0:
				_put(buf, j * n + i, value * f)


static func _capsule(
	buf: PackedByteArray, n: int, origin: Vector2, cell: float, a: Vector2, b: Vector2,
	half_w: float, fade: float, value: float
) -> void:
	var m := half_w + fade
	var sp := _span(
		n, origin, cell, Vector2(minf(a.x, b.x) - m, minf(a.y, b.y) - m),
		Vector2(maxf(a.x, b.x) + m, maxf(a.y, b.y) + m)
	)
	if sp.is_empty():
		return
	var ab := b - a
	var len2 := maxf(ab.length_squared(), 1e-6)
	for j in range(sp[1], sp[3] + 1):
		var z := origin.y + (j + 0.5) * cell
		for i in range(sp[0], sp[2] + 1):
			var p := Vector2(origin.x + (i + 0.5) * cell, z)
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t) - half_w
			var f := _falloff(d, fade)
			if f > 0.0:
				_put(buf, j * n + i, value * f)


## Повёрнутая коробка палатки: half = (поперёк x, вдоль z) в осях basis, кольцо спада ring м.
static func _box(
	buf: PackedByteArray, n: int, origin: Vector2, cell: float, c: Vector2, half: Vector2,
	basis: Basis, ring: float, value: float
) -> void:
	var m := half.length() + ring
	var sp := _span(n, origin, cell, c - Vector2(m, m), c + Vector2(m, m))
	if sp.is_empty():
		return
	var inv := basis.inverse()
	for j in range(sp[1], sp[3] + 1):
		var z := origin.y + (j + 0.5) * cell
		for i in range(sp[0], sp[2] + 1):
			var dv := Vector2(origin.x + (i + 0.5) * cell, z) - c
			var l := inv * Vector3(dv.x, 0.0, dv.y)
			var q := Vector2(absf(l.x), absf(l.z)) - half
			var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)
			var f := _falloff(d, ring)
			if f > 0.0:
				_put(buf, j * n + i, value * f)
