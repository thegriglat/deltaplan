extends TestCase
## Дома посёлков в пятнах застройки (NO-2, N3): godot --headless --path . res://tests/run_tests.tscn -- --filter=test_villages

const PLACES := ["altai", "askarovo", "aushkul", "ongudai"]

static var _t := {}
static var _h := {}


func _place(id: String) -> Dictionary:
	if not _t.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		_t[id] = t
		var bp := BuiltPatches.for_terrain(t)
		var vcfg: Dictionary = WorldObjects.load_config().villages
		var t0 := Time.get_ticks_usec()
		var houses := VillagePlacer.plan(bp, id, vcfg, t.height_at)
		_h[id] = {"bp": bp, "houses": houses, "plan_s": (Time.get_ticks_usec() - t0) / 1.0e6}
	return _h[id]


func test_counts() -> void:
	for id in PLACES:
		var d := _place(id)
		var n: int = d.houses.size()
		print("test_villages: %s пятен %d домов %d (план %.2f с)" % [id, d.bp.patches().size(), n, d.plan_s])
		check(n > 300, "%s: домов %d" % [id, n])
		check(n < 27000, "%s: домов не больше прежних зданий OSM (%d)" % [id, n])


func test_deterministic() -> void:
	var id := "ongudai"
	var d := _place(id)
	var vcfg: Dictionary = WorldObjects.load_config().villages
	VillagePlacer._cache.clear()
	var again := VillagePlacer.plan(d.bp, id, vcfg, _t[id].height_at)
	check(again == d.houses, "тот же план при повторной сборке")
	VillagePlacer._cache.clear()
	var other := VillagePlacer.plan(d.bp, "other", vcfg, _t[id].height_at)
	check(other != d.houses, "ключ места влияет на расстановку")


func test_inside_patches_and_slope() -> void:
	var vcfg: Dictionary = WorldObjects.load_config().villages
	var lim := float(vcfg.max_slope_deg) + 1.0
	for id in PLACES:
		var d := _place(id)
		var bad_in := 0
		var bad_slope := 0
		var n := 0
		for b: Array in d.houses:
			n += 1
			if n % 7 != 0:
				continue
			if d.bp.share_at(float(b[0]), float(b[1])) <= 0.0:
				bad_in += 1
			var hf: Callable = _t[id].height_at
			var x := float(b[0])
			var z := float(b[1])
			var gx := (float(hf.call(x + 5.0, z)) - float(hf.call(x - 5.0, z))) / 10.0
			var gz := (float(hf.call(x, z + 5.0)) - float(hf.call(x, z - 5.0))) / 10.0
			if rad_to_deg(atan(Vector2(gx, gz).length())) > lim:
				bad_slope += 1
		check(bad_in == 0, "%s: домов вне пятен %d" % [id, bad_in])
		check(bad_slope == 0, "%s: домов на склоне круче %.0f° — %d" % [id, lim, bad_slope])


func test_density_follows_share() -> void:
	var d := _place("askarovo")
	var inner := 0
	var inner_cells := 0
	var vcfg: Dictionary = WorldObjects.load_config().villages
	var step := sqrt(float(vcfg.yard_m2))
	for p in d.bp.patches():
		if p.area_m2 < 100000.0:
			continue
		inner_cells += int(p.area_m2 / (step * step))
	for b: Array in d.houses:
		if d.bp.share_at(float(b[0]), float(b[1])) >= 0.5:
			inner += 1
	check(inner > 0 and inner_cells > 0, "дома есть в крупных пятнах")
	var per_yard := float(d.houses.size()) / maxf(float(d.bp.patches().size()), 1.0)
	check(per_yard > 1.0, "в среднем больше одного дома на пятно (%.1f)" % per_yard)


func test_types_sizes() -> void:
	var d := _place("askarovo")
	var big := 0
	for b: Array in d.houses:
		check(float(b[2]) >= 3.0 and float(b[3]) <= 10.0 and float(b[5]) <= 3.2, "размеры в пределах конфига")
		if float(b[2]) >= 6.0:
			big += 1
	check(big > d.houses.size() / 4, "домов 6×8 и крупнее — около половины (%d из %d)" % [big, d.houses.size()])


func test_build_in_world_and_clearings() -> void:
	var id := "askarovo"
	var d := _place(id)
	var t: Terrain = _t[id]
	var w := WorldObjects.new()
	w.build(
		id, t.get_start_sites(), t.get_landing_sites(), t.height_at, Callable(), t.latlon_to_local,
		Vector2(t.center_lat, t.center_lon), d.bp
	)
	print("test_villages: %s сборка WorldObjects %.2f с, домов %d" % [id, w.build_time_s, w.houses.size()])
	check(w.houses.size() == d.houses.size(), "дома в мире = план")
	check(w.build_time_s < 6.0, "сборка объектов %.2f с (NFR-2)" % w.build_time_s)
	check(w.village_layer != null and w.village_layer.stats.buildings == w.houses.size(), "MultiMesh по числу домов")
	var h: Array = w.houses[w.houses.size() / 2]
	var x := float(h[0])
	var z := float(h[1])
	var y := t.height_at(x, z)
	var hit := w.obstacle_hit(Vector3(x - 30.0, y + 1.5, z), Vector3(x + 30.0, y + 1.5, z))
	check(not hit.is_empty() and hit.kind == "building", "дом — препятствие building")
	var c := WorldClearings.build_for(id)
	check(c.is_clear_at(x, z), "в доме деревья не растут")
	w.free()
