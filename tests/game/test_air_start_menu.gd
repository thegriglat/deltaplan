extends Node
## ASM-К2: старт в воздухе из настроек полёта — Game.start(s) ставит крыло над стартом по его курсу
## тем же путём, что --air-start; установившийся полёт без рывка и срыва (docs/contracts/air-start-menu.md).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const AGL := 200.0
const SETTLE_TICKS := 60  # 0,5 с

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _air_settings(wind_ms: float) -> FlightSettings:
	var s := FlightSettings.defaults()
	s.wind_speed_kmh = wind_ms * 3.6
	s.set_air_start(AGL)
	return s


func _boot() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--bots=0"])))
	add_child(main)
	for i in 900:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	return [main, main.get_node("Game")]


func _finish(main: Node) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


## Спокойный однородный воздух без поля (ASM-К2): ветер wind_ms на востоке, и снова постановка.
func _uniform_air(game: Game, wind_ms: float) -> void:
	game.glider.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3(wind_ms, 0.0, 0.0))
	game.restart()


func _steady(game: Game, tag: String) -> void:
	var st := game.get_start()
	var tel := game.glider.get_telemetry()
	var trim: float = float(game.glider.model.solve_trim().V)
	check(Vector2(tel.position.x - st.position.x, tel.position.z - st.position.z).length() < 1.0, "%s: над стартом" % tag)
	check(absf(tel.altitude_agl - AGL) < 1.0, "%s: высота %.1f" % [tag, tel.altitude_agl])
	check(absf(tel.airspeed - trim) < 1.0, "%s: скорость %.1f / трим %.1f" % [tag, tel.airspeed, trim])
	check(game.glider.phase() == "flying" and game.stats.armed, "%s: летит, взведён" % tag)
	var pitch0 := tel.pitch_deg
	var nmin := 10.0
	var n_early := 10.0
	var nmax := 0.0
	var vmin := 1e9
	var vmax := 0.0
	var pmax := 0.0
	var bmax := 0.0
	var stalled := false
	var phase_ok := true
	for i in 120 * 20:
		game.tick(DT)
		var t := game.glider.get_telemetry()
		if i >= SETTLE_TICKS:  # первые ~0,5 с — переходный провал n (см. отчёт ASM-1)
			nmin = minf(nmin, t.load_factor)
		else:
			n_early = minf(n_early, t.load_factor)
		nmax = maxf(nmax, t.load_factor)
		vmin = minf(vmin, t.airspeed)
		vmax = maxf(vmax, t.airspeed)
		pmax = maxf(pmax, absf(t.pitch_deg - pitch0))
		bmax = maxf(bmax, absf(t.bank_deg))
		stalled = stalled or t.stalled
		phase_ok = phase_ok and game.glider.phase() == "flying"
	check(vmin > trim * 0.95 and vmax < trim * 1.05, "%s: скорость %.1f..%.1f (трим %.1f)" % [tag, vmin, vmax, trim])
	check(pmax <= 3.0, "%s: тангаж ±%.2f°" % [tag, pmax])
	check(bmax < 2.0, "%s: крен %.2f°" % [tag, bmax])
	check(nmin >= 0.9 and nmax <= 1.1, "%s: n %.3f..%.3f" % [tag, nmin, nmax])
	check(n_early >= 0.75, "%s: провал n в первые 0,5 с %.3f" % [tag, n_early])
	check(not stalled, "%s: без срыва" % tag)
	check(phase_ok, "%s: фаза flying" % tag)


func test_air_start_from_settings() -> void:
	var r := await _boot()
	var main: Node = r[0]
	var game: Game = r[1]
	game.process_mode = Node.PROCESS_MODE_DISABLED
	for wind in [0.0, 6.0]:
		var ok: bool = await game.start(_air_settings(wind))
		check(ok, "start ветер %s" % wind)
		check(game.air_start_m == 0.0 and game.air_start_agl_m == AGL, "поля Game")
		_uniform_air(game, wind)
		_steady(game, "ветер %s" % wind)
		game.restart()
		_steady(game, "ветер %s, ещё раз" % wind)
	# с земли после воздуха — не «залипает»
	var ok2: bool = await game.start(FlightSettings.defaults())
	check(ok2 and game.air_start_m < 0.0, "наземные настройки — с земли")
	check(game.glider.phase() == "standing", "на земле")
	await _finish(main)


func test_air_start_flag_wins_and_training() -> void:
	var r := await _boot()
	var main: Node = r[0]
	var game: Game = r[1]
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.cli_air_start_m = 500.0
	game.cli_air_start_agl_m = 150.0
	await game.start(_air_settings(0.0))
	check(game.air_start_m == 500.0 and game.air_start_agl_m == 150.0, "--air-start главнее")
	game.cli_air_start_m = -1.0
	game.menu_air_allowed = false
	await game.start(_air_settings(0.0))
	check(game.air_start_m < 0.0, "тренировка — настройки воздуха не применяются")
	game.menu_air_allowed = true
	game.inspect_mode = true
	await game.start(_air_settings(0.0))
	check(game.air_start_m < 0.0, "осмотр карты — с земли")
	await _finish(main)


## Точный старт над водой/обрывом (ASM-К2): в воздухе принимается без вырубки поляны, с земли — отклоняется.
func test_exact_start_water_steep_in_air() -> void:
	var r := await _boot()
	var main: Node = r[0]
	var game: Game = r[1]
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var terrain: Terrain = game.terrain
	var b := terrain.detail_bounds().grow(-250.0)
	var found := {}
	var x := b.position.x
	while x < b.end.x and found.size() < 2:
		var z := b.position.y
		while z < b.end.y and found.size() < 2:
			var chk := StartSpot.check(terrain, x, z)
			if chk.reason in ["water", "steep"] and not found.has(chk.reason):
				found[chk.reason] = Vector2(x, z)
			z += 40.0
		x += 40.0
	check(not found.is_empty(), "на карте есть вода или обрыв")
	for reason: String in found:
		var q: Vector2 = found[reason]
		var ll := terrain.local_to_latlon(q.x, q.y)
		var s := FlightSettings.defaults()
		s.set_exact_start(ll.x, ll.y, 90.0)
		s.set_air_start(AGL)
		var n0: int = terrain._start_clearings.size()
		# Выбор старта без запуска полёта (game.start пересчитал бы поле ветра минутами)
		game.settings = s
		game._choose_air_start()
		game._choose_start()
		var st: Vector3 = game._start_pos
		check(game.air_start_m == 0.0 and game._exact_start, "%s: старт в воздухе принят" % reason)
		check(Vector2(st.x - q.x, st.z - q.y).length() < 1.0, "%s: точка та, что задана" % reason)
		check(terrain._start_clearings.size() == n0, "%s: поляна не вырублена" % reason)
		var g := FlightSettings.defaults()
		g.set_exact_start(ll.x, ll.y, 90.0)
		game.settings = g
		game._choose_air_start()
		game._choose_start()
		check(not game._exact_start, "%s: с земли точка отклонена" % reason)
	await _finish(main)
