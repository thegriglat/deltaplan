extends Node
## SP-1 (а), продолжение: постоянный «поток GPU» — свой локальный RD (RuntimeGpu) создаётся,
## используется и освобождается в одном Thread на всю жизнь; главный поток только ставит задачи
## и забирает итог. Решатель области 400 м (Онгудай 12:00, 3 м/с со 150°, пара) как в полёте:
## первая задача холодная, следующие — тёплый старт от state() прошлой (час +15 мин).
## Кадры главного потока — со временем от начала, события потока — тоже: где рывки.
## Плюс A7: можно ли записывать следующую порцию до sync() (submit → compute_list_begin)?
##
##   XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock godot --path . \
##     --audio-driver Dummy --resolution 1280x720 res://tools/research/air_speed/gpu_thread_probe.tscn \
##     -- [--out=tools/research/air_speed/out/gpu_thread.json]

var _out := "res://tools/research/air_speed/out/gpu_thread.json"
var _th: Thread
var _mx := Mutex.new()
var _sem := Semaphore.new()
var _queue: Array = []
var _done: Array = []
var _events: Array = []  # [t_ms, событие]
var _quit := false
var _t0 := 0
var _frames: Array = []  # [t_ms, dt_ms]
var _t_last := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	_t0 = Time.get_ticks_usec()
	_run.call_deferred()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _t_last > 0:
		_frames.append([(now - _t0) / 1000.0, (now - _t_last) / 1000.0])
	_t_last = now


func _ev(s: String) -> void:
	_mx.lock()
	_events.append([(Time.get_ticks_usec() - _t0) / 1000.0, s])
	_mx.unlock()


func _gpu_loop() -> void:
	_ev("init begin")
	var g := AirRuntime.RuntimeGpu.new()
	var ok := g.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES + AirWindowJob.WINDOW_SHADERS)
	_ev("init end ok=%s" % ok)
	_a7(g.rd)
	while true:
		_sem.wait()
		_mx.lock()
		var task: Variant = _queue.pop_front() if not _queue.is_empty() else null
		var q := _quit
		_mx.unlock()
		if task == null:
			if q:
				break
			continue
		var job := AirPicardJob.new()
		job.case = task.case
		job.mech = true
		job.warm = task.warm
		_ev("job start")
		var t1 := Time.get_ticks_usec()
		var good := job.start(g) and job.run_blocking()
		var wall := (Time.get_ticks_usec() - t1) / 1000.0
		_ev("job solved")
		var res := {
			ok = good, err = job.error, wall_ms = wall, gpu_ms = job.gpu_ms_total,
			record_cpu_ms = job.record_cpu_ms, sync_wait_ms = job.sync_wait_ms,
			iters = job.results.map(func(r: Dictionary) -> int: return int(r.iters)),
			warm = not task.warm.is_empty(),
		}
		if good:
			var t2 := Time.get_ticks_usec()
			res.state = job.state()
			res.pd = job.parent_data()
			res.read_ms = (Time.get_ticks_usec() - t2) / 1000.0
			var t3 := Time.get_ticks_usec()
			res.field = job.field()  # сборка WindField тоже здесь (в игре — field_async)
			res.field_ms = (Time.get_ticks_usec() - t3) / 1000.0
		job.release()
		_ev("job done")
		_mx.lock()
		_done.append(res)
		_mx.unlock()
	g.destroy()
	_ev("destroyed")


## A7: после submit() — запись следующего списка до sync(): ошибка или можно?
func _a7(rd: RenderingDevice) -> void:
	var b := rd.storage_buffer_create(1024)
	rd.submit()
	var t := Time.get_ticks_usec()
	rd.buffer_clear(b, 0, 1024)  # команда до sync
	_ev("A7: buffer_clear после submit до sync — вызов прошёл (%.2f мс), смотри ошибки в логе" % ((Time.get_ticks_usec() - t) / 1000.0))
	rd.sync()
	rd.free_rid(b)


func _run() -> void:
	for i in 30:
		await get_tree().process_frame
	_ev("main: thread start")
	_th = Thread.new()
	_th.start(_gpu_loop)
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	var warm := {}
	var rows := []
	for r in 4:
		var hour := 12.0 + 0.25 * r
		# вход места — в WorkerThreadPool (как AirRuntime._prep_task)
		var holder := {}
		_ev("prep start h=%.2f" % hour)
		var tid := WorkerThreadPool.add_task(func() -> void:
			holder.case = AirRuntime.PreparedCase.from_case(
				AirPlace.domain_case(lw[0], lw[1], loc, 400.0, hour, 3.0, 150.0)))
		while not WorkerThreadPool.is_task_completed(tid):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(tid)
		_ev("prep end")
		var f0 := _frames.size()
		var t1 := Time.get_ticks_usec()
		_mx.lock()
		_queue.append({case = holder.case, warm = warm})
		_mx.unlock()
		_sem.post()
		var res: Dictionary = {}
		while true:
			await get_tree().process_frame
			_mx.lock()
			if not _done.is_empty():
				res = _done.pop_front()
			_mx.unlock()
			if not res.is_empty():
				break
		var wall := (Time.get_ticks_usec() - t1) / 1000.0
		var fr := _frames.slice(f0)
		var dts: Array[float] = []
		for x: Array in fr:
			dts.append(float(x[1]))
		warm = res.get("state", {})
		res.erase("state")
		res.erase("pd")
		res.erase("field")
		res.main_wall_ms = wall
		res.hour = hour
		res.frame = _stats(dts)
		rows.append(res)
		print("[row] ", JSON.stringify(res))
	_mx.lock()
	_quit = true
	_mx.unlock()
	_sem.post()
	_th.wait_to_finish()
	var p := ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify({rows = rows, events = _events, frames = _frames}) + "\n")
	f.close()
	for e: Array in _events:
		print("[ev] %8.1f %s" % [e[0], e[1]])
	var big := _frames.filter(func(x: Array) -> bool: return float(x[1]) > 40.0)
	print("[big frames] ", big)
	get_tree().quit(0)


static func _stats(a: Array[float]) -> Dictionary:
	if a.is_empty():
		return {}
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	return {n = s.size(), mean = sum / s.size(), p50 = s[s.size() / 2],
		p95 = s[mini(s.size() - 1, int(0.95 * s.size()))], max = s[-1]}
