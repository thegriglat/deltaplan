extends Node
## Замер рывков «Подождать час» (Q-17): время кадра во время ожидания (макс., p99, среднее).
## Окно, не headless: godot --path . res://tools/bench/wait_bench.tscn -- [--speed=60] [--hour=12]
## (под dp lock gpu). Пишет строку WAIT_BENCH в stdout.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _frames: PackedFloat32Array = []
var _recording := false
var _last_us := 0


func _ready() -> void:
	var speed := 60.0
	var hour := 12.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--speed="):
			speed = float(a.substr(8))
		elif a.begins_with("--hour="):
			hour = float(a.substr(7))
	var main: Node = MAIN_SCENE.instantiate()
	main.opts = LaunchOptions.new()
	main.name = "WaitBenchMain"
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	var s := FlightSettings.defaults()
	s.start_hour = hour
	await main.call("_fly", s)
	game._cfg["wait_speed"] = speed
	if OS.get_environment("WR") != "":
		game._cfg["wait_refresh_s"] = float(OS.get_environment("WR"))
	for i in 600:
		await get_tree().process_frame
	_last_us = Time.get_ticks_usec()
	_recording = true
	if OS.get_environment("BASE") != "":
		_recording = true
		for i in 600:
			await get_tree().process_frame
		_recording = false
		_frames.sort()
		print("WAIT_BENCH baseline mean=%.1f p99=%.1f max=%.1f мс" % [_mean(), _frames[int(_frames.size() * 0.99)], _frames[-1]])
		get_tree().quit()
		return
	if OS.get_environment("NOREC") != "":
		game.air_runtime.recompute_enabled = false
	var ok := game.start_wait()
	var t0 := Time.get_ticks_usec()
	var h0 := game.sky.clock.hour
	while game.is_waiting():
		await get_tree().process_frame
	_recording = false
	var wall := float(Time.get_ticks_usec() - t0) / 1.0e6
	var rt = game.air_runtime
	print("WAIT_BENCH air_runtime main_ms=%s stage_ms=%s busy=%s" % [rt._main_ms if rt != null else -1, str(rt._stage_ms) if rt != null else "", rt.busy() if rt != null else ""])
	var worst := []
	for i in _frames.size():
		if _frames[i] > 400.0:
			worst.append("%d:%.0f" % [i, _frames[i]])
	print("WAIT_BENCH кадры >400 мс (номер:мс): ", worst)
	_frames.sort()
	var n := _frames.size()
	var sum := 0.0
	for f in _frames:
		sum += f
	print("WAIT_BENCH speed=%.0f ok=%s wall=%.1f s hours=+%.2f frames=%d mean=%.1f p99=%.1f max=%.1f мс" % [
		speed, ok, wall, game.sky.clock.hour - h0, n, sum / maxf(n, 1), _frames[int(n * 0.99)] if n > 0 else 0.0, _frames[n - 1] if n > 0 else 0.0])
	get_tree().quit()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _recording:
		var ft := float(now - _last_us) / 1000.0
		_frames.append(ft)
		var rt = get_node("WaitBenchMain/Game").air_runtime if has_node("WaitBenchMain/Game") else null
		if ft > 400.0 and rt != null:
			print("WAIT_BENCH большой кадр %.0f мс: стадия %s, stage_ms %s" % [ft, rt.Stage.keys()[rt._stage], str(rt._stage_ms)])
	_last_us = now


func _mean() -> float:
	var sum := 0.0
	for f in _frames:
		sum += f
	return sum / maxf(_frames.size(), 1)
