extends Node
## Время кадра игры для полётного замера термиков (TB-14, контракт TB5 v1, поле frame). Не игровой код:
## инстанцирует scenes/main.tscn как tools/bench/probe.gd (--autostart --autopilot), ждёт полёта,
## снимает вертикальную синхронизацию и меряет интервалы между кадрами --sim-s секунд симуляции.
## Нужен дисплей (под замком GPU); пресет графики — тот, что в профиле (run_flight.sh ставит medium).
## Флаг шаблона пузыря (thermal.bubble_template) лежит в user://configs/atmosphere.json профиля.
##
##   godot --path . --audio-driver Dummy --disable-vsync --resolution 1920x1080 \
##     res://tools/research/thermal_bubble/flight/flight_frame.tscn -- --location=ongudai --seed=1 \
##     --sim-s=180 --out=<json>

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 900.0
const WARMUP_S := 10.0
const HITCH_MS := 50.0

var _main: Node
var _game: Game
var _dts := PackedFloat64Array()
var _t_last := 0
var _sampling := false


func _ready() -> void:
	var o := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			var kv := a.substr(2).split("=", true, 1)
			o[kv[0]] = kv[1]
	var location := String(o.get("location", "ongudai"))
	var sim_s := float(o.get("sim-s", 180))
	var out := String(o.get("out", ""))
	get_tree().create_timer(TIMEOUT_S, true).timeout.connect(_fail.bind("таймаут"))
	# прогноз — как в flight_probe.gd (FlightSettings.defaults()); ветер не по курсу старта
	var args := PackedStringArray(
		[
			"--autostart", "--autopilot", "--location=" + location, "--seed=" + String(o.get("seed", "1")),
			"--temp=26", "--wind=3", "--from=270", "--sky=clear", "--hour=13", "--bots=0",
		]
	)
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(args))
	add_child(_main)
	for i in 6000:
		if int(_main.get("state")) == 2:
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING")
		return
	_game = _main.get_node("Game")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_game.camera.set_mode("chase")
	var t_start := 0.0
	while int(_main.get("state")) == 2 and _game.sim_time_s < WARMUP_S:
		await get_tree().physics_frame
	t_start = _game.sim_time_s
	_t_last = 0
	_sampling = true
	var ended := "time"
	while _game.sim_time_s - t_start < sim_s:
		await get_tree().physics_frame
		if int(_main.get("state")) != 2:
			ended = "state"
			break
	_sampling = false
	var res := _stats()
	res["sim_s"] = snappedf(_game.sim_time_s - t_start, 0.1)
	res["end"] = ended
	res["location"] = location
	if out != "":
		var tmp := out + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(JSON.stringify(res, "  ", false) + "\n")
		f.close()
		DirAccess.rename_absolute(tmp, out)
	print("flight_frame: OK ", JSON.stringify(res))
	await _quit(0)


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _sampling and _t_last > 0:
		_dts.append((now - _t_last) / 1000.0)
	_t_last = now


func _stats() -> Dictionary:
	var a := _dts.duplicate()
	if a.is_empty():
		return {"ms_mean": 0.0, "ms_p99": 0.0, "ms_max": 0.0, "hitch_50ms": 0, "n": 0}
	var sum := 0.0
	var hitch := 0
	for d in a:
		sum += d
		if d > HITCH_MS:
			hitch += 1
	a.sort()
	return {
		"ms_mean": snappedf(sum / a.size(), 0.001),
		"ms_p99": snappedf(a[clampi(int(ceil(0.99 * a.size())) - 1, 0, a.size() - 1)], 0.001),
		"ms_max": snappedf(a[a.size() - 1], 0.001),
		"hitch_50ms": hitch,
		"n": a.size(),
	}


func _fail(why: String) -> void:
	print("flight_frame: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
