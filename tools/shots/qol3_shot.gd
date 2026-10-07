extends Node
## QL-3: подсказка на старте (Q-08) и экран «Управление» со свободной камерой (Q-10).
##   godot --path . --audio-driver Dummy --resolution 1920x1080 res://tools/shots/qol3_shot.tscn -- --out=<каталог>
## Пишет <out>/{start_hint,controls}.png. Профиль пилота не трогается (state_path — временный).

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	UserSettings.state_path = "user://qol3_shot_state.json"
	get_tree().create_timer(120.0).timeout.connect(get_tree().quit.bind(1))
	var main: Node = MAIN_SCENE.instantiate()
	(main as Object).set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	var menu: StartMenu = main.get_node("UI/StartMenu")
	while state_wait(main, menu):
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout
	main.call("_show_start_hint")
	await _snap("start_hint")
	main.call("_hide_start_hint")
	main.call("_pause")
	main.call("_open_overlay", main.get("controls_screen"), main.get("pause_menu"))
	await _snap("controls")
	var sc := (main.get("controls_screen") as Control).find_children("*", "ScrollContainer", true, false)
	if not sc.is_empty():
		(sc[0] as ScrollContainer).scroll_vertical = 100000
	await _snap("controls_free_camera")
	DirAccess.remove_absolute(UserSettings.state_path)
	get_tree().quit(0)


func state_wait(main: Node, _menu: StartMenu) -> bool:
	return int(main.get("state")) != 2  # State.FLYING


func _snap(name: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(name + ".png"))
	print("qol3_shot: ", name)
