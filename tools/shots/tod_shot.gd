extends Node
## Кадры времени суток (VR-5): мир за меню (главная сцена), солнце по часам в заданные часы.
## Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/tod_shot.tscn -- --out=/tmp/tod [--hours=7,13,19] [--yaw=<град>]
## Пишет <out>/tod_HH.png (вид с камеры меню) и <out>/tod_HH_terrain.png (взгляд вдоль склона
## вниз с высоты 300 м, курс площадки + yaw). Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 100.0

var _out := ""
var _hours: PackedFloat64Array = [7.0, 13.0, 19.0]
var _yaw := 0.0
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--hours="):
			_hours = PackedFloat64Array()
			for x in a.substr(8).split(","):
				_hours.append(float(x))
		elif a.begins_with("--yaw="):
			_yaw = float(a.substr(6))
	if _out == "":
		push_error("tod_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("tod_shot: FAIL (%s)" % why)
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
	for h in _hours:
		clock.set_hour(h)
		var a := clock.angles()
		print("tod_shot: %s — азимут %.0f°, высота %.1f°" % [clock.time_text(), a.x, a.y])
		var tag := "%02d" % int(h)
		await _shoot("%s/tod_%s.png" % [_out, tag])
	# вид на рельеф: камера над стартом смотрит вниз по склону
	var start: Dictionary = game.get_start()
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	var p: Vector3 = start.position + Vector3.UP * 300.0
	var dir := TerrainGeo.heading_vector(float(start.heading_deg) + _yaw)
	cam.look_at_from_position(p, p + dir * 1000.0 + Vector3.DOWN * 250.0)
	cam.make_current()
	for h in _hours:
		clock.set_hour(h)
		await _shoot("%s/tod_%02d_terrain.png" % [_out, int(h)])
	print("tod_shot: OK")
	await _quit(0)


func _shoot(path: String) -> void:
	for i in 12:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("tod_shot: %s (%s)" % [path, error_string(err)])
