class_name AirPicardJob
extends AirGpuJob
## Пикар на GPU, один уровень (AM-03): установившееся среднее поле масштаба 1 по эталону AM-01
## (tools/research/air3d/air.py, reference.md → «Дискретизация»), блоками AM-02 (прогонки,
## V-цикл, редукции) и ядрами air_picard.glsl. Порциями (AirGpuJob): главный поток не ждёт GPU.
## Описание, буферы, замеры — docs/guide/air-model-gpu.md → «Пикар».
##
##   var job := AirPicardJob.new()
##   job.case = c                       # AirCase (prepare() — внутри start)
##   job.mech = true                    # сначала решение без нагрева → w_mech (Стык 1↔2)
##   job.warm = prev.state()            # по желанию: тёплый старт (u, v, w, θ′, θ′_d, p)
##   job.finished.connect(...); job.failed.connect(...)
##   job.start(); …раз в кадр: job.poll() …
##   var f := job.field()               # WindField (docs/guide/air-model.md → «Поле на CPU»)
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
	"air_picard:resid",
	"air_picard:relax",
	"air_picard:freeze",
	"air_picard:rmask",
	"air_picard:fixrow",
	"air_picard:prolong"
]

## Вид точки для ядер P11 (air_picard.glsl: relax/freeze/rmask).
const KIND_U := 0
const KIND_V := 1
const KIND_C := 2  # центр клетки и грань w — своя колонна
const KIND_IN := 3  # внутренняя клетка без ореола (rhs)
## Плоскость первой клетки воздуха столбца в AirCase.col (air_picard.glsl: C_KF).
const COL_KF := 1

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
## Тёплый старт решения с нагревом (при паре mech): {u, v, w, th, thd, p} той же раскладки; пусто —
## как прежде (решение с нагревом — с фона, «reinit»).
var warm_heat := {}
## Старт от грубой сетки (AirRuntime, air_model.picard_start = coarse): {dims (Vector3i, с ореолом),
## x0, y0, dx, z_bot, mech: {u, v, w, th, thd, p}, heat: {…}} — решения грубой сетки той же
## области; на GPU интерполируются на эту сетку (air_picard:prolong) и стартуют каждое своё решение.
## Важнее warm / warm_heat. Пусто — нет.
var warm_coarse := {}
## Критерий (эталон: Air.solve).
var tol_mom := 2e-5
var tol_th := 5e-7
var tol_div := 1e-6
var check_every := 10
var max_outer := 3000
## P11 (air-phase): ω недорелаксации по колоннам, ny·nx без ореола (u ← u + ω(u* − u), K — так же);
## пусто — ω = 1, шаг как прежде. Обычно — AirPhaseJob.omega (P10).
var omega_map := PackedFloat32Array()
## P11: 1 — колонна отдана механизму фазы (ny·nx); её u, v, w, θ′, θ′_d, K после каждой итерации
## переписываются полем механизма, невязка и критерий — только по остальным. Пусто — нет.
var freeze_mask := PackedByteArray()
## То же для решения без нагрева (P10 v5 freeze_mech); пусто — freeze_mask для обоих. С ним
## freeze_mask — только для решения с нагревом.
var freeze_mask_mech := PackedByteArray()
## P11: поле механизма для замороженных колонн — {u, v, w, th, thd} в раскладке warm (N с ореолом);
## нет канала — его значение после старта (тёплый старт, спроецированный). K — всегда после старта.
var freeze_field := {}
## Поле механизма для решения без нагрева (mech; P10 `mech_field_mech`, сверх контракта AP-19);
## пусто — freeze_field для обоих решений. С ним freeze_field — только для решения с нагревом.
var freeze_field_mech := {}
## P11: запасное правило — нет сходимости к x итерациям решения → ω := min(ω, y) во всех колоннах.
## (0, 0) — выкл. (по умолчанию; игра ставит из configs/atmosphere.json → air_model).
var omega_fallback := Vector2.ZERO
## P12 v2 (запасной путь по сходимости): с итерации late_from каждое состояние проверки копится
## в среднее (late_mean; 0 — не копится). Решение упёрлось в max_outer — его поле := late_mean, в
## колоннах nonconv_mask (ny·nx, 1 — механизм H/D) := nonconv_field ({u, v, w, th, thd}, раскладка
## warm; нет канала — late_mean), затем проекция-сшивка finalize. Всё пусто — как прежде.
var late_from := 0
var nonconv_mask := PackedByteArray()
var nonconv_field := {}
## P12 v2, итог: запасной путь сработал (на любом из решений), доля колонн механизма.
var nonconv_fallback := false
var nonconv_frac := 0.0
## P11, итог: запасное правило сработало (на любом из решений) и итерация переключения (−1 — нет);
## доля замороженных колонн.
var omega_fallback_used := false
var omega_switch_iter := -1
var frozen_frac := 0.0

## Итог по решениям (порядок: без нагрева, с нагревом): {label, status, iters, hist, div_rms, …}.
var results: Array[Dictionary] = []
## GPU-время всех порций, мс; стена от start() до готовности, мс.
var gpu_ms_total := 0.0
var wall_ms := 0.0
## GPU-время по этапам, мс (P14): init — старт (фон/тёплый + проекция), iter — итерации Пикара с
## проверками, final — проекция-сшивка (finalize V-циклами) и копии решения без нагрева.
var phase_gpu_ms := {init = 0.0, iter = 0.0, final = 0.0}
var _log_i := 0
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
# P11: ω по колоннам включено (карта или сработавшее запасное правило), заморозка, каналы снимка
# после старта, число неизвестных по незамороженным (как AirCase.n_unk / n_fluid).
var _relax := false
var _freeze := false
var _snap_names: Array[String] = []
var _omega_cols := PackedFloat32Array()
var _n_unk_free := PackedInt32Array()
var _n_fluid_free := 0
# P12 v2: состояний в среднем решения, программа применения на FINAL.
var _late_n := 0
var _late_ch: Array[String] = ["u", "v", "w", "th", "thd"]
var _nonconv := false


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
	if not _setup_p11():
		return false
	if not warm_coarse.is_empty():
		var cd: Vector3i = warm_coarse.dims
		for nm in ["u", "v", "w", "th", "thd", "p"]:
			buf["c" + nm] = gpu.buffer(cd.x * cd.y * cd.z)
		_prolong("mech")
	_phase = Phase.INIT
	_iters = 0
	_hist = []
	return true


## P11: буферы карты ω, заморозки и снимка; проверка размеров. Всё пусто — ничего не заводится.
func _setup_p11() -> bool:
	var ncell := case.nx * case.ny
	_log_i = chunk_log.size()
	phase_gpu_ms = {init = 0.0, iter = 0.0, final = 0.0}
	omega_fallback_used = false
	omega_switch_iter = -1
	frozen_frac = 0.0
	_relax = not omega_map.is_empty()
	_freeze = not freeze_mask.is_empty() or not freeze_mask_mech.is_empty()
	if _relax and omega_map.size() != ncell:
		error = "AirPicardJob: omega_map не ny·nx"
		return false
	for m: PackedByteArray in [freeze_mask, freeze_mask_mech]:
		if not m.is_empty() and m.size() != ncell:
			error = "AirPicardJob: freeze_mask не ny·nx"
			return false
	var ncol := _dims.x * _dims.y
	if _relax or omega_fallback.x > 0.0:
		var om := omega_map
		if om.is_empty():
			om = PackedFloat32Array()
			om.resize(ncell)
			om.fill(1.0)
		_omega_cols = _pad_cols(om, true)
		buf.omc = gpu.buffer(ncol, _omega_cols)
		for nm in ["uo", "vo", "wo", "nuo", "nuho"]:
			buf[nm] = gpu.buffer(_n)
	if not _setup_nonconv(ncell, ncol):
		return false
	if not _freeze:
		return true
	buf.frz = gpu.buffer(ncol)
	_use_freeze_mask(_mask_of(0))
	_snap_names = ["nu", "nuh"]
	var first := freeze_field_mech if (_cases.size() > 1 and not freeze_field_mech.is_empty()) else freeze_field
	for nm in ["u", "v", "w", "th", "thd"]:
		buf["f" + nm] = gpu.buffer(_n)
		var a: PackedFloat32Array = first.get(nm, PackedFloat32Array())
		if a.is_empty():
			_snap_names.append(nm)
		elif a.size() != _n:
			error = "AirPicardJob: freeze_field другого размера"
			return false
		else:
			gpu.upload(buf["f" + nm], a)
	buf.fnu = gpu.buffer(_n)
	buf.fnuh = gpu.buffer(_n)
	return true


## Маска заморозки решения ci (0 — первое: без нагрева при паре).
func _mask_of(ci: int) -> PackedByteArray:
	var mech_first := _cases.size() > 1 and ci == 0
	if mech_first and not freeze_mask_mech.is_empty():
		return freeze_mask_mech
	if freeze_mask.is_empty() and not freeze_mask_mech.is_empty():
		var z := PackedByteArray()
		z.resize(freeze_mask_mech.size())
		return z
	return freeze_mask


## Маска на GPU, доля замороженных, числа неизвестных по незамороженным.
func _use_freeze_mask(m: PackedByteArray) -> void:
	var ncell := m.size()
	var fz := PackedFloat32Array()
	fz.resize(ncell)
	var nfr := 0
	for q in ncell:
		fz[q] = 1.0 if m[q] != 0 else 0.0
		nfr += 1 if m[q] != 0 else 0
	frozen_frac = float(nfr) / float(maxi(ncell, 1))
	gpu.upload(buf.frz, _pad_cols(fz, false))
	_count_free(m)


## P12 v2: буферы среднего и поля механизма для запасного пути.
func _setup_nonconv(ncell: int, ncol: int) -> bool:
	nonconv_fallback = false
	nonconv_frac = 0.0
	_late_n = 0
	_nonconv = not nonconv_mask.is_empty()
	if _nonconv and nonconv_mask.size() != ncell:
		error = "AirPicardJob: nonconv_mask не ny·nx"
		return false
	if late_from <= 0 and not _nonconv:
		return true
	for nm in _late_ch:
		buf["l" + nm] = gpu.buffer(_n)
	if not _nonconv:
		return true
	var m := PackedFloat32Array()
	m.resize(ncell)
	var cnt := 0
	for q in ncell:
		m[q] = 1.0 if nonconv_mask[q] != 0 else 0.0
		cnt += 1 if nonconv_mask[q] != 0 else 0
	nonconv_frac = float(cnt) / float(ncell)
	buf.ncm = gpu.buffer(ncol, _pad_cols(m, false))
	for nm in _late_ch:
		var a: PackedFloat32Array = nonconv_field.get(nm, PackedFloat32Array())
		if a.is_empty():
			continue
		if a.size() != _n:
			error = "AirPicardJob: nonconv_field другого размера"
			return false
		buf["n" + nm] = gpu.buffer(_n, a)
	return true


func _heat_warm_ok() -> bool:
	if warm_coarse.has("heat"):
		return true
	return PackedFloat32Array(warm_heat.get("u", PackedFloat32Array())).size() == _n


## Есть тёплый старт первого решения (warm или грубая сетка).
func _warm_on() -> bool:
	return not warm.is_empty() or not warm_coarse.is_empty()


## Решение грубой сетки (which: mech | heat) → u, v, w, θ′, θ′_d, p этой сетки (сразу в очередь GPU).
func _prolong(which: String) -> void:
	var st: Dictionary = warm_coarse.get(which, {})
	var cd: Vector3i = warm_coarse.dims
	var nc := cd.x * cd.y * cd.z
	var d := _pc0()
	var dxc := float(warm_coarse.dx)
	var f := [
		(case.x0 - float(warm_coarse.x0)) / dxc, (case.y0 - float(warm_coarse.y0)) / dxc, case.dx / dxc
	]
	var ksh := roundi((case.z_bot - float(warm_coarse.z_bot)) / case.dz)
	var kinds := {u = KIND_U, v = KIND_V}
	for nm in ["u", "v", "w", "th", "thd", "p"]:
		var a: PackedFloat32Array = st.get(nm, PackedFloat32Array())
		if a.size() != nc:
			gpu.fill(buf[nm], _n)
			continue
		gpu.upload(buf["c" + nm], a)
		gpu.kernel(
			"air_picard:prolong", [buf["c" + nm], buf[nm]], _n,
			[d[0], d[1], d[2], kinds.get(nm, KIND_C)], [cd.x, cd.y, cd.z, ksh], f
		)


func _zeros() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(_n)
	return z


## Решение с нагревом после mech: тёплый старт warm_heat (если задан) и его поле механизма (freeze_field), если для mech было своё.
func _upload_heated_freeze() -> void:
	if warm_coarse.has("heat"):
		_prolong("heat")
	elif _heat_warm_ok():
		for nm in ["u", "v", "w", "th", "thd", "p"]:
			var a: PackedFloat32Array = warm_heat.get(nm, PackedFloat32Array())
			if a.size() == _n:
				gpu.upload(buf[nm], a)
			elif nm == "thd":
				gpu.upload(buf.thd, _zeros())
	if not _freeze:
		return
	if not freeze_mask_mech.is_empty():
		_use_freeze_mask(_mask_of(_ci))
	if freeze_field_mech.is_empty():
		return
	for nm in ["u", "v", "w", "th", "thd"]:
		var a: PackedFloat32Array = freeze_field.get(nm, PackedFloat32Array())
		if a.size() == _n:
			gpu.upload(buf["f" + nm], a)


## Колонночная карта ny·nx → с ореолом (NY·NX): edge — ореол значением края (ω), иначе 0
## (заморозка; research P4 v6: pad edge / constant False).
func _pad_cols(a: PackedFloat32Array, edge: bool) -> PackedFloat32Array:
	var nx := case.nx
	var ny := case.ny
	var out := PackedFloat32Array()
	out.resize(_dims.x * _dims.y)
	for j in _dims.y:
		for i in _dims.x:
			var inside := i >= 1 and i <= nx and j >= 1 and j <= ny
			if inside or edge:
				var src := clampi(j - 1, 0, ny - 1) * nx + clampi(i - 1, 0, nx - 1)
				out[j * _dims.x + i] = a[src]
	return out


## Неизвестные по незамороженным (как AirCase._count_unknowns; грань u/v заморожена, когда
## заморожена хотя бы одна колонна — air_picard.glsl:frozen_at).
func _count_free(mask: PackedByteArray) -> void:
	var nxh := _dims.x
	var nyh := _dims.y
	var nzh := _dims.z
	var cl := case.col
	var fr := func(j: int, i: int) -> bool:
		return mask[(j - 1) * case.nx + (i - 1)] != 0
	var kf := func(j: int, i: int) -> int:
		return maxi(int(cl[COL_KF * nxh * nyh + j * nxh + i]), 1)
	var nf := 0
	var nw := 0
	var nu := 0
	var nv := 0
	for j in range(1, nyh - 1):
		for i in range(1, nxh - 1):
			if not fr.call(j, i):
				var c := maxi(nzh - 2 - kf.call(j, i) + 1, 0)
				nf += c
				nw += maxi(c - 1, 0)
			if i >= 2 and not (fr.call(j, i) or fr.call(j, i - 1)):
				nu += maxi(nzh - 2 - maxi(kf.call(j, i), kf.call(j, i - 1)) + 1, 0)
			if j >= 2 and not (fr.call(j, i) or fr.call(j - 1, i)):
				nv += maxi(nzh - 2 - maxi(kf.call(j, i), kf.call(j - 1, i)) + 1, 0)
	_n_unk_free = PackedInt32Array([nu, nv, nw, nf])
	_n_fluid_free = nf


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
	if _freeze:
		var fx: RID = [buf.fu, buf.fv, buf.fw][comp]
		gpu.kernel("air_picard:fixrow", [buf.frz, c, fx], _n, [d[0], d[1], d[2], [KIND_U, KIND_V, KIND_C][comp]])


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
	if _freeze:
		var fx: RID = buf.fthd if mode == 0 else buf.fth
		gpu.kernel("air_picard:fixrow", [buf.frz, buf.Cu, fx], _n, [d[0], d[1], d[2], KIND_C])


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
	if _freeze:
		_rmask(buf.r, mini(which, KIND_C), _n)
	gpu.reduce(AirGpu.Red.DOT, buf.r, _n, S_R2 + which if r2_slot < 0 else r2_slot, buf.r)
	gpu.reduce(AirGpu.Red.MAXABS, buf.r, _n, S_RMAX + which if rmax_slot < 0 else rmax_slot)


## P11: x ← x_old + ω(x − x_old) по колоннам (air_picard.glsl:relax).
func _relax_k(x: RID, xo: RID, kind: int) -> void:
	var d := _pc0()
	gpu.kernel("air_picard:relax", [buf.omc, x, xo], _n, [d[0], d[1], d[2], kind])


## P11: замороженные точки x ← xf (air_picard.glsl:freeze).
func _freeze_k(x: RID, xf: RID, kind: int) -> void:
	var d := _pc0()
	gpu.kernel("air_picard:freeze", [buf.frz, x, xf], _n, [d[0], d[1], d[2], kind])


## P11: невязка в замороженных точках → 0 (n — длина r).
func _rmask(r: RID, kind: int, n: int) -> void:
	var d := _pc0()
	gpu.kernel("air_picard:rmask", [buf.frz, r], n, [d[0], d[1], d[2], kind], [n])


func _rec_relax_u() -> void:
	_relax_k(buf.u, buf.uo, KIND_U)
	_relax_k(buf.v, buf.vo, KIND_V)
	_relax_k(buf.w, buf.wo, KIND_C)


## Замороженные колонны → поле механизма (u, v, w, θ′, θ′_d, K).
func _rec_freeze() -> void:
	_freeze_k(buf.u, buf.fu, KIND_U)
	_freeze_k(buf.v, buf.fv, KIND_V)
	for nm in ["w", "th", "thd", "nu", "nuh"]:
		_freeze_k(buf[nm], buf["f" + nm], KIND_C)


## Снимок после старта: каналы заморозки без freeze_field и K.
func _rec_snap() -> void:
	for nm in _snap_names:
		gpu.vec(AirGpu.Vec.COPY, buf[nm], buf["f" + nm], _n)


## Проекция: ∇·u → минус среднее → cycles V-циклов от φ = 0 → φ минус среднее → u −= K∇φ (p += φ).
## masked (P11, итерации с заморозкой): ∇·u замороженных клеток в правую часть не идёт — поле
## механизма там граничное условие, проекция его не «чинит» потоком через соседей (иначе вечный
## источник и нет сходимости); finalize — без маски (сшивка всего поля).
func _prog_project(cycles: int, update_p: bool, masked := false) -> Array:
	var a := gpu.record(_rec_project_head.bind(masked))
	for _c in cycles:
		a.append_array(mg.program(buf.phi, buf.rhs))
	a.append_array(gpu.record(_rec_project_tail.bind(update_p)))
	return a


func _rec_project_head(masked := false) -> void:
	_div()
	if masked:
		_rmask(buf.rhs, KIND_IN, _ni)
	gpu.reduce(AirGpu.Red.SUM, buf.rhs, _ni, S_RSUM)
	# совместность: среднее — по незамороженным, замороженным — 0 (иначе постоянный источник там
	# и φ не гаснет: p дрейфует, невязка импульса не сходится)
	var nf := float(_n_fluid_free) if masked else float(case.n_fluid)
	gpu.axpy(-1.0 / nf, buf.act, buf.rhs, _ni, S_RSUM)
	if masked:
		_rmask(buf.rhs, KIND_IN, _ni)
	gpu.fill(buf.phi, _ni)


func _rec_project_tail(update_p: bool) -> void:
	gpu.reduce(AirGpu.Red.DOT, buf.phi, _ni, S_PHI, buf.act)
	gpu.axpy(-1.0 / float(case.n_fluid), buf.act, buf.phi, _ni, S_PHI)
	_proj(update_p)


## Одна итерация Пикара (reference.md → «Итерация Пикара»).
## no_thd — без прохода θ′_d (решение без нагрева, _no_thd()).
func _prog_iteration(no_thd := false) -> Array:
	var a := gpu.record(_rec_momentum)
	a.append_array(_prog_project(int(case.p.vcycles), true, _freeze))
	if _relax:
		a.append_array(gpu.record(_rec_relax_u))
	a.append_array(gpu.record(_rec_heat_step.bind(no_thd)))
	if _freeze:
		a.append_array(gpu.record(_rec_freeze))
	return a


func _rec_momentum() -> void:
	var d := case.dims()
	_bc(0)
	var lk := bool(case.p.local_k)
	if _relax and lk:
		gpu.vec(AirGpu.Vec.COPY, buf.nu, buf.nuo, _n)
		gpu.vec(AirGpu.Vec.COPY, buf.nuh, buf.nuho, _n)
	if lk:
		_kloc()
	if _relax:
		if lk:
			_relax_k(buf.nu, buf.nuo, KIND_C)
			_relax_k(buf.nuh, buf.nuho, KIND_C)
		gpu.vec(AirGpu.Vec.COPY, buf.u, buf.uo, _n)
		gpu.vec(AirGpu.Vec.COPY, buf.v, buf.vo, _n)
		gpu.vec(AirGpu.Vec.COPY, buf.w, buf.wo, _n)
	_mom(0)
	_mom(1)
	_mom(2)
	for _s in int(case.p.mom_sweeps):
		gpu.zebra(buf.Cu, buf.u, RID(), d, [2, 0, 1], true)
		gpu.zebra(buf.Cv, buf.v, RID(), d, [2, 0, 1], true)
		gpu.zebra(buf.Cw, buf.w, RID(), d, [2, 0, 1], true)


## Шаг тепла (Air.heat_step): шаблон θ′_d → прогонки θ′_d → шаблон θ′ (от нового θ′_d) → прогонки.
## no_thd: θ′_d ≡ 0 точно (нет нагрева и θ′_d родителя) — его проход пропускается (А2).
func _rec_heat_step(no_thd := false) -> void:
	if not no_thd:
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
	_rec_div_stats(_freeze)


## masked: ∇·u только незамороженных и за вычетом их среднего — постоянная совместности от поля
## механизма (его суммарный поток через общие грани) не ошибка решения; она — в S_RSUM.
func _rec_div_stats(masked := false) -> void:
	_div()
	if masked:
		_rmask(buf.rhs, KIND_IN, _ni)
		gpu.reduce(AirGpu.Red.SUM, buf.rhs, _ni, S_RSUM)
		gpu.axpy(-1.0 / float(_n_fluid_free), buf.act, buf.rhs, _ni, S_RSUM)
		_rmask(buf.rhs, KIND_IN, _ni)
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
		"reinit_warm":
			a = gpu.record(func() -> void:
				_record_setup()
				_bc(0))
			a.append_array(_prog_project(4, false))
		"iters", "iters_nh", "iters_r", "iters_nh_r", "iters_f", "iters_nh_f", "iters_r_f", "iters_nh_r_f":
			var nh := key.begins_with("iters_nh")
			if nh:  # тёплое θ′_d без нагрева — к точному решению 0 (заодно и после init)
				a = gpu.record(func() -> void: gpu.fill(buf.thd, _n))
			var one := _prog_iteration(nh)
			for _i in check_every:
				a.append_array(one)
			a.append_array(_prog_check())
		"final":
			a = gpu.record(_bc.bind(0))
			a.append_array(_prog_project(10, false))
			a.append_array(gpu.record(_rec_div_stats))
		"mech_done":
			a = gpu.record(_rec_copy_wmech)
		"fsnap":
			a = gpu.record(_rec_snap)
		"late_copy", "late_add":
			var add := key == "late_add"
			a = gpu.record(func() -> void:
				for nm in _late_ch:
					if add:
						gpu.axpy(1.0, buf[nm], buf["l" + nm], _n)
					else:
						gpu.vec(AirGpu.Vec.COPY, buf[nm], buf["l" + nm], _n))
	_progs[key] = a
	return a


func _step_program(_i: int) -> Array:
	match _phase:
		Phase.INIT:
			if _ci > 0:
				return _program("reinit_warm" if _heat_warm_ok() else "reinit")
			var a: Array = _program("warm" if _warm_on() else "init")
			return a + _program("fsnap") if _freeze else a
		Phase.ITER:
			if _late_on() and _iters >= late_from and _iters > 0:
				_late_n += 1
				return _program("late_copy" if _late_n == 1 else "late_add") + _program(_iter_key())
			return _program(_iter_key())
		Phase.FINAL:
			var pre := _late_apply_program()
			if _ci < _cases.size() - 1:
				return pre + _program("final") + _program("mech_done")
			return pre + _program("final")
	return []


func _late_on() -> bool:
	return late_from > 0 or _nonconv


## P12 v2: решение упёрлось в max_outer — поле := late_mean (+ механизм в колоннах nonconv_mask);
## иначе пусто. Масштаб 1/n — свой на каждое решение, программа не кэшируется.
func _late_apply_program() -> Array:
	if _status != "max" or not _late_on() or _late_n == 0:
		return []
	nonconv_fallback = true
	var inv := 1.0 / float(_late_n)
	var d := _pc0()
	return gpu.record(func() -> void:
		for nm in _late_ch:
			gpu.vec(AirGpu.Vec.COPY, buf["l" + nm], buf[nm], _n)
			gpu.vec(AirGpu.Vec.SCALE, RID(), buf[nm], _n, inv)
		if _nonconv:
			var kinds := {u = KIND_U, v = KIND_V}
			for nm in _late_ch:
				if buf.has("n" + nm):
					gpu.kernel(
						"air_picard:freeze", [buf.ncm, buf[nm], buf["n" + nm]], _n,
						[d[0], d[1], d[2], kinds.get(nm, KIND_C)]
					))


## Программа пачки итераций: без θ′_d (nh), с картой ω (r), с заморозкой (f).
func _iter_key() -> String:
	var k := "iters_nh" if _no_thd() else "iters"
	if _relax:
		k += "_r"
	if _freeze:
		k += "_f"
	return k


## Запасное правило P11: ω := min(ω, omega_fallback.y) во всех колоннах; дальше — с картой ω.
func _switch_omega() -> void:
	for q in _omega_cols.size():
		_omega_cols[q] = minf(_omega_cols[q], omega_fallback.y)
	gpu.upload(buf.omc, _omega_cols)
	_relax = true
	omega_fallback_used = true
	omega_switch_iter = _iters


## Решение без θ′_d: нет нагрева (Q ≡ 0) и θ′_d на границах ≡ 0 — тогда уравнение θ′_d однородно,
## его решение 0 точно (Air.solve: no_thd). Окно добавляет условие «θ′_d родителя ≡ 0».
func _no_thd() -> bool:
	return _cases[_ci].heat.is_empty()


func _after_sync() -> bool:
	var ms := 0.0
	for q in range(_log_i, chunk_log.size()):
		ms += chunk_log[q].y
	_log_i = chunk_log.size()
	var pk: String = ["init", "iter", "final", "final"][_phase]
	phase_gpu_ms[pk] = float(phase_gpu_ms[pk]) + ms
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
			elif omega_fallback.x > 0.0 and not omega_fallback_used and _iters >= int(omega_fallback.x):
				_switch_omega()
		Phase.FINAL:
			_finish_result()
			if _ci < _cases.size() - 1:
				_ci += 1
				_upload_case(_cases[_ci])
				_upload_heated_freeze()
				_phase = Phase.INIT
				_late_n = 0
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
		omega_fallback_used = omega_fallback_used,
		omega_switch_iter = omega_switch_iter,
		frozen_frac = frozen_frac,
		nonconv_fallback = _status == "max" and _late_on() and _late_n > 0,
		late_n = _late_n,
	}
	results.append(res)


func _read_residuals() -> Dictionary:
	var s := gpu.download(gpu.scalars, N_SCALARS)
	var c := _cases[_ci]
	# P11: с заморозкой — по незамороженным (типы клеток одни у обоих решений)
	var n_unk: PackedInt32Array = _n_unk_free if _freeze else c.n_unk
	var n_fl := _n_fluid_free if _freeze else c.n_fluid
	var rms := []
	for q in 4:
		rms.append(sqrt(s[S_R2 + q] / maxf(float(n_unk[q]), 1.0)))
	var rms_d := sqrt(s[S_R2D] / maxf(float(n_unk[3]), 1.0))
	# критерий тепла — по обоим скалярам (θ′ и θ′_d), как Air.residuals
	return {
		mom_rms = sqrt((rms[0] * rms[0] + rms[1] * rms[1] + rms[2] * rms[2]) / 3.0),
		mom_max = maxf(s[S_RMAX], maxf(s[S_RMAX + 1], s[S_RMAX + 2])),
		th_rms = maxf(rms[3], rms_d),
		th_max = maxf(s[S_RMAX + 3], s[S_RMAXD]),
		thd_rms = rms_d,
		thd_max = s[S_RMAXD],
		div_rms = sqrt(s[S_DIV2] / maxf(float(n_fl), 1.0)),
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
