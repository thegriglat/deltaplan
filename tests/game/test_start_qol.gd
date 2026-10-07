extends Node
## QL-3: подсказка управления на старте каждого полёта (Q-08), запоминание камеры (Q-09),
## снимок экрана F12 (Q-11), клавиши свободной камеры на экране «Управление» (Q-10).
## Профиль пилота подменён: UserSettings.state_path и screenshot_dir — во временный каталог.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TMP := "user://test_start_qol_tmp"

var failures: PackedStringArray = []
var _old_state_path := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _begin() -> void:
	_old_state_path = UserSettings.state_path
	DirAccess.make_dir_recursive_absolute(TMP)
	UserSettings.state_path = TMP.path_join("state.json")
	if FileAccess.file_exists(UserSettings.state_path):
		DirAccess.remove_absolute(UserSettings.state_path)


func _end() -> void:
	UserSettings.state_path = _old_state_path
	for d in [TMP.path_join("shots"), TMP]:
		if not DirAccess.dir_exists_absolute(d):
			continue
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)


func _open_main() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	main.screenshot_dir = TMP.path_join("shots")
	# headless: у вьюпорта нет картинки — подставляем свою
	main.screenshot_source = func() -> Image: return Image.create(8, 8, false, Image.FORMAT_RGB8)
	return main


func test_start_hint_every_flight_hides_on_w() -> void:
	_begin()
	var main := await _open_main()
	(main.get("opts") as LaunchOptions).autostart = false
	var w := InputEventKey.new()
	w.physical_keycode = KEY_W
	w.pressed = true
	for flight in 2:
		main.call("_maybe_show_start_hint")
		var hint: Control = main.get("_start_hint")
		check(hint != null and hint.visible, "полёт %d: подсказка видна" % flight)
		check(hint.modulate.a < 1.0, "полупрозрачная")
		var l := (hint.get_node("Left/Text") as Label).text
		var r := (hint.get_node("Right/Text") as Label).text
		check(l.contains("Shift") and l.contains("↑") and l.contains("W"), "слева клавиши: " + l)
		check(r != "" and not r.contains("%s"), "справа мышь: " + r)
		main.call("_unhandled_input", w)
		check(not hint.visible, "полёт %d: первое W скрыло подсказку" % flight)
	# автостарт (скриншоты, smoke) подсказку не показывает
	(main.get("opts") as LaunchOptions).autostart = true
	main.call("_maybe_show_start_hint")
	check(not (main.get("_start_hint") as Control).visible, "автостарт без подсказки")
	main.queue_free()
	_end()


func test_camera_remembered_between_flights() -> void:
	_begin()
	var main := await _open_main()
	var game: Game = main.get_node("Game")
	(main.get("opts") as LaunchOptions).autostart = true
	check(UserSettings.start_camera() == "cockpit", "без выбора — default_mode")
	game.set_flying(true)
	check(game.camera.mode == "cockpit", "первый полёт из кабины")
	game.camera.next_mode()  # cockpit → chase
	check(game.camera.mode == "chase", "камера сменилась")
	game.set_flying(false)
	game.set_flying(true)
	check(game.camera.mode == "chase", "новый полёт с той же камерой")
	game.camera.next_mode()  # chase → free: не запоминается
	check(game.camera.mode == "free", "свободная")
	game.set_flying(true)
	check(game.camera.mode == "chase", "свободная камера не запоминается")
	main.queue_free()
	_end()


func test_f12_writes_file() -> void:
	_begin()
	check(InputMap.has_action("screenshot"), "действие screenshot есть")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F12
	check(InputMap.event_is_action(ev, "screenshot"), "F12 — снимок")
	var main := await _open_main()
	main.call("_screenshot_key")
	for i in 30:
		await get_tree().process_frame
	var dir: String = main.screenshot_dir
	var files := DirAccess.get_files_at(dir)
	check(files.size() == 1 and String(files[0]).ends_with(".png"), "файл снимка: %s" % [files])
	if files.size() == 1:
		var img := Image.load_from_file(dir.path_join(files[0]))
		check(img != null and img.get_width() > 0, "PNG читается")
	# два снимка в одну секунду не затирают друг друга
	var i2 := Image.create(4, 4, false, Image.FORMAT_RGB8)
	var a := UserSettings.save_screenshot(i2, dir)
	var b := UserSettings.save_screenshot(i2, dir)
	check(a != "" and b != "" and a != b, "имена разные")
	main.queue_free()
	_end()


func test_controls_screen_has_free_camera_keys() -> void:
	var keys: Array[String] = []
	for r in ControlsScreen.rows():
		keys.append(String(r.get("keys", "")))
	check(keys.has("E") and keys.has("Q"), "E и Q свободной камеры — отдельные строки")
	check(keys.has("F12"), "F12 на экране")
