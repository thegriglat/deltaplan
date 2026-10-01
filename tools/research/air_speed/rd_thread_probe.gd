extends Node
## SP-1 (а): можно ли локальный RenderingDevice целиком в рабочем потоке (Godot 4.7.2)?
## И (б) — общий RD (RenderingServer.get_rendering_device()): запуски ядер внутри кадра.
##
##   XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock godot --path . \
##     --audio-driver Dummy --resolution 320x240 res://tools/research/air_speed/rd_thread_probe.tscn \
##     -- [--out=tools/research/air_speed/out/rd_thread.json] [--skip-solver] [--frames-limit=N]
##
## Случаи (каждый пишет строку в out JSON; ошибки движка — в stderr, лог прогона сохраняется рядом):
##  A1 Thread: create_local_rendering_device + компиляция + буфер + запуск + submit/sync + чтение;
##  A2 то же в WorkerThreadPool;
##  A3 RD создан в главном потоке, используется в рабочем;
##  A4 RD создан в рабочем потоке, используется в главном;
##  A5 решатель области 400 м (Онгудай 12:00, 3 м/с со 150°, пара как в игре): AirGpu и
##     AirPicardJob.run_blocking() целиком в Thread, главный поток рисует кадры — стена, GPU,
##     кадры; против того же в главном потоке run_blocking() (замороженный) и poll() раз в кадр;
##     поля сравниваются побитно;
##  B1 общий RD: N зависимых запусков за кадр (цепочка с барьерами) — цена кадра.

const SRC := """
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) restrict buffer B { float d[]; };
layout(push_constant) uniform P { uint n; float a; uint pad0; uint pad1; } p;
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i < p.n) d[i] = d[i] * 0.5 + p.a;
}
"""

var _rows: Array = []
var _out := "res://tools/research/air_speed/out/rd_thread.json"
var _skip_solver := false
var _frames: Array[float] = []
var _render_gpu: Array[float] = []
var _t_frame := 0
var _watch := false
var _vp := RID()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		match kv[0]:
			"out":
				_out = kv[1]
			"skip-solver":
				_skip_solver = true
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	_run.call_deferred()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _watch and _t_frame > 0:
		_frames.append((now - _t_frame) / 1000.0)
		_render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp))
	_t_frame = now


func _run() -> void:
	for i in 10:
		await get_tree().process_frame
	_row("env", {
		godot = Engine.get_version_info().string,
		adapter = RenderingServer.get_video_adapter_name(),
		api = RenderingServer.get_video_adapter_api_version(),
		driver = OS.get_video_adapter_driver_info(),
		threaded_render = ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1),
		window = DisplayServer.window_get_size(),
		vsync = DisplayServer.window_get_vsync_mode(),
	})
	# A1: Thread
	var th := Thread.new()
	th.start(_tiny_case.bind("A1 Thread: всё в рабочем потоке"))
	_row("A1", await _join(th))
	# A2: WorkerThreadPool
	var res := {}
	var tid := WorkerThreadPool.add_task(func() -> void: res.merge(_tiny_case("A2 WorkerThreadPool")))
	while not WorkerThreadPool.is_task_completed(tid):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	_row("A2", res)
	# A3: создан в главном, используется в рабочем
	var rd_main := RenderingServer.create_local_rendering_device()
	print("A3: RD создан в главном потоке")
	th = Thread.new()
	th.start(_tiny_case.bind("A3 RD главного потока в рабочем", rd_main))
	_row("A3", await _join(th))
	rd_main.free()
	# A4: создан в рабочем, используется в главном
	th = Thread.new()
	th.start(func() -> RenderingDevice: return RenderingServer.create_local_rendering_device())
	var rd_w: RenderingDevice = await _join(th)
	print("A4: RD создан в рабочем потоке, используем в главном")
	_row("A4", _tiny_case("A4 RD рабочего потока в главном", rd_w) if rd_w != null else {ok = false})
	if rd_w != null:
		rd_w.free()
	# B1: общий RD — цепочка запусков внутри кадра
	await _shared_rd_chain()
	if not _skip_solver:
		await _solver_cases()
	_save()
	get_tree().quit(0)


func _join(th: Thread) -> Variant:
	while th.is_alive():
		await get_tree().process_frame
	return th.wait_to_finish()


func _row(id: String, d: Dictionary) -> void:
	d.id = id
	_rows.append(d)
	print("[row] ", JSON.stringify(d))


func _save() -> void:
	var p := ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify(_rows, " ") + "\n")
	f.close()
	print("rd_thread_probe: ", p)


## Минимальный случай на RD rd (null — создать здесь же). Возвращает {ok, err, thread, …}.
func _tiny_case(label: String, rd: RenderingDevice = null) -> Dictionary:
	var out := {label = label, thread = OS.get_thread_caller_id(), main = OS.get_main_thread_id()}
	var own := rd == null
	var t0 := Time.get_ticks_usec()
	if own:
		rd = RenderingServer.create_local_rendering_device()
	out.create_ms = (Time.get_ticks_usec() - t0) / 1000.0
	if rd == null:
		out.ok = false
		out.err = "create_local_rendering_device() → null"
		return out
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SRC
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv == null or spirv.compile_error_compute != "":
		out.ok = false
		out.err = "компиляция: %s" % (spirv.compile_error_compute if spirv else "null")
		if own:
			rd.free()
		return out
	var sh := rd.shader_create_from_spirv(spirv, "tiny")
	if not sh.is_valid():
		out.ok = false
		out.err = "shader_create_from_spirv: недействителен"
		if own:
			rd.free()
		return out
	var pipe := rd.compute_pipeline_create(sh)
	var n := 1 << 16
	var init := PackedFloat32Array()
	init.resize(n)
	init.fill(1.0)
	var buf := rd.storage_buffer_create(n * 4, init.to_byte_array())
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf)
	var us := rd.uniform_set_create([u], sh, 0)
	var pc := PackedInt32Array([n, 0, 0, 0]).to_byte_array()
	pc.encode_float(4, 1.0)
	var reps := 200
	var t1 := Time.get_ticks_usec()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, us, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	for i in reps:
		rd.compute_list_dispatch(cl, n / 64, 1, 1)
		rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	rd.capture_timestamp("end")
	rd.submit()
	rd.sync()
	out.wall_ms = (Time.get_ticks_usec() - t1) / 1000.0
	var back := rd.buffer_get_data(buf, 0, 16).to_float32_array()
	# x → 0,5x + 1 двести раз из 1: стремится к 2
	out.value = back[0]
	out.ok = absf(back[0] - 2.0) < 1e-5
	out.err = "" if out.ok else "неверный результат"
	rd.free_rid(us)
	rd.free_rid(buf)
	rd.free_rid(pipe)
	rd.free_rid(sh)
	if own:
		rd.free()
	return out


## B1: общий RD (рендер) — k зависимых запусков (n = 500 000 элементов) раз в кадр, 120 кадров на k.
func _shared_rd_chain() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_row("B1", {ok = false, err = "нет общего RD"})
		return
	var src := RDShaderSource.new()
	src.source_compute = SRC
	var spirv := rd.shader_compile_spirv_from_source(src)
	var sh := rd.shader_create_from_spirv(spirv, "tiny_shared")
	var pipe := rd.compute_pipeline_create(sh)
	var n := 500000
	var buf := rd.storage_buffer_create(n * 4)
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf)
	var us := rd.uniform_set_create([u], sh, 0)
	var pc := PackedInt32Array([n, 0, 0, 0]).to_byte_array()
	pc.encode_float(4, 1.0)
	for k in [0, 50, 150, 300, 600, 1200]:
		_frames.clear()
		_render_gpu.clear()
		var stamps: Array[float] = []
		var rec_ms := 0.0
		_watch = true
		for f in 120:
			var t0 := Time.get_ticks_usec()
			if k > 0:
				rd.capture_timestamp("b1_begin")
				var cl := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(cl, pipe)
				rd.compute_list_bind_uniform_set(cl, us, 0)
				rd.compute_list_set_push_constant(cl, pc, pc.size())
				for i in k:
					rd.compute_list_dispatch(cl, ceili(n / 64.0), 1, 1)
					rd.compute_list_add_barrier(cl)
				rd.compute_list_end()
				rd.capture_timestamp("b1_end")
			rec_ms += (Time.get_ticks_usec() - t0) / 1000.0
			await get_tree().process_frame
			# метки общего RD — с задержкой в несколько кадров (кадры в полёте)
			var b := -1
			var e := -1
			for i in rd.get_captured_timestamps_count():
				var nm := rd.get_captured_timestamp_name(i)
				if nm == "b1_begin":
					b = rd.get_captured_timestamp_gpu_time(i)
				elif nm == "b1_end":
					e = rd.get_captured_timestamp_gpu_time(i)
			if b >= 0 and e > b:
				stamps.append((e - b) / 1e6)
		_watch = false
		_row("B1", {
			k = k,
			frame_ms = _stats(_frames),
			render_gpu_ms = _stats(_render_gpu),
			chain_gpu_ms = _stats(stamps),
			record_ms_per_frame = rec_ms / 120.0,
		})
	rd.free_rid(us)
	rd.free_rid(buf)
	rd.free_rid(pipe)
	rd.free_rid(sh)


static func _stats(a: Array[float]) -> Dictionary:
	if a.is_empty():
		return {}
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	return {
		n = s.size(), mean = sum / s.size(), p50 = s[s.size() / 2],
		p95 = s[mini(s.size() - 1, int(0.95 * s.size()))], max = s[-1],
	}


# ---------------------------------------------------------------- A5: решатель в рабочем потоке


func _domain() -> AirCase:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	return AirPlace.domain_case(lw[0], lw[1], loc, 400.0, 12.0, 3.0, 150.0)


## Решение в текущем потоке: свой AirGpu (локальный RD), run_blocking, state. Возвращает
## {ok, err, wall_ms, init_ms, gpu_ms, iters, chunks, state}.
static func _solve_here(c: AirCase) -> Dictionary:
	var out := {thread = OS.get_thread_caller_id(), main = OS.get_main_thread_id()}
	var t0 := Time.get_ticks_usec()
	var g := AirGpu.new()
	if not g.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES):
		out.ok = false
		out.err = g.error
		return out
	out.init_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var job := AirPicardJob.new()
	job.case = c
	job.mech = true
	var t1 := Time.get_ticks_usec()
	var ok := job.start(g) and job.run_blocking()
	out.wall_ms = (Time.get_ticks_usec() - t1) / 1000.0
	out.ok = ok
	out.err = job.error
	out.gpu_ms = job.gpu_ms_total
	out.iters = job.results.map(func(r: Dictionary) -> int: return int(r.iters))
	out.chunks = job.chunks
	out.record_cpu_ms = job.record_cpu_ms
	out.sync_wait_ms = job.sync_wait_ms
	if ok:
		var t2 := Time.get_ticks_usec()
		out.state = job.state()
		out.read_ms = (Time.get_ticks_usec() - t2) / 1000.0
	job.release()
	g.release()
	return out


func _solver_cases() -> void:
	var t0 := Time.get_ticks_usec()
	var c := _domain()
	var prep_ms := (Time.get_ticks_usec() - t0) / 1000.0
	# prepare() обоих решений заранее — как AirRuntime.PreparedCase (не в замер решателя)
	var pc := AirRuntime.PreparedCase.from_case(c)
	_row("A5_prep", {domain_case_ms = prep_ms, prepare_ms = (Time.get_ticks_usec() - t0) / 1000.0 - prep_ms})
	# прогрев (сборка конвейеров драйвера при первом запуске)
	_solve_here(pc)
	# 1) главный поток, run_blocking (окно замерло)
	_frames.clear()
	_watch = true
	var main := _solve_here(pc)
	await get_tree().process_frame
	_watch = false
	var st_main: Dictionary = main.get("state", {})
	main.erase("state")
	_row("A5_main_blocking", main)
	# 2) рабочий поток, главный рисует кадры
	for rep in 3:
		_frames.clear()
		_render_gpu.clear()
		_watch = true
		var th := Thread.new()
		var tw := Time.get_ticks_usec()
		th.start(_solve_here.bind(pc))
		var res: Dictionary = await _join(th)
		var wall_total := (Time.get_ticks_usec() - tw) / 1000.0
		_watch = false
		var st: Dictionary = res.get("state", {})
		res.erase("state")
		res.wall_with_join_ms = wall_total
		res.frame_ms = _stats(_frames)
		res.render_gpu_ms = _stats(_render_gpu)
		res.bitwise_vs_main = _diff(st, st_main)
		_row("A5_thread", res)
	# 3) главный поток, poll() раз в кадр — как AirRuntime в полёте (без тёплого старта)
	var g := AirRuntime.RuntimeGpu.new()
	g.init(AirGpu.SHADERS + AirPicardJob.SHADER_NAMES)
	for rep in 2:
		var job := AirPicardJob.new()
		job.case = pc
		job.mech = true
		job.chunk_ms = AirRuntime.FLIGHT_CHUNK_MS
		_frames.clear()
		_render_gpu.clear()
		var t1 := Time.get_ticks_usec()
		job.start(g)
		_watch = true
		while not job.is_done() and job.error == "":
			job.poll()
			await get_tree().process_frame
		_watch = false
		var wall := (Time.get_ticks_usec() - t1) / 1000.0
		var st := job.state()
		var gaps := _chunk_gaps(job)
		_row("A5_main_poll", {
			wall_ms = wall, gpu_ms = job.gpu_ms_total, chunks = job.chunks,
			iters = job.results.map(func(r: Dictionary) -> int: return int(r.iters)),
			record_cpu_ms = job.record_cpu_ms, sync_wait_ms = job.sync_wait_ms,
			poll_max_ms = job.max_poll_cpu_ms, frame_ms = _stats(_frames),
			render_gpu_ms = _stats(_render_gpu), chunk = gaps,
			bitwise_vs_main = _diff(st, st_main),
		})
		job.release()
	g.destroy()


static func _chunk_gaps(job: AirGpuJob) -> Dictionary:
	var gp: Array[float] = []
	var w: Array[float] = []
	for v: Vector3 in job.chunk_log:
		gp.append(v.y)
		w.append(v.x)
	return {gpu_ms = _stats(gp), launches = _stats(w)}


## Наибольшая |разность| state (u, v, w, …) — 0 значит побитно.
static func _diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k in a.keys():
		if not b.has(k):
			continue
		var x: Variant = a[k]
		var y: Variant = b[k]
		if x is PackedFloat32Array and y is PackedFloat32Array:
			var m := 0.0
			if x.size() != y.size():
				out[k] = "размер"
				continue
			var xb: PackedByteArray = (x as PackedFloat32Array).to_byte_array()
			var yb: PackedByteArray = (y as PackedFloat32Array).to_byte_array()
			if xb == yb:
				out[k] = 0.0
				continue
			for i in x.size():
				m = maxf(m, absf(x[i] - y[i]))
			out[k] = m
		elif x is Dictionary and y is Dictionary:
			out[k] = _diff(x, y)
	return out
