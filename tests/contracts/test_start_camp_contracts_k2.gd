extends TestCase
## Контракт SC-K2 (docs/contracts/start-camp.md): StartGear.plan/build_node, WorldObjects.start_gear,
## препятствия «gear».
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_camp_contracts_k2

const KINDS := ["wing", "kit_bundle", "kit_frame", "bag", "harness", "helmet", "bottle"]


func _env() -> Dictionary:
	return {"height_fn": func(_x: float, _z: float) -> float: return 50.0}


func test_plan_signature_and_fields() -> void:
	var cfg: Dictionary = WorldObjects.load_config().start_gear
	var items: Array[Dictionary] = StartGear.plan(Vector3(0, 50, 0), 10.0, cfg, _env())
	check(items.size() > 0, "набор не пуст")
	for it: Dictionary in items:
		check(String(it.kind) in KINDS, "вид %s" % it.kind)
		check(it.variant is String and String(it.variant) != "", "variant")
		check(it.position is Vector3, "position")
		check(it.basis is Basis, "basis")
		check(it.yaw is float, "yaw")
		check(it.color is int, "color")
		check(it.radius_m is float and float(it.radius_m) > 0.0, "radius_m")
		check(it.box is Vector3, "box")
		var obstacle: bool = it.kind in ["wing", "kit_bundle", "kit_frame", "bag"]
		check((it.box != Vector3.ZERO) == obstacle, "box ≠ 0 только у крыльев, аппарата, чехлов: %s" % it.kind)
		if int(it.color) >= 0:
			check(int(it.color) < (cfg.colors as Array).size(), "цвет в палитре")
		# без масштаба
		var b: Basis = it.basis
		check(absf(b.x.length() - 1.0) < 0.01 and absf(b.y.length() - 1.0) < 0.01, "basis без масштаба")


func test_kit_pair_close() -> void:
	var cfg: Dictionary = WorldObjects.load_config().start_gear
	for hd in [0.0, 100.0, 250.0]:
		var items := StartGear.plan(Vector3(0, 50, 0), hd, cfg, _env())
		var b := items.filter(func(i: Dictionary) -> bool: return i.kind == "kit_bundle")
		var f := items.filter(func(i: Dictionary) -> bool: return i.kind == "kit_frame")
		check(b.size() == 1 and f.size() == 1, "пара аппарата (%d/%d)" % [b.size(), f.size()])
		if b.size() == 1 and f.size() == 1:
			var d := (b[0].position as Vector3).distance_to(f[0].position)
			check(d <= 4.0, "аппарат: расстояние %.1f > 4 м" % d)


func test_counts_ranges() -> void:
	var cfg: Dictionary = WorldObjects.load_config().start_gear
	var c: Dictionary = cfg.counts
	var seen_wings := {}
	for k in 12:
		var items := StartGear.plan(Vector3(k * 37.0, 50, k * -21.0), k * 29.0, cfg, _env())
		for pair: Array in [
			["wing", "wing"], ["bag", "bag"], ["harness", "harness"], ["helmet", "helmet"], ["bottle", "bottle"]
		]:
			var n := items.filter(func(i: Dictionary) -> bool: return i.kind == pair[0]).size()
			check(
				n >= int(c[pair[1]][0]) and n <= int(c[pair[1]][1]),
				"%s: %d вне диапазона" % [pair[0], n]
			)
		for it in items:
			if it.kind == "wing":
				seen_wings[it.variant] = true
	check(seen_wings.size() <= 6, "разных крыльев %d > 6" % seen_wings.size())


func test_world_objects_start_gear_and_obstacles() -> void:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location("ongudai")
	var w := WorldObjects.new()
	var sites: Array = t.get_start_sites()
	w.build(
		"ongudai",
		sites,
		t.get_landing_sites(),
		t.height_at,
		Callable(),
		t.latlon_to_local,
		Vector2(t.center_lat, t.center_lon)
	)
	check(w.start_gear.size() == sites.size(), "набор на каждый старт: %d из %d" % [w.start_gear.size(), sites.size()])
	var with_node := 0
	for i in sites.size():
		if w.get_node_or_null("StartGear_%d" % i) != null:
			with_node += 1
	var nonempty := w.start_gear.filter(func(a: Array) -> bool: return not a.is_empty()).size()
	check(with_node == nonempty, "узлы StartGear_<i> у непустых наборов (%d/%d)" % [with_node, nonempty])
	check(nonempty > 0, "хотя бы у одного старта есть набор")
	for items: Array in w.start_gear:
		for it: Dictionary in items:
			if it.kind == "wing":
				var c: Vector3 = it.center
				var hit := w.obstacles.hit(
					Vector3(c.x - 20.0, c.y + 0.3, c.z), Vector3(c.x + 20.0, c.y + 0.3, c.z)
				)
				check(not hit.is_empty(), "крыло — препятствие")
				w.free()
				t.free()
				return
	w.free()
	t.free()
