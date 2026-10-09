class_name AirClipmap
extends RefCounted
## Клипмапы среднего поля (AM-04, docs/guide/air-model-gpu.md → «Клипмапы», контракт C7): область
## (400 м, AirPicardJob, её считает вызывающий — AirRuntime) + окна 64 × 64 с клеткой 100 и 50 м
## вокруг пилота (AirWindowJob). Решение сверху вниз: родитель окна 100 м — область, окна 50 м —
## окно 100 м; граница и зона релаксации — от родителя, w_mech — от родителя без нагрева.
## При загрузке — все окна с центром на старте; в полёте — сдвиг окна, когда пилот ушёл от его
## центра дальше shift_frac стороны окна: новый центр — у пилота, кратно клетке окна; окно и все
## мельче пересчитываются фоном (случай — в рабочем потоке, GPU — порциями раз в кадр, тёплый
## старт — старое окно + родитель). До готовности игра выбирает старые уровни; готовый набор —
## сигналом levels_changed (уровни от мелкого к грубому, последний — область) → вызывающий
## подаёт его в Atmosphere.set_air_field(levels, blend_s) (подмена плавная, C8).
##
##   var cm := AirClipmap.new()
##   cm.setup(detail, water, loc, hour, u10, wdir, t_max, sky)
##   cm.levels_changed.connect(func(lv): atmo.set_air_field(lv))
##   cm.set_domain(domain_job, domain_field)     # после решения области (при пересчёте — снова)
##   cm.start(start_xz)                          # окна с центром на старте
##   …раз в кадр: cm.update(pilot_pos); cm.poll()  (экран загрузки: cm.poll_slice(40))

## Новый набор уровней готов (от мелкого к грубому: окно 50 м, окно 100 м, область).
signal levels_changed(levels: Array[WindField])
## Окно не посчиталось (нет GPU, разошлось, таймаут) — игра остаётся на прежних уровнях.
signal failed(message: String)

## Клетки окон от грубого к мелкому, м (air_model.window_levels_m).
var window_dx: Array[float] = [100.0, 50.0]
## Доля стороны окна, на которую пилот уходит от центра до сдвига (air_model.window_shift_frac).
var shift_frac := 0.25
## Столбцов окна по стороне.
var cells := AirWindowCase.N_WINDOW
## Бюджет GPU порции, мс (AirGpuJob.chunk_ms), и предел времени одного окна, с.
var chunk_ms := 30.0
var timeout_s := 60.0

## Итоги по окнам (для замеров): {dx, x0, y0, reason, iters: [без нагрева, с нагревом], wall_ms,
## gpu_ms, max_chunk_ms, chunks, prep_ms, poll_max_ms}.
var history: Array[Dictionary] = []

var _detail: HeightLayer
var _surface: AirPlace.Surface = null
var _water: Image
var _loc := {}
var _ctx := {}
var _hour := 12.0
var _u10 := 0.0
var _wdir := 270.0
var _t_max := NAN
var _sky := "clear"
## Множитель притока окон (C2 v6, C7 v3) — тот же, что у области.
var _inflow_k := 1.0

var _domain_field: WindField
var _domain_pd := {}
## Уровни окон (от грубого к мелкому): {dx, x0, y0, field, pd (parent_data), st (window_state)}.
var _lv: Array[Dictionary] = []
## Очередь пересчёта: индексы уровней (по порядку от грубого) и причина.
var _queue: Array[int] = []
var _reason := ""
## Новые уровни, пока очередь не пройдена (подменяются целиком в конце).
var _pending: Array[Dictionary] = []
var _job: AirWindowJob = null
var _cur := -1
var _cur_row := {}
var _t_level := 0
var _waiting_field := false
var _field_job: AirWindowJob = null
## Одно устройство на все окна: ядра собираются один раз (первое окно), дальше задачи только
## заводят и освобождают свои буферы.
var _gpu: AirGpu = null
## Устройство снаружи (AirRuntime: одно на игру; ядра окон — в его init) — не освобождается здесь.
var _gpu_external := false
## Область сменилась во время расчёта — пересчитать окна после.
var _domain_dirty := false
## После неудачи — не пробовать сдвиг до этого момента (мкс).
var _retry_at := 0


## Вход места — как AirPlace.domain_case (detail — слой 25 м, water — маска или null, loc —
## configs/locations/<место>.json; u10 — ветер меню, inflow_k — множитель притока, как у области;
## surface — снимок поверхности места AirPlace.surface_of, C2 v8).
func setup(
	detail: HeightLayer,
	water: Image,
	loc: Dictionary,
	hour: float,
	u10: float,
	wdir: float,
	t_max := NAN,
	sky := "clear",
	inflow_k := 1.0,
	surface: AirPlace.Surface = null
) -> void:
	_detail = detail
	_surface = surface
	_inflow_k = inflow_k
	_loc = loc
	_hour = hour
	_u10 = u10
	_wdir = wdir
	_t_max = t_max
	_sky = sky
	_water = water
	if water != null and (water.is_compressed() or water.get_format() != Image.FORMAT_L8):
		# один раз: AirPlace.water_fraction иначе переводит маску на каждом окне
		_water = water.duplicate()
		if _water.is_compressed():
			_water.decompress()
		_water.convert(Image.FORMAT_L8)
	_ctx = AirPlace.context(detail, loc, WeatherModel.config())
	var ac: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	shift_frac = float(ac.get("window_shift_frac", shift_frac))
	var lv: Array = ac.get("window_levels_m", [])
	if not lv.is_empty():
		window_dx.clear()
		for v: Variant in lv:
			window_dx.append(float(v))


## Смена часа / ветра / погоды (фоновый пересчёт по игровому времени): затем set_domain(…) —
## окна пересчитаются с тёплого старта от своих прошлых полей.
func set_conditions(
	hour: float, u10: float, wdir: float, t_max := NAN, sky := "clear", inflow_k := 1.0
) -> void:
	_inflow_k = inflow_k
	_hour = hour
	_u10 = u10
	_wdir = wdir
	_t_max = t_max
	_sky = sky


## Область решена (задача ещё не освобождена — берём поле родителя с GPU) и её WindField.
## Окна, если уже есть, пересчитываются от новой области на прежних местах.
func set_domain(domain_job: AirPicardJob, domain_field: WindField) -> void:
	set_domain_data(domain_job.parent_data(), domain_field)


## То же с готовым parent_data() области (задача уже освобождена).
func set_domain_data(pd: Dictionary, domain_field: WindField) -> void:
	_domain_pd = pd
	_domain_field = domain_field
	if not _lv.is_empty():
		if is_busy():
			_domain_dirty = true
		else:
			_enqueue(0, "область")


## Окна с центром в (x, y) осей решателя (x — восток, y — север = −z мира).
func start(center_xy: Vector2) -> void:
	_lv.clear()
	for dx in window_dx:
		var o := _corner(center_xy, dx)
		_lv.append({dx = dx, x0 = o.x, y0 = o.y, field = null, pd = {}, st = {}})
	_enqueue(0, "загрузка")


## Общее устройство (AirGpu с ядрами AirWindowJob): окна не заводят своё. Задачи на нём идут по
## очереди — вызывающий не запускает свои, пока is_busy().
func use_gpu(g: AirGpu) -> void:
	_gpu = g
	_gpu_external = g != null


## Идёт расчёт (очередь не пуста).
func is_busy() -> bool:
	return _cur >= 0 or not _queue.is_empty()


## Доля очереди 0..1 (экран загрузки): готовые окна + доля текущей задачи.
func progress() -> float:
	if _pending.is_empty():
		return 1.0
	var done := 0.0
	for row in _pending:
		if row.field != null:
			done += 1.0
	if _job != null:
		done += _job.progress()
	return clampf(done / _pending.size(), 0.0, 1.0)


## Все окна посчитаны хотя бы раз.
func is_ready() -> bool:
	if _lv.is_empty():
		return false
	for l in _lv:
		if l.field == null:
			return false
	return true


## Текущие уровни от мелкого к грубому (готовые окна + область).
func levels() -> Array[WindField]:
	var out: Array[WindField] = []
	for q in range(_lv.size() - 1, -1, -1):
		if _lv[q].field != null:
			out.append(_lv[q].field)
	if _domain_field != null:
		out.append(_domain_field)
	return out


## Центр окна уровня q (от грубого), оси решателя.
func window_center(q: int) -> Vector2:
	var l := _lv[q]
	var h := 0.5 * cells * float(l.dx)
	return Vector2(float(l.x0) + h, float(l.y0) + h)


## Позиция пилота (мир) — раз в кадр: сдвиг окон, если он ушёл от центра дальше shift_frac.
func update(pilot_pos: Vector3) -> void:
	if _lv.is_empty() or is_busy() or not is_ready() or Time.get_ticks_usec() < _retry_at:
		return
	var p := Vector2(pilot_pos.x, -pilot_pos.z)
	for q in _lv.size():
		var l := _lv[q]
		var side := cells * float(l.dx)
		var c := window_center(q)
		if maxf(absf(p.x - c.x), absf(p.y - c.y)) > shift_frac * side:
			_enqueue(q, "сдвиг", p)
			return


## Раз в кадр (игра идёт): порции GPU в пределах кадра.
func poll() -> void:
	_poll(-1.0)


## Экран загрузки: порции подряд в пределах slice_ms главного потока.
func poll_slice(slice_ms: float) -> void:
	_poll(slice_ms)


func release() -> void:
	if _job != null:
		_job.release()
		_job = null
	_wait_tasks()
	_queue.clear()
	_cur = -1
	if _gpu != null and not _gpu_external:
		_gpu.release()
	_gpu = null if not _gpu_external else _gpu


# ---------------------------------------------------------------- внутреннее


func _corner(center: Vector2, dx: float) -> Vector2:
	var h := 0.5 * cells * dx
	return Vector2(roundf((center.x - h) / 25.0) * 25.0, roundf((center.y - h) / 25.0) * 25.0)


## Пересчитать уровень q и все мельче (мельче — от нового родителя); pilot — сдвиг: новый угол
## окна — старый + целое число клеток так, чтобы пилот был у центра.
func _enqueue(q: int, reason: String, pilot := Vector2(NAN, NAN)) -> void:
	if is_busy():
		return
	_reason = reason
	_queue.clear()
	_pending.clear()
	for i in range(q, _lv.size()):
		_queue.append(i)
		var row: Dictionary = _lv[i].duplicate()
		if not is_nan(pilot.x):
			var dx := float(row.dx)
			var c := window_center(i)
			row.x0 = float(row.x0) + roundf((pilot.x - c.x) / dx) * dx
			row.y0 = float(row.y0) + roundf((pilot.y - c.y) / dx) * dx
		row.field = null
		_pending.append(row)
	_start_tasks()
	_next()


func _pending_row(q: int) -> Dictionary:
	return _pending[q - (_lv.size() - _pending.size())]


func _next() -> void:
	if _queue.is_empty():
		_finish_all()
		return
	_cur = _queue.pop_front()
	_cur_row = _pending_row(_cur)
	_t_level = int(_cur_row.t_enq)


## Входы всех окон очереди — сразу в рабочих потоках (от родителя не зависят).
func _start_tasks() -> void:
	for row in _pending:
		row.t_enq = Time.get_ticks_usec()
		var args := [
			float(row.dx), float(row.x0), float(row.y0), _hour, _u10, _wdir, _t_max, _sky, _inflow_k
		]
		row.case = null
		row.task = WorkerThreadPool.add_task(_prepare_case.bind(args, row))


func _wait_tasks() -> void:
	for row in _pending:
		if int(row.get("task", -1)) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(row.task))
			row.task = -1


## Рабочий поток: вход окна (рельеф, погода, солнце) и подготовка обоих случаев (K_b, губки).
func _prepare_case(a: Array, row: Dictionary) -> void:
	var c := AirWindowCase.window_at(
		_detail,
		_water,
		_loc,
		a[0],
		a[1],
		a[2],
		a[3],
		a[4],
		a[5],
		a[6],
		a[7],
		true,
		_ctx,
		cells,
		a[8],
		_surface
	)
	if c != null and not c.prepare_pair():
		c = null
	row.case = c
	row.prep_ms = (Time.get_ticks_usec() - int(row.t_enq)) / 1000.0


func _poll(slice_ms: float) -> void:
	if _cur < 0:
		return
	var row := _cur_row
	if int(row.task) >= 0:
		if not WorkerThreadPool.is_task_completed(int(row.task)):
			return
		WorkerThreadPool.wait_for_task_completion(int(row.task))
		row.task = -1
	if _job == null and not _waiting_field:
		if _cur == 0 and _domain_pd.is_empty():
			return  # область ещё считается
		_start_job()
		return
	if _job == null or _waiting_field:
		return
	if slice_ms > 0.0:
		_job.poll_slice(slice_ms)
	else:
		_job.poll()
	if _job.error != "":
		_fail(_job.error)
	elif _job.is_done():
		_level_done()


func _start_job() -> void:
	var c: AirWindowCase = _cur_row.case
	_cur_row.case = null
	if c == null:
		_fail("окно вне слоя рельефа")
		return
	var row := _cur_row
	var q := _cur
	var job := AirWindowJob.new()
	job.case = c
	job.mech = true
	job.chunk_ms = chunk_ms
	job.timeout_s = timeout_s
	job.parent = _domain_pd if q == 0 else _pending_parent(q)
	var old: Dictionary = _lv[q]
	job.prev = old.st
	var t0 := Time.get_ticks_usec()
	if _gpu == null:
		_gpu = AirGpu.new()
		if not _gpu.init(job._shaders()):
			var msg := _gpu.error
			_gpu = null
			_fail(msg)
			return
	job.shared_gpu = true
	if not job.start(_gpu):
		_fail(job.error)
		return
	_job = job
	row.t_start = Time.get_ticks_usec()
	row.start_ms = (row.t_start - t0) / 1000.0


func _pending_parent(q: int) -> Dictionary:
	# родитель — уровень q − 1: новый, если он пересчитан в этой очереди, иначе прежний
	if q - 1 >= _lv.size() - _pending.size():
		return _pending_row(q - 1).pd
	return _lv[q - 1].pd


func _level_done() -> void:
	var job := _job
	var row := _cur_row
	var q := _cur
	var r := job.results
	var t_done := Time.get_ticks_usec()
	(
		history
		. append(
			{
				dx = row.dx,
				x0 = row.x0,
				y0 = row.y0,
				reason = _reason,
				iters = [int(r[0].iters), int(r[-1].iters)],
				status = String(r[-1].status),
				warm = not job.prev.is_empty(),
				wall_ms = (Time.get_ticks_usec() - int(row.t_start)) / 1000.0,
				total_ms = (Time.get_ticks_usec() - _t_level) / 1000.0,
				prep_ms = float(row.get("prep_ms", 0.0)),
				gpu_ms = job.gpu_ms_total,
				max_chunk_ms = job.max_chunk_gpu_ms,
				chunks = job.chunks,
				poll_max_ms = job.max_poll_cpu_ms,
			}
		)
	)
	if q < _lv.size() - 1:
		row.pd = job.parent_data()
	row.st = job.window_state()
	_waiting_field = true
	job.field_ready.connect(_on_field.bind(row), CONNECT_ONE_SHOT)
	job.field_async()
	job.release()  # буферы уже прочитаны; сама задача живёт до сигнала (Callable её не держит)
	_field_job = job
	_job = null
	history[-1].finish_ms = (Time.get_ticks_usec() - t_done) / 1000.0
	history[-1].start_ms = float(row.get("start_ms", 0.0))


func _on_field(f: WindField, row: Dictionary) -> void:
	_waiting_field = false
	_field_job = null
	if f == null:
		_fail("поле окна не построено")
		return
	row.field = f
	_cur = -1
	_next()


func _finish_all() -> void:
	var off := _lv.size() - _pending.size()
	for i in _pending.size():
		_lv[off + i] = _pending[i]
	_pending.clear()
	_cur = -1
	levels_changed.emit(levels())
	if _domain_dirty:
		_domain_dirty = false
		_enqueue(0, "область")


func _fail(msg: String) -> void:
	_wait_tasks()
	if _job != null:
		_job.release()
		_job = null
	_queue.clear()
	_pending.clear()
	_cur = -1
	_retry_at = Time.get_ticks_usec() + 10000000
	push_warning("AirClipmap: " + msg)
	failed.emit(msg)
