extends Node
## Кадры меню с учебным островом (TI-14): список стран со строкой «—», четыре старта острова,
## окно «Полёт…» с выбранным стартом (фиксированная погода) и вкладка «Цели».
## Запуск (нужно окно; DISPLAY; XDG_DATA_HOME — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/training_island_menu_shot.tscn -- --out=<каталог>
## Пишет <out>/01_places.jpg … 04_goals.jpg (JPEG q88, 1920×1080).

const TMP_RECENT := "user://training_island_menu_shot_recent.json"
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


func _run() -> void:
	Language.apply("ru")
	var screen: FlightSetupScreen = (
		(load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	)
	screen.recent_places_path = TMP_RECENT
	screen.settings = FlightSettings.defaults()
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.2, 0.26)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(bg)
	_vp.add_child(screen)
	await get_tree().process_frame
	(screen.get("_places_btn") as Button).pressed.emit()
	var w: PopularPlacesWindow = screen.get("_places_window")
	# (а) список стран; строка «—» — в прокрутке, показываем её
	await get_tree().process_frame
	var sc: ScrollContainer = w.get("_scroll")
	var list: Control = w.get("_list")
	for c in list.get_children():
		if c is Button and (c as Button).text.begins_with("—"):
			sc.ensure_control_visible(c)
	await _snap("01_places")
	# (б) четыре старта острова
	w.enter_country("")
	await _snap("02_island_starts")
	# (в) выбран старт острова — окно «Полёт…»
	w.press_row(0)
	await _snap("03_setup_island")
	# вкладка «Цели»
	var tabs: TabContainer = screen.get("_tabs")
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == tr("setup_tab_goals"):
			tabs.current_tab = i
	await _snap("04_goals")
	if FileAccess.file_exists(TMP_RECENT):
		DirAccess.remove_absolute(TMP_RECENT)
	get_tree().quit(0)
