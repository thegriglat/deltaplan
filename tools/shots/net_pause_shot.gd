extends Node
## Скриншоты NET-52: пауза и экран загрузки с сетевой зоной (код, пилоты) — данные подставные
## (NetPauseInfo.build на подготовленном состоянии, без сети). Запуск (всегда с временным
## профилем — окно тайлового WM иначе сжимается, поэтому --fullscreen):
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --audio-driver Dummy --fullscreen \
##     --resolution 1920x1080 res://tools/shots/net_pause_shot.tscn -- --out=/tmp/net --lang=ru
## Пишет <out>/{pause,loading}_<язык>.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 90.0

var _out := ""
var _lang := "ru"
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--lang="):
			_lang = a.substr(7)
	if _out == "":
		push_error("net_pause_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("net_pause_shot: FAIL (%s)" % why)
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
	for i in 900:
		if game.settings != null:
			break
		await get_tree().process_frame
	if game.settings == null:
		_fail("фон за меню не загрузился")
		return
	Language.apply(_lang)
	main.call("_rebuild_ui")
	for i in 4:
		await get_tree().process_frame

	var info := {
		"code": "4721",
		"pilots":
		[
			{"name": "Папа", "alt_m": 1850.0, "is_leader": true, "is_me": false},
			{"name": "Alex", "alt_m": null, "is_leader": false, "is_me": false},
			{"name": UserSettings.pilot_name(), "alt_m": 1620.0, "is_leader": false, "is_me": true},
		],
	}

	var pause_menu: PauseMenu = main.get_node("UI/PauseMenu")
	main.get_node("UI/StartMenu").visible = false
	pause_menu.set_net_info(info)
	pause_menu.visible = true
	await _shoot("pause")
	pause_menu.visible = false

	var loading_screen: LoadingScreen = main.get_node("UI/LoadingScreen")
	var progress := LoadProgress.new({"a": 1.0, "b": 3.0})
	progress.begin()
	loading_screen.open(progress, "50.6000, 86.4000")
	progress.stage("b", tr("loading_dem"))
	progress.sub(1, 2)
	loading_screen.set_net_info(info)
	for i in 4:
		await get_tree().process_frame
	await _shoot("loading")

	print("net_pause_shot: OK")
	await _quit(0)


func _shoot(state: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("%s_%s.png" % [state, _lang])
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("net_pause_shot: %s (%s)" % [path, error_string(err)])
