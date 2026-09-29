extends Node
## Кадры и замер FPS отладочных слоёв (DebugOverlays): F1 — производительность, F5 — ветер,
## F6 — термики, всё вместе. Запуск (временный профиль):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/debug_overlay_shot.tscn -- --out=<каталог> [флаги LaunchOptions…]
## Флаги игры (--location, --site, --hour, --wind, --from, --air-start …) передаются как есть,
## --autostart --autopilot добавляются сами. Пишет <out>/0N_*.png, печатает строки FPS.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const MEASURE_S := 6.0

var _out := ""
var _main: Node
var _game: Game
var _cam: Camera3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var game_args := PackedStringArray(["--autostart", "--autopilot"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		else:
			game_args.append(a)
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(game_args))
	add_child(_main)
	_run()


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _fps(label: String) -> float:
	var f0 := Engine.get_frames_drawn()
	var t0 := Time.get_ticks_usec()
	await _wait(MEASURE_S)
	var fps := (Engine.get_frames_drawn() - f0) / ((Time.get_ticks_usec() - t0) / 1.0e6)
	print("FPS %s: %.1f" % [label, fps])
	return fps


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var f := _out.path_join(name)
	get_viewport().get_texture().get_image().save_png(f)
	print("shot: ", f)


## Своя камера: сбоку от пилота поперёк ветра, выше и дальше — видно склон и сетку стрелок.
func _side_cam(dist: float, up: float, look_ahead: float) -> void:
	var p := _game.glider.global_position
	var w: Vector3 = _game.air.call("mean_wind_at", p)
	var wd := Vector3(w.x, 0, w.z).normalized() if w.length() > 0.1 else Vector3.FORWARD
	var side := wd.cross(Vector3.UP).normalized()
	if _cam == null:
		_cam = Camera3D.new()
		_cam.far = 60000.0
		_cam.fov = 60.0
		add_child(_cam)
	_cam.global_position = p + side * dist + Vector3.UP * up
	_cam.look_at(p + wd * look_ahead, Vector3.UP)
	_cam.current = true


func _run() -> void:
	_game = _main.get_node("Game")
	for i in 3000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	_game.camera.set_mode("chase")
	await _wait(8.0)
	# Замер: погоня, без слоёв / F5 / F6 / всё — в полёте и на паузе (картинка стоит,
	# разброс меньше; слои работают и на паузе).
	for paused: bool in [false, true]:
		get_tree().paused = paused
		var tag := " (пауза)" if paused else " (полёт)"
		var base := await _fps("без слоёв" + tag)
		_press("debug_wind")
		await _wait(1.0)
		var fw := await _fps("F5" + tag)
		_press("debug_wind")
		_press("debug_thermals")
		await _wait(1.0)
		var ft := await _fps("F6" + tag)
		_press("debug_wind")
		_press("debug_perf")
		await _wait(1.0)
		var fa := await _fps("F1+F5+F6" + tag)
		_press("debug_wind")
		_press("debug_thermals")
		_press("debug_perf")
		await _wait(1.0)
		print(
			(
				"FPS итог%s: без %.1f, F5 %.1f (%+.1f%%), F6 %.1f (%+.1f%%), всё %.1f (%+.1f%%)"
				% [
					tag,
					base,
					fw,
					(fw / base - 1) * 100,
					ft,
					(ft / base - 1) * 100,
					fa,
					(fa / base - 1) * 100
				]
			)
		)
	get_tree().paused = false
	_press("debug_perf")
	await _wait(1.0)
	# Кадры.
	await _shoot("01_f1_производительность.png")
	_press("debug_perf")
	_press("debug_wind")
	_side_cam(1400.0, 500.0, 0.0)
	await _wait(1.5)
	await _shoot("02_f5_ветер.png")
	_press("debug_wind")
	_press("debug_thermals")
	_side_cam(3500.0, 900.0, 1500.0)
	await _wait(1.0)
	await _shoot("03_f6_термики.png")
	_press("debug_wind")
	_press("debug_perf")
	_side_cam(1800.0, 600.0, 600.0)
	await _wait(1.5)
	await _shoot("04_всё_вместе.png")
	_main.queue_free()
	for i in 3:
		await get_tree().process_frame
	get_tree().quit(0)
