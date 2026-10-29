extends Node
## RW-P5: игровой путь входа на место (Main._fly → Game.start) доводит воздух до READY с полем Пикара:
## условия Game._air_conditions принимает крейт (раньше без quantum_h — BAD_INPUT, молча: поле не
## считалось, этапа «Рассчитываем ветер» не было, ветер 0), стадия подготовки видна экрану загрузки,
## у старта ветер ≠ 0. Режим поля «on» — в headless «auto» поле не включает (как и раньше).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=place_air_stage

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []
var _stage_seen := false
var _iters_seen := false
var _fly_done := false
var _failed := ""


func needs_gpu() -> bool:
	return false


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _skip() -> bool:
	return not ClassDB.class_exists("DpAir")


func _watch(air: Node) -> void:
	while not _fly_done:
		var st: Dictionary = air.call("status")
		if String(st.get("stage", "")) != "":
			_stage_seen = true
			_iters_seen = _iters_seen or int(st.get("iters", 0)) > 0
		if int(st.state) == Atmosphere.STATE_FAILED:
			_failed = String(st.reason)
		await get_tree().process_frame


## Игровой путь: условия приняты крейтом, поле считается — экран загрузки видит этап «Рассчитываем ветер».
## Ждём этап (а не READY: полный счёт Пикара — минуты), затем обрываем загрузку.
func test_game_path_shows_wind_stage() -> void:
	if _skip():
		return
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	var game: Game = main.get_node("Game")
	var air: Node = game.air
	check(air is Atmosphere, "воздух — Atmosphere")
	air.call("set_air_mode", "on")
	(main.get("opts") as LaunchOptions).autostart = true
	_watch(air)
	main.call("_fly", FlightSettings.defaults())
	var t0 := Time.get_ticks_msec()
	while not _stage_seen and _failed == "" and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_fly_done = true
	check(_failed == "", "воздух не FAILED: " + _failed)
	check(String(air.call("last_error")) == "", "нет ошибки воздуха: " + String(air.call("last_error")))
	check(_stage_seen, "этап подготовки ветра виден экрану загрузки")
	check(bool(game.terrain.progress.text != ""), "экран загрузки с текстом")
	main.queue_free()
	await get_tree().process_frame
