extends Node
## Скриншоты NET-50: экран «Сетевая игра» на подставном клиенте (NetUiFakeBackend) поверх
## обычного мира за меню. Запуск (всегда с временным профилем):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/net_screen_shot.tscn -- --out=/tmp/net --lang=ru
## Пишет <out>/<состояние>_<язык>.png: menu, input, nearby_empty, nearby_two,
## nearby_other_version (NET-53), connecting, zone, error_unreachable, error_zone_not_found,
## error_version_mismatch, error_zone_full, error_disconnected, error_port_busy,
## error_server_failed.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const NET_SCENE := preload("res://scenes/ui/net_screen.tscn")
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
		push_error("net_screen_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("net_screen_shot: FAIL (%s)" % why)
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
	await _shoot("menu")

	var fake := NetUiFakeBackend.new()
	fake.auto_resolve = false
	fake.fake_peers = [
		{"id": "3", "name": "Папа", "join_order": 1, "is_leader": true, "is_me": false},
		{"id": "7", "name": "Мама", "join_order": 2, "is_leader": false, "is_me": false},
		{"id": "8", "name": "Alex", "join_order": 3, "is_leader": false, "is_me": false},
		{
			"id": "9",
			"name": UserSettings.pilot_name(),
			"join_order": 4,
			"is_leader": false,
			"is_me": true
		},
	]
	var net: NetScreen = NET_SCENE.instantiate()
	net.backend = fake
	main.get_node("UI/StartMenu").visible = false
	main.get_node("UI").add_child(net)
	net.set_server("192.168.1.10:8765")
	await _shoot("input")

	# NET-53: «Рядом» — пусто, затем зоны рядом (одна выбрана по умолчанию), затем чужая версия.
	await _shoot("nearby_empty")
	var my_version := str(ProjectSettings.get_setting("application/config/version", ""))
	fake.set_nearby(
		[
			{
				"code": "4721",
				"host_name": "Коля",
				"address": "192.168.1.5",
				"port": 8765,
				"game_version": my_version,
				"pilots_count": 2,
				"same_version": true,
			},
			{
				"code": "1234",
				"host_name": "Оля",
				"address": "192.168.1.6",
				"port": 8765,
				"game_version": my_version,
				"pilots_count": 1,
				"same_version": true,
			},
		]
	)
	await _shoot("nearby_two")
	fake.set_nearby(
		[
			{
				"code": "4721",
				"host_name": "Коля",
				"address": "192.168.1.5",
				"port": 8765,
				"game_version": my_version,
				"pilots_count": 2,
				"same_version": true,
			},
			{
				"code": "9999",
				"host_name": "Стас",
				"address": "192.168.1.7",
				"port": 8765,
				"game_version": "0.0.0",
				"pilots_count": 1,
				"same_version": false,
			},
		]
	)
	await _shoot("nearby_other_version")
	fake.set_nearby([])

	net.set_code("4721")
	net.join_zone()
	await _shoot("connecting")
	fake.resolve()
	await _shoot("zone")

	fake.drop()
	await _shoot("error_disconnected")

	fake.outcome = "unreachable"
	net.create_zone()
	fake.resolve()
	await _shoot("error_unreachable")

	for kind in ["zone_not_found", "version_mismatch", "zone_full", "port_busy", "server_failed"]:
		fake.outcome = kind
		net.join_zone()
		fake.resolve()
		await _shoot("error_" + kind)

	print("net_screen_shot: OK")
	await _quit(0)


func _shoot(state: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("%s_%s.png" % [state, _lang])
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("net_screen_shot: %s (%s)" % [path, error_string(err)])
