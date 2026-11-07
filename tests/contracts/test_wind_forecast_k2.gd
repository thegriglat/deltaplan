extends Node
## WF-К2 v2: «На старте X м/с» в подсказке старта — из поля воздуха, а не из меню.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TMP := "user://test_wf_k2_tmp"

var failures: PackedStringArray = []
var _old_state_path := ""


class StubAir:
	extends Node3D
	var on := true
	var wind := Vector3(-7.4, 0.0, 0.0)  # дует на запад → ветер с востока

	func is_air_field_on() -> bool:
		return on

	func mean_wind_at(_p: Vector3) -> Vector3:
		return wind


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _hint_text(on: bool) -> String:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	for i in 1200:
		if (main.get_node("UI/StartMenu") as Control).visible:
			break
		await get_tree().process_frame
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var air := StubAir.new()
	air.on = on
	game.air = air
	game.settings = FlightSettings.new()
	game.settings.wind_speed_kmh = 21.6  # меню: 6 м/с
	(main.get("opts") as LaunchOptions).autostart = false
	main.call("_maybe_show_start_hint")
	var t := ((main.get("_start_hint") as Control).get_node("Left/Text") as Label).text
	game.air = null
	air.free()
	main.queue_free()
	return t


func test_wind_from_field_not_menu() -> void:
	_old_state_path = UserSettings.state_path
	DirAccess.make_dir_recursive_absolute(TMP)
	UserSettings.state_path = TMP.path_join("state.json")
	var t := await _hint_text(true)
	check(t.contains("7.4"), "скорость из поля: " + t)
	check(not t.contains("6.0 м/с, ветер") and not t.contains("At launch 6.0"), "не из меню: " + t)
	var t2 := await _hint_text(false)
	check(not t2.contains("7.4"), "поля нет — числа поля нет: " + t2)
	UserSettings.state_path = _old_state_path
