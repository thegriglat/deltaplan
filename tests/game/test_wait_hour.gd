extends Node
## «Подождать час» (Q-17): время мира ×wait_speed на земле, пилот стоит, любая клавиша прерывает,
## в сети пункта нет.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _world() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	var s := FlightSettings.defaults()
	s.start_hour = 12.0
	await main.call("_fly", s)
	game.set_physics_process(false)  # тики — вручную
	return [main, game]


func test_wait_hour_advances_world() -> void:
	var w := await _world()
	var main: Node = w[0]
	var game: Game = w[1]
	var air: Atmosphere = game.air as Atmosphere
	check(game.can_wait(), "на старте ждать можно (фаза %s)" % game.glider.phase())
	var pos0: Vector3 = game.glider.get_telemetry().position
	var h0 := game.sky.clock.hour
	var t0 := air.time_s
	check(game.start_wait(), "start_wait")
	var dt := 1.0 / 60.0
	var ticks := 0
	while game.is_waiting() and ticks < 60 * 90:
		game.tick(dt)
		ticks += 1
	var secs := ticks * dt
	var dh := (game.sky.clock.hour - h0) * 60.0
	print("         ожидание: %.1f с, часы +%.1f мин, time_s +%.0f с" % [secs, dh, air.time_s - t0])
	check(absf(secs - 60.0) < 2.0, "60 с: %.1f" % secs)
	check(absf(dh - 60.0) < 2.0, "часы +1 ч: %.1f мин" % dh)
	check(absf((air.time_s - t0) - 3600.0) < 120.0, "time_s +3600: %.0f" % (air.time_s - t0))
	check(game.glider.get_telemetry().position.is_equal_approx(pos0), "пилот не сдвинулся")
	check(not game.is_waiting(), "ожидание кончилось")
	check(is_equal_approx(game.sky.clock.speed, 1.0), "множитель прежний")
	main.queue_free()


func test_wait_interrupt_and_net() -> void:
	var w := await _world()
	var main: Node = w[0]
	var game: Game = w[1]
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.pressed = true
	check(game.start_wait(), "start_wait")
	for i in 120:
		game.tick(1.0 / 60.0)
	main.call("_unhandled_input", ev) if main.get("_wait_label") != null else game.stop_wait()
	check(not game.is_waiting(), "клавиша прервала")
	var h := game.sky.clock.hour
	check(h > 12.0 and h < 12.5, "часы прошли часть часа: %.3f" % h)
	# пункт паузы: на земле одиночной игры есть
	main.call("_pause")
	check(main.pause_menu.wait_visible(), "пункт есть на старте")
	main.call("_resume")
	main.queue_free()
