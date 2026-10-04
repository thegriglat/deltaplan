extends Node
## Кадр окна «Популярные места» поверх экрана «Полёт…» на тестовом каталоге (не data/).
## Запуск (окно нужно; DISPLAY; XDG_DATA_HOME — временный):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/popular_places_shot.tscn -- --out=/home/greg/deltaplan/build/screenshots/popular-places \
##     --tag=02_1920x1080_страны --size=1920x1080 [--state=countries|country|search] [--country=SI] [--query=гор]
## Пишет <out>/<tag>.png.

const FIXTURE := "res://tests/ui/fixtures/hg_takeoffs_test.json"
const TMP_RECENT := "user://popular_places_shot_recent.json"

var _out := ""
var _tag := "shot"
var _state := "countries"
var _country := "SI"
var _query := "гор"
var _size := Vector2i(1920, 1080)  ## разрешение кадра: рисуется в SubViewport этого размера


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--state="):
			_state = a.substr(8)
		elif a.begins_with("--country="):
			_country = a.substr(10)
		elif a.begins_with("--size="):
			var wh := a.substr(7).split("x")
			_size = Vector2i(int(wh[0]), int(wh[1]))
		elif a.begins_with("--query="):
			_query = a.substr(8)
	if _out == "":
		push_error("popular_places_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _run() -> void:
	Language.apply("ru")
	var screen: FlightSetupScreen = (
		(load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	)
	screen.recent_places_path = TMP_RECENT
	screen.popular_places_path = FIXTURE
	screen.settings = FlightSettings.defaults()
	var vp := SubViewport.new()
	vp.size = _size
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()  # фон под затемнением — как главное меню
	bg.color = Color(0.16, 0.2, 0.26)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vp.add_child(bg)
	vp.add_child(screen)
	await get_tree().process_frame
	(screen.get("_places_btn") as Button).pressed.emit()
	var w: PopularPlacesWindow = screen.get("_places_window")
	if _state == "country":
		w.enter_country(_country)
	if _state == "search":
		var le: LineEdit = w.get("_search")
		le.text = _query
		le.text_changed.emit(_query)
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var path := "%s/%s.png" % [_out, _tag]
	print("popular_places_shot: %s (%s) окно %s" % [path, error_string(img.save_png(path)), w.panel_rect()])
	if FileAccess.file_exists(TMP_RECENT):
		DirAccess.remove_absolute(TMP_RECENT)
	get_tree().quit(0)
