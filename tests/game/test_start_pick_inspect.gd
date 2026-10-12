extends Node
## SP-2: выбор старта в осмотре — точка, курс, «Лететь отсюда» без перезагрузки места, сброс,
## недопустимая точка, строка в «Настройках полёта».

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _inspect() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	if game.settings == null:
		failures.append("мир не загрузился")
		return [main, null]
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", FlightSettings.defaults(), true)
	return [main, game]


## Допустимая точка недалеко от автостарта.
func _good_spot(game: Game) -> Vector2:
	var c := game.get_start().position as Vector3
	for r: float in [30.0, 60.0, 120.0, 200.0]:
		for a in 12:
			var x: float = c.x + r * cos(TAU * a / 12.0)
			var z: float = c.z + r * sin(TAU * a / 12.0)
			if bool(StartSpot.check(game.terrain, x, z).ok):
				return Vector2(x, z)
	return Vector2(c.x, c.z)


func test_ray_to_ground() -> void:
	var h := func(_x: float, _z: float) -> float: return 100.0
	var p := Game.ray_to_ground(h, Vector3(0, 300, 0), Vector3(1, -1, 0))
	check(p != Vector3.INF and absf(p.x - 200.0) < 0.5 and absf(p.y - 100.0) < 0.5, "луч вниз %s" % p)
	check(Game.ray_to_ground(h, Vector3(0, 300, 0), Vector3(1, 1, 0)) == Vector3.INF, "вверх — мимо")


func test_pick_flow() -> void:
	var r := await _inspect()
	var main: Node = r[0]
	var game: Game = r[1]
	if game == null:
		main.queue_free()
		return
	var panel: StartPickPanel = main.get("_pick_panel")
	check(panel != null and panel.visible, "панель есть")
	check(game.pick.is_empty() and not game.settings.has_exact_start(), "точки нет")
	var spot := _good_spot(game)
	game.pick_point(spot.x, spot.y)
	check(bool(game.pick.ok), "точка допустима")
	check(is_equal_approx(float(game.pick.heading), float(game.pick.downhill_deg)), "курс вниз по склону")
	check(game.settings.has_exact_start(), "записано в настройки полёта")
	check((main.get("flight") as FlightSettings).has_exact_start(), "и в настройки меню")
	check(panel.fly_button.visible and not panel.reason_label.visible, "«Лететь отсюда» видна")
	var h0 := float(game.pick.heading)
	panel.turn_requested.emit(5.0)
	check(absf(wrapf(float(game.pick.heading) - h0 - 5.0, -180, 180)) < 0.01, "+5°")
	panel.turn_requested.emit(-10.0)
	check(absf(wrapf(float(game.pick.heading) - h0 + 5.0, -180, 180)) < 0.01, "−5° от начала")
	var want := float(game.pick.heading)
	# протяжка: курс на восток
	game.pick_heading_to(spot.x + 100.0, spot.y)
	check(absf(float(game.pick.heading) - 90.0) < 0.01, "курс к курсору: 90°")
	want = 90.0
	check(game._pick_marker.visible, "маркер виден")
	# лететь отсюда: место не перезагружается
	var loc_before: String = game.terrain.location_id
	var terr_node_id := game.terrain.get_instance_id()
	var ll := Vector2(game.settings.start_lat, game.settings.start_lon)
	panel.fly_requested.emit()
	for i in 600:
		if not game.inspect_mode and main.get("state") == 2:
			break
		await get_tree().process_frame
	check(not game.inspect_mode and main.get("state") == 2, "полёт начался")
	check(game.terrain.location_id == loc_before and game.terrain.get_instance_id() == terr_node_id, "место то же")
	var st := game.get_start()
	var q := game.terrain.latlon_to_local(ll.x, ll.y)
	check(Vector2(st.position.x - q.x, st.position.z - q.y).length() < 0.5, "старт в точке %s vs %s" % [st.position, q])
	check(absf(wrapf(float(st.heading_deg) - want, -180, 180)) < 0.5, "курс %s" % st.heading_deg)
	check(game.glider.visible, "крыло видно")
	# вернуться в меню: точка осталась, осмотр снова — маркер на ней
	main.call("_show_menu")
	check((main.get("flight") as FlightSettings).has_exact_start(), "после «В меню» точка остаётся")
	await main.call("_fly", main.get("flight"), true)
	check(not game.pick.is_empty() and bool(game.pick.ok) and game._pick_marker.visible, "маркер на заданной точке")
	check(absf(float(game.pick.heading) - want) < 0.5, "курс сохранён")
	# сброс
	panel = main.get("_pick_panel")
	panel.reset_requested.emit()
	check(game.pick.is_empty() and not game.settings.has_exact_start(), "сброс в игре")
	check(not (main.get("flight") as FlightSettings).has_exact_start(), "сброс в настройках меню")
	main.queue_free()


func test_bad_spot() -> void:
	var r := await _inspect()
	var main: Node = r[0]
	var game: Game = r[1]
	if game == null:
		main.queue_free()
		return
	var b: Rect2 = game.terrain.detail_bounds()
	game.pick_point(b.position.x + 10.0, b.position.y + 10.0)  # у края — за отступом
	var panel: StartPickPanel = main.get("_pick_panel")
	check(not bool(game.pick.ok) and game.pick.reason == "outside", "за краем: %s" % game.pick.get("reason"))
	check(not game.settings.has_exact_start(), "недопустимая точка не пишется")
	check(not panel.fly_button.visible and panel.reason_label.visible, "вместо кнопки — причина")
	check(panel.reason_label.text == tr("start_pick_bad_outside") and panel.reason_label.text != "start_pick_bad_outside", "текст причины")
	main.queue_free()


func test_setup_row() -> void:
	var s := FlightSettings.defaults()
	var row := PlacePickRow.new()
	row.settings = s
	add_child(row)
	row.build(row)
	row.refresh()
	check(not row.exact_label.visible and not row.exact_reset_btn.visible, "без точки строки нет")
	s.set_exact_start(51.0, 85.0, 123.0)
	row.refresh()
	check(row.exact_label.visible and row.exact_label.text.contains("123"), "строка с курсом: %s" % row.exact_label.text)
	row.exact_reset_btn.pressed.emit()
	check(not s.has_exact_start() and not row.exact_label.visible, "«Сбросить» убирает точку")
	row.queue_free()
