extends Node
## Проба FPS/времени загрузки (карточка docs/archive/plan/build/03-zamery-fps-zagruzka.md, tools/bench/).
## Не игровой код: инстанцирует scenes/main.tscn как обычный запуск (--autostart --autopilot),
## сама переключает камеру по отметкам симуляционного времени полёта и печатает метрики.
## Управляют tools/bench/frame_bench.sh и tools/bench/load_bench.sh.
##
##   godot --path . --audio-driver Dummy --disable-vsync --fullscreen --resolution 1920x1080 \
##     res://tools/bench/probe.tscn -- --location=ongudai --wing=sport --mode=fps \
##     --marks=2:cockpit,2:chase,30:cockpit,30:chase,60:cockpit,60:chase --sample=4
##   --mode=fps    на каждой отметке "<с сим.времени полёта>:<камера>" сэмплировать --sample= с
##                 рендер-кадров, печатать средний и 1%-low FPS
##   --mode=load   напечатать время от старта скрипта до первого кадра полёта (FLYING) и выйти
##                 (движок уже запущен — время не включает старт самого Godot)
## Печатает:
##   BENCH <location> <camera>@<t>с: avg=XX.X fps 1%low=YY.Y fps (N кадров)
##   LOAD <location>: Z.ZZ с

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 110.0

var _location := ""
var _wing := ""
var _mode := "fps"
var _sample_s := 4.0
var _marks: Array = []  # [[t_s, camera], ...]
var _main: Node


func _ready() -> void:
	var t_start := Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--location="):
			_location = a.substr(11)
		elif a.begins_with("--wing="):
			_wing = a.substr(7)
		elif a.begins_with("--mode="):
			_mode = a.substr(7)
		elif a.begins_with("--sample="):
			_sample_s = float(a.substr(9))
		elif a.begins_with("--marks="):
			for part in a.substr(8).split(","):
				var kv := part.split(":")
				if kv.size() == 2:
					_marks.append([float(kv[0]), kv[1]])
	if _location == "":
		push_error("probe: нужен --location=")
		get_tree().quit(1)
		return
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))

	var args := PackedStringArray(["--autostart", "--autopilot", "--location=" + _location])
	if _wing != "":
		args.append("--wing=" + _wing)
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	main.set("opts", LaunchOptions.parse(args))
	add_child(main)

	for i in 3600:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не долетели до FLYING")
		return

	if _mode == "load":
		var dt_ms := Time.get_ticks_msec() - t_start
		print("LOAD %s: %.2f с" % [_location, dt_ms / 1000.0])
		await _quit(0)
		return

	# игра ставит VSync и предел кадров из game.json → display (QL-13) поверх --disable-vsync
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var game: Game = main.get_node("Game")
	for m in _marks:
		var t_mark: float = m[0]
		var cam: String = m[1]
		while game.sim_time_s < t_mark and int(main.get("state")) == 2:
			await get_tree().physics_frame
		if int(main.get("state")) != 2:
			_fail("сел раньше отметки %s" % t_mark)
			return
		game.camera.set_mode(cam)
		await _sample(cam, t_mark)
	print("probe: OK %s" % _location)
	await _quit(0)


func _sample(cam: String, t_mark: float) -> void:
	var dts: PackedFloat64Array = []
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) < _sample_s * 1e6:
		await RenderingServer.frame_post_draw
		dts.append(get_process_delta_time())
	if dts.is_empty():
		print("BENCH %s %s@%sс: нет кадров" % [_location, cam, t_mark])
		return
	var sum := 0.0
	for d in dts:
		sum += d
	var mean_dt: float = sum / dts.size()
	var avg_fps: float = 1.0 / mean_dt if mean_dt > 0.0 else 0.0
	var sorted_dts := dts.duplicate()
	sorted_dts.sort()
	var n1 := maxi(1, int(ceil(sorted_dts.size() * 0.01)))
	var worst := sorted_dts.slice(sorted_dts.size() - n1, sorted_dts.size())
	var wsum := 0.0
	for d in worst:
		wsum += d
	var worst_mean: float = wsum / worst.size()
	var low_fps: float = 1.0 / worst_mean if worst_mean > 0.0 else 0.0
	print(
		(
			"BENCH %s %s@%sс: avg=%.1f fps 1%%low=%.1f fps (%d кадров)"
			% [_location, cam, t_mark, avg_fps, low_fps, dts.size()]
		)
	)


func _fail(why: String) -> void:
	print("probe: FAIL %s (%s)" % [_location, why])
	await _quit(1)


## Убрать игровой мир перед выходом (как main.gd::_quit) — иначе аудиосервер оставляет
## висящие генераторы и движок ругается на утечки объектов при выходе.
func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
