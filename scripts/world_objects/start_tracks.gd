class_name StartTracks
extends RefCounted
## Тропы к стартам (грунтовые дорожки/тропы, docs/world_objects.md): от ближайшей автомобильной
## дороги или посёлка вверх к площадке старта. Если в OSM есть track, конец которого рядом со
## стартом, — используется он (обрезанный до max_length_m); иначе — процедурная тропа по рельефу:
## простая трассировка с серпантином (обход участков круче max_slope_deg, обход воды по OSM
## rivers/lakes). Без OSM (рантайм-локация по координатам) — спуск в сторону падения рельефа
## фиксированной длины. Рисуется как дороги (лента по рельефу), но уже и естественнее: ширина и
## вытоптанность (подмес wear_color пятнами, не параллельными рельсами-колеями) гуляют вдоль пути по
## плавному псевдошуму от длины дуги, край ленты мягкий и рваный (draped.gdshader), видимость
## near..far короче, чем у дорог, и мягко угасает к дальней границе. Параметры —
## configs/world_objects.json → start_tracks. Без нод — используется и WorldObjects (рендер), и
## WorldClearings (просека).
##   var tracks := StartTracks.plan(terrain.get_start_sites(), osm, cfg.start_tracks,
##       terrain.height_at)
##   var tiles := StartTracks.build_meshes(tracks, cfg.start_tracks, terrain.height_at)


## Тропа на каждый старт (в порядке start_sites), мир (x, z). Пустой массив у сайта — не должно
## случаться (процедурная тропа — запасной вариант всегда доступен).
static func plan(start_sites: Array, osm: OsmData, cfg: Dictionary, height_fn: Callable) -> Array:
	var out: Array = []
	for s in start_sites:
		var p: Vector3 = s.position
		var start := Vector2(p.x, p.z)
		var pts := _match_osm(start, osm, cfg)
		if pts.size() < 2:
			pts = _generate(start, osm, cfg, height_fn)
		out.append(pts)
	return out


## Меши троп (как RoadMesher.build): {"<tx>:<tz>": {mesh: ArrayMesh, origin: Vector3}}.
static func build_meshes(tracks: Array, cfg: Dictionary, height_fn: Callable) -> Dictionary:
	var acc := {}
	var tile := float(cfg.tile_m)
	var lift := float(cfg.lift_m)
	var col := WorldTiles.linear_color(cfg.color)
	var wear_col := WorldTiles.linear_color(cfg.wear_color)
	var width_min := float(cfg.width_min_m)
	var width_max := float(cfg.width_max_m)
	var width_wave := maxf(float(cfg.width_wave_m), 0.01)
	var wear_strength := float(cfg.wear_strength)
	var wear_wave := maxf(float(cfg.wear_wave_m), 0.01)
	var step := float(cfg.step_m)
	for raw in tracks:
		var pts: PackedVector2Array = raw
		if pts.size() < 2:
			continue
		var rs := _resample(pts, step)
		if rs.size() < 2:
			continue
		_add_strip(
			acc, rs, width_min, width_max, width_wave, col, wear_col, wear_strength, wear_wave,
			lift, tile, step, height_fn
		)
	var out := {}
	for k in acc:
		var a: Dictionary = acc[k]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = a.v
		arrays[Mesh.ARRAY_NORMAL] = a.n
		arrays[Mesh.ARRAY_COLOR] = a.c
		arrays[Mesh.ARRAY_TEX_UV] = a.uv
		arrays[Mesh.ARRAY_INDEX] = a.i
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out[k] = {"mesh": mesh, "origin": a.origin}
	return out


## Уклон вдоль ломаной (град), максимум по сегментам — для проверки в тестах.
static func max_slope_deg(pts: PackedVector2Array, height_fn: Callable) -> float:
	var worst := 0.0
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var d := a.distance_to(b)
		if d < 0.01:
			continue
		var ha := float(height_fn.call(a.x, a.y))
		var hb := float(height_fn.call(b.x, b.y))
		worst = maxf(worst, rad_to_deg(atan2(absf(hb - ha), d)))
	return worst


## OSM track/path (start_tracks.osm_track_classes), чей ближайший к старту участок — в радиусе
## osm_match_radius_m: обрезается до max_length_m в сторону дальнего конца (к дороге/посёлку),
## к старту пристёгивается точная точка старта.
static func _match_osm(start: Vector2, osm: OsmData, cfg: Dictionary) -> PackedVector2Array:
	if osm == null:
		return PackedVector2Array()
	var classes: Array = cfg.get("osm_track_classes", ["track"])
	var radius := float(cfg.osm_match_radius_m)
	var max_len := float(cfg.max_length_m)
	var best_d := radius
	var best: Dictionary = {}
	var best_pts := PackedVector2Array()
	for r in osm.roads:
		if not classes.has(String(r.t)):
			continue
		var pts := OsmData.points(r.p)
		if pts.size() < 2:
			continue
		var hit := _closest_on_polyline(pts, start)
		if float(hit.dist) < best_d:
			best_d = float(hit.dist)
			best = hit
			best_pts = pts
	if best.is_empty():
		return PackedVector2Array()
	var forward := (
		_remaining_len(best_pts, int(best.seg), true)
		>= _remaining_len(best_pts, int(best.seg), false)
	)
	var walked := _walk(best_pts, int(best.seg), best.point, forward, max_len)
	var out := PackedVector2Array()
	if start.distance_to(walked[0]) > 0.5:
		out.append(start)
	out.append_array(walked)
	return out


## Ближайшая точка сегмента ломаной к p: {dist, seg, point}.
static func _closest_on_polyline(pts: PackedVector2Array, p: Vector2) -> Dictionary:
	var best_dist := INF
	var best := {}
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0) if len2 > 1.0e-6 else 0.0
		var proj := a + ab * t
		var d := p.distance_to(proj)
		if d < best_dist:
			best_dist = d
			best = {"dist": d, "seg": i, "point": proj}
	return best


## Длина ломаной от узла seg (не включая обрезок до найденной точки) до соответствующего конца.
static func _remaining_len(pts: PackedVector2Array, seg: int, forward: bool) -> float:
	var total := 0.0
	if forward:
		for i in range(seg + 1, pts.size() - 1):
			total += pts[i].distance_to(pts[i + 1])
	else:
		for i in range(seg, 0, -1):
			total += pts[i].distance_to(pts[i - 1])
	return total


## От точки внутри сегмента seg — вдоль ломаной в выбранную сторону, не длиннее max_len.
static func _walk(
	pts: PackedVector2Array, seg: int, point: Vector2, forward: bool, max_len: float
) -> PackedVector2Array:
	var out := PackedVector2Array([point])
	var acc := 0.0
	var idx := seg + 1 if forward else seg
	var step := 1 if forward else -1
	var cur := point
	while idx >= 0 and idx < pts.size():
		var nxt: Vector2 = pts[idx]
		var d := cur.distance_to(nxt)
		if acc + d >= max_len:
			if d > 0.01:
				out.append(cur.lerp(nxt, (max_len - acc) / d))
			break
		out.append(nxt)
		acc += d
		cur = nxt
		idx += step
	return out


## Ближайшая точка автомобильной дороги или посёлка (destinaton процедурной тропы). null — нет OSM.
static func _nearest_destination(start: Vector2, osm: OsmData, cfg: Dictionary):
	if osm == null:
		return null
	var classes: Array = cfg.get(
		"road_classes",
		["trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "service"]
	)
	var best_d := INF
	var best := Vector2.ZERO
	var found := false
	for r in osm.roads:
		if not classes.has(String(r.t)):
			continue
		var pts := OsmData.points(r.p)
		if pts.size() < 2:
			continue
		var hit := _closest_on_polyline(pts, start)
		if float(hit.dist) < best_d:
			best_d = float(hit.dist)
			best = hit.point
			found = true
	for pl in osm.places:
		var p := Vector2(float(pl.x), float(pl.z))
		var d := start.distance_to(p)
		if d < best_d:
			best_d = d
			best = p
			found = true
	return best if found else null


static func _generate(
	start: Vector2, osm: OsmData, cfg: Dictionary, height_fn: Callable
) -> PackedVector2Array:
	var dest = _nearest_destination(start, osm, cfg)
	if dest == null:
		return _descend(start, height_fn, cfg)
	return _generate_from(start, dest, osm, cfg, height_fn)


## Реки/озёра, чей ограничивающий прямоугольник ближе margin к прямоугольнику [lo, hi] (быстрый
## отсев перед O(точек) проверкой воды — иначе перебор всех osm.rivers/lakes на каждом шаге
## трассировки был бы слишком медленным). Точки полилиний разбираются один раз на весь путь.
static func _nearby_water(osm: OsmData, lo: Vector2, hi: Vector2, margin: float) -> Dictionary:
	var out := {"lakes": [], "rivers": []}
	if osm == null:
		return out
	for lk in osm.lakes:
		var poly := OsmData.points(lk.p)
		if poly.size() >= 3 and _bbox_overlaps(poly, lo, hi, margin):
			out.lakes.append(poly)
	for rv in osm.rivers:
		var pts := OsmData.points(rv.p)
		if pts.size() >= 2 and _bbox_overlaps(pts, lo, hi, margin):
			out.rivers.append(pts)
	return out


static func _bbox_overlaps(
	pts: PackedVector2Array, lo: Vector2, hi: Vector2, margin: float
) -> bool:
	var blo := pts[0]
	var bhi := pts[0]
	for p in pts:
		blo.x = minf(blo.x, p.x)
		blo.y = minf(blo.y, p.y)
		bhi.x = maxf(bhi.x, p.x)
		bhi.y = maxf(bhi.y, p.y)
	var outside_x := bhi.x < lo.x - margin or blo.x > hi.x + margin
	var outside_z := bhi.y < lo.y - margin or blo.y > hi.y + margin
	return not (outside_x or outside_z)


## Нет OSM (рантайм-локация без выгрузки) — тропа вниз по склону (направление наибольшего спуска
## у старта), фиксированной длины no_destination_length_m, тот же серпантин по уклону.
static func _descend(start: Vector2, height_fn: Callable, cfg: Dictionary) -> PackedVector2Array:
	var probe := float(cfg.step_m)
	var best_dir := Vector2.DOWN
	var best_h := float(height_fn.call(start.x, start.y))
	for a in range(0, 360, 30):
		var d := Vector2.RIGHT.rotated(deg_to_rad(float(a)))
		var h := float(height_fn.call(start.x + d.x * probe, start.y + d.y * probe))
		if h < best_h:
			best_h = h
			best_dir = d
	var length := float(cfg.get("no_destination_length_m", 300.0))
	return _generate_from(start, start + best_dir * length, null, cfg, height_fn)


## Простая трассировка от start к dest: серпантин, если уклон прямого шага > max_slope_deg
## (перебор углов от прямого к диагональному, чередование сторон через angles_deg), обход воды.
static func _generate_from(
	start: Vector2, dest: Vector2, osm: OsmData, cfg: Dictionary, height_fn: Callable
) -> PackedVector2Array:
	var step := float(cfg.step_m)
	var max_slope := deg_to_rad(float(cfg.max_slope_deg))
	var water_buf := float(cfg.water_buffer_m)
	var fracs: Array = cfg.get("contour_fractions", [0.0, 0.35, 0.6, 0.8, 1.0])
	var max_steps := int(cfg.get("max_steps", 400))
	var margin := float(cfg.get("water_search_margin_m", 250.0))
	var water := _nearby_water(
		osm,
		Vector2(minf(start.x, dest.x), minf(start.y, dest.y)),
		Vector2(maxf(start.x, dest.x), maxf(start.y, dest.y)),
		margin
	)
	var out := PackedVector2Array([start])
	var cur := start
	var h_cur := float(height_fn.call(cur.x, cur.y))
	for _i in max_steps:
		var rem := dest - cur
		var dr := rem.length()
		if dr < 0.05:
			return out
		var dir := rem / dr
		if dr <= step:
			# Финальный подход (последний отрезок короче шага): тот же поиск, но если и подшагом
			# уклон нигде не укладывается в предел — трасса останавливается чуть раньше цели
			# (короткий разрыв до дороги/посёлка лучше, чем нарушение уклона в самом конце).
			var fin := _best_step(cur, dir, dr, water, water_buf, height_fn, max_slope, fracs, h_cur)
			if bool(fin.chosen):
				out.append(fin.pt)
			return out
		var r := _best_step(cur, dir, step, water, water_buf, height_fn, max_slope, fracs, h_cur)
		var chosen_pt: Vector2 = r.pt
		var chosen_h: float = r.h
		if not bool(r.chosen) and not bool(r.any_fallback):
			# все кандидаты в воде — идём прямо, игнорируя воду (крайний случай).
			chosen_pt = cur + dir * step
			chosen_h = float(height_fn.call(chosen_pt.x, chosen_pt.y))
		out.append(chosen_pt)
		cur = chosen_pt
		h_cur = chosen_h
	out.append(dest)
	return out


## Лучший следующий шаг из cur в сторону dir: пробует уменьшающиеся длины шага (base_step, половина,
## четверть — кривизна рельефа на полном шаге может не дать уложиться в уклон), на каждой — контур
## (направление нулевого уклона) с нарастающей долей отклонения (fracs, обе стороны). Первый шаг с
## уклоном ≤ max_slope — сразу возврат; иначе — {chosen: false, ...} и самый пологий кандидат
## (any_fallback) на случай, если вызывающий код решит всё равно продолжить (не в последнем шаге).
static func _best_step(
	cur: Vector2,
	dir: Vector2,
	base_step: float,
	water: Dictionary,
	water_buf: float,
	height_fn: Callable,
	max_slope: float,
	fracs: Array,
	h_cur: float
) -> Dictionary:
	var step_sizes: Array[float] = [base_step, base_step * 0.5, base_step * 0.25]
	var fallback_pt := Vector2.ZERO
	var fallback_h := 0.0
	var fallback_slope := INF
	var any_fallback := false
	for s in step_sizes:
		# Локальный уклон в cur: контур (перпендикуляр к градиенту) — направление нулевого
		# уклона, всегда существует (кроме идеальной вершины/ямы) — серпантин к нему сводится.
		var contour := _contour_dir(cur, dir, s * 0.5, height_fn)
		for f in fracs:
			var t := float(f)
			var sides := [1.0] if t <= 0.0 else [1.0, -1.0]
			for side in sides:
				var cand_dir: Vector2 = dir.slerp(contour * side, t).normalized()
				var cand := cur + cand_dir * s
				if _in_water_near(cand, water, water_buf):
					continue
				var h := float(height_fn.call(cand.x, cand.y))
				var slope := atan2(absf(h - h_cur), s)
				if slope <= max_slope:
					return {"chosen": true, "pt": cand, "h": h, "any_fallback": true}
				if not any_fallback or slope < fallback_slope:
					any_fallback = true
					fallback_slope = slope
					fallback_pt = cand
					fallback_h = h
	return {"chosen": false, "pt": fallback_pt, "h": fallback_h, "any_fallback": any_fallback}


## Направление нулевого уклона в p (перпендикуляр к градиенту высоты, центральные разности с шагом
## probe), сориентированное в сторону toward (положительная проекция) — серпантин отклоняется от
## toward к этому направлению, когда прямой шаг круче предела.
static func _contour_dir(p: Vector2, toward: Vector2, probe: float, height_fn: Callable) -> Vector2:
	var dx := float(height_fn.call(p.x + probe, p.y)) - float(height_fn.call(p.x - probe, p.y))
	var dz := float(height_fn.call(p.x, p.y + probe)) - float(height_fn.call(p.x, p.y - probe))
	var grad := Vector2(dx, dz)
	if grad.length_squared() < 1.0e-9:
		return toward
	var contour := Vector2(-grad.y, grad.x).normalized()
	return contour if contour.dot(toward) >= 0.0 else -contour


## Полный перебор osm.rivers/lakes (тесты, редкие разовые проверки — не в горячем цикле
## трассировки).
static func _in_water(p: Vector2, osm: OsmData, buffer: float) -> bool:
	if osm == null:
		return false
	return _in_water_near(p, _nearby_water(osm, p, p, buffer + 1.0), buffer)


## То же по уже отфильтрованному набору (_nearby_water) — горячий цикл _generate_from.
static func _in_water_near(p: Vector2, water: Dictionary, buffer: float) -> bool:
	for poly in water.lakes:
		if _point_in_polygon(p, poly):
			return true
	for pts in water.rivers:
		if _closest_on_polyline(pts, p).dist <= buffer:
			return true
	return false


static func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi := poly[i]
		var pj := poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var x := (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
			if p.x < x:
				inside = not inside
		j = i
	return inside


## Точки ломаной не реже шага (как RoadMesher._resample).
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


## Псевдошум в [-1, 1] от длины дуги s (два незацикленных гармоники — без видимого повтора периода
## на длине обычной тропы), fast/slow — доли периода wave медленной/быстрой гармоники.
static func _wander(s: float, wave: float, phase: float, fast: float, slow: float) -> float:
	return sin(s / wave * TAU + phase) * slow + sin(s / (wave * 0.41) * TAU + phase * 1.7) * fast


## Лента вдоль pts с гуляющей шириной (width_min..width_max) и вытоптанностью пятнами (col →
## wear_col по wear_strength), тайлы tile_m (как RoadMesher._add_strip, без деления на major).
## Альфа вершин — не сплошная лента, а разрывы/пятна вдоль пути (мягкий рваный край — в
## draped.gdshader, по UV и миру). s — длина дуги от начала pts, растёт с шагом ~step.
static func _add_strip(
	acc: Dictionary,
	pts: PackedVector2Array,
	width_min: float,
	width_max: float,
	width_wave: float,
	col: Color,
	wear_col: Color,
	wear_strength: float,
	wear_wave: float,
	lift: float,
	tile: float,
	step: float,
	height_fn: Callable
) -> void:
	var start := 0
	while start < pts.size() - 1:
		var tk := WorldTiles.key(pts[start].x, pts[start].y, tile)
		var end := start + 1
		while end < pts.size() - 1 and WorldTiles.key(pts[end].x, pts[end].y, tile) == tk:
			end += 1
		var key := "%d:%d" % [tk.x, tk.y]
		if not acc.has(key):
			acc[key] = {
				"v": PackedVector3Array(),
				"n": PackedVector3Array(),
				"c": PackedColorArray(),
				"uv": PackedVector2Array(),
				"i": PackedInt32Array(),
				"origin": WorldTiles.center(tk, tile),
			}
		var a: Dictionary = acc[key]
		var o: Vector3 = a.origin
		var base: int = a.v.size()
		for j in range(start, end + 1):
			var prev := pts[maxi(j - 1, 0)]
			var next := pts[mini(j + 1, pts.size() - 1)]
			var dir := (next - prev).normalized()
			var s := float(j) * step
			var width_t := clampf(0.5 + 0.5 * _wander(s, width_wave, 1.7, 0.3, 0.7), 0.0, 1.0)
			var half := lerpf(width_min, width_max, width_t) * 0.5
			var wear_t := clampf(0.5 + 0.5 * _wander(s, wear_wave, 2.3, 0.35, 0.65), 0.0, 1.0)
			var vcol := col.lerp(wear_col, wear_t * wear_strength)
			var alpha := clampf(0.55 + 0.45 * _wander(s, wear_wave * 1.6, 0.9, 0.3, 0.7), 0.0, 1.0)
			var side := Vector2(-dir.y, dir.x) * half
			for sg in [-1.0, 1.0]:
				var p: Vector2 = pts[j] + side * sg
				a.v.append(Vector3(p.x - o.x, float(height_fn.call(p.x, p.y)) + lift, p.y - o.z))
				a.n.append(Vector3.UP)
				a.c.append(Color(vcol.r, vcol.g, vcol.b, alpha))
				a.uv.append(Vector2(0.5 + 0.5 * sg, 0.0))
		for j in end - start:
			var q := base + 2 * j
			a.i.append_array(PackedInt32Array([q, q + 2, q + 1, q + 1, q + 2, q + 3]))
		start = end
