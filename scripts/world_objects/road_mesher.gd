class_name RoadMesher
extends RefCounted
## Дороги из OSM → ленты по рельефу (VR-9). Ломаная пересэмплируется с шагом step_m, каждая
## вершина кромки кладётся на height_at + lift_m. Меши группируются по тайлам и по «главная /
## второстепенная» (разная дальность видимости).
## Цвет — цвет вершин (линейный). UV.x — поперёк (0 левый край … 1 правый), UV.y — вдоль, в метрах от начала
## полилинии (L7: шум и пунктир разметки; в шейдере — fract/mod). UV2: x — код вида (cfg.look.styles: 0 асфальт,
## 1 пунктир+края, 2 сплошная+края, 3 пунктир, 4 грунтовка), y — ширина ленты, м.
## Без нод и ресурсов — build безопасен в рабочих потоках: результат {"<major>:<tx>:<tz>": {arrays: Array,
## origin: Vector3, major: bool}}; ArrayMesh из него делает meshes() на главном потоке.


## counts (необязательно) — сколько лент построено по классам: {класс: число}.
static func build(roads: Array, cfg: Dictionary, height_fn: Callable, counts: Dictionary = {}) -> Dictionary:
	var classes: Dictionary = cfg.classes
	var step_major := float(cfg.step_m)
	var step_minor := float(cfg.minor_step_m)
	var lift := float(cfg.lift_m)
	var tile := float(cfg.tile_m)
	var styles: Dictionary = (cfg.get("look", {}) as Dictionary).get("styles", {})
	var acc := {}
	for r in roads:
		var t := String(r.t)
		if not classes.has(t):
			continue
		var cls: Array = classes[t]
		var major := int(cls[1]) == 1
		var pts := _resample(r.p as PackedVector2Array, step_major if major else step_minor)
		if pts.size() < 2:
			continue
		counts[t] = int(counts.get(t, 0)) + 1
		var col := WorldTiles.linear_color([cls[2], cls[3], cls[4]])
		var width := float(cls[0])
		var rw := float(r.get("w", 0.0))
		if rw > 0.0:  # ширина из тега width, с ограничением сверху
			width = clampf(rw, 1.0, minf(width * 2.5, 40.0))
		_add_strip(acc, pts, width, major, col, lift, tile, height_fn, float(styles.get(t, 0)))
	var out := {}
	for k in acc:
		var a: Dictionary = acc[k]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = a.v
		arrays[Mesh.ARRAY_NORMAL] = a.n
		arrays[Mesh.ARRAY_COLOR] = a.c
		arrays[Mesh.ARRAY_TEX_UV] = a.uv
		arrays[Mesh.ARRAY_TEX_UV2] = a.uv2
		arrays[Mesh.ARRAY_INDEX] = a.i
		out[k] = {"arrays": arrays, "origin": a.origin, "major": a.major}
	return out


## Массивы → ArrayMesh (только главный поток): добавляет в каждую запись ключ mesh.
static func meshes(tiles: Dictionary) -> void:
	for k in tiles:
		var t: Dictionary = tiles[k]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, t.arrays)
		t["mesh"] = mesh


## Точки ломаной не реже шага.
static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var n := maxi(1, ceili(a.distance_to(b) / step))
		for k in n:
			out.append(a.lerp(b, float(k) / n))
	if pts.size() > 0:
		out.append(pts[pts.size() - 1])
	return out


static func _add_strip(
	acc: Dictionary,
	pts: PackedVector2Array,
	width: float,
	major: bool,
	col: Color,
	lift: float,
	tile: float,
	height_fn: Callable,
	style: float = 0.0
) -> void:
	var half := width * 0.5
	var along := PackedFloat32Array()  # метры от начала полилинии (L7)
	along.resize(pts.size())
	for j in range(1, pts.size()):
		along[j] = along[j - 1] + pts[j].distance_to(pts[j - 1])
	var start := 0
	while start < pts.size() - 1:
		var tk := WorldTiles.key(pts[start].x, pts[start].y, tile)
		var end := start + 1
		while end < pts.size() - 1 and WorldTiles.key(pts[end].x, pts[end].y, tile) == tk:
			end += 1
		var key := "%d:%d:%d" % [int(major), tk.x, tk.y]
		if not acc.has(key):
			acc[key] = {
				"v": PackedVector3Array(),
				"n": PackedVector3Array(),
				"c": PackedColorArray(),
				"uv": PackedVector2Array(),
				"uv2": PackedVector2Array(),
				"i": PackedInt32Array(),
				"origin": WorldTiles.center(tk, tile),
				"major": major,
			}
		var a: Dictionary = acc[key]
		var o: Vector3 = a.origin
		var base: int = a.v.size()
		for j in range(start, end + 1):
			var prev := pts[maxi(j - 1, 0)]
			var next := pts[mini(j + 1, pts.size() - 1)]
			var dir := (next - prev).normalized()
			var side := Vector2(-dir.y, dir.x) * half
			for s in [-1.0, 1.0]:
				var p: Vector2 = pts[j] + side * s
				a.v.append(Vector3(p.x - o.x, float(height_fn.call(p.x, p.y)) + lift, p.y - o.z))
				a.n.append(Vector3.UP)
				a.c.append(col)
				a.uv.append(Vector2(0.5 + 0.5 * s, along[j]))
				a.uv2.append(Vector2(style, width))
		for j in end - start:
			var q := base + 2 * j
			a.i.append_array(PackedInt32Array([q, q + 2, q + 1, q + 1, q + 2, q + 3]))
		start = end
