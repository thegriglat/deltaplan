extends Node
## Кадры окна «Тренировка» (TI-16, VI-К2): вкладка учебного острова и вкладка вулканического острова.
## Запуск (нужно окно; DISPLAY; XDG_DATA_HOME — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/training_island_menu_shot.tscn -- --out=<каталог>
## Пишет <out>/01_training_island.jpg, 02_training_volcano.jpg (JPEG q88, 1920×1080).

const SIZE := Vector2i(1920, 1080)

var _out := ""
var _vp: SubViewport


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	if _out == "":
		push_error("training_island_menu_shot: нужен --out=")
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


func _select_tab(w: TrainingMenu, group_id: String) -> void:
	var tabs: TabContainer = w.get("_tabs")
	for i in tabs.get_tab_count():
		if tabs.get_child(i).name == group_id:
			tabs.current_tab = i


func _run() -> void:
	Language.apply("ru")
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = "user://training_island_menu_shot_fav.json"
	_vp.add_child(m)
	await get_tree().process_frame
	for b in m.find_children("*", "Button", true, false):
		if (b as Button).text == tr("menu_training"):
			(b as Button).pressed.emit()
	await get_tree().process_frame
	var w: TrainingMenu = m.get("_training")
	# (а) вкладка учебного острова (первая группа)
	_select_tab(w, "training_island")
	await _snap("01_training_island")
	# (б) вкладка вулканического острова
	_select_tab(w, "volcano_island")
	await _snap("02_training_volcano")
	get_tree().quit(0)
