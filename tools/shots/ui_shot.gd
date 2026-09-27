extends Node
## Скриншоты карточки 11-02 (docs/plan/ui/02-pauza-nastrojki-itog.md): пауза, настройки,
## «Об игре», итог (мягкая посадка и авария). Фон — обычный мир за меню (main.gd грузит его без
## полёта), экраны показаны напрямую (без полного полёта — устойчивее и быстрее). Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/ui_shot.tscn -- --out=/tmp/ui
## Пишет <out>/{menu,setup,pause,settings,about,result_soft,result_crash}.png. Код выхода 0/1.
## --lang=ru|en — язык интерфейса (без записи в профиль); --only=setup — только «Полёт…»:
## setup, setup_kingpost (класс «мачтовые», модель Laminar), setup_classes (список классов открыт).

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 60.0

var _out := ""
var _lang := ""
var _only := ""
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--lang="):
			_lang = a.substr(7)
		elif a.begins_with("--only="):
			_only = a.substr(7)
	if _out == "":
		push_error("ui_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("ui_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if game.settings != null:
			break
		await get_tree().process_frame
	if game.settings == null:
		_fail("фон за меню не загрузился")
		return

	if _lang != "":
		Language.apply(_lang)
		main.call("_rebuild_ui")
		for i in 4:
			await get_tree().process_frame
	if _only == "setup":
		await _shoot_setup(main)
		print("ui_shot: OK")
		await _quit(0)
		return

	var start_menu: Control = main.get_node("UI/StartMenu")
	var pause_menu: PauseMenu = main.get_node("UI/PauseMenu")
	var settings_panel: SettingsPanel = main.get_node("UI/SettingsPanel")
	var about_screen: AboutScreen = main.get_node("UI/AboutScreen")
	var result_screen: ResultScreen = main.get_node("UI/ResultScreen")

	await _shoot("menu")

	var setup: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
	start_menu.visible = false
	setup.visible = true
	await _shoot("setup")
	setup.visible = false

	pause_menu.visible = true
	await _shoot("pause")

	pause_menu.visible = false
	settings_panel.visible = true
	await _shoot("settings")

	settings_panel.visible = false
	about_screen.visible = true
	await _shoot("about")

	about_screen.visible = false
	result_screen.show_result("landed", _soft_landing_info())
	await _shoot("result_soft")

	result_screen.show_result("landed", _crash_info())
	await _shoot("result_crash")

	print("ui_shot: OK")
	await _quit(0)


## «Полёт…»: учебные (по умолчанию), мачтовые с Laminar, открытый список классов.
func _shoot_setup(main: Node) -> void:
	main.get_node("UI/StartMenu").visible = false
	var setup: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
	var s := FlightSettings.defaults()
	s.wing = "wings/training"
	setup.set_settings(s)
	setup.visible = true
	await _shoot("setup")
	s.wing = "wings/laminar"
	setup.set_settings(s)
	await _shoot("setup_kingpost")
	var class_opt: OptionButton = setup.get("_class_opt")
	class_opt.show_popup()
	await _shoot("setup_classes")
	class_opt.get_popup().hide()


func _soft_landing_info() -> Dictionary:
	return {
		"grade": "soft",
		"vertical_speed_ms": 1.1,
		"horizontal_speed_ms": 3.4,
		"bank_deg": 4.0,
		"flight_time_s": 754.0,
		"distance_m": 2130.0,
		"track_length_m": 5420.0,
		"max_altitude_msl_m": 1780.0,
		"height_gain_m": 320.0,
		"avg_speed_ms": 7.5,
		"total_climb_m": 410.0,
		"best_thermal_climb_ms": 1.8,
		"max_climb_ms": 2.4,
		"max_sink_ms": 3.1,
		"circling_fraction": 0.35,
		"avg_glide_ratio": 7.2,
	}


func _crash_info() -> Dictionary:
	return {
		"grade": "crash",
		"collision": "wire",
		"text": TranslationServer.translate("collision"),
		"vertical_speed_ms": 9.0,
		"horizontal_speed_ms": 14.0,
		"bank_deg": 38.0,
		"flight_time_s": 212.0,
		"distance_m": 860.0,
		"track_length_m": 1490.0,
		"max_altitude_msl_m": 1520.0,
		"height_gain_m": 60.0,
	}


func _shoot(name: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".png")
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("ui_shot: %s (%s)" % [path, error_string(err)])
