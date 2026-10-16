extends Node
## Кадры TI-16: главное меню с кнопкой «Тренировка» и окно тренировок с 4 карточками.
## Запуск (нужно окно; DISPLAY; XDG_DATA_HOME — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/training_menu_shot.tscn -- --out=<каталог>
## Пишет <out>/10_main_menu.jpg, 11_training.jpg (JPEG q88, 1920×1080).

const SIZE := Vector2i(1920, 1080)

var _out := ""
var _vp: SubViewport


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		push_error("training_menu_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _snap(tag: String) -> void:
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/%s.jpg" % [_out, tag]
	print("shot: ", path, " ", error_string(_vp.get_texture().get_image().save_jpg(path, 0.88)))


func _run() -> void:
	Language.apply("ru")
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = "user://training_menu_shot_fav.json"
	_vp.add_child(m)
	await get_tree().process_frame
	await _snap("10_main_menu")
	for b in m.find_children("*", "Button", true, false):
		if (b as Button).text == tr("menu_training"):
			(b as Button).pressed.emit()
	await _snap("11_training")
	get_tree().quit(0)
