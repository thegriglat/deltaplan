extends TestCase
## Палатки у старта (TentCamp, WorldObjects.place_camp):
## godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects

## (локация, старт) — две приёмочные площадки.
const SITES := [["ongudai", "kayancha_south"], ["askarovo", "biyagoda_west"]]
const COUNT := 5

static var _worlds: Dictionary = {}


func _cfg() -> Dictionary:
	return WorldObjects.load_config().tents


## [Terrain, WorldObjects, старт] для локации (одна сборка на все тесты).
func _world(loc: String, site_id: String) -> Array:
	var key := loc + "/" + site_id
	if not _worlds.has(key):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(loc)
		var w := WorldObjects.new()
		w.build(
			loc,
			t.get_start_sites(),
			t.get_landing_sites(),
			t.height_at,
			Callable(),
			t.latlon_to_local,
			Vector2(t.center_lat, t.center_lon)
		)
		var site: Dictionary = {}
		for s in t.get_start_sites():
			if s.id == site_id:
				site = s
		_worlds[key] = [t, w, site]
	return _worlds[key]


func test_count_is_player_plus_bots() -> void:
	check(TentCamp.tent_count(0) == 1, "без ботов — одна палатка (игрок)")
	check(TentCamp.tent_count(7) == 8, "7 ботов — 8 палаток")
	var bots := int(Config.value("bots", "count", 4))
	check(TentCamp.tent_count() == 1 + bots, "по настройке: 1 + %d" % bots)


func test_flat_ground_places_all() -> void:
	var env := {"height_fn": func(_x: float, _z: float) -> float: return 100.0}
	var camp := TentCamp.plan(Vector3(0, 100, 0), 0.0, 21, _cfg(), env)
	check(camp.size() == 21, "на ровном поле — все 21, встало %d" % camp.size())
	_check_gaps(camp, "ровное поле")
	var types := {}
	var colors := {}
	for t in camp:
		types[t.type] = true
		colors[t.color] = true
	check(types.size() >= 2, "типы вперемешку: %s" % [types.keys()])
	check(colors.size() >= 3, "цвета вперемешку: %d" % colors.size())


func test_steep_slope_places_none() -> void:
	var env := {"height_fn": func(x: float, _z: float) -> float: return x * 0.4}
	var camp := TentCamp.plan(Vector3(0, 0, 0), 0.0, 5, _cfg(), env)
	check(camp.is_empty(), "на склоне 22° палаток нет, встало %d" % camp.size())


func test_deterministic() -> void:
	var env := {
		"height_fn": func(x: float, z: float) -> float: return 3.0 * sin(x * 0.02) + 0.05 * z
	}
	var a := TentCamp.plan(Vector3(10, 0, 20), 30.0, 6, _cfg(), env)
	var b := TentCamp.plan(Vector3(10, 0, 20), 30.0, 6, _cfg(), env)
	check(a.size() == b.size() and a.size() > 0, "одинаковое число: %d / %d" % [a.size(), b.size()])
	for i in mini(a.size(), b.size()):
		check(
			a[i].position.is_equal_approx(b[i].position) and a[i].type == b[i].type,
			"палатка %d совпадает" % i
		)
	var c := TentCamp.plan(Vector3(400, 0, -300), 30.0, 6, _cfg(), env)
	check(
		c.is_empty() or not (c[0].position as Vector3).is_equal_approx(a[0].position),
		"другой старт — другой лагерь"
	)


func test_camps_at_real_starts() -> void:
	var cfg := _cfg()
	for pair: Array in SITES:
		var d := _world(pair[0], pair[1])
		var t: Terrain = d[0]
		var w: WorldObjects = d[1]
		var site: Dictionary = d[2]
		var tag := "%s/%s" % pair
		check(not site.is_empty(), tag + ": нет старта")
		if site.is_empty():
			continue
		var sp: Vector3 = site.position
		var hd := float(site.heading_deg)
		w.place_camp(sp, hd, t, COUNT)
		var camp := w.camp.duplicate()
		check(camp.size() == COUNT, "%s: палаток %d из %d" % [tag, camp.size(), COUNT])
		_check_gaps(camp, tag)
		# детерминированно: тот же старт — тот же лагерь (и препятствия не копятся)
		w.place_camp(sp, hd, t, COUNT)
		check(w.camp.size() == camp.size(), tag + ": повтор — столько же")
		for i in mini(camp.size(), w.camp.size()):
			check(
				(camp[i].position as Vector3).is_equal_approx(w.camp[i].position),
				"%s: повтор — палатка %d на том же месте" % [tag, i]
			)
		var zone := TentCamp.launch_zone(cfg)
		var h := TerrainGeo.heading_vector(hd)
		var fwd := Vector2(h.x, h.z)
		var right := Vector2(-fwd.y, fwd.x)
		var track: PackedVector2Array = w.start_tracks[t.get_start_sites().find(site)]
		for tent: Dictionary in camp:
			var p: Vector3 = tent.position
			var v := Vector2(p.x - sp.x, p.z - sp.z)
			var r := float(tent.radius)
			var d0 := v.length()
			check(d0 >= 20.0 and d0 <= 190.0, "%s: палатка в %.0f м от старта" % [tag, d0])
			check(v.dot(fwd) < 0.0, "%s: палатка впереди линии старта" % tag)
			check(
				v.dot(fwd) < -float(zone.behind_m) or absf(v.dot(right)) > float(zone.lateral_m),
				(
					"%s: палатка в коридоре разбега / на местах ботов (%.0f, %.0f)"
					% [tag, v.dot(fwd), v.dot(right)]
				)
			)
			var dt := TentCamp.dist_to_polyline(Vector2(p.x, p.z), track)
			check(dt > r + 2.0, "%s: палатка на тропе (%.1f м)" % [tag, dt])
			var sc := t.surface_at(p.x, p.z)
			check(
				not sc in [SurfaceLayer.WATER, SurfaceLayer.FOREST],
				"%s: палатка в воде/лесу (%d)" % [tag, sc]
			)
			var worst := 0.0
			for k in 8:
				var q := Vector2(p.x, p.z) + Vector2.from_angle(k * TAU / 8.0) * r
				worst = maxf(worst, absf(t.height_at(q.x, q.y) - t.height_at(p.x, p.z)))
			check(
				rad_to_deg(atan2(worst, r)) <= float(cfg.max_slope_deg) + 0.5,
				"%s: уклон под палаткой %.1f°" % [tag, rad_to_deg(atan2(worst, r))]
			)
			var hit := w.obstacle_hit(p + Vector3(-5, 0.6, 0), p + Vector3(5, 0.6, 0))
			check(hit.get("kind", "") == "tent", "%s: палатка — препятствие" % tag)


func test_build_node() -> void:
	var env := {"height_fn": func(_x: float, _z: float) -> float: return 0.0}
	var camp := TentCamp.plan(Vector3.ZERO, 90.0, 4, _cfg(), env)
	var node := TentCamp.build_node(camp, _cfg())
	check(node.get_child_count() == camp.size(), "узел на палатку")
	var mi := node.get_child(0).get_node_or_null("LOD0") as MeshInstance3D
	check(mi != null and mi.mesh != null, "ближний LOD есть")
	check(node.get_child(0).get_node_or_null("LOD1") != null, "дальний LOD есть")
	node.free()


func _check_gaps(camp: Array, tag: String) -> void:
	var gap: Array = _cfg().gap_m
	for i in camp.size():
		var nearest := INF
		for j in camp.size():
			if i == j:
				continue
			var a: Vector3 = camp[i].position
			var b: Vector3 = camp[j].position
			var g := (
				Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
				- float(camp[i].radius)
				- float(camp[j].radius)
			)
			check(
				g >= float(gap[0]) - 0.01,
				"%s: палатки %d и %d ближе зазора (%.1f м)" % [tag, i, j, g]
			)
			nearest = minf(nearest, g)
		if camp.size() > 1:
			check(
				nearest <= 25.0, "%s: палатка %d в стороне от лагеря (%.1f м)" % [tag, i, nearest]
			)
