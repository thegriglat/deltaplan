extends Node
## Кадры дымки у горизонта: мир за меню, камера над стартом на заданных высотах AGL смотрит
## к горизонту (чуть вниз) в заданные часы — проверка верхней границы дымки.
## Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/haze_shot.tscn -- --out=/tmp/haze [--hours=7,13,19] [--agl=300,2500] \
##     [--pitch=-3] [--yaw=<град>] [--legacy]
## --legacy — дымка как до исправления «ступеньки» у горизонта (для сравнения до/после):
## чистый воздух не трогает небо, его цвет не зависит от солнца, верх слоя 60 м.
## Пишет <out>/haze_HH_<agl>.png. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 150.0

var _out := ""
var _hours: PackedFloat64Array = [7.0, 13.0, 19.0]
var _agl: PackedFloat64Array = [300.0, 2500.0]
var _pitch := -3.0
var _yaw := 0.0
var _legacy := false
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--hours="):
			_hours = _floats(a.substr(8))
		elif a.begins_with("--agl="):
			_agl = _floats(a.substr(6))
		elif a.begins_with("--pitch="):
			_pitch = float(a.substr(8))
		elif a.begins_with("--yaw="):
			_yaw = float(a.substr(6))
		elif a == "--legacy":
			_legacy = true
	if _out == "":
		push_error("haze_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _floats(s: String) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	for x in s.split(","):
		r.append(float(x))
	return r


func _fail(why: String) -> void:
	print("haze_shot: FAIL (%s)" % why)
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
		_fail("мир за меню не загрузился")
		return
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var clock := game.sky.clock
	var start: Dictionary = game.get_start()
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	var dir := TerrainGeo.heading_vector(float(start.heading_deg) + _yaw)
	var look := dir * cos(deg_to_rad(_pitch)) + Vector3.UP * sin(deg_to_rad(_pitch))
	print(
		(
			"haze_shot: старт %.0f м MSL, верх дымки %.0f м MSL"
			% [(start.position as Vector3).y, game.sky.get_haze_top_msl()]
		)
	)
	for agl in _agl:
		var p: Vector3 = start.position + Vector3.UP * agl
		cam.look_at_from_position(p, p + look * 1000.0)
		cam.make_current()
		for h in _hours:
			clock.set_hour(h)
			if _legacy:
				_make_legacy(game.sky)
			await _shoot("%s/haze_%02d_%d.png" % [_out, int(h), int(agl)])
	print("haze_shot: OK")
	await _quit(0)


func _make_legacy(sky: SkyEnvironment) -> void:
	var m := sky.haze_material()
	var hz: Dictionary = Config.get_config("world").get("haze", {})
	m.set_shader_parameter("clear_sky_height_m", 0.0)
	m.set_shader_parameter("top_transition_m", 60.0)
	m.set_shader_parameter("clear_color", SkyEnvironment._color(hz.clear_air_color))


func _shoot(path: String) -> void:
	for i in 12:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("haze_shot: %s (%s)" % [path, error_string(err)])
