extends TestCase
## Снаряжение у стартов (StartGear, WorldObjects.start_gear), контракты SC-K1/SC-K2:
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_gear

const SITES := [["ongudai", "kayancha_south"], ["askarovo", "biyagoda_west"]]

static var _worlds: Dictionary = {}


func _cfg() -> Dictionary:
	return WorldObjects.load_config().start_gear


func _flat(h: float = 100.0) -> Dictionary:
	return {"height_fn": func(_x: float, _z: float) -> float: return h}


## Оси старта как у BotPilots.find_spots: fwd = (sin h, −cos h), right = (cos h, sin h).
func _axes(hd: float) -> Array:
	var h := deg_to_rad(hd)
	return [Vector2(sin(h), -cos(h)), Vector2(cos(h), sin(h))]


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
		var idx := -1
		for i in t.get_start_sites().size():
			if t.get_start_sites()[i].id == site_id:
				site = t.get_start_sites()[i]
				idx = i
		_worlds[key] = [t, w, site, idx]
	return _worlds[key]


func _count(items: Array, kind: String) -> int:
	return items.filter(func(i: Dictionary) -> bool: return i.kind == kind).size()


func test_set_on_flat_ground() -> void:
	var cfg := _cfg()
	var items := StartGear.plan(Vector3(0, 100, 0), 0.0, cfg, _flat())
	var c: Dictionary = cfg.counts
	_check_counts(items, c, "ровное поле")
	for it: Dictionary in items:
		check(
			it.has_all(["kind", "variant", "position", "basis", "yaw", "color", "radius_m", "box"]),
			"поля элемента %s" % it.get("kind")
		)
	var kits := _count(items, "kit_bundle")
	check(kits == _count(items, "kit_frame"), "аппарат парой")
	for ch in items.filter(func(i: Dictionary) -> bool: return i.kind == "wing"):
		check(String(ch.variant) in cfg.wing_pool, "крыло из пула: %s" % ch.variant)


func _check_counts(items: Array, c: Dictionary, tag: String) -> void:
	for pair: Array in [
		["wing", "wing"],
		["kit_bundle", "kit"],
		["bag", "bag"],
		["harness", "harness"],
		["helmet", "helmet"],
		["bottle", "bottle"]
	]:
		var n := _count(items, pair[0])
		var lo := int(c[pair[1]][0])
		var hi := int(c[pair[1]][1])
		check(n >= lo and n <= hi, "%s: %s %d вне [%d, %d]" % [tag, pair[0], n, lo, hi])


func test_deterministic_and_varies() -> void:
	var cfg := _cfg()
	var env := {
		"height_fn": func(x: float, z: float) -> float: return 3.0 * sin(x * 0.02) + 0.03 * z
	}
	var a := StartGear.plan(Vector3(10, 0, 20), 30.0, cfg, env)
	var b := StartGear.plan(Vector3(10, 0, 20), 30.0, cfg, env)
	check(a.size() == b.size() and a.size() > 0, "одинаковое число: %d / %d" % [a.size(), b.size()])
	for i in mini(a.size(), b.size()):
		check(
			(a[i].position as Vector3).is_equal_approx(b[i].position) and a[i].variant == b[i].variant,
			"вещь %d совпадает" % i
		)
	var c := StartGear.plan(Vector3(400, 0, -300), 30.0, cfg, env)
	check(
		c.is_empty() or not (c[0].position as Vector3).is_equal_approx(a[0].position),
		"другой старт — другой набор"
	)


func test_k1_zones_flat() -> void:
	var cfg := _cfg()
	for hd in [0.0, 90.0, 215.0]:
		var start := Vector3(50, 100, -30)
		var items := StartGear.plan(start, hd, cfg, _flat())
		var ax := _axes(hd)
		_check_k1(items, start, ax[0], ax[1], cfg, "курс %d" % hd)


func _check_k1(items: Array, start: Vector3, fwd: Vector2, right: Vector2, cfg: Dictionary, tag: String) -> void:
	var bots: Dictionary = Config.get_config("bots").get("launch", {})
	var half := float(bots.get("corridor_half_width_m", 9.0)) + 2.0
	for it: Dictionary in items:
		var p: Vector3 = it.center
		var rel := Vector2(p.x - start.x, p.z - start.z)
		var d := rel.length()
		var along := rel.dot(fwd)
		var lat := rel.dot(right)
		var r := float(it.radius_m)
		check(d >= 6.0 - 0.01 and d <= 28.0 + 0.01, "%s: %s в %.1f м от старта" % [tag, it.kind, d])
		check(along <= -3.0 + 0.01, "%s: %s впереди (along %.1f)" % [tag, it.kind, along])
		check(
			not (along > -8.0 - r + 0.01 and absf(lat) < half + r - 0.01),
			"%s: %s в коридоре (along %.1f lat %.1f r %.1f)" % [tag, it.kind, along, lat, r]
		)


func test_wing_on_bar_nose_to_wind() -> void:
	var cfg := _cfg()
	var start := Vector3(0, 100, 0)
	# ровно и с уклоном 5° в обе стороны
	var funcs := {
		"ровно": func(_x: float, _z: float) -> float: return 100.0,
		"уклон вдоль": func(x: float, z: float) -> float: return 100.0 + 0.07 * (z + x * 0.5),
		"уклон поперёк": func(x: float, _z: float) -> float: return 100.0 + 0.087 * x,
	}
	for tag: String in funcs:
		var env := {"height_fn": funcs[tag]}
		for hd in [0.0, 130.0]:
			var items := StartGear.plan(start, hd, cfg, env)
			var fwd: Vector2 = _axes(hd)[0]
			var wings := items.filter(func(i: Dictionary) -> bool: return i.kind == "wing")
			check(wings.size() >= 2, "%s %d: крыльев %d" % [tag, hd, wings.size()])
			for w: Dictionary in wings:
				var pose := StartGear.wing_pose(String(w.variant))
				var b: Basis = w.basis
				var pos: Vector3 = w.position
				var hf: Callable = env.height_fn
				for key in ["nose", "bar_l", "bar_r"]:
					var q: Vector3 = pos + b * (pose[key] as Vector3)
					var g: float = hf.call(q.x, q.z)
					check(
						absf(q.y - g) <= 0.05,
						"%s %d: %s %s на высоте %.3f над землёй" % [tag, hd, w.variant, key, q.y - g]
					)
				var nose_dir := b * ((pose.nose as Vector3) - ((pose.bar_l as Vector3) + (pose.bar_r as Vector3)) * 0.5)
				var hv := Vector2(nose_dir.x, nose_dir.z).normalized()
				var ang := rad_to_deg(acos(clampf(hv.dot(fwd), -1.0, 1.0)))
				check(ang <= 12.0, "%s %d: нос %s %.1f° от курса" % [tag, hd, w.variant, ang])


func test_wings_do_not_overlap() -> void:
	var items := StartGear.plan(Vector3(0, 100, 0), 20.0, _cfg(), _flat())
	var wings := items.filter(func(i: Dictionary) -> bool: return i.kind == "wing")
	for i in wings.size():
		for j in range(i + 1, wings.size()):
			var a: Vector3 = wings[i].center
			var b: Vector3 = wings[j].center
			var gap := Vector2(a.x - b.x, a.z - b.z).length() - float(wings[i].radius_m) - float(wings[j].radius_m)
			check(gap >= 0.5 - 0.01, "крылья %d и %d: зазор %.2f" % [i, j, gap])


func test_steep_slope_places_nothing_bad() -> void:
	var env := {"height_fn": func(x: float, _z: float) -> float: return x * 0.5}
	var items := StartGear.plan(Vector3(0, 0, 0), 0.0, _cfg(), env)
	check(items.is_empty(), "на склоне 27° вещей нет, получено %d" % items.size())


func test_blocked_and_lines() -> void:
	var cfg := _cfg()
	var start := Vector3(0, 100, 0)
	var env := {
		"height_fn": func(_x: float, _z: float) -> float: return 100.0,
		"blocked_fn": func(x: float, _z: float) -> bool: return x < 0.0,
		"lines": [[PackedVector2Array([Vector2(6, -50), Vector2(6, 50)]), 3.0]],
		"points": [Vector3(20, 10, 4.0)],
	}
	var items := StartGear.plan(start, 0.0, cfg, env)
	check(items.size() > 0, "справа от старта место есть")
	for it: Dictionary in items:
		var p: Vector3 = it.center
		var r := float(it.radius_m)
		check(p.x - r >= -0.01 or p.x > 0.0, "%s не в заблокированной зоне (x %.1f)" % [it.kind, p.x])
		check(absf(p.x - 6.0) > 3.0 + r - 0.01, "%s не на тропе (x %.1f)" % [it.kind, p.x])
		check(Vector2(p.x - 20, p.z - 10).length() > 4.0 + r - 0.01, "%s не на камне" % it.kind)


func test_real_starts() -> void:
	var cfg := _cfg()
	var seen_wings := {}
	for pair: Array in SITES:
		var d := _world(pair[0], pair[1])
		var w: WorldObjects = d[1]
		var site: Dictionary = d[2]
		var idx: int = d[3]
		var tag := "%s/%s" % pair
		check(idx >= 0, tag + ": нет старта")
		if idx < 0:
			continue
		check(w.start_gear.size() == w.start_gear.size() and w.start_gear.size() >= idx + 1, tag + ": набор есть")
		var items: Array = w.start_gear[idx]
		var sp: Vector3 = site.position
		var ax := _axes(float(site.heading_deg))
		_check_k1(items, sp, ax[0], ax[1], cfg, tag)
		for it: Dictionary in items:
			if it.kind == "wing":
				seen_wings[it.variant] = true
		# препятствия «gear» есть
		var any_box := items.filter(func(i: Dictionary) -> bool: return (i.box as Vector3) != Vector3.ZERO)
		check(any_box.size() > 0, tag + ": нет препятствий")
		if any_box.is_empty():
			continue
		var c: Vector3 = any_box[0].center
		var hit := w.obstacles.hit(Vector3(c.x - 30.0, c.y + 0.3, c.z), Vector3(c.x + 30.0, c.y + 0.3, c.z))
		check(not hit.is_empty(), tag + ": отрезок через вещь без столкновения")
	check(seen_wings.size() <= 6, "разных крыльев на локацию %d" % seen_wings.size())


func test_budget_and_draw_calls() -> void:
	var cfg := _cfg()
	var worst_near := 0
	var worst_far := 0
	var worst_calls := 0
	for hd in [0.0, 45.0, 90.0, 180.0, 270.0]:
		var items := StartGear.plan(Vector3(0, 100, 0), hd, cfg, _flat())
		var node := StartGear.build_node(items, cfg)
		var near := StartGear.stats(node, 5.0)
		var far := StartGear.stats(node, float(cfg.wing_detail_m) + 20.0)
		worst_near = maxi(worst_near, int(near.tris))
		worst_far = maxi(worst_far, int(far.tris))
		worst_calls = maxi(worst_calls, int(near.draw_calls_small))
		check(int(far.tris_small) == 0, "вдали мелочи нет")
		node.free()
	print("MEASURE tris_near ", worst_near, " tris_far ", worst_far, " draw_calls_small ", worst_calls)
	check(worst_near <= int(cfg.budget_near_tris), "вблизи %d тр." % worst_near)
	check(worst_far <= int(cfg.budget_far_tris), "вдали %d тр." % worst_far)
	check(worst_calls <= 20, "вызовов мелочи %d" % worst_calls)

