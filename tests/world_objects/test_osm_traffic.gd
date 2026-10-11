extends TestCase
## Трафик на дорогах OSM (OsmTraffic) на синтетических дорогах: продолжение по общей точке (самое прямое,
## в том числе в середине другой дороги и назад по ней), тупик → разворот, торможение перед 90°,
## следование без сближения и обгона с учётом длин, перестановка вышедших за радиус в кольцо, время шага.

func _cfg() -> Dictionary:
	return Config.get_config("world_objects")


func _flat(_x: float, _z: float) -> float:
	return 100.0


func _road(t: String, pts: Array) -> Dictionary:
	var p := PackedVector2Array()
	for q: Vector2 in pts:
		p.append(q)
	return {"t": t, "p": p}


func _net(roads: Array, auto: bool = false, groups: int = 1) -> OsmTraffic:
	var cfg := _cfg().duplicate(true)
	cfg.osm_traffic.update_groups = groups
	var n := OsmTraffic.make_for_test(roads, cfg, _flat)
	n.auto = auto
	return n


func test_straightest_continuation_at_shared_point() -> void:
	# A кончается в (200,0); там же середина дороги F, идущей из (400,-100) через (200,0) к (100,60):
	# вперёд по F — поворот ~149° (нельзя), назад по F (к (300,-30)) — ~6°. И поперечная B (90°).
	var roads := [
		_road("primary", [Vector2(0, 0), Vector2(200, 0)]),
		_road("primary", [Vector2(400, -100), Vector2(300, -30), Vector2(200, 0), Vector2(100, 60)]),
		_road("primary", [Vector2(200, -300), Vector2(200, -150), Vector2(200, 0), Vector2(200, 150)]),
	]
	var t := _net(roads)
	var c := t.spawn_at(0, 0, 1, 50.0, 10.0, 15.0)
	check(c != null and c.next_road == 1, "выбрана F, а не поперечная B: %d" % (c.next_road if c else -9))
	check(c.next_dir == -1, "по F едем назад (к (300,-30))")
	# машина едет в обратную сторону A (dir -1): конец в (0,0) — продолжения нет → тупик
	var c2 := t.spawn_at(0, 0, -1, 50.0, 10.0, 15.0)
	check(c2.next_road == -1, "в (0,0) продолжения нет")
	t.free()


func test_dead_end_uturn() -> void:
	var t := _net([_road("primary", [Vector2(0, 0), Vector2(300, 0)])])
	var c := t.spawn_at(0, 0, 1, 200.0, 12.0, 14.0)
	var flipped := false
	var v_at_flip := 99.0
	for i in 2400:
		t.advance(0.05, Vector3.ZERO)
		check(c.s <= 300.0 + 1e-3, "не выехала за конец")
		if c.dir < 0:
			flipped = true
			v_at_flip = c.v
			break
	check(flipped, "развернулась в тупике")
	check(v_at_flip < 0.5, "разворот на остановке, v=%.2f" % v_at_flip)
	for i in 100:
		t.advance(0.05, Vector3.ZERO)
	check(c.dir < 0 and c.s < 299.0, "поехала обратно")
	t.free()


func test_slow_before_90_turn_not_before_straight() -> void:
	var turn := _net([
		_road("primary", [Vector2(0, 0), Vector2(400, 0)]),
		_road("primary", [Vector2(400, 0), Vector2(400, 400)]),
	])
	var c := turn.spawn_at(0, 0, 1, 0.0, 20.0, 20.0)
	var v_near := 99.0
	var entered := false
	for i in 4000:
		turn.advance(0.05, Vector3.ZERO)
		if c.road == 0 and 400.0 - c.s < 1.5:
			v_near = minf(v_near, c.v)
		if c.road == 1:
			entered = true
			break
	check(entered, "въехала на вторую дорогу")
	check(v_near < 7.5, "перед 90° скорость мала (~20 км/ч=5.6): %.2f" % v_near)
	turn.free()
	var straight := _net([
		_road("primary", [Vector2(0, 0), Vector2(400, 0)]),
		_road("primary", [Vector2(400, 0), Vector2(800, 5)]),
	])
	var c2 := straight.spawn_at(0, 0, 1, 0.0, 20.0, 20.0)
	var v_min := 99.0
	for i in 2000:
		straight.advance(0.05, Vector3.ZERO)
		if c2.road == 1:
			break
		if c2.s > 100.0:
			v_min = minf(v_min, c2.v)
	check(c2.road == 1, "прямое продолжение пройдено")
	check(v_min > 19.0, "прямо без снижения: %.2f" % v_min)
	straight.free()


func _follow(lead_type: int) -> Array:
	var t := _net([_road("primary", [Vector2(0, 0), Vector2(9000, 0)])])
	var lead := t.spawn_at(lead_type, 0, 1, 150.0, 8.0, 8.0)
	var fol := t.spawn_at(0, 0, 1, 0.0, 30.0, 30.0)
	var min_gap := 1e9
	var passed := false
	for i in 3600:
		t.advance(0.05, Vector3.ZERO)
		var g := lead.s - fol.s - 0.5 * (lead.length + fol.length)
		min_gap = minf(min_gap, g)
		if fol.s >= lead.s:
			passed = true
	var res := [min_gap, lead.s - fol.s, passed, fol.v]
	t.free()
	return res


func test_follow_no_closing_no_overtake_lengths() -> void:
	var a := _follow(0)  # легковушка впереди
	var b := _follow(2)  # грузовик впереди (9 м)
	check(not a[2] and not b[2], "обгона нет")
	check(a[0] > 3.0 and b[0] > 3.0, "зазор бампер-бампер не меньше 3 м: %.2f / %.2f" % [a[0], b[0]])
	approx(a[3], 8.0, 0.6, "идёт за ведущей со скоростью ведущей")
	# установившийся зазор бампер-бампер одинаков, значит расстояние между центрами больше на разность длин/2
	approx(float(b[1]) - float(a[1]), 0.5 * (9.0 - 4.2), 0.5, "длины учтены в дистанции")


func test_respawn_into_ring_outside_radius() -> void:
	var t := _net([_road("primary", [Vector2(-9000, 0), Vector2(9000, 0)])], true, 3)
	var R := float(_cfg().osm_traffic.radius_m)
	var cen := Vector3(3000, 100, 0)
	for i in 3:
		t.advance(0.05, cen)
	var n0 := t.active_count()
	check(n0 > 10, "машины появились в радиусе: %d" % n0)
	var far := 0
	for c in t.cars:
		if c.active and absf(c.pos.x - cen.x) > R:
			far += 1
	check(far == 0, "никого за радиусом")
	var cen2 := Vector3(4200, 100, 0)  # улетели на 1200 м < 1.5 R: машины перетекают
	for i in 3:
		t.advance(0.05, cen2)
	var ring := 0
	var out := 0
	for c in t.cars:
		if not c.active:
			continue
		var d := absf(c.pos.x - cen2.x)
		if d > R * 1.06:
			out += 1
		if d >= 0.78 * R:
			ring += 1
	check(out == 0, "все в радиусе после перелёта: вне %d" % out)
	check(ring > 3, "переставленные у дальней границы: %d" % ring)
	check(t.active_count() <= int(_cfg().osm_traffic.max_cars), "не больше max_cars")
	t.free()


func test_update_time_200_cars() -> void:
	var roads: Array = []
	for i in 40:
		roads.append(_road("primary", [Vector2(-1400, -1000 + i * 50), Vector2(1400, -1000 + i * 50 + 10)]))
	for i in 20:
		roads.append(_road("secondary", [Vector2(-1000 + i * 100, -1400), Vector2(-1000 + i * 100, 1400)]))
	var t := _net(roads, true, 3)
	for i in 5:
		t.advance(0.03, Vector3.ZERO)
	var n := t.active_count()
	var tot := 0.0
	var steps := 200
	for i in steps:
		t.advance(0.03, Vector3.ZERO)
		tot += t.frame_ms()
	print("[osm_traffic] машин %d, шаг %.3f мс (без MultiMesh)" % [n, tot / steps])
	check(n >= 150, "много машин: %d" % n)
	check(tot / steps < 1.0, "шаг %.3f мс" % (tot / steps))
	t.free()
