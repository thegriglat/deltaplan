extends Node
## Скриншот F3 (AM-10) и грубый замер GPU-времени кадра трава-с-полем/без (WF-10, для сравнения
## с бюджетом ≤ 0,2 мс на «Высоком»): полная игра с автостартом (как cloud_shadow_shot.gd),
## затем — по --shot включает WindFieldDebug (F3) и снимает кадр; по --gpu=N измеряет среднее
## GPU-время кадра (RenderingServer, как в cloud_shadow_shot.gd — общий кадр, не только трава).
## Нужно окно (настоящий рендер):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/wind_field_shot.tscn -- --autostart --bots=0 --location=ongudai \
##     --site=kayancha_south --wind=3 --from=180 --hour=13 [--air-field=<путь>] \
##     --out=<каталог> --tag=<имя> [--shot] [--gpu=120] [--preset=high]
## Пишет <out>/<tag>_f3.png (если --shot) и печатает "wind_field_shot: GPU <tag>: кадр X мс".

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 200.0

var _out := ""
var _tag := "wf"
var _do_shot := false
var _gpu_frames := 0
var _main: Node = null
var _game: Game = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out":
				_out = v
			"tag":
				_tag = v
			"shot":
				_do_shot = true
			"gpu":
				_gpu_frames = int(v)
			"preset":
				GraphicsPresets.select(v)
	if _out == "":
		push_error("wind_field_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("wind_field_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	for i in 4000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = _main.get_node("Game")
	await get_tree().create_timer(3.0, true, false, true).timeout
	var mode := "аналитика"
	if _game.air.has_method("is_air_field_on") and bool(_game.air.call("is_air_field_on")):
		mode = "поле"
	print("wind_field_shot: режим ветра — %s" % mode)
	if _do_shot:
		var dbg := _game.get_node_or_null("WindFieldDebug")
		if dbg == null or not dbg.has_method("_toggle"):
			_fail("нет WindFieldDebug")
			return
		dbg.call("_toggle")
		for i in 30:
			await RenderingServer.frame_post_draw
		var path := "%s/%s_f3.png" % [_out, _tag]
		var img := get_viewport().get_texture().get_image()
		print("wind_field_shot: %s (%s)" % [path, error_string(img.save_png(path))])
	if _gpu_frames > 0:
		await _measure()
	print("wind_field_shot: OK %s" % _tag)
	await _quit(0)


## Среднее GPU-время кадра (общий кадр окна — трава в нём одна из многих статей; сравнение
## делает вызывающий скрипт между двумя запусками, с полем и без).
func _measure() -> void:
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 10:
		await RenderingServer.frame_post_draw
	var g := 0.0
	for i in _gpu_frames:
		await RenderingServer.frame_post_draw
		g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	print("wind_field_shot: GPU %s: кадр %.3f мс" % [_tag, g / _gpu_frames])
