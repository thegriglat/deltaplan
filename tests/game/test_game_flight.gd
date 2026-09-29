extends Node
## Интеграция: главная сцена грузится, синтетический пилот (Autopilot жмёт клавиши InputMap)
## стоит → разбегается (Shift) → взлетает → летит 30 с. В логе нет ошибок.
## Шаги физики — Game.tick() вручную (тот же порядок, что в игре), поэтому тест быстрый.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const FLIGHT_S := 30.0
const LONG_S := 300.0
const MAX_GROUND_S := 15.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_main_scene_autopilot_flight() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	# Меню мир больше не грузит — загрузить, как раньше за меню.
	await main.call("load_menu_world")
	check(game.settings != null, "мир за меню загружен")
	check(main.get_node("UI/StartMenu").visible, "меню видно")
	if game.settings == null:
		await _finish(main, catcher)
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	var s := FlightSettings.defaults()  # то, что увидит пилот при первом запуске
	(main.get("opts") as LaunchOptions).autostart = true  # не запоминать выбор в user://
	await main.call("_fly", s)
	check(main.get("state") == 2, "состояние FLYING после «Лететь»")
	check(game.air is Atmosphere, "настоящая атмосфера (%s)" % game.air.get_script())
	check(not game.mounted.is_empty() and game.mounted[0].is_inside_tree(), "прибор на трапеции")
	game.autopilot = Autopilot.new()
	game.restart()

	var phases := {}
	var anims := {}
	var ended: Array = []
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))
	var t_air := 0.0
	var t := 0.0
	while t < MAX_GROUND_S + FLIGHT_S + 5.0 and ended.is_empty():
		game.tick(DT)
		t += DT
		var ph := game.glider.phase()
		phases[ph] = true
		anims[game.get("_animator").current()] = true
		if ph == "flying":
			t_air += DT
			if t_air >= FLIGHT_S:
				break
		elif t > MAX_GROUND_S and t_air == 0.0:
			break
	var tel := game.glider.get_telemetry()
	print(
		(
			"         фазы %s, в воздухе %.1f с, AGL %.0f м, V %.0f км/ч, от старта %.0f м"
			% [
				phases.keys(),
				t_air,
				tel.altitude_agl,
				Units.to_kmh(tel.airspeed),
				game.stats.distance_from_takeoff(tel.position)
			]
		)
	)
	print("         анимации пилота: %s" % [anims.keys()])
	if (game.get("_animator") as PilotAnimator).player != null:
		for a in ["stand", "run", "run_air", "climb_in", "prone"]:
			check(anims.has(a), "анимация %s" % a)
	check(phases.has("standing"), "стоял на старте")
	check(phases.has("running"), "разбегался")
	check(ended.is_empty(), "полёт не закончился раньше времени: %s" % [ended])
	check(t_air >= FLIGHT_S, "летел %.0f с (нужно %.0f)" % [t_air, FLIGHT_S])
	check(game.stats.took_off, "статистика увидела взлёт")
	check(game.instrument.get_vario().in_flight, "прибор считает полёт")
	check(game.stats.distance_from_takeoff(tel.position) > 150.0, "улетел от старта")
	game.autopilot.release_all()
	await _finish(main, catcher)


func test_landing_shows_result_screen() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	(main as Node).set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	# Низко над склоном, носом в гору: через пару секунд — касание.
	var st := game.get_start()
	var p: Vector3 = st.position
	p.y = game.terrain.height_at(p.x, p.z) + 3.0
	game.glider.reset_in_air(p, float(st.heading_deg) + 180.0)
	var ended: Array = []
	game.flight_ended.connect(func(k: String, _i: Dictionary) -> void: ended.append(k))
	for i in 120 * 20:
		game.tick(DT)
		if not ended.is_empty():
			break
	check(ended == ["landed"], "посадка: %s" % [ended])
	await get_tree().create_timer(float(Config.value("game", "result_delay_s")) + 0.3).timeout
	var rs: Control = main.get_node("UI/ResultScreen")
	check(rs.visible, "экран итога показан")
	check(get_tree().paused, "игра на паузе под экраном итога")
	main.call("_restart")
	check(not get_tree().paused and not rs.visible, "«Ещё раз» — снова в полёте")
	check(game.glider.phase() == "standing", "на старте")
	get_tree().paused = false
	main.queue_free()
	await _settle()


## --air-start: сразу в полёте в 1000 м от старта по его курсу на ~300 м над рельефом,
## на скорости трима; полёт «взведён» (не «взлёт сорван»), «Ещё раз» — снова в воздухе.
func test_air_start() -> void:
	var o := LaunchOptions.parse(PackedStringArray(["--air-start"]))
	check(o.air_start_m == 1000.0 and o.air_start_agl_m == 300.0, "--air-start: 1000 м / 300 м")
	o = LaunchOptions.parse(PackedStringArray(["--autostart", "--air-start=600,150"]))
	check(o.air_start_m == 600.0 and o.air_start_agl_m == 150.0, "--air-start=600,150")
	check(LaunchOptions.parse(PackedStringArray([])).air_start_m < 0.0, "без флага — с земли")
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", o)
	var game: Game = main.get_node("Game")
	add_child(main)
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	for round_i in 2:
		var tel := game.glider.get_telemetry()
		var st := game.get_start()
		var d := Vector2(tel.position.x - st.position.x, tel.position.z - st.position.z)
		var h := deg_to_rad(float(st.heading_deg))
		check(game.glider.phase() == "flying", "сразу в полёте")
		check(absf(d.length() - 600.0) < 1.0, "в 600 м от старта: %.0f" % d.length())
		check(d.normalized().dot(Vector2(sin(h), -cos(h))) > 0.999, "по курсу старта")
		check(absf(tel.altitude_agl - 150.0) < 1.0, "150 м над рельефом: %.0f" % tel.altitude_agl)
		var trim := game.glider.model.trim_speed()
		check(absf(tel.airspeed - trim) < 1.0, "скорость трима %.1f / %.1f" % [tel.airspeed, trim])
		for i in 120 * 3:
			game.tick(DT)
		check(game.glider.phase() == "flying", "летит 3 с")
		check(game.stats.armed, "полёт взведён — касание будет посадкой")
		game.restart()
	main.queue_free()
	await _settle()


## После удаления сцены: 2 кадра и ~100 мс — аудиосервер отпускает генераторы звука.
func _settle() -> void:
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


## W+Shift зажаты весь разбег и ещё 3 с после отрыва: защёлка не даёт W разогнать крыло
## в пике — высота над землёй не падает, полёт продолжается.
func test_takeoff_with_held_keys_latch() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED
	game.autopilot.hold_after_takeoff_s = 3.0
	game.restart()
	var agl0 := -1.0
	var min_agl := INF
	var air_t := 0.0
	var latched_seen := false
	for i in 120 * 20:
		game.tick(DT)
		var t := game.glider.get_telemetry()
		if t.phase == "flying":
			if agl0 < 0.0:
				agl0 = t.altitude_agl
			air_t += DT
			latched_seen = latched_seen or game.input_controller.is_latched("pitch_pull_in")
			if air_t > 0.5:
				min_agl = minf(min_agl, t.altitude_agl)
			if air_t >= 3.0:
				break
	var agl3 := game.glider.get_telemetry().altitude_agl
	var pitch3 := game.input_controller.control.pitch
	print(
		(
			"         защёлка: AGL при отрыве %.1f, мин. 0,5–3 с %.1f, через 3 с %.1f м; трапеция %.2f"
			% [agl0, min_agl, agl3, pitch3]
		)
	)
	check(agl0 >= 0.0, "взлетел с зажатыми W+Shift")
	check(latched_seen, "W после отрыва защёлкнута")
	check(air_t >= 3.0, "летит 3 с после отрыва")
	check(min_agl >= agl0 - 0.2, "не пикирует: высота над землёй не падает")
	check(agl3 > 2.0, "через 3 с набрал высоту над склоном (%.1f м)" % agl3)
	game.autopilot.release_all()
	main.queue_free()
	await _settle()


## 5 минут автополёта (с посадкой, если она случится) — в логе ни одной ошибки.
func test_long_autoflight_no_errors() -> void:
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var air_t := 0.0
	for i in int(LONG_S / DT):
		game.tick(DT)
		if game.glider.phase() == "flying":
			air_t += DT
	print("         5 мин: в воздухе %.0f с, фаза %s" % [air_t, game.glider.phase()])
	check(air_t > 20.0, "взлетел и летел")
	game.autopilot.release_all()
	await _finish(main, catcher)


func _finish(main: Node, catcher: ErrorCatcher) -> void:
	main.queue_free()
	await _settle()
	OS.remove_logger(catcher)
	for e in catcher.errors:
		failures.append("ошибка в логе: " + e)
