class_name AirWindowJob
extends AirPicardJob
## Окно клипмапа на GPU (AM-04): Пикар AirPicardJob на сетке окна (AirWindowCase) с граничными
## условиями от родителя по эталону AM-01 (air.py → Air.set_nest_bc, init_nest; reference.md →
## «Граничные условия области»): поле родителя в центрах его клеток трилинейно во все грани
## и клетки окна (air_window.glsl:nest) → граничные грани (типы 2/3), θ′ и θ′_d ореола и цель зоны
## релаксации (губки окна тянут u, v, w, θ′, θ′_d к родителю); поправка потока Σ = 0 по площади
## граничных граней (flux → две редукции → corr). Старт — поле родителя + 30 V-циклов (p = 0);
## тёплый старт (prev) — старое окно той же клетки со сдвигом на целое число клеток (shift),
## остальное — родитель, + 4 V-цикла. Решение без нагрева (w_mech) — от родителя без нагрева.
##
##   var job := AirWindowJob.new()
##   job.case = AirWindowCase.window_case(…)   # prepare_pair() — заранее в рабочем потоке
##   job.parent = parent_job.parent_data()     # AirPicardJob области или AirWindowJob окна
##   job.prev = old_job.window_state()         # по желанию: сдвиг / пересчёт окна
##   job.start(); …раз в кадр job.poll() … job.field_async() → field_ready
##   var child_parent := job.parent_data()     # для окна мельче
##   job.release()

const WINDOW_SHADERS := [
	"air_window:nest", "air_window:flux", "air_window:corr", "air_window:shift"
]
const S_NET := 20  # 20 — поток через границу, 21 — площадь граничных граней

## Родитель: AirPicardJob.parent_data() — {grid, tc, heat: {u, v, w, th, thd}, mech: {…}} (N
## родителя; нет thd — нули).
var parent := {}
## Тёплый старт от прошлого окна той же клетки: window_state() — {grid, heat: {u, v, w, th, thd, p},
## mech: {…}}; сдвиг — целое число клеток по x, y, z (иначе не используется).
var prev := {}

## Устройство общее с другими задачами (start(g) с готовым AirGpu): release() освобождает только
## свои буферы — RD и собранные ядра остаются (сдвиг окна без пересборки ядер).
var shared_gpu := false

var _prev_shift := Vector3i.ZERO
var _use_prev := false
var _mark := 0
var _par_thd_zero := false


func _shaders() -> Array:
	return super._shaders() + WINDOW_SHADERS


func _setup() -> bool:
	_mark = gpu.mark()
	if parent.is_empty() or not parent.has("grid"):
		error = "AirWindowJob: нет родителя"
		return false
	if not (case is AirWindowCase):
		error = "AirWindowJob: случай не окно (AirWindowCase)"
		return false
	_use_prev = _prev_ok()
	return super._setup()


## Прошлое окно подходит для тёплого старта: та же клетка, сдвиг — целое число клеток.
func _prev_ok() -> bool:
	if prev.is_empty() or not prev.has("grid"):
		return false
	var g: Dictionary = prev.grid
	if not is_equal_approx(float(g.dx), case.dx) or not is_equal_approx(float(g.dz), case.dz):
		return false
	var fx := (case.x0 - float(g.x0)) / case.dx
	var fy := (case.y0 - float(g.y0)) / case.dx
	var fz := (case.z_bot - float(g.z_bot)) / case.dz
	if absf(fx - roundf(fx)) > 1e-3 or absf(fy - roundf(fy)) > 1e-3 or absf(fz - roundf(fz)) > 1e-3:
		return false
	_prev_shift = Vector3i(roundi(fx), roundi(fy), roundi(fz))
	# старое окно не пересекается с новым — старта от него нет
	return (
		absi(_prev_shift.x) < int(g.nx)
		and absi(_prev_shift.y) < int(g.ny)
		and absi(_prev_shift.z) < int(g.nz) + 2
	)


## Родитель и прошлое окно для случая c (с нагревом или без) — в буферы окна. Зовётся базой
## перед подготовкой каждого случая (_setup, смена случая после finalize).
func _upload_case(c: AirCase) -> void:
	super._upload_case(c)
	var pg: Dictionary = parent.grid
	var pn := (int(pg.nx) + 2) * (int(pg.ny) + 2) * (int(pg.nz) + 2)
	if not buf.has("par_u"):
		for nm in ["par_u", "par_v", "par_w", "par_th", "par_thd", "par_tc"]:
			buf[nm] = gpu.buffer(pn)
		buf.nprm = gpu.buffer(8)
		buf.nar = gpu.buffer(_n)
		gpu.upload(buf.par_tc, parent.tc)
		var pdx := float(pg.dx)
		var pdz := float(pg.dz)
		gpu.upload(
			buf.nprm,
			PackedFloat32Array(
				[
					(case.x0 - float(pg.x0)) / pdx,
					(case.y0 - float(pg.y0)) / pdx,
					(case.z_bot - float(pg.z_bot)) / pdz,
					case.dx / pdx,
					case.dz / pdz,
					0.0,
					0.0,
					0.0
				]
			)
		)
	var set_name := "mech" if c.heat.is_empty() and parent.has("mech") else "heat"
	var src: Dictionary = parent[set_name]
	gpu.upload(buf.par_u, src.u)
	gpu.upload(buf.par_v, src.v)
	gpu.upload(buf.par_w, src.w)
	gpu.upload(buf.par_th, src.th)
	_upload_or_zero(buf.par_thd, src.get("thd", PackedFloat32Array()), pn)
	var ptd: PackedFloat32Array = src.get("thd", PackedFloat32Array())
	_par_thd_zero = ptd.count(0.0) == ptd.size()
	if _use_prev:
		var og: Dictionary = prev.grid
		var on := (int(og.nx) + 2) * (int(og.ny) + 2) * (int(og.nz) + 2)
		if not buf.has("old_u"):
			for nm in ["old_u", "old_v", "old_w", "old_th", "old_thd", "old_p"]:
				buf[nm] = gpu.buffer(on)
			buf.sprm = gpu.buffer(4)
			gpu.upload(
				buf.sprm, PackedFloat32Array([_prev_shift.x, _prev_shift.y, _prev_shift.z, 0.0])
			)
		var ps: Dictionary = prev.get(set_name, prev.get("heat", {}))
		for nm in ["u", "v", "w", "th", "p"]:
			gpu.upload(buf["old_" + nm], ps[nm])
		_upload_or_zero(buf.old_thd, ps.get("thd", PackedFloat32Array()), on)


## a — в буфер b из n чисел; нет массива (родитель или прошлое окно без θ′_d) — нули (редкий
## путь: parent_data/window_state несут thd всегда).
func _upload_or_zero(b: RID, a: PackedFloat32Array, n: int) -> void:
	if a.size() != n:
		a = PackedFloat32Array()
		a.resize(n)
	gpu.upload(b, a)


## Подготовка случая (база) + граница от родителя.
func _record_setup() -> void:
	super._record_setup()
	_rec_nest()


func _rec_nest() -> void:
	var d := _pc0()
	var pg: Dictionary = parent.grid
	var pd := [int(pg.nx) + 2, int(pg.ny) + 2, int(pg.nz) + 2, 0]
	gpu.kernel(
		"air_window:nest",
		[
			buf.prm,
			buf.nprm,
			buf.tcode,
			buf.par_tc,
			buf.par_u,
			buf.par_v,
			buf.par_w,
			buf.par_th,
			buf.ubu,
			buf.ubv,
			buf.ubw,
			buf.thb,
			buf.par_thd,
			buf.thbd
		],
		_n,
		[d[0], d[1], d[2], 0],
		pd,
		[],
		8.0
	)
	gpu.kernel(
		"air_window:flux",
		[buf.prm, buf.tcode, buf.ubu, buf.ubv, buf.ubw, buf.r, buf.nar],
		_n,
		[d[0], d[1], d[2], 0]
	)
	gpu.reduce(AirGpu.Red.SUM, buf.r, _n, S_NET)
	gpu.reduce(AirGpu.Red.SUM, buf.nar, _n, S_NET + 1)
	gpu.kernel(
		"air_window:corr",
		[buf.prm, buf.tcode, gpu.scalars, buf.ubu, buf.ubv, buf.ubw],
		_n,
		[d[0], d[1], d[2], 0],
		[0, 0, 0, S_NET]
	)


func _rec_shift() -> void:
	var d := _pc0()
	var og: Dictionary = prev.grid
	gpu.kernel(
		"air_window:shift",
		[
			buf.prm,
			buf.sprm,
			buf.tcode,
			buf.old_u,
			buf.old_v,
			buf.old_w,
			buf.old_th,
			buf.old_p,
			buf.u,
			buf.v,
			buf.w,
			buf.th,
			buf.p,
			buf.old_thd,
			buf.thd
		],
		_n,
		[d[0], d[1], d[2], 0],
		[int(og.nx) + 2, int(og.ny) + 2, int(og.nz) + 2, 0],
		[],
		2.0
	)


func _rec_warm_init() -> void:
	_bc(1)
	_rec_shift()


func _rec_warm_reinit() -> void:
	_record_setup()
	_bc(1)
	_rec_shift()


func _program(key: String) -> Array:
	if _progs.has(key):
		return _progs[key]
	var a := []
	match key:
		"winit":
			a = gpu.record(_rec_warm_init)
			a.append_array(_prog_project(4, false))
		"wreinit":
			a = gpu.record(_rec_warm_reinit)
			a.append_array(_prog_project(4, false))
		_:
			return super._program(key)
	_progs[key] = a
	return a


func _no_thd() -> bool:
	return super._no_thd() and _par_thd_zero


func _step_program(i: int) -> Array:
	if _phase == Phase.INIT and _use_prev:
		return _program("wreinit" if _ci > 0 else "winit")
	return super._step_program(i)


func release() -> void:
	if not shared_gpu or gpu == null:
		super.release()
		return
	if _submitted:
		gpu.sync()
		_submitted = false
	gpu.free_from(_mark)
	gpu = null


## Состояние окна для тёплого старта следующего (сдвиг, пересчёт): {grid, heat, mech}.
func window_state() -> Dictionary:
	return {grid = grid(), heat = state(false), mech = state(true)}


## Поправка потока через границу окна (м/с по нормали) последнего случая — для отчёта.
func nest_corr() -> float:
	var s := gpu.download(gpu.scalars, 2, S_NET)
	return s[0] / s[1] if s[1] > 0.0 else 0.0
