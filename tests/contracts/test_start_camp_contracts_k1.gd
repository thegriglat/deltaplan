extends TestCase
## Контрактные тесты start-camp: SC-K1 — зона старта (кольцо лагеря, боты вне палаток),
## SC-K2 — ObstacleIndex.points_near (владелец SC-1). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/start-camp.md"


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	check(text.contains("## SC-K1 v1"), "SC-K1 v1 заголовок")
	check(text.contains("## SC-K2 v1"), "SC-K2 v1 заголовок")


func _flat_env() -> Dictionary:
	return {"height_fn": func(_x: float, _z: float) -> float: return 50.0}


func test_k1_ring() -> void:
	var cfg: Dictionary = WorldObjects.load_config().tents
	check(cfg.distance_m == [30.0, 50.0], "distance_m 30–50: %s" % [cfg.distance_m])
	check(float(cfg.prefer_distance_m) == 40.0, "prefer 40")
	check(float(cfg.camp_min_edge_m) == 32.0, "camp_min_edge_m 32")
	check(float(cfg.max_drop_m) == 5.0, "max_drop_m 5")
	check(cfg.distance_steps_m == [60.0, 80.0, 150.0], "ступени 60/80/150")
	var camp := TentCamp.plan(Vector3(100, 50, -40), 37.0, 5, cfg, _flat_env())
	check(camp.size() == 5, "5 палаток на ровном месте: %d" % camp.size())
	var s := Vector2(100, -40)
	var h := deg_to_rad(37.0)
	var fwd := Vector2(sin(h), -cos(h))
	var right := Vector2(cos(h), sin(h))
	var mid := Vector2.ZERO
	for t: Dictionary in camp:
		var rel := Vector2(t.position.x, t.position.z) - s
		mid += rel / camp.size()
		check(rel.length() - float(t.radius) >= 32.0 - 0.01, "край ≥ 32 м (%.1f)" % rel.length())
		check(rel.dot(fwd) <= -5.0, "along ≤ −5 (%.1f)" % rel.dot(fwd))
		check(not (rel.dot(fwd) > -8.0 and absf(rel.dot(right)) < 11.0), "вне коридора")
	check(mid.length() >= 28.0 and mid.length() <= 52.0, "центр лагеря 30–50 м: %.1f" % mid.length())


## Ровный пятак только на 70–90 м позади: кольцо расширяется ступенями.
func test_k1_steps() -> void:
	var cfg: Dictionary = WorldObjects.load_config().tents
	var env := {
		"height_fn": func(x: float, z: float) -> float:
			# курс 0 (на север, −Z): позади = +Z; крутой склон везде, кроме z in [70, 100]
			return 50.0 if (z > 66.0 and z < 104.0 and absf(x) < 30.0) else 50.0 + x * 0.5 + z * 0.4
	}
	var camp := TentCamp.plan(Vector3(0, 50, 0), 0.0, 2, cfg, env)
	check(camp.size() >= 1, "палатка встала на дальней ступени")
	for t: Dictionary in camp:
		check(t.position.z > 60.0, "палатка в 60+ м: z=%.1f" % t.position.z)


func test_k2_points_near() -> void:
	var idx := ObstacleIndex.new()
	idx.add_box(10.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, "tent")
	idx.add_box(200.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, "tent")
	idx.add_cylinder(0.0, 12.0, 0.5, 0.0, 3.0, "tree")
	idx.add_box(-6.0, 3.0, 0.5, 0.5, 0.0, 0.0, 1.0, "gear")
	idx.add_capsule(Vector3(0, 5, -10), Vector3(0, 5, -20), 0.1, "wire")
	var pts := idx.points_near(Vector2.ZERO, 20.0, PackedStringArray(["tent", "gear"]))
	check(pts.size() == 2, "палатка рядом и вещь: %d (дальняя и другие виды — нет)" % pts.size())
	for p in pts:
		check(p.z > 0.0, "радиус задан")
	var none := idx.points_near(Vector2.ZERO, 20.0, PackedStringArray(["bush"]))
	check(none.is_empty(), "нет такого вида — пусто")
	var far := idx.points_near(Vector2(200, 0), 1.0, PackedStringArray(["tent"]))
	check(far.size() == 1, "дальняя палатка в своём круге")
	idx.remove_kind("tent")
	check(
		idx.points_near(Vector2.ZERO, 300.0, PackedStringArray(["tent"])).is_empty(),
		"после remove_kind пусто"
	)


## Боты и очередь в сети ждут вне палаток: набор препятствий включает палатки и вещи.
func test_k1_bots_avoid_tents() -> void:
	var cfg: Dictionary = WorldObjects.load_config().tents
	var start := Vector3(0, 50, 0)
	var camp := TentCamp.plan(start, 0.0, 5, cfg, _flat_env())
	var idx := ObstacleIndex.new()
	for t: Dictionary in camp:
		idx.add_box(t.position.x, t.position.z, 1.5, 1.5, 0.0, 49.0, 52.0, "tent")
	var obs: Array = idx.points_near(Vector2.ZERO, 110.0, PackedStringArray(["tent", "gear"]))
	check(obs.size() == camp.size(), "палатки в запросе: %d" % obs.size())
	var lc: Dictionary = Config.get_config("bots").get("launch", {})
	var spots := BotPilots.find_spots(
		func(_x: float, _z: float) -> float: return 50.0, start, 0.0, 12, lc, obs
	)
	var net := NetQueue.spots_for(
		func(_x: float, _z: float) -> float: return 50.0, start, 0.0, 13, obs
	)
	check(net.size() == 13 and spots.size() == 12, "места есть")
	for sp: Dictionary in spots:
		for o: Vector3 in obs:
			check(
				Vector2(sp.position.x, sp.position.z).distance_to(Vector2(o.x, o.z)) >= o.z,
				"бот не в палатке"
			)
