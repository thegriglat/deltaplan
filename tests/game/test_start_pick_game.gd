extends Node
## SP-К1: Game._choose_start применяет точный старт (get_start по точке и курсу, в т. ч. после
## restart()); недопустимая точка — прежний автостарт.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return false


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _open(s: FlightSettings) -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	if not menu.visible:
		main.queue_free()
		return null
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", s)
	(main.get_node("Game") as Game).process_mode = Node.PROCESS_MODE_DISABLED
	return main


## Точка в 60 м от автостарта, допустимая по StartSpot; пусто — не нашлась.
func _near_ok(game: Game) -> Vector2:
	var base := game.get_start().position as Vector3
	for d: Vector2 in [Vector2(60, 0), Vector2(-60, 0), Vector2(0, 60), Vector2(0, -60), Vector2(90, 90)]:
		var p := Vector2(base.x, base.z) + d
		if bool(StartSpot.check(game.terrain, p.x, p.y).ok):
			return p
	return Vector2(NAN, NAN)


func test_exact_start_applied() -> void:
	var main := await _open(FlightSettings.defaults())
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var p := _near_ok(game)
	var auto_h: float = game.get_start().heading_deg
	var ll := game.terrain.local_to_latlon(p.x, p.y)
	main.queue_free()
	await get_tree().process_frame
	check(is_finite(p.x), "допустимая точка рядом со стартом найдена")
	if not is_finite(p.x):
		return
	var s := FlightSettings.defaults()
	var want_h := fposmod(auto_h + 137.0, 360.0)
	s.set_exact_start(ll.x, ll.y, want_h)
	var m2 := await _open(s)
	if m2 == null:
		return
	var g2: Game = m2.get_node("Game")
	for phase in ["старт", "после restart"]:
		var st := g2.get_start()
		var pos := st.position as Vector3
		var q := g2.terrain.latlon_to_local(s.start_lat, s.start_lon)
		check(Vector2(pos.x, pos.z).distance_to(q) <= 0.5, "%s: позиция в 0,5 м (%s vs %s)" % [phase, pos, q])
		check(absf(wrapf(float(st.heading_deg) - want_h, -180.0, 180.0)) <= 0.01, "%s: курс %f vs %f" % [phase, st.heading_deg, want_h])
		g2.restart()
	m2.queue_free()
	await get_tree().process_frame


func test_bad_exact_start_falls_back() -> void:
	var s := FlightSettings.defaults()
	s.set_exact_start(0.0, 0.0, 77.0)  # далеко за рельефом
	var main := await _open(s)
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var pos := game.get_start().position as Vector3
	var q := game.terrain.latlon_to_local(0.0, 0.0)
	check(Vector2(pos.x, pos.z).distance_to(q) > 100.0, "недопустимая точка — автостарт")
	main.queue_free()
	await get_tree().process_frame
