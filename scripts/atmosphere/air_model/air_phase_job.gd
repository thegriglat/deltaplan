class_name AirPhaseJob
extends AirGpuJob
## Фазы поля на GPU (P10 v2): подготовка по столбцам (AirPhase.prepare) — в рабочем потоке, затем
## ядра air_phase.glsl на каркасе AirGpu порциями (AirGpuJob, порция ≤ air_phase.chunk_ms).
## Тот же код на CPU — AirPhaseCpu (gpu = null).
##
##   var job := AirPhaseJob.new(gpu)     # gpu: AirGpu (общий с Пикаром) или null — CPU
##   var r := job.run(case)              # синхронно (CPU или GPU подряд)
##   # или порциями (GPU):
##   job.case = case; job.start(gpu); …раз в кадр: job.poll() … job.is_done() → job.result()
##   job.release()                       # свои буферы (общий AirGpu не освобождается)
##
## Выход — словарь P10 (AirPhase.result): weights, omega, freeze, warm, mech_field, stats, ms (+ те
## же ключи *_mech — решение без нагрева).

var case: AirCase
var cfg := {}

var _gpu0: AirGpu
var _own_gpu := false
var _mark := 0
var _p := {}
var _task := -1
var _gpu_started := false
var _result := {}
var _bufs := {}
var _passes := 0
var _ms_prep := 0.0


func _init(g: AirGpu = null) -> void:
	_gpu0 = g


## Синхронно: gpu = null (или нет RD) — CPU-путь (AirPhaseCpu), иначе GPU подряд.
func run(c: AirCase) -> Dictionary:
	case = c
	if cfg.is_empty():
		cfg = AirPhase.config()
	if _gpu0 == null:
		_result = AirPhaseCpu.run(c, cfg)
		error = _result.get("error", "")
		return _result
	var t := Time.get_ticks_usec()
	_p = AirPhase.prepare(c, cfg)
	_ms_prep = (Time.get_ticks_usec() - t) / 1000
	if _p.has("error"):
		error = _p.error
		return {error = error}
	if not super.start(_gpu0):
		return {error = error}
	_gpu_started = true
	run_blocking()
	return result()


## Порциями: подготовка в рабочем потоке, ядра — с первого poll() после неё.
func start(g: AirGpu = null) -> bool:
	if g != null:
		_gpu0 = g
	if case == null:
		return _fail("AirPhaseJob: нет случая")
	if cfg.is_empty():
		cfg = AirPhase.config()
	chunk_ms = float(cfg.get("chunk_ms", chunk_ms))
	_task = WorkerThreadPool.add_task(_prepare_task)
	return true


func _prepare_task() -> void:
	var t := Time.get_ticks_usec()
	_p = AirPhase.prepare(case, cfg)
	_ms_prep = (Time.get_ticks_usec() - t) / 1000


func poll() -> float:
	if not _gpu_started:
		if error != "":
			return 0.0
		if _task >= 0 and not WorkerThreadPool.is_task_completed(_task):
			return 0.0
		if _task >= 0:
			WorkerThreadPool.wait_for_task_completion(_task)
			_task = -1
		if _p.has("error"):
			_fail(_p.error)
			return 0.0
		_gpu_started = true
		if not super.start(_gpu0):
			return 0.0
	return super.poll()


func is_done() -> bool:
	return _gpu_started and super.is_done()


## Словарь P10 (после is_done(); GPU-буферы читаются здесь, главный поток).
func result() -> Dictionary:
	if not _result.is_empty() or not is_done():
		return _result
	var t := Time.get_ticks_usec()
	var n2: int = _p.n2
	var wf := []
	var frz := []
	var outv := []
	var o2 := gpu.download(_bufs.o2d)
	for v in 2:
		wf.append(gpu.download(_bufs.wts, AirPhase.K * n2, ((v * AirPhase.NWS + AirPhase.WS_FIN) * AirPhase.K) * n2))
		var b := PackedByteArray()
		b.resize(n2)
		var pl := AirPhase.O_FRZ_H if v == AirPhase.V_H else AirPhase.O_FRZ_M
		for c in n2:
			b[c] = 1 if o2[pl * n2 + c] > 0.5 else 0
		frz.append(b)
		outv.append(gpu.download(_bufs.outv[v]))
	var gms := 0.0
	for e in chunk_log:
		gms += e.y
	var parts := {
		prepare = _ms_prep,
		gpu = gms,
		download = (Time.get_ticks_usec() - t) / 1000,
	}
	_result = AirPhase.result(_p, wf, frz, outv, parts, o2[AirPhase.O_FLAG * n2] > 0.5)
	return _result


## Свои буферы; собственный AirGpu (создан здесь) — целиком.
func release() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if gpu == null:
		return
	if _own_gpu:
		super.release()
		return
	if _submitted:
		gpu.sync()
		_submitted = false
	gpu.free_from(_mark)
	gpu = null


# ---------------------------------------------------------------- AirGpuJob


func _shaders() -> Array:
	return AirGpu.SHADERS + _names()


static func _names() -> Array:
	var out := []
	for k in [
		"classify",
		"smoothx",
		"smoothy",
		"final",
		"synth0",
		"synth1",
		"synth2",
		"sorinit",
		"sor",
		"dgrad",
		"uml",
		"thinit",
		"theta",
		"fill",
		"faces"
	]:
		out.append("air_phase:" + k)
	return out


func _setup() -> bool:
	_own_gpu = _gpu0 == null
	if not _ensure_shaders(gpu):
		error = gpu.error
		return false
	_mark = gpu.mark()
	var p := _p
	var n2: int = p.n2
	var nlev: int = p.lev.size()
	var nl: int = maxi(p.zl.size(), 1)
	_bufs = {
		prm = gpu.buffer(AirPhase.NPRM, p.prm),
		col = gpu.buffer(AirPhase.NCI * n2, AirCase.to_f32(p.col)),
		md = gpu.buffer(AirPhase.NMO * n2, AirCase.to_f32(p.modes)),
		wts = gpu.buffer(2 * AirPhase.NWS * AirPhase.K * n2),
		slab = gpu.buffer(nlev * AirPhase.NCOMP * n2),
		stmp = gpu.buffer(nlev * (16 + 2 * AirPhase.NCOMP) * n2),
		phi = gpu.buffer(nl * 3 * n2),
		o2d = gpu.buffer(AirPhase.NO2D * n2),
		ctr = gpu.buffer(4 * int(p.N)),
		outv = [gpu.buffer(4 * int(p.N)), gpu.buffer(4 * int(p.N))],
	}
	max_steps_per_chunk = 1
	return true


## Ядра air_phase.glsl в уже открытом AirGpu (общий с Пикаром: init() их не собирал).
static func _ensure_shaders(g: AirGpu) -> bool:
	for s in _names():
		if g._shader.has(s):
			continue
		var parts: PackedStringArray = String(s).split(":")
		var file := load(AirGpu.DIR + parts[0] + ".glsl") as RDShaderFile
		if file == null:
			g.error = "нет ядра %s.glsl" % parts[0]
			return false
		var spirv := file.get_spirv(StringName(parts[1]))
		if spirv == null or spirv.compile_error_compute != "":
			g.error = "ошибка компиляции %s: %s" % [s, spirv.compile_error_compute if spirv else "нет SPIR-V"]
			return false
		var sh := g.rd.shader_create_from_spirv(spirv, s)
		if not sh.is_valid():
			g.error = "драйвер не принял ядро %s" % s
			return false
		g._shader[s] = sh
	return true


func _k(nm: String, total: int, w := 0, i1 := 0, wf := 1.0, outb := RID()) -> void:
	var b: Dictionary = _bufs
	var bufs := [b.prm, b.col, b.md, b.wts, b.slab, b.stmp, b.phi, b.o2d, b.ctr, outb if outb.is_valid() else b.outv[0]]
	gpu.kernel("air_phase:" + nm, bufs, total, [_p.nx, _p.ny, _p.nz, w], [i1], [], wf)


func _record_all() -> void:
	var p := _p
	var n2: int = p.n2
	var nx: int = p.nx
	var nlev: int = p.lev.size()
	var nl: int = p.zl.size()
	var n: int = p.N
	for v in 2:
		_k("classify", n2, v)
		_k("smoothx", AirPhase.K * n2, v, 0, p.gk.size())
		_k("smoothy", n2, v, 0, AirPhase.K * p.gk.size())
		_k("final", n2, v)
	_k("synth0", nlev * n2, 0, 0, 16)
	_k("synth1", nlev * AirPhase.NCOMP * n2, 0, 0, 4 * nx)
	_k("synth2", nlev * AirPhase.NCOMP * n2, 0, 0, 4 * int(p.ny))
	if nl > 0:
		_k("sorinit", nl * n2)
		for _it in int(AirPhase.cv(cfg, "d", "sor_iters")):
			_k("sor", nl * n2, 0, 0)
			_k("sor", nl * n2, 0, 1)
		_k("dgrad", nl * n2)
	_passes = 0
	if p.heated:
		_k("uml", n2, 0, 0, 40)
		_k("thinit", n2)
		_passes = nx + int(p.ny)
		for q in _passes:
			_k("theta", n2, 0, q % 2)
	for v in 2:
		_k("fill", n, v, _passes % 2, 20)
		_k("faces", n, v, 0, 2, _bufs.outv[v])


func _step_program(i: int) -> Array:
	if i > 0:
		return []
	return gpu.record(_record_all)


func _after_sync() -> bool:
	return true


func _total_steps() -> int:
	return 1
