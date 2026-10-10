extends Node
## 12-02. Сквозной тест свободного полёта на всех локациях (configs/locations/*.json, список —
## не хардкод): меню → «Полёт…» (FlightSetupScreen, выбор локации и первого старта) → «Готово»
## → «Лететь» (эмит кнопки) → разбег W+Shift (Autopilot, защёлка после отрыва) → 60 с по курсу
## от склона → снижение и посадка у точки посадки локации (landing_sites; если нет — у стартовой
## площадки, она гарантированно ровная) → ResultScreen. Физика — Game.tick() вручную (быстро
## и детерминированно, как в tests/game/test_game_flight.gd).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAX_TAKEOFF_S := 15.0
const HOLD_COURSE_S := 60.0
const MAX_MENU_FRAMES := 600
const MAX_LOAD_FRAMES := 1200
const MAX_LAND_S := 30.0
## Точка приземления без landing_sites (altai) — в долине по курсу разбега, дальше от подъёма
## над склоном (см. _landing_target).
const FALLBACK_LANDING_DIST_M := 3000.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Один прогон на каждую локацию (см. критерий приёмки карточки 12-02).
func test_e2e_all_locations() -> void:
	var locations := Config.list_configs("locations")
	check(not locations.is_empty(), "есть локации в configs/locations")
	for loc_name in locations:
		await _run_location(loc_name.get_file())


func _run_location(loc_id: String) -> void:
	print("== e2e: %s ==" % loc_id)
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")

	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in MAX_MENU_FRAMES:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "%s: меню открыто (мир за меню не грузится)" % loc_id)
	if not menu.visible:
		await _finish(main, catcher)
		return
	game.autopilot = Autopilot.new()

	var start_menu: StartMenu = main.get_node("UI/StartMenu")
	var fss: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
	start_menu.setup_requested.emit()
	check(fss.visible, "%s: экран «Полёт…» открыт" % loc_id)

	var place := _first_place(fss, loc_id)
	check(not place.is_empty(), "%s: в «Популярных местах» есть эта локация" % loc_id)
	if place.is_empty():
		fss.visible = false
		await _finish(main, catcher)
		return
	# как выбор пилота в окне «Популярные места» (снимает и точку с карты, которую мог помнить user://)
	fss.call("_on_place_chosen", place)
	(fss.get("_done_btn") as Button).emit_signal("pressed")  # «Готово» — выбор, назад в меню
	check(not fss.visible and start_menu.visible, "%s: «Готово» вернула в меню" % loc_id)
	(start_menu.get("_fly_btn") as Button).emit_signal("pressed")  # «Лететь»

	var loaded := false
	for i in MAX_LOAD_FRAMES:
		if int(main.get("state")) == 2:  # main.gd State.FLYING
			loaded = true
			break
		await get_tree().process_frame
	check(loaded, "%s: состояние FLYING после «Лететь»" % loc_id)
	if not loaded:
		await _finish(main, catcher)
		return
	check(game.settings.location_id == loc_id, "%s: загружена выбранная локация" % loc_id)

	game.process_mode = Node.PROCESS_MODE_DISABLED  # шагаем сами
	var ended: Array = []
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))
	var target := _landing_target(game)

	var t := 0.0
	var t_air := 0.0
	var took_off_at := -1.0
	var repositioned := false
	var max_t := MAX_TAKEOFF_S + HOLD_COURSE_S + MAX_LAND_S + 5.0
	while ended.is_empty() and t < max_t:
		game.tick(DT)
		t += DT
		var ph := game.glider.phase()
		if ph == "flying":
			if took_off_at < 0.0:
				took_off_at = t
			t_air += DT
			if t_air >= HOLD_COURSE_S and not repositioned:
				var tel := game.glider.get_telemetry()
				var y := game.terrain.height_at(target.x, target.y) + 5.0
				game.glider.reset_in_air(Vector3(target.x, y, target.y), tel.heading_deg)
				repositioned = true
		elif took_off_at < 0.0 and t > MAX_TAKEOFF_S:
			break

	print(
		(
			"         %s: отрыв за %.1f с, в воздухе %.1f с, посадка %s"
			% [loc_id, took_off_at, t_air, not ended.is_empty()]
		)
	)
	check(took_off_at >= 0.0, "%s: взлетел" % loc_id)
	check(
		took_off_at >= 0.0 and took_off_at <= MAX_TAKEOFF_S,
		"%s: отрыв ≤ %.0f с (было %.1f)" % [loc_id, MAX_TAKEOFF_S, took_off_at]
	)
	check(not ended.is_empty(), "%s: посадка (flight_ended)" % loc_id)
	game.autopilot.release_all()

	if not ended.is_empty():
		var kind: String = ended[0][0]
		var info: Dictionary = ended[0][1]
		check(kind == "landed", "%s: kind == landed (%s)" % [loc_id, kind])
		check(float(info.get("flight_time_s", 0.0)) > 0.0, "%s: время полёта > 0" % loc_id)
		check(float(info.get("distance_m", 0.0)) > 0.0, "%s: дистанция > 0" % loc_id)
		check(info.has("vertical_speed_ms"), "%s: есть скорость касания" % loc_id)
		await get_tree().create_timer(float(Config.value("game", "result_delay_s", 2.0)) + 0.3).timeout
		var rs: Control = main.get_node("UI/ResultScreen")
		check(rs.visible, "%s: ResultScreen показан" % loc_id)
		check(int(main.get("state")) == 4, "%s: состояние RESULT" % loc_id)  # State.RESULT

	await _finish(main, catcher)


## Первый старт встроенной локации в каталоге «Популярные места» экрана ({} — нет).
func _first_place(fss: FlightSetupScreen, loc_id: String) -> Dictionary:
	for p: Dictionary in (fss.get("_places_catalog") as Dictionary).get("takeoffs", []):
		if String(p.get("location", "")) == loc_id:
			return p
	return {}


## Точка посадки локации (первая из landing_sites); если нет (altai) — точка в долине по
## курсу разбега (там нет орографического подъёма склона, глайд туда гарантированно снижается).
func _landing_target(game: Game) -> Vector2:
	var sites := game.terrain.get_landing_sites()
	if not sites.is_empty():
		var p: Vector3 = sites[0].position
		return Vector2(p.x, p.z)
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var h := deg_to_rad(float(start.heading_deg))
	var dirv := Vector2(sin(h), -cos(h))
	return Vector2(sp.x, sp.z) + dirv * FALLBACK_LANDING_DIST_M


func _finish(main: Node, catcher: ErrorCatcher) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	OS.remove_logger(catcher)
	for e in catcher.errors:
		failures.append("ошибка в логе: " + e)
