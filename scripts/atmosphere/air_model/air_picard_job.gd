class_name AirPicardJob
extends AirGpuJob
## Пикар на GPU, один уровень (AM-03): установившееся среднее поле масштаба 1 по эталону AM-01
## (tools/research/air3d/air.py, reference.md → «Дискретизация»), блоками AM-02 (прогонки,
## V-цикл, редукции) и ядрами air_picard.glsl. Порциями (AirGpuJob): главный поток не ждёт GPU.
## Описание, буферы, замеры — docs/air_model_gpu.md → «Пикар».
##
##   var job := AirPicardJob.new()
##   job.case = c                       # AirCase (prepare() — внутри start)
##   job.mech = true                    # сначала решение без нагрева → w_mech (Стык 1↔2)
##   job.warm = prev.state()            # по желанию: тёплый старт (u, v, w, θ′, θ′_d, p)
##   job.finished.connect(...); job.failed.connect(...)
##   job.start(); …раз в кадр: job.poll() …
##   var f := job.field()               # WindField (docs/air_model.md → «Поле на CPU»)
##   job.release()
##
## Шаг задачи (AirGpuJob) — фаза: старт (фон + 30 V-циклов, тёплый — 4), затем по 10 итераций
## Пикара с проверкой невязки в конце (как Air.solve эталона), затем finalize (10 V-циклов без
## изменения p). Порция — не больше одного шага (проверка читается до следующего шага), шаг
## дороже бюджета режется между кадрами.

## Готово поле field_async() (null — размеры не сошлись).
signal field_ready(f: WindField)

enum Phase { INIT, ITER, FINAL, DONE }

const SHADER_NAMES := [
	"air_picard:setup",
	"air_picard:mgfaces",
	"air_picard:bc",
	"air_picard:kloc",
	"air_picard:mom",
	"air_picard:heat",
	"air_picard:div",
	"air_picard:proj",
	"air_picard:resid"
]

# скаляры (AirGpu.scalars)
const S_RSUM := 0
const S_PHI := 1
const S_R2 := 10  # 10..13 Σr² (u, v, w, θ′)
const S_RMAX := 14  # 14..17 max|r|
const S_DIV2 := 18
const S_DIVMAX := 19
# 20, 21 — окно (AirWindowJob.S_NET); невязка θ′_d (диабатическая часть)
const S_R2D := 22
const S_RMAXD := 23
const N_SCALARS := 24

## Вход: случай (с нагревом). mech — сначала решить его же без нагрева (w_mech для игры).
var case: AirCase
var mech := true
## Тёплый старт: {u, v, w, th, thd, p} — массивы N с ореолом (state() прошлого решения той же
## сетки); нет thd — θ′_d с нуля.
var warm := {}
## Критерий (эталон: Air.solve).
var tol_mom := 2e-5
var tol_th := 5e-7
var tol_div := 1e-6
var check_every := 10
var max_outer := 3000

## Итог по решениям (порядок: без нагрева, с нагревом): {label, status, iters, hist, div_rms, …}.
var results: Array[Dictionary] = []
## GPU-время всех порций, мс; стена от start() до готовности, мс.
var gpu_ms_total := 0.0
var wall_ms := 0.0
## V-цикл давления и буферы по именам (для замеров и тестов блоков).
var mg := AirMultigrid.new()
var buf := {}

var _cases: Array[AirCase] = []
var _ci := 0
var _phase := Phase.INIT
var _iters := 0
var _hist: Array[Dictionary] = []
var _status := ""
var _progs := {}
var _t0 := 0
var _dims := Vector3i.ZERO
var _n := 0
var _ni := 0
var _cache := {}


func _shaders() -> Array:
	return AirGpu.SHADERS + SHADER_NAMES


func _setup() -> bool:
	_t0 = Time.get_ticks_usec()
	max_steps_per_chunk = 1
	if case == null:
		error = "AirPicardJob: нет случая"
		return false
	_cases.clear()
	if mech and not case.heat.is_empty():
		_cases.append(case.without_heat())
	_cases.append(case)
	for c in _cases:
		if not c.prepare():
			error = "AirPicardJob: вход не сходится по размерам"
			return false
	_dims = case.dims()
	_n = _dims.x * _dims.y * _dims.z
	_ni = case.nx * case.ny * case.nz
	var n := _n
	for nm in [
		"tcode",
		"ubu",
		"ubv",
		"ubw",
		"thb",
		"spu",
		"spw",
		"spc",
		"kbg",
		"Q",
		"Kx",
		"Ky",
		"Kz",
		"u",
		"v",
		"w",
		"th",
		"thd",
		"thbd",
		"p",
		"nu",
		"nuh",
		"r",
		"wmech"
	]:
		buf[nm] = gpu.buffer(n)
	# решение без нагрева целиком (родитель окна без нагрева — AM-04, state(true))
	if _cases.size() > 1:
		for nm in ["um", "vm", "thm", "thdm", "pm"]:
			buf[nm] = gpu.buffer(n)
	# шаблоны строкой на точку (C0..C6, b); шаблон тепла — в Cu
	for nm in ["Cu", "Cv", "Cw"]:
		buf[nm] = gpu.buffer(8 * n)
	buf.prm = gpu.buffer(32)
	buf.col = gpu.buffer(AirCase.NCOL * _dims.x * _dims.y)
	buf.lev = gpu.buffer(AirCase.NLEV * _dims.z)
	var nx := case.nx
	var ny := case.ny
	var nz := case.nz
	buf.cx = gpu.buffer((nx + 1) * ny * nz)
	buf.cy = gpu.buffer(nx * (ny + 1) * nz)
	buf.cz = gpu.buffer(nx * ny * (nz + 1))
	buf.act = gpu.buffer(_ni)
	buf.rhs = gpu.buffer(_ni)
	buf.phi = gpu.buffer(_ni)
	_ci = 0
	_upload_case(_cases[0])
	_record_setup()
	# грани и маска V-цикла (одни для обоих решений: губки и θ̄ те же)
	var d := _pc0()
	for which in 4:
		var out: RID = [buf.cx, buf.cy, buf.cz, buf.act][which]
		gpu.kernel(
			"air_picard:mgfaces",
			[buf.prm, buf.tcode, buf.Kx, buf.Ky, buf.Kz, out],
			_n,
			[d[0], d[1], d[2], which]
		)
	mg.build(gpu, buf.cx, buf.cy, buf.cz, buf.act, Vector3i(nx, ny, nz))
	if not warm.is_empty():
		for nm in ["u", "v", "w", "th", "thd", "p"]:
			if nm == "thd" and not warm.has(nm):
				continue  # θ′_d с нуля (буфер новый — нули)
			var a: PackedFloat32Array = warm.get(nm, PackedFloat32Array())
			if a.size() != n:
				error = "AirPicardJob: тёплый старт другого размера"
				return false
			gpu.upload(buf[nm], a)
	_phase = Phase.INIT
	_iters = 0
	_hist = []
	return true


func _upload_case(c: AirCase) -> void:
	gpu.upload(buf.prm, c.prm)
	gpu.upload(buf.col, c.col)
	gpu.upload(buf.lev, c.lev)


func _pc0() -> Array:
	return [_dims.x, _dims.y, _dims.z]


## Поклеточная подготовка случая на GPU + K ← K_b.
func _record_setup() -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:setup",
		[
			buf.prm,
			buf.col,
			buf.lev,
			buf.tcode,
			buf.ubu,
			buf.ubv,
			buf.spu,
			buf.spw,
			buf.spc,
			buf.kbg,
			buf.Q,
			buf.Kx,
			buf.Ky,
			buf.Kz
		],
		_n,
		[d[0], d[1], d[2], 0],
		[],
		[],
		4.0
	)
	gpu.vec(AirGpu.Vec.COPY, buf.kbg, buf.nu, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.kbg, buf.nuh, _n)


# ---------------------------------------------------------------- записи ядер


func _bc(mode: int) -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:bc",
		[
			buf.prm,
			buf.tcode,
			buf.ubu,
			buf.ubv,
			buf.ubw,
			buf.thb,
			buf.u,
			buf.v,
			buf.w,
			buf.th,
			buf.p,
			buf.thbd,
			buf.thd
		],
		_n,
		[d[0], d[1], d[2], mode],
		[],
		[],
		2.0
	)


func _kloc() -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:kloc",
		[
			buf.prm,
			buf.tcode,
			buf.lev,
			buf.col,
			buf.kbg,
			buf.u,
			buf.v,
			buf.w,
			buf.th,
			buf.nu,
			buf.nuh
		],
		_n,
		[d[0], d[1], d[2], 0],
		[],
		[],
		6.0
	)


func _mom(comp: int) -> void:
	var d := _pc0()
	var sp: RID = buf.spw if comp == 2 else buf.spu
	var bg: RID = [buf.ubu, buf.ubv, buf.ubw][comp]
	var c: RID = [buf.Cu, buf.Cv, buf.Cw][comp]
	gpu.kernel(
		"air_picard:mom",
		[
			buf.prm,
			buf.tcode,
			buf.lev,
			buf.u,
			buf.v,
			buf.w,
			buf.p,
			buf.th,
			sp,
			bg,
			buf.nu,
			buf.nuh,
			c
		],
		_n,
		[d[0], d[1], d[2], comp],
		[],
		[],
		5.0
	)


## Шаблон тепла в Cu: mode 0 — θ′_d, 1 — полное θ′ (air_picard.glsl:heat).
func _heat(mode: int) -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:heat",
		[
			buf.prm,
			buf.tcode,
			buf.lev,
			buf.u,
			buf.v,
			buf.w,
			buf.th,
			buf.Q,
			buf.spc,
			buf.thb,
			buf.nu,
			buf.nuh,
			buf.Cu,
			buf.thd,
			buf.thbd
		],
		_n,
		[d[0], d[1], d[2], mode],
		[],
		[],
		5.0
	)


func _div() -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:div",
		[buf.prm, buf.tcode, buf.u, buf.v, buf.w, buf.rhs],
		_ni,
		[d[0], d[1], d[2], 0],
		[],
		[],
		2.0
	)


func _proj(update_p: bool) -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:proj",
		[buf.prm, buf.Kx, buf.Ky, buf.Kz, buf.phi, buf.u, buf.v, buf.w, buf.p],
		_n,
		[d[0], d[1], d[2], 1 if update_p else 0],
		[],
		[],
		3.0
	)


## Невязка по неизвестным типа which → Σr² и max|r| в слоты S_R2 + which, S_RMAX + which (или
## r2_slot, rmax_slot).
func _resid(c: RID, x: RID, which: int, r2_slot := -1, rmax_slot := -1) -> void:
	var d := _pc0()
	gpu.kernel(
		"air_picard:resid",
		[buf.prm, buf.tcode, c, x, buf.r],
		_n,
		[d[0], d[1], d[2], which],
		[],
		[],
		3.0
	)
	gpu.reduce(AirGpu.Red.DOT, buf.r, _n, S_R2 + which if r2_slot < 0 else r2_slot, buf.r)
	gpu.reduce(AirGpu.Red.MAXABS, buf.r, _n, S_RMAX + which if rmax_slot < 0 else rmax_slot)


## Проекция: ∇·u → минус среднее → cycles V-циклов от φ = 0 → φ минус среднее → u −= K∇φ (p += φ).
func _prog_project(cycles: int, update_p: bool) -> Array:
	var a := gpu.record(_rec_project_head)
	for _c in cycles:
		a.append_array(mg.program(buf.phi, buf.rhs))
	a.append_array(gpu.record(_rec_project_tail.bind(update_p)))
	return a


func _rec_project_head() -> void:
	_div()
	gpu.reduce(AirGpu.Red.SUM, buf.rhs, _ni, S_RSUM)
	gpu.axpy(-1.0 / float(case.n_fluid), buf.act, buf.rhs, _ni, S_RSUM)
	gpu.fill(buf.phi, _ni)


func _rec_project_tail(update_p: bool) -> void:
	gpu.reduce(AirGpu.Red.DOT, buf.phi, _ni, S_PHI, buf.act)
	gpu.axpy(-1.0 / float(case.n_fluid), buf.act, buf.phi, _ni, S_PHI)
	_proj(update_p)


## Одна итерация Пикара (reference.md → «Итерация Пикара»).
func _prog_iteration() -> Array:
	var a := gpu.record(_rec_momentum)
	a.append_array(_prog_project(int(case.p.vcycles), true))
	a.append_array(gpu.record(_rec_heat_step))
	return a


func _rec_momentum() -> void:
	var d := case.dims()
	_bc(0)
	if bool(case.p.local_k):
		_kloc()
	_mom(0)
	_mom(1)
	_mom(2)
	for _s in int(case.p.mom_sweeps):
		gpu.zebra(buf.Cu, buf.u, RID(), d, [2, 0, 1], true)
		gpu.zebra(buf.Cv, buf.v, RID(), d, [2, 0, 1], true)
		gpu.zebra(buf.Cw, buf.w, RID(), d, [2, 0, 1], true)


## Шаг тепла (Air.heat_step): шаблон θ′_d → прогонки θ′_d → шаблон θ′ (от нового θ′_d) → прогонки.
func _rec_heat_step() -> void:
	_heat(0)
	for _s in int(case.p.heat_sweeps):
		gpu.zebra(buf.Cu, buf.thd, RID(), case.dims(), [2, 0, 1], true)
	_heat(1)
	for _s in int(case.p.heat_sweeps):
		gpu.zebra(buf.Cu, buf.th, RID(), case.dims(), [2, 0, 1], true)


## Невязка установившихся уравнений от текущего состояния (Air.residuals) → скаляры.
func _prog_check() -> Array:
	return gpu.record(_rec_check)


func _rec_check() -> void:
	_bc(0)
	_mom(0)
	_mom(1)
	_mom(2)
	_resid(buf.Cu, buf.u, 0)
	_resid(buf.Cv, buf.v, 1)
	_resid(buf.Cw, buf.w, 2)
	_heat(0)
	_resid(buf.Cu, buf.thd, 3, S_R2D, S_RMAXD)
	_heat(1)
	_resid(buf.Cu, buf.th, 3)
	_rec_div_stats()


func _rec_div_stats() -> void:
	_div()
	gpu.reduce(AirGpu.Red.DOT, buf.rhs, _ni, S_DIV2, buf.rhs)
	gpu.reduce(AirGpu.Red.MAXABS, buf.rhs, _ni, S_DIVMAX)


func _rec_reinit() -> void:
	_record_setup()
	_bc(1)


func _rec_copy_wmech() -> void:
	gpu.vec(AirGpu.Vec.COPY, buf.w, buf.wmech, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.u, buf.um, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.v, buf.vm, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.th, buf.thm, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.thd, buf.thdm, _n)
	gpu.vec(AirGpu.Vec.COPY, buf.p, buf.pm, _n)


func _program(key: String) -> Array:
	if _progs.has(key):
		return _progs[key]
	var a := []
	match key:
		"init":
			a = gpu.record(_bc.bind(1))
			a.append_array(_prog_project(30, false))
		"warm":
			a = gpu.record(_bc.bind(0))
			a.append_array(_prog_project(4, false))
		"reinit":
			a = gpu.record(_rec_reinit)
			a.append_array(_prog_project(30, false))
		"iters":
			var one := _prog_iteration()
			for _i in check_every:
				a.append_array(one)
			a.append_array(_prog_check())
		"final":
			a = gpu.record(_bc.bind(0))
			a.append_array(_prog_project(10, false))
			a.append_array(gpu.record(_rec_div_stats))
		"mech_done":
			a = gpu.record(_rec_copy_wmech)
	_progs[key] = a
	return a


func _step_program(_i: int) -> Array:
	match _phase:
		Phase.INIT:
			if _ci > 0:
				return _program("reinit")
			return _program("warm" if not warm.is_empty() else "init")
		Phase.ITER:
			return _program("iters")
		Phase.FINAL:
			if _ci < _cases.size() - 1:
				return _program("final") + _program("mech_done")
			return _program("final")
	return []


func _after_sync() -> bool:
	match _phase:
		Phase.INIT:
			_phase = Phase.ITER
		Phase.ITER:
			_iters += check_every
			var r := _read_residuals()
			r.it = _iters
			_hist.append(r)
			var bad := false
			for v in r.values():
				bad = bad or not is_finite(float(v))
			if bad or float(r.mom_max) > 50.0:
				_status = "diverged"
				error = "Пикар разошёлся (%s, итерация %d)" % [_cases[_ci].label, _iters]
				_finish_result()
				return false
			if r.mom_rms < tol_mom and r.th_rms < tol_th and r.div_rms < tol_div:
				_status = "ok"
				_phase = Phase.FINAL
			elif _iters >= max_outer:
				_status = "max"
				_phase = Phase.FINAL
		Phase.FINAL:
			_finish_result()
			if _ci < _cases.size() - 1:
				_ci += 1
				_upload_case(_cases[_ci])
				_phase = Phase.INIT
				_iters = 0
				_hist = []
				return false
			_phase = Phase.DONE
			for e in chunk_log:
				gpu_ms_total += e.y
			wall_ms = (Time.get_ticks_usec() - _t0) / 1000.0
			return true
	return false


func _finish_result() -> void:
	var c := _cases[_ci]
	var nf := float(c.n_fluid)
	var res := {
		label = c.label,
		status = _status,
		iters = _iters,
		hist = _hist,
		div_rms = sqrt(gpu.read_scalar(S_DIV2) / nf),
		div_max = gpu.read_scalar(S_DIVMAX),
		heated = not c.heat.is_empty(),
	}
	results.append(res)


func _read_residuals() -> Dictionary:
	var s := gpu.download(gpu.scalars, N_SCALARS)
	var c := _cases[_ci]
	var rms := []
	for q in 4:
		rms.append(sqrt(s[S_R2 + q] / maxf(float(c.n_unk[q]), 1.0)))
	var rms_d := sqrt(s[S_R2D] / maxf(float(c.n_unk[3]), 1.0))
	# критерий тепла — по обоим скалярам (θ′ и θ′_d), как Air.residuals
	return {
		mom_rms = sqrt((rms[0] * rms[0] + rms[1] * rms[1] + rms[2] * rms[2]) / 3.0),
		mom_max = maxf(s[S_RMAX], maxf(s[S_RMAX + 1], s[S_RMAX + 2])),
		th_rms = maxf(rms[3], rms_d),
		th_max = maxf(s[S_RMAX + 3], s[S_RMAXD]),
		thd_rms = rms_d,
		thd_max = s[S_RMAXD],
		div_rms = sqrt(s[S_DIV2] / maxf(float(c.n_fluid), 1.0)),
		div_max = s[S_DIVMAX],
	}


func progress() -> float:
	if is_done():
		return 1.0
	var per := 1.0 / maxf(_cases.size(), 1)
	var inner := 0.0
	match _phase:
		Phase.ITER:
			# грубо: сходимость — по доле пути невязки импульса к порогу (логарифм)
			inner = 0.1
			if not _hist.is_empty():
				var r0 := log(maxf(float(_hist[0].mom_rms), tol_mom * 1.01))
				var r1 := log(maxf(float(_hist[-1].mom_rms), tol_mom))
				inner = 0.1 + 0.85 * clampf((r0 - r1) / maxf(r0 - log(tol_mom), 1e-6), 0.0, 1.0)
		Phase.FINAL:
			inner = 0.97
	return clampf((_ci + inner) * per, 0.0, 0.99)


func _total_steps() -> int:
	return -1


# ---------------------------------------------------------------- выход (после is_done())


## Массив буфера (N с ореолом или nz·ny·nx для внутренних).
func download(name: String) -> PackedFloat32Array:
	return gpu.download(buf[name])


## Буфер решения с GPU; после готовности — один раз (state, parent_data, поле читают одно и то
## же — окна клипмапа берут всё сразу).
func _read(name: String) -> PackedFloat32Array:
	if not is_done():
		return gpu.download(buf[name])
	if not _cache.has(name):
		_cache[name] = gpu.download(buf[name])
	return _cache[name]


## Состояние для тёплого старта: {u, v, w, th, thd, p}; mech — решения без нагрева (при паре;
## иначе то же, что с нагревом).
func state(mech_state := false) -> Dictionary:
	var out := {}
	var keys := ["u", "v", "w", "th", "thd", "p"]
	var names := keys
	if mech_state and _cases.size() > 1:
		names = ["um", "vm", "wmech", "thm", "thdm", "pm"]
	for q in names.size():
		out[keys[q]] = _read(names[q])
	return out


## Поле уровня как родитель окна клипмапа (AM-04, AirWindowJob.parent): сетка, типы клеток и
## граней, решения с нагревом и без — грани u, v, w, θ′ и θ′_d с ореолом (N). Читается с GPU на
## вызывающем потоке (главный, после is_done()).
func parent_data() -> Dictionary:
	var heat := state(false)
	var mech := state(true) if _cases.size() > 1 else heat
	heat.erase("p")
	mech.erase("p")
	return {
		grid = grid(),
		tc = _read("tcode"),
		heat = heat,
		mech = mech,
	}


## Сетка решения: dx, dz, x0, y0, z_bot, nx, ny, nz.
func grid() -> Dictionary:
	return {
		dx = case.dx,
		dz = case.dz,
		x0 = case.x0,
		y0 = case.y0,
		z_bot = case.z_bot,
		nx = case.nx,
		ny = case.ny,
		nz = case.nz,
	}


## Поле для игры (WindField): u, v, θ′ — решение с нагревом, w_mech — без нагрева (если mech);
## meta — AirCase.meta() (с входом термиков AM-07). Сразу, на вызывающем потоке (~0,2–1 с CPU на
## 400 м — для игры field_async()).
func field(max_speed := 40.0, max_w := 10.0) -> WindField:
	if not _mech_ok():
		return null
	return _build_field(_field_inputs(), max_speed, max_w)


## Поле для игры — только с решением без нагрева (mech = true): иначе w_mech = w — двойной счёт
## с пузырями (контракт C3). Без нагрева w и есть механическая вертикаль.
func _mech_ok() -> bool:
	if _cases.size() > 1 or case.heat.is_empty():
		return true
	push_error(
		(
			"AirPicardJob.field: случай с нагревом решён без mech — w_mech нет "
			+ "(mech = false только для замеров)"
		)
	)
	return false


## То же без остановки кадра: буферы читаются здесь (главный поток, RD), сборка WindField —
## в WorkerThreadPool; готовое поле — сигналом field_ready (на главном потоке, отложенно).
func field_async(max_speed := 40.0, max_w := 10.0) -> void:
	if not _mech_ok():
		field_ready.emit.call_deferred(null)
		return
	var inp := _field_inputs()
	WorkerThreadPool.add_task(_field_task.bind(inp, max_speed, max_w))


func _field_task(inp: Dictionary, max_speed: float, max_w: float) -> void:
	var f := _build_field(inp, max_speed, max_w)
	field_ready.emit.call_deferred(f)


func _field_inputs() -> Dictionary:
	var w := _read("w")
	return {
		meta = case.meta(),
		u = _read("u"),
		v = _read("v"),
		w = w,
		wm = _read("wmech") if _cases.size() > 1 else w.duplicate(),
		th = _read("th"),
		tc = _read("tcode"),
		hc = case.hc,
	}


static func _build_field(a: Dictionary, max_speed: float, max_w: float) -> WindField:
	var tc: PackedFloat32Array = a.tc
	var cell := PackedFloat32Array()
	cell.resize(tc.size())
	for q in tc.size():
		cell[q] = float(int(tc[q]) & 3)
	var hc: PackedFloat64Array = a.hc
	var hc32 := PackedFloat32Array()
	hc32.resize(hc.size())
	for q in hc32.size():
		hc32[q] = hc[q]
	var f := WindField.from_mac(a.meta, a.u, a.v, a.w, a.wm, a.th, cell, hc32)
	if f != null:
		f.clamp_values(max_speed, max_w)
	return f


## Итоговые итерации решения с нагревом.
func iterations() -> int:
	return int(results[-1].iters) if not results.is_empty() else 0
