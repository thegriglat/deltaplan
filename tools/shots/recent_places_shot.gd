extends Node
## Кадр экрана «Полёт…» со списком «Недавние места» (карточка «Недавние места»): фон — обычный
## мир за меню (main.gd грузит его без полёта, как в tools/shots/ui_shot.gd), экран «Полёт…»
## показан напрямую поверх с временным списком мест (не трогает пользовательский
## user://recent_places.json — RecentPlaces.PATH подменяется на свой временный файл на время кадра
## и убирается после). Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/recent_places_shot.tscn -- --out=/tmp/recent
## Пишет <out>/recent_places.png. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 60.0
const TMP_RECENT_PATH := "user://shots_recent_places_tmp.json"

var _out := ""
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		push_error("recent_places_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("recent_places_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if FileAccess.file_exists(TMP_RECENT_PATH):
		DirAccess.remove_absolute(TMP_RECENT_PATH)
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


## Временный список — своя точка (осталась без имени), закреплённая точка со своим именем,
## место из каталога (Горно-Алтайск) и переименованная.
func _write_tmp_recent() -> void:
	if FileAccess.file_exists(TMP_RECENT_PATH):
		DirAccess.remove_absolute(TMP_RECENT_PATH)
	var now := Time.get_unix_time_from_system()
	RecentPlaces.add(51.87, 85.87, "Горно-Алтайск", TMP_RECENT_PATH, now)
	var pinned_id := RecentPlaces.add(50.6, 86.4, "", TMP_RECENT_PATH, now - 1.0)
	RecentPlaces.set_pinned(pinned_id, true, TMP_RECENT_PATH)
	var named_id := RecentPlaces.add(51.9, 85.6, "", TMP_RECENT_PATH, now - 2.0)
	RecentPlaces.rename(named_id, "Площадка у реки", TMP_RECENT_PATH)
	RecentPlaces.add(51.75, 85.95, "", TMP_RECENT_PATH, now - 3.0)


func _run() -> void:
	_write_tmp_recent()
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

	var start_menu: Control = main.get_node("UI/StartMenu")
	var setup: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
	setup.recent_places_path = TMP_RECENT_PATH
	setup.set_settings(FlightSettings.defaults())
	start_menu.visible = false
	setup.visible = true
	await _shoot("recent_places")

	print("recent_places_shot: OK")
	await _quit(0)


func _shoot(name: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".png")
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("recent_places_shot: %s (%s)" % [path, error_string(err)])
