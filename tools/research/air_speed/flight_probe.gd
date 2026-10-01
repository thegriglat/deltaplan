extends Node
## SP-1: разбивка стены пересчёта поля в полёте (AirRuntime, C9 v2) в настоящей игре.
## Меню → «Лететь» (место, час, ветер) → полёт → N пересчётов по сроку (час +15 мин, тёплый старт,
## как в игре) → по кадрам: этап AirRuntime, время главного потока в AirRuntime._process, порции
## (метки GPU начала/конца — простои GPU между порциями), отрисовка кадра (GPU), рывок после
## подачи поля (термики AM-07); затем AirThermals.build отдельно — в главном и в рабочем потоке.
##
##   XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock godot --path . \
##     --audio-driver Dummy --resolution 1280x720 res://tools/research/air_speed/flight_probe.tscn \
##     -- --out=tools/research/air_speed/out/flight_1280.json [--runs=3] [--variant=base]
##
## Варианты (только инструментовка снаружи AirRuntime, код игры не меняется):
##   base      — как в игре: poll() раз в кадр;
##   slice<ms> — в этапах решателя области и окон ещё poll_slice(<ms>) за кадр (порции подряд с
##               sync в том же кадре, как экран загрузки), например slice8, slice16;
##   gapoff    — бюджет порции не ограничен промежутком кадров (frame_gap_limit = false, 20 мс).
##   thread<ms> — прототип (а): AirRuntime не пересчитывает; решатель области (пара, тёплый старт,
##               час +15 мин) — в своём постоянном Thread со своим локальным RD (run_blocking,
##               chunk_ms = <ms>), игра рисует кадры; меряются кадры и стена.
## AirRuntime не опрашивает себя сам (set_process(false)) — его _process зовёт этот узел, чтобы
## мерить время главного потока точно.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _out := "res://tools/research/air_speed/out/flight.json"
var _runs := 3
var _variant := "base"
var _location := "ongudai"
var _hour := 12.0
var _wind := 3.0
var _wdir := 150.0
## Окно полёта (игра разворачивает своё окно по настройкам; --resolution не держится) — WxH.
var _win := Vector2i.ZERO
var _main: Node
var _game: Game
var _rt: AirRuntime
var _vp := RID()
var _drive := false
var _t_last := 0
var _rec: Array = []  # строки кадров текущего прогона
var _recording := false
var _t_run := 0
var _seen_begin := {}
var _chunks: Array = []
var _jobs: Array = []
var _cond := {}
var _report := {}


func _ready() -> void:
	process_priority = 1000
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"out":
				_out = v
			"runs":
				_runs = int(v)
			"variant":
				_variant = v
			"location":
				_location = v
			"hour":
				_hour = float(v)
			"wind":
				_wind = float(v)
			"wdir":
				_wdir = float(v)
			"win":
				var wh := v.split("x")
				_win = Vector2i(int(wh[0]), int(wh[1]))
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	_run.call_deferred()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	var dt_ms := (now - _t_last) / 1000.0 if _t_last > 0 else 0.0
	_t_last = now
	if not _drive or not is_instance_valid(_rt):
		return
	var stage := int(_rt.get("_stage"))
	var extra_ms := 0.0
	var slice := _variant.begins_with("slice")
	if slice and stage == AirRuntime.Stage.SOLVE:
		var job: AirGpuJob = _rt.get("_job")
		if job != null and not job.is_done():
			var t := Time.get_ticks_usec()
			job.poll_slice(float(_variant.trim_prefix("slice")))
			extra_ms = (Time.get_ticks_usec() - t) / 1000.0
	if slice and stage == AirRuntime.Stage.WINDOWS:
		var cl: AirClipmap = _rt.get("_clip")
		var wj: AirGpuJob = cl.get("_job") if cl != null else null
		if wj != null and not wj.is_done() and wj.error == "":
			var t := Time.get_ticks_usec()
			wj.poll_slice(float(_variant.trim_prefix("slice")))
			extra_ms = (Time.get_ticks_usec() - t) / 1000.0
	if _variant == "gapoff":
		for j: AirGpuJob in _live_jobs():
			j.frame_gap_limit = false
	var t0 := Time.get_ticks_usec()
	_rt._process(dt_ms / 1000.0)
	var rt_ms := (Time.get_ticks_usec() - t0) / 1000.0 + extra_ms
	_note_jobs()
	_read_stamps()
	if _recording:
		var cl: AirClipmap = _rt.get("_clip")
		_rec.append({
			t = (now - _t_run) / 1000.0,
			dt = dt_ms,
			stage = stage,
			sub = _clip_sub(cl) if stage == AirRuntime.Stage.WINDOWS else "",
			rt_ms = rt_ms,
			rgpu = RenderingServer.viewport_get_measured_render_time_gpu(_vp),
			rcpu = RenderingServer.viewport_get_measured_render_time_cpu(_vp),
			phys = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			proc = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			applied = _rt.applied_count,
		})


func _live_jobs() -> Array:
	var out := []
	var j: Variant = _rt.get("_job")
	if j != null:
		out.append(j)
	var cl: AirClipmap = _rt.get("_clip")
	if cl != null and cl.get("_job") != null:
		out.append(cl.get("_job"))
	return out


func _note_jobs() -> void:
	for j: AirGpuJob in _live_jobs():
		if not _jobs.has(j):
			_jobs.append(j)


## Метки порций: после sync метки последней порции видны на RD (общий RD AirRuntime).
func _read_stamps() -> void:
	var g: AirGpu = _rt.get("_gpu")
	if g == null or g.rd == null:
		return
	var rd := g.rd
	var b := -1
	var e := -1
	for i in rd.get_captured_timestamps_count():
		var nm := rd.get_captured_timestamp_name(i)
		if nm == "air_chunk_begin":
			b = rd.get_captured_timestamp_gpu_time(i)
		elif nm == "air_chunk_end":
			e = rd.get_captured_timestamp_gpu_time(i)
	if b > 0 and e >= b and not _seen_begin.has(b):
		_seen_begin[b] = true
		if _recording:
			_chunks.append({b = b, e = e, t_sync = (Time.get_ticks_usec() - _t_run) / 1000.0})


static func _clip_sub(cl: AirClipmap) -> String:
	if cl == null:
		return "-"
	var cur := int(cl.get("_cur"))
	if cur < 0:
		return "idle"
	var row: Dictionary = cl.get("_cur_row")
	if int(row.get("task", -1)) >= 0:
		return "w%d:prep" % cur
	if bool(cl.get("_waiting_field")):
		return "w%d:field" % cur
	if cl.get("_job") != null:
		return "w%d:gpu" % cur
	return "w%d:wait" % cur


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(PackedStringArray()))
	add_child(_main)
	_game = _main.get_node("Game")
	for i in 1200:
		if _game.settings != null and int(_main.get("state")) == 0:
			break
		await get_tree().process_frame
	for i in 10:
		await get_tree().process_frame
	(_main.get("opts") as LaunchOptions).autostart = true
	var s: FlightSettings = (_main.get("flight") as FlightSettings).duplicate()
	s.location_id = _location
	s.site_id = ""
	s.start_hour = _hour
	s.wind_speed_kmh = _wind * 3.6
	s.wind_from_deg = _wdir
	s.wind_into_launch = false
	var start_menu: StartMenu = _main.get_node("UI/StartMenu")
	var t_load := Time.get_ticks_usec()
	start_menu.fly_requested.emit(s)
	while int(_main.get("state")) != 2:
		await get_tree().process_frame
		if int(_main.get("state")) == 0 or (Time.get_ticks_usec() - t_load) / 1e6 > 300.0:
			push_error("flight_probe: полёт не начался")
			get_tree().quit(1)
			return
	_rt = _game.air_runtime
	if _win != Vector2i.ZERO:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		await get_tree().process_frame
		DisplayServer.window_set_size(_win)
		for i in 30:
			await get_tree().process_frame
	_report.env = {
		godot = Engine.get_version_info().string,
		adapter = RenderingServer.get_video_adapter_name(),
		window = DisplayServer.window_get_size(),
		viewport = get_viewport().get_visible_rect().size,
		vsync = DisplayServer.window_get_vsync_mode(),
		max_fps = Engine.max_fps,
		refresh_hz = DisplayServer.screen_get_refresh_rate(),
		variant = _variant,
		location = _location, hour = _hour, wind = _wind, wdir = _wdir,
		load_s = (Time.get_ticks_usec() - t_load) / 1e6,
		load_info = _rt.last_info,
	}
	print("flight_probe: полёт, загрузка %.1f с; %s" % [_report.env.load_s, _rt.last_info])
	_rt.set_process(false)
	_drive = true
	for i in 120:  # 2 с кадров полёта (сдвиг окон за пилотом мог начаться)
		await get_tree().process_frame
	while _rt.busy():
		await get_tree().process_frame
	# фон: 3 с кадров без расчёта
	_start_rec()
	await _frames_for(3.0)
	_report.idle = _rec.duplicate()
	_recording = false
	_cond = _rt.current_conditions().duplicate()
	_rt.conditions_fn = func() -> Dictionary: return _cond
	_report.runs = []
	if _variant.begins_with("thread"):
		await _thread_runs(float(_variant.trim_prefix("thread")))
		_runs = 0
	for r in _runs:
		_cond.hour = float(_cond.hour) + 0.25
		_start_rec()
		_jobs.clear()
		_chunks.clear()
		var n0 := _rt.applied_count
		var f0 := _rt.failed_count
		while _rt.applied_count == n0 and _rt.failed_count == f0:
			await get_tree().process_frame
			if (Time.get_ticks_usec() - _t_run) / 1e6 > 90.0:
				break
		var t_apply := (Time.get_ticks_usec() - _t_run) / 1000.0
		await _frames_for(2.0)  # рывок после подачи (термики из поля — AM-07)
		_recording = false
		var cl: AirClipmap = _rt.get("_clip")
		var run := {
			info = _rt.last_info.duplicate(true),
			error = _rt.last_error,
			t_apply_ms = t_apply,
			frames = _rec.duplicate(),
			chunks = _chunks.duplicate(),
			jobs = _jobs.map(_job_row),
			windows = cl.history.slice(-2) if cl != null else [],
		}
		run.info.erase("windows")
		_report.runs.append(run)
		print("flight_probe: прогон %d: %.2f с, %s" % [r, t_apply / 1000.0, _rt.last_info.get("iters")])
	_drive = false
	_rt.set_process(true)
	await _thermals_probe()
	_save()
	_main.queue_free()
	for i in 3:
		await get_tree().process_frame
	get_tree().quit(0)


# ---------------------------------------------------------------- прототип: поток GPU в игре

var _th_mx := Mutex.new()
var _th_sem := Semaphore.new()
var _th_q: Array = []
var _th_done: Array = []
var _th_quit := false
var _th_init := {}


func _gpu_loop(chunk: float) -> void:
	var t0 := Time.get_ticks_usec()
	var g := AirRuntime.RuntimeGpu.new()
	var ok := g.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES)
	_th_mx.lock()
	_th_init = {ok = ok, init_ms = (Time.get_ticks_usec() - t0) / 1000.0}
	_th_mx.unlock()
	while true:
		_th_sem.wait()
		_th_mx.lock()
		var task: Variant = _th_q.pop_front() if not _th_q.is_empty() else null
		var q := _th_quit
		_th_mx.unlock()
		if task == null:
			if q:
				break
			continue
		var job := AirPicardJob.new()
		job.case = task.case
		job.mech = true
		job.warm = task.warm
		job.chunk_ms = chunk
		job.frame_gap_limit = false
		var t1 := Time.get_ticks_usec()
		var good := job.start(g) and job.run_blocking()
		var res := {
			ok = good, wall_ms = (Time.get_ticks_usec() - t1) / 1000.0, gpu_ms = job.gpu_ms_total,
			record_cpu_ms = job.record_cpu_ms, sync_wait_ms = job.sync_wait_ms,
			chunks = job.chunks, max_chunk_gpu_ms = job.max_chunk_gpu_ms,
			iters = job.results.map(func(r: Dictionary) -> int: return int(r.iters)),
		}
		if good:
			res.state = job.state()
		job.release()
		_th_mx.lock()
		_th_done.append(res)
		_th_mx.unlock()
	g.destroy()


func _thread_runs(chunk: float) -> void:
	_rt.recompute_enabled = false
	var th := Thread.new()
	_start_rec()
	th.start(_gpu_loop.bind(chunk))
	while true:
		await get_tree().process_frame
		_th_mx.lock()
		var ready := not _th_init.is_empty()
		_th_mx.unlock()
		if ready:
			break
	_recording = false
	_report.thread_init = {info = _th_init, frames = _rec.duplicate()}
	var place: Dictionary = _rt.get("_place")
	var warm: Dictionary = (_rt.get("_warm") as Dictionary)
	for r in _runs:
		_cond.hour = float(_cond.hour) + 0.25
		var c := _cond.duplicate()
		_start_rec()
		var holder := {}
		var tid := WorkerThreadPool.add_task(AirRuntime._prep_task.bind(place, c, holder))
		while not WorkerThreadPool.is_task_completed(tid):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(tid)
		var t_prep := (Time.get_ticks_usec() - _t_run) / 1000.0
		_th_mx.lock()
		_th_q.append({case = holder.case, warm = warm})
		_th_mx.unlock()
		_th_sem.post()
		var res := {}
		while res.is_empty():
			await get_tree().process_frame
			_th_mx.lock()
			if not _th_done.is_empty():
				res = _th_done.pop_front()
			_th_mx.unlock()
		var t_done := (Time.get_ticks_usec() - _t_run) / 1000.0
		await _frames_for(0.5)
		_recording = false
		warm = res.get("state", {})
		res.erase("state")
		_report.runs.append({thread = res, t_prep_ms = t_prep, t_done_ms = t_done, frames = _rec.duplicate()})
		print("flight_probe: поток GPU, прогон %d: подготовка %.0f мс, решатель %.0f мс, %s" % [r, t_prep, t_done - t_prep, res.iters])
	_th_mx.lock()
	_th_quit = true
	_th_mx.unlock()
	_th_sem.post()
	th.wait_to_finish()


func _job_row(j: AirGpuJob) -> Dictionary:
	var log := []
	for v: Vector3 in j.chunk_log:
		log.append([v.x, v.y, v.z])
	return {
		kind = j.get_script().get_global_name(),
		chunks = j.chunks,
		gpu_ms = j.get("gpu_ms_total"),
		poll_cpu_ms = j.poll_cpu_ms,
		record_cpu_ms = j.record_cpu_ms,
		sync_wait_ms = j.sync_wait_ms,
		max_poll_cpu_ms = j.max_poll_cpu_ms,
		iters = j.get("results").map(func(x: Dictionary) -> int: return int(x.iters)),
		chunk_log = log,
	}


func _start_rec() -> void:
	_rec.clear()
	_t_run = Time.get_ticks_usec()
	_recording = true


func _frames_for(sec: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) / 1e6 < sec:
		await get_tree().process_frame


## AirThermals.build на поле в атмосфере: в главном потоке (как ThermalField._update_air) и в
## рабочем (WorkerThreadPool) — стена, кадры во время, совпадение источников.
func _thermals_probe() -> void:
	var atmo: Atmosphere = _game.air as Atmosphere
	if atmo == null or atmo.air_field == null or atmo.air_field.levels.is_empty():
		return
	var tf: ThermalField = atmo.field
	var f: WindField = atmo.air_field.levels[atmo.air_field.levels.size() - 1]
	var cfg: Dictionary = (tf.get("_cfg") as Dictionary).duplicate()
	cfg["duty"] = float((tf.get("_w") as Dictionary).thermal_duty)
	cfg["cloudbase_msl"] = tf.cloudbase_msl
	cfg["height_fn"] = tf.ground.height
	cfg["pick_fn"] = AirThermals.pick_in_column.bind(
		f, tf.ground, int(tf.get("_seed")), int(tf.get("_cfg").source_candidates)
	)
	var main_ms: Array[float] = []
	var ref: AirThermals
	for i in 3:
		var src := AirThermals.new()
		var t0 := Time.get_ticks_usec()
		src.build(f, cfg)
		main_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		ref = src
		await get_tree().process_frame
	# ThermalField._update_air целиком (ключ сброшен — пересборка)
	var upd_ms: Array[float] = []
	for i in 2:
		tf.set("_air_key", "")
		var t0 := Time.get_ticks_usec()
		tf.call("_update_air")
		upd_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		await get_tree().process_frame
	var thr := []
	for i in 3:
		var src := AirThermals.new()
		var t0 := Time.get_ticks_usec()
		var gaps: Array[float] = []
		var tl := Time.get_ticks_usec()
		var tid := WorkerThreadPool.add_task(func() -> void: src.build(f, cfg))
		while not WorkerThreadPool.is_task_completed(tid):
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			gaps.append((now - tl) / 1000.0)
			tl = now
		WorkerThreadPool.wait_for_task_completion(tid)
		var same := src.count() == ref.count() and src.mask_bytes() == ref.mask_bytes()
		same = same and src.col == ref.col and src.phi == ref.phi
		thr.append({
			wall_ms = (Time.get_ticks_usec() - t0) / 1000.0,
			frames = gaps.size(),
			frame_max_ms = gaps.max() if not gaps.is_empty() else 0.0,
			same_as_main = same,
		})
	_report.thermals = {
		main_build_ms = main_ms, update_air_ms = upd_ms, thread = thr,
		sources = ref.count(), grid = [f.nx, f.ny, f.nz],
	}
	print("flight_probe: термики %s" % _report.thermals)


func _save() -> void:
	var p := ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var fa := FileAccess.open(p, FileAccess.WRITE)
	fa.store_string(JSON.stringify(_report) + "\n")
	fa.close()
	print("flight_probe: ", p)
