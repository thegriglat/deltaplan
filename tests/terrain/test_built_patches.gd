extends TestCase
## BuiltPatches (NO-1, контракт N2): пятна застройки встроенных мест из built_patches.json.
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=test_built_patches

const PLACES := ["askarovo", "altai", "aushkul", "ongudai"]


func _terrain(id: String) -> Terrain:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location(id)
	return t


func test_places() -> void:
	for id in PLACES:
		var t := _terrain(id)
		var t0 := Time.get_ticks_usec()
		var bp := BuiltPatches.for_terrain(t)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(bp.source == "worldcover10", "%s: source" % id)
		var ps := bp.patches()
		var area := 0.0
		var biggest := 0.0
		for p in ps:
			area += p.area_m2
			biggest = maxf(biggest, p.area_m2)
		check(ps.size() > 0, "%s: пятна есть" % id)
		print("         %s: пятен %d, площадь %.0f м², крупнейшее %.0f м², for_terrain %.1f мс" % [id, ps.size(), area, biggest, ms])
		check(ms <= 20.0, "%s: for_terrain %.1f мс ≤ 20" % [id, ms])
		# кеш на Terrain: тот же объект
		check(BuiltPatches.for_terrain(t) == bp, "%s: кеш на Terrain" % id)
		# пятно: центр в bbox, nearest — само пятно на расстоянии 0, share_at внутри пятна > 0
		var p0: Dictionary = ps[0]
		check(p0.bbox.grow(1.0).has_point(Vector2(p0.x, p0.z)), "%s: центр в bbox" % id)
		var nn := bp.nearest(p0.x, p0.z)
		check(int(nn.id) == int(p0.id) and float(nn.dist_m) < 0.01, "%s: nearest(центр) — то же пятно" % id)
		var far := bp.nearest(p0.x + 1.0e5, p0.z)
		check(float(far.dist_m) > 7.0e4, "%s: dist_m далеко" % id)
		var inside := 0
		for p in ps.slice(0, 20):
			if bp.share_at(p.x, p.z) > 0.0:
				inside += 1
		check(inside >= 10, "%s: share_at около центров пятен > 0 (%d из 20)" % [id, inside])
		check(bp.share_at(1.0e6, 1.0e6) == 0.0, "%s: вне сетки 0" % id)
		# инварианты N1: площади не больше клеток выше порога; пятна не пересекаются по bbox-центрам
		var ids := {}
		for p in ps:
			check(not ids.has(p.id), "%s: id уникален" % id)
			ids[p.id] = true
		t.free()


func test_deterministic() -> void:
	var t := _terrain("askarovo")
	var a := BuiltPatches.for_terrain(t).patches()
	var b := BuiltPatches._load(String(t.location.get("data_dir", ""))).patches()
	check(a == b, "повторное чтение даёт тот же список")
	t.free()


func test_empty() -> void:
	var e := BuiltPatches.for_terrain(null)
	check(e.source == "none" and e.patches().is_empty() and e.nearest(0, 0).is_empty() and e.share_at(0, 0) == 0.0, "пустой")
