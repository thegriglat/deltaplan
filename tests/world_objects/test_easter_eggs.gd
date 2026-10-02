extends Node
## Каркас пасхалок (docs/contracts/easter-eggs.md → К7): не трогает физику (побитно), жизнь,
## запреты, расписание, конфиг, меню. Каждая новая пасхалка из configs/easter_eggs.json попадает
## в эти проверки сама (force("all") включает только enabled; проба форсится по имени).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const FLIGHT_S := 90.0
const SRC_DIR := "res://scripts/world_objects/easter_eggs"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Контекст без игры (тесты планировщика отдельно от мира).
func _ctx(t: float, key := "K") -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = key
	c.pilot_pos = Vector3(0.0, 500.0, 0.0)
	return c


func _eggs(overrides := {}) -> EasterEggs:
	var e := EasterEggs.new()
	e.cfg = Config.get_config("easter_eggs").duplicate(true)
	for k in overrides:
		(e.cfg.eggs.probe as Dictionary)[k] = overrides[k]
	add_child(e)
	return e


func _settle(n := 3) -> void:
	for i in n:
		await get_tree().process_frame


# ---------------------------------------------------------------- 1. физика побитно


## Лётный прогон 90 с: журнал (крыло, боты, воздух) раз в секунду. with_eggs — force("all") + проба.
func _flight(with_eggs: bool) -> Dictionary:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", FlightSettings.defaults())
	game.autopilot = Autopilot.new()
	game.restart()
	if with_eggs:
		game.eggs.enabled = true
		game.eggs.force("all")
		game.eggs.force("probe")
		game.eggs.force("probe", 45.0)
	else:
		game.eggs.enabled = false
	var key_start := game.world_key()
	var start: Vector3 = game.get_start().position
	var pts: Array[Vector3] = []
	for i in 8:
		var a := TAU * i / 8.0
		var p: Vector3 = start + Vector3(cos(a), 0.0, sin(a)) * 40.0 * i
		p.y = (
			game.terrain.height_at(p.x, p.z)
			+ [0.0, 20.0, 60.0, 150.0, 400.0, 800.0, 1200.0, 1500.0][i]
		)
		pts.append(p)
	var rec: Array = []
	var steps := int(FLIGHT_S / DT)
	var alive_max := 0
	for i in steps:
		game.tick(DT)
		if i % 4 == 0:
			game.eggs.update()
			alive_max = maxi(alive_max, game.eggs.active().size())
		if i % 120 == 119:
			var tel := game.glider.get_telemetry()
			rec.append([tel.position, tel.velocity, tel.basis, tel.airspeed, tel.phase])
			var bp: Array = []
			for b in game.bots.agents:
				bp.append(b.model.position)
			rec.append(bp)
			var av: Array = []
			for p in pts:
				av.append(game.air.air_velocity_at(p))
			rec.append(av)
	var out := {
		"rec": rec,
		"spawned": game.eggs.spawn_log.size(),
		"alive_max": alive_max,
		"key_start": key_start,
		"key_end": game.world_key(),
		"bots": game.bots.agents.size(),
	}
	game.autopilot.release_all()
	main.queue_free()
	await _settle()
	return out


func _first_diff(a: Array, b: Array) -> String:
	if a.size() != b.size():
		return "размеры %d / %d" % [a.size(), b.size()]
	for i in a.size():
		if a[i] != b[i]:
			return "запись %d (t≈%d с): %s ≠ %s" % [i, i / 3 + 1, a[i], b[i]]
	return ""


func test_physics_bitwise_same() -> void:
	var a1 := await _flight(false)
	var a2 := await _flight(false)
	var base_diff := _first_diff(a1.rec, a2.rec)
	check(base_diff == "", "база: два прогона без пасхалок совпадают побитно: " + base_diff)
	check((a1.rec as Array).size() > 200, "журнал записан (%d)" % (a1.rec as Array).size())
	check(a1.spawned == 0, "в прогоне A пасхалок нет")
	if base_diff != "":
		return  # шлюз координатору: без базы сравнивать нечего
	var b := await _flight(true)
	check(int(b.spawned) >= 2, "в прогоне B пасхалки появились (%d)" % int(b.spawned))
	check(int(b.alive_max) >= 1, "и были живы в дереве")
	# К9 (v5): пасхалки не добавляют ботов в game.bots и не меняют ключ мира
	check(int(b.bots) == int(a1.bots), "ботов игры столько же: %d / %d" % [b.bots, a1.bots])
	check(
		b.key_start == a1.key_start and b.key_end == a1.key_start,
		"ключ мира тот же: %s → %s / %s" % [b.key_start, b.key_end, a1.key_start]
	)
	var d := _first_diff(a1.rec, b.rec)
	check(d == "", "с пасхалками физика та же побитно: " + d)
	print("         B: появлений %d, одновременно ≤ %d" % [b.spawned, b.alive_max])


# ---------------------------------------------------------------- 2. жизнь


func test_lifecycle() -> void:
	var e := _eggs()
	var ids: Array = e._egg_ids()
	check(ids.has("probe"), "проба в конфиге")
	# случайные появления (interval, per_flight) не должны подменять проверяемую force-пасхалку:
	# все выключены, а force по имени работает и для выключенных (К6)
	for k in ids:
		(e.cfg.eggs[k] as Dictionary)["enabled"] = false
	for id in ids:
		e.reset()
		var t := 100.0
		e.step(_ctx(t))
		e.force(id)
		e.step(_ctx(t))
		var mine := e.active().filter(func(x: EasterEgg) -> bool: return x.id == id)
		check(not mine.is_empty(), "%s: force — появилась" % id)
		if mine.is_empty():
			continue
		check(mine[0].is_inside_tree(), "%s: в дереве" % id)
		var life := float(e._egg_cfg(id).get("lifetime_s", 0.0))
		var t_end := t
		if life > 0.0:
			while t_end < t + life + 5.0:
				t_end += 0.25
				e.step(_ctx(t_end))
				if e.active().filter(func(x: EasterEgg) -> bool: return x.id == id).is_empty():
					break
			check(
				t_end - t <= life + 1.0,
				"%s: удалена не позже lifetime_s+1 (%.2f/%.0f)" % [id, t_end - t, life]
			)
			check(
				(
					e.get_child_count() == 0
					or e.active().filter(func(x: EasterEgg) -> bool: return x.id == id).is_empty()
				),
				"%s: ушла из дерева" % id
			)
		else:
			e.step(_ctx(t + 3600.0))
			check(
				not e.active().filter(func(x: EasterEgg) -> bool: return x.id == id).is_empty(),
				"%s: постоянная живёт" % id
			)
		e.reset()
		check(e.get_child_count() == 0, "%s: reset() убрал всех" % id)
	e.queue_free()


# ---------------------------------------------------------------- 3. запреты


func _walk(n: Node, out: Array) -> void:
	for c in n.get_children():
		out.append(c)
		_walk(c, out)


func test_forbidden() -> void:
	var e := _eggs()
	e.step(_ctx(50.0))
	e.force("all")
	e.force("probe")
	for i in 5:
		e.step(_ctx(50.0 + i * 0.2))
	check(e.active().size() >= 1, "есть что проверять")
	var nodes: Array = []
	_walk(e, nodes)
	for n in nodes:
		var bad: bool = n is CollisionObject3D or n is CollisionShape3D or n is RayCast3D
		check(not bad, "запрещённый узел %s (%s)" % [n.name, n.get_class()])
	e.queue_free()
	# исходники: глобальный генератор (не через rng.)
	var re_fn := RegEx.create_from_string(
		"(?<![\\w.])(randf|randi|randf_range|randi_range|randfn|randomize|seed)\\s*\\("
	)
	var re_arr := RegEx.create_from_string("\\.(shuffle|pick_random)\\s*\\(")
	var d := DirAccess.open(SRC_DIR)
	check(d != null, "папка пасхалок есть")
	if d == null:
		return
	var n_files := 0
	for f in d.get_files():
		if not f.ends_with(".gd"):
			continue
		n_files += 1
		var lines := FileAccess.get_file_as_string(SRC_DIR.path_join(f)).split("\n")
		for i in lines.size():
			var code := lines[i].split("#")[0]
			if re_fn.search(code) != null or re_arr.search(code) != null:
				check(
					false, "%s:%d — глобальный генератор: %s" % [f, i + 1, lines[i].strip_edges()]
				)
	check(n_files >= 1, "исходники просмотрены (%d)" % n_files)


# ---------------------------------------------------------------- 4. расписание


func _schedule(e: EasterEggs, key: String, t_from: float, t_to: float, dt: float) -> Array:
	var t := t_from
	while t <= t_to:
		e.step(_ctx(t, key))
		t += dt
	var out: Array = []
	for s in e.spawn_log:
		out.append(float(s[1]))
	return out


func test_schedule() -> void:
	var ov := {"enabled": true, "mean_interval_s": 150}
	var life := 20.0
	var e1 := _eggs(ov)
	var l1 := _schedule(e1, "world-A", 0.0, 7200.0, 1.0 / 30.0)
	var e2 := _eggs(ov)
	var l2 := _schedule(e2, "world-A", 0.0, 7200.0, 5.0)
	check(l1.size() > 15, "за 2 часа набралось появлений (%d)" % l1.size())
	check(l1 == l2, "шаг 1/30 и 5 с — то же расписание (%d / %d)" % [l1.size(), l2.size()])
	# прыжок: сразу в середину, дальше шагами
	var e3 := _eggs(ov)
	var jump_t := 3600.5
	e3.step(_ctx(jump_t, "world-A"))
	var l3 := _schedule(e3, "world-A", jump_t + 5.0, 7200.0, 5.0)
	var want: Array = l1.filter(func(t0: float) -> bool: return t0 + life > jump_t)
	check(l3 == want, "прыжок времени — то же расписание (%d / %d)" % [l3.size(), want.size()])
	# другой ключ мира — другое расписание
	var e4 := _eggs(ov)
	var l4 := _schedule(e4, "world-B", 0.0, 7200.0, 5.0)
	check(l4 != l1, "другой ключ мира — другое расписание")
	# per_flight: один бросок, стабильный
	var pf := {"enabled": true, "mode": "per_flight", "chance": 1.0, "window_s": [100.0, 200.0]}
	var e5 := _eggs(pf)
	var l5 := _schedule(e5, "world-A", 0.0, 400.0, 1.0)
	check(
		l5.size() == 1 and l5[0] >= 100.0 and l5[0] <= 200.0,
		"per_flight: одно появление в окне %s" % [l5]
	)
	for e in [e1, e2, e3, e4, e5]:
		e.queue_free()


# ---------------------------------------------------------------- 5. конфиг


func _check_docs(d: Dictionary, path: String) -> void:
	check(d.has("_doc"), "%s: нет _doc" % path)
	for k in d:
		var ks := String(k)
		if ks == "_doc" or ks.ends_with("_doc"):
			continue
		if d[k] is Dictionary:
			_check_docs(d[k], path + "." + ks)
		else:
			check(d.has(ks + "_doc"), "%s.%s: нет %s_doc" % [path, ks, ks])


func test_config() -> void:
	var cfg := Config.get_config("easter_eggs")
	check(not cfg.is_empty(), "configs/easter_eggs.json грузится")
	_check_docs(cfg, "easter_eggs")
	var eggs: Dictionary = cfg.get("eggs", {})
	for id in eggs:
		if String(id).begins_with("_") or String(id).ends_with("_doc"):
			continue
		var b: Dictionary = eggs[id]
		check(String(b.get("mode", "")) in ["interval", "per_flight", "condition"], "%s: mode" % id)
		var path := String(b.get("script", ""))
		var sc: Script = load(path) if ResourceLoader.exists(path) else null
		check(sc != null, "%s: script грузится (%s)" % [id, path])
		if sc != null:
			var inst: Variant = sc.new()
			check(inst is EasterEgg, "%s: extends EasterEgg" % id)
			if inst is Node:
				(inst as Node).free()
		if String(b.get("mode", "")) == "interval":
			check(b.has("slot_s") and b.has("mean_interval_s"), "%s: slot_s/mean_interval_s" % id)
		check(b.has("lifetime_s"), "%s: lifetime_s" % id)


# ---------------------------------------------------------------- 6. меню


func test_menu_no_dice() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(not game.flying_enabled, "в меню")
	game.eggs.force("probe")
	game.eggs.force("all")
	for i in 50:
		game.tick(DT)
		game.eggs.update()
	check(game.eggs.get_child_count() == 0, "в меню детей нет")
	check(game.eggs.roll_count == 0, "в меню кубик не бросается (%d)" % game.eggs.roll_count)
	check(game.eggs.spawn_log.is_empty(), "и ничего не появилось")
	main.queue_free()
	await _settle()
