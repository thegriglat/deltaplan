extends Node
## Пасхалка E10 «другая группа на дальнем склоне» (К9): где появляется, боты в воздухе над тем
## склоном, подшаги 1/120 с и предел догона, боты игры и ключ мира не меняются.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_group

const MAIN_SCENE := preload("res://scenes/main.tscn")
const LOCATIONS := ["altai", "askarovo", "aushkul", "ongudai"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Место с заданными стартами и ровной землёй на высоте 0.
class Place:
	extends EggPlace
	var sites: Array[Dictionary] = []

	func start_sites() -> Array[Dictionary]:
		return sites.duplicate(true)

	func height_at(_x: float, _z: float) -> float:
		return 0.0


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.group


func _site(id: String, x: float, z: float, hdg: float) -> Dictionary:
	return {"id": id, "position": Vector3(x, 0.0, z), "heading_deg": hdg}


## Игрок на старте A (0, 0, курс 0); B — в 5 км, курс 10; C — в 1 км, курс 0.
func _ctx() -> EggContext:
	var pl := Place.new()
	pl.sites = [_site("A", 0, 0, 0), _site("B", 5000, 0, 10), _site("C", 0, -1000, 0)]
	var c := EggContext.new()
	c.place = pl
	c.world_key = "G"
	c.sun_elev_deg = 40.0
	c.sky = "partly"
	c.wind_ms = 4.0
	c.wind_from_deg = 0.0
	c.height_at = pl.height_at
	c.pilot_pos = Vector3(0.0, 50.0, 0.0)
	return c


func _spawn(c: EggContext, seed_i: int, t0 := 0.0) -> EggGroup:
	var e := EggGroup.new()
	add_child(e)
	var rng := RandomNumberGenerator.new()
	rng.seed = ("G|%d" % seed_i).hash()
	e.begin(c, _cfg(), rng, t0)
	e.update(c)
	return e


func test_conditions() -> void:
	var cfg := _cfg()
	var c := _ctx()
	check(EggGroup.can_appear(c, cfg), "дальний старт B и ветер на него: можно")
	var far := EggGroup.far_sites(c, cfg, true)
	check(far.size() == 1 and far[0].id == "B", "кандидат — только B (C ближе 2 км)")
	c.wind_from_deg = 180.0
	check(not EggGroup.can_appear(c, cfg), "ветер не на тот склон: нельзя")
	c.wind_from_deg = 70.0
	check(not EggGroup.can_appear(c, cfg), "ветер 60° к курсу B: нельзя")
	c.wind_from_deg = 50.0
	check(EggGroup.can_appear(c, cfg), "ветер 40° к курсу B: можно")
	c.wind_ms = 0.5
	c.wind_from_deg = 180.0
	check(EggGroup.can_appear(c, cfg), "штиль: склон не важен")
	c = _ctx()
	c.sky = "overcast"
	check(not EggGroup.can_appear(c, cfg), "сплошная облачность: нельзя")
	c = _ctx()
	c.sun_elev_deg = 3.0
	check(not EggGroup.can_appear(c, cfg), "солнце низко: нельзя")
	c = _ctx()
	c.wind_ms = 12.0
	check(not EggGroup.can_appear(c, cfg), "сильный ветер: нельзя")
	c = _ctx()
	(c.place as Place).sites = [_site("A", 0, 0, 0), _site("C", 0, -1000, 0)]
	check(not EggGroup.can_appear(c, cfg), "только ближние старты: нельзя")
	c.place = null
	check(not EggGroup.can_appear(c, cfg), "нет места: нельзя")


## Реальные локации: для каждого старта игрока с «ветром в старт» — есть ли дальний.
func test_real_locations() -> void:
	var cfg := _cfg()
	var found := {}
	for id in LOCATIONS:
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var pl := EggPlace.build(t, null)
		var c := EggContext.new()
		c.place = pl
		c.sun_elev_deg = 40.0
		c.wind_ms = 4.0
		var lines: PackedStringArray = []
		var n_ok := 0
		var sites := pl.start_sites()
		for s in sites:
			c.pilot_pos = (s.position as Vector3) + Vector3.UP * 30.0
			c.wind_from_deg = float(s.heading_deg)  # ветер в старт игрока (умолчание игры)
			var far := EggGroup.far_sites(c, cfg, false)
			var ok := EggGroup.can_appear(c, cfg)
			n_ok += int(ok)
			var dd: PackedStringArray = []
			for f in far:
				var d := Vector2(f.position.x - s.position.x, f.position.z - s.position.z)
				dd.append("%s %.1f км %.0f°" % [f.id, d.length() / 1000.0, EggGroup.wind_angle(c, f)])
			lines.append("%s → %s%s" % [s.id, ", ".join(dd), "  ГРУППА" if ok else ""])
		found[id] = n_ok
		print("         %-9s стартов %d, с группой %d" % [id, sites.size(), n_ok])
		for l in lines:
			print("            " + l)
		t.free()
	check(int(found.ongudai) == 0, "ongudai (один старт): никогда")
	check(int(found.altai) > 0, "altai: есть старт с дальней группой")
	check(int(found.askarovo) > 0, "askarovo: есть старт с дальней группой")


func test_bots_airborne_over_far_slope() -> void:
	var counts := {}
	for sd in 8:
		var c := _ctx()
		var e := _spawn(c, sd)
		var n := e.bot_count()
		counts[n] = int(counts.get(n, 0)) + 1
		check(n >= 1 and n <= 3, "ботов 1–3: %d" % n)
		check(e.site.get("id", "") == "B", "группа над стартом B")
		check(e.bots.get_parent() == e, "BotPilots — дочерний узел пасхалки")
		for k in 240:  # 2 с подшагами по 1/120 с за «кадр» в 1/60 с
			c.t = (k + 1) / 120.0 * 2.0
			e.update(c)
		check(e.substeps_done == 480, "подшаги: floor(t·120) = %d" % e.substeps_done)
		for a in e.bots.agents:
			var p := a.model.position
			check(a.is_airborne(), "бот %d в воздухе" % a.id)
			check(p.y > 100.0, "бот %d выше 100 м над землёй: %.0f" % [a.id, p.y])
			var d := Vector2(p.x - 5000.0, p.z).length()
			check(d < 1500.0, "бот %d над склоном B: %.0f м" % [a.id, d])
		e.free()
	print("         числа ботов по сидам: %s" % counts)
	check(counts.size() >= 2, "число ботов зависит от rng")


func test_deterministic_and_catchup() -> void:
	var c1 := _ctx()
	var c2 := _ctx()
	var e1 := _spawn(c1, 5)
	var e2 := _spawn(c2, 5)
	check(e1.bot_count() == e2.bot_count(), "тот же rng — то же число")
	for k in 120:
		c1.t = k / 60.0
		c2.t = c1.t
		e1.update(c1)
		e2.update(c2)
	var same := true
	for i in e1.bot_count():
		same = same and e1.bots.agents[i].model.position == e2.bots.agents[i].model.position
	check(same, "тот же rng и время — те же положения ботов")
	# прыжок времени на 100 с: догон не больше 0,5 с
	var before := e1.bots.sim_time_s
	c1.t += 100.0
	e1.update(c1)
	var adv := e1.bots.sim_time_s - before
	check(adv <= 0.5 + 1.0e-6 and adv > 0.4, "прыжок: догнали ≤ 0,5 с (%.3f)" % adv)
	check(e1.substeps_done == floori(c1.t * 120.0), "после прыжка — на текущем подшаге")
	e1.free()
	e2.free()


func test_no_place_empty() -> void:
	var c := _ctx()
	c.place = null
	var e := _spawn(c, 1)
	check(e.bots == null and e.bot_count() == 0, "без места — пусто")
	c.t = 10.0
	check(e.update(c), "без места — жива")
	e.free()
	c = _ctx()
	(c.place as Place).sites = [_site("A", 0, 0, 0)]
	e = _spawn(c, 1)
	check(e.bot_count() == 0, "один старт (форс) — пусто")
	e.free()
	c = _ctx()
	c.wind_from_deg = 180.0
	e = _spawn(c, 1)
	check(e.site.get("id", "") == "B", "форс без условий: лучший по ветру дальний старт")
	e.free()


## Полёт 30 с на altai со старта sinyukha_east (дальний — tugaya_south, ветер в старт): журнал
## раз в 1 с (крыло, боты игры, воздух в 4 точках); with_group — force("group").
func _flight(with_group: bool) -> Dictionary:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	var fs := FlightSettings.defaults()
	fs.location_id = "altai"
	fs.site_id = "sinyukha_east"
	await main.call("_fly", fs)
	game.autopilot = Autopilot.new()
	game.restart()
	game.eggs.enabled = with_group
	# в прогоне B — только группа (остальные пасхалки выключены, их проверяет К7)
	for k in game.eggs._egg_ids():
		(game.eggs.cfg.eggs[k] as Dictionary)["enabled"] = false
	var key := game.world_key()
	if with_group:
		game.eggs.force("group")
	var st: Vector3 = game.get_start().position
	var pts: Array[Vector3] = []
	for i in 4:
		pts.append(st + Vector3(60.0 * i, 30.0 + 300.0 * i, -80.0 * i))
	var rec: Array = []
	for i in 120 * 30:
		game.tick(1.0 / 120.0)
		if i % 4 == 0:
			game.eggs.update()
		if i % 120 == 119:
			var tel := game.glider.get_telemetry()
			var bp: Array = []
			for b in game.bots.agents:
				bp.append(b.model.position)
			var av: Array = []
			for p in pts:
				av.append(game.air.air_velocity_at(p))
			rec.append([tel.position, tel.velocity, tel.basis, bp, av])
	var out := {
		"rec": rec,
		"bots": game.bots.agents.size(),
		"key": key,
		"key_end": game.world_key(),
		"group": null,
	}
	var groups := game.eggs.active().filter(func(x: EasterEgg) -> bool: return x.id == "group")
	if groups.size() == 1:
		var g: EggGroup = groups[0]
		var air := 0
		var foreign := 0
		for a in g.bots.agents:
			air += int(a.is_airborne())
			foreign += int(game.bots.agents.has(a))
		var d := Vector2(g.site.position.x - st.x, g.site.position.z - st.z).length()
		out.group = {
			"n": g.bot_count(),
			"air": air,
			"foreign": foreign,
			"site": g.site.id,
			"dist": d,
			"own": g.bots.get_parent() == g and g.bots != game.bots,
			"substeps": g.substeps_done,
			"sim_t": g.bots.sim_time_s,
		}
	game.autopilot.release_all()
	main.queue_free()
	for i in 3:
		await get_tree().process_frame
	return out


## Игра: группа — не в game.bots, число ботов игры и ключ мира те же, физика побитно та же.
func test_game_bots_untouched() -> void:
	var a := await _flight(false)
	var b := await _flight(true)
	var g: Variant = b.group
	check(g != null, "группа появилась")
	if g != null:
		print(
			(
				"         игра: старт группы %s в %.1f км, ботов %d, в воздухе %d, подшагов %d, t ботов %.2f с"
				% [g.site, g.dist / 1000.0, g.n, g.air, g.substeps, g.sim_t]
			)
		)
		check(int(g.n) >= 1 and int(g.air) >= 1, "боты группы летают")
		check(int(g.foreign) == 0, "боты группы не в game.bots")
		check(bool(g.own), "свой BotPilots — дочерний узел пасхалки")
		check(String(g.site) == "tugaya_south" and float(g.dist) >= 2000.0, "старт группы дальний")
	check(int(b.bots) == int(a.bots), "ботов игры столько же: %d / %d" % [b.bots, a.bots])
	check(b.key == a.key and b.key_end == a.key, "ключ мира тот же")
	var ra: Array = a.rec
	var rb: Array = b.rec
	var diff := ""
	if ra.size() != rb.size():
		diff = "размеры %d / %d" % [ra.size(), rb.size()]
	for i in mini(ra.size(), rb.size()):
		if ra[i] != rb[i]:
			diff = "t≈%d с" % (i + 1)
			break
	check(ra.size() == 30, "журнал записан (%d)" % ra.size())
	check(diff == "", "с группой физика игрока, боты игры и воздух те же побитно: " + diff)
