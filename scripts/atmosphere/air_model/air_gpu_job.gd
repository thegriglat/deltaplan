class_name AirGpuJob
extends RefCounted
## Каркас решателя модели воздуха на GPU порциями (AM-02; API в духе WF-02).
## start() — локальный RD, ядра, буферы (_setup). poll() раз в кадр: если порция отправлена —
## sync() — только если с submit() прошло не меньше ожидаемого GPU-времени порции (иначе poll
## просто возвращается), так что sync не ждёт; проверка на границе шага
## (_after_sync), затем запись и submit() следующей порции. Главный поток не ждёт GPU.
## Шаг — программа запусков ядер (AirGpu.record, записывается один раз); порция — сколько
## запусков влезает в бюджет по GPU-цене шага из прошлых порций (метки времени): на быстрой
## карте — целые шаги (порция кончается на границе шага), на медленной шаг режется между кадрами
## (доля запусков ≈ доля бюджета). Первая порция — один шаг.
## Бюджет — min(0,8 · chunk_ms, 0,8 · промежуток от конца poll до следующего poll).
## Ошибки (нет RD, компиляция, таймаут, наследник) — signal failed и error, не падение.
## Наследник задаёт: _setup() -> bool; _step_program(i) -> Array (программа шага i);
## _record_check() — запись проверки после шага (например невязка → скаляр);
## _after_sync() -> bool (true — готово; читать только скаляры: gpu.read_scalar);
## _total_steps() -> int (предел шагов и прогресс; −1 — без предела).

signal failed(message: String)
signal finished

## Бюджет GPU-работы одной порции, мс.
var chunk_ms := 30.0
## Предел времени всего расчёта, с (стена).
var timeout_s := 60.0
var gpu: AirGpu
var error := ""
var steps_done := 0
## Статистика порций: число, наибольшее GPU-время, наибольшее ожидание в sync (главный поток), мс.
var chunks := 0
var max_chunk_gpu_ms := 0.0
var max_sync_wait_ms := 0.0
var chunk_log: Array[Vector3] = []  # (запусков, GPU мс, ожидание sync мс)

var _done := false
var _submitted := false
var _prog: Array = []
var _cursor := 0
var _chunk_items := 0
var _chunk_steps := 0
var _chunk_boundary := false
var _ms_per_step := -1.0
var _chunk_whole := false
var _t_submit := 0
var _expected_ms := 0.0
var _t_start := 0
var _t_poll_end := 0
var _gap_ms := -1.0


## Запуск: RD, ядра, данные. false — error/failed (расчёт не начат).
func start(g: AirGpu = null) -> bool:
	gpu = g if g != null else AirGpu.new()
	if gpu.rd == null and not gpu.init():
		return _fail(gpu.error)
	if not _setup():
		return _fail(error if error != "" else "не удалось подготовить расчёт")
	_t_start = Time.get_ticks_usec()
	return true


## Шаг опроса (раз в кадр). Возвращает прогресс 0..1.
func poll() -> float:
	if _done or error != "":
		return progress()
	var now := Time.get_ticks_usec()
	if _t_poll_end > 0:
		var dt := (now - _t_poll_end) / 1000.0
		_gap_ms = dt if _gap_ms < 0.0 else minf(dt, lerpf(_gap_ms, dt, 0.3))
	if _submitted and (now - _t_submit) / 1000.0 < _expected_ms:
		return progress()  # GPU по оценке ещё считает — не ждать, заглянуть в следующем кадре
	if _submitted and not _finish_chunk():
		return progress()
	if (Time.get_ticks_usec() - _t_start) / 1e6 > timeout_s:
		_fail("таймаут расчёта (%.0f с)" % timeout_s)
		return progress()
	_record_chunk()
	_t_poll_end = Time.get_ticks_usec()
	return progress()


## sync() отправленной порции, учёт времени, проверка. false — расчёт окончен (готово или ошибка).
func _finish_chunk() -> bool:
	var t0 := Time.get_ticks_usec()
	gpu.sync()
	var wait := (Time.get_ticks_usec() - t0) / 1000.0
	_submitted = false
	var gpu_ms := _chunk_gpu_ms()
	chunks += 1
	max_chunk_gpu_ms = maxf(max_chunk_gpu_ms, gpu_ms)
	max_sync_wait_ms = maxf(max_sync_wait_ms, wait)
	chunk_log.append(Vector3(_chunk_items, gpu_ms, wait))
	if gpu_ms > 0.0:
		# цена шага: по целым шагам или по доле программы шага (при разрезанном шаге)
		var per := gpu_ms / _chunk_steps if _chunk_whole else gpu_ms * _prog.size() / _chunk_items
		_ms_per_step = per if _ms_per_step < 0.0 else maxf(per, 0.7 * _ms_per_step + 0.3 * per)
	steps_done += _chunk_steps
	if _chunk_boundary and _after_sync():
		_done = true
		finished.emit()
		return false
	if error == "" and _total_steps() > 0 and steps_done >= _total_steps():
		error = "не сошлось за %d шагов" % steps_done
	if error != "":
		_fail(error)
		return false
	return true


func is_done() -> bool:
	return _done


func progress() -> float:
	if _done:
		return 1.0
	var total := _total_steps()
	return clampf(float(steps_done) / total, 0.0, 0.99) if total > 0 else 0.0


## Освободить GPU (можно в любой момент, в т. ч. до окончания).
func release() -> void:
	if gpu != null:
		if _submitted:
			gpu.sync()
			_submitted = false
		gpu.release()
		gpu = null


## Бюджет текущей порции, мс.
func budget_ms() -> float:
	var b := 0.8 * chunk_ms
	# промежуток между кадрами ещё не измерен — осторожно, 8 мс
	b = minf(b, 0.8 * _gap_ms if _gap_ms > 0.0 else 8.0)
	return maxf(b, 1.0)


func _record_chunk() -> void:
	var total := _total_steps()
	var start_cursor := _cursor
	if _cursor >= _prog.size():
		if total > 0 and steps_done >= total:
			_fail("не сошлось за %d шагов" % steps_done)
			return
		_prog = _step_program(steps_done)
		_cursor = 0
		start_cursor = 0
	# первая порция — один шаг; дальше — по цене шага (шаг дороже бюджета — режем по запускам)
	var cap := _prog.size()
	if _ms_per_step > 0.0:
		var steps_fit := budget_ms() / _ms_per_step
		cap = maxi(1, floori(steps_fit * _prog.size()))
		if steps_fit >= 1.0:
			cap = maxi(_prog.size() - _cursor, cap)
	var items := 0
	var steps := 0
	gpu.stamp("air_chunk_begin")
	while items < cap:
		if _cursor >= _prog.size():
			if total > 0 and steps_done + steps >= total:
				break
			var next := _step_program(steps_done + steps)
			# целый шаг не влезает, а порция уже не пуста — закончить на границе шага
			if next.is_empty() or (steps > 0 and items + next.size() > cap):
				break
			_prog = next
			_cursor = 0
		var take := mini(cap - items, _prog.size() - _cursor)
		gpu.run(_prog, _cursor, _cursor + take)
		_cursor += take
		items += take
		if _cursor >= _prog.size():
			steps += 1
	_chunk_boundary = _cursor >= _prog.size() and steps > 0
	if _chunk_boundary:
		_record_check()
	gpu.stamp("air_chunk_end")
	gpu.submit()
	_t_submit = Time.get_ticks_usec()
	_submitted = true
	_expected_ms = _ms_per_step * items / _prog.size() if _ms_per_step > 0.0 else 0.0
	_chunk_items = maxi(items, 1)
	_chunk_steps = steps
	_chunk_whole = start_cursor == 0 and _chunk_boundary


## GPU-время последней порции по меткам (мс); −1 — метки недоступны.
func _chunk_gpu_ms() -> float:
	var rd := gpu.rd
	var cnt := rd.get_captured_timestamps_count()
	var t0 := -1
	var t1 := -1
	for i in cnt:
		var nm := rd.get_captured_timestamp_name(i)
		if nm == "air_chunk_begin":
			t0 = rd.get_captured_timestamp_gpu_time(i)
		elif nm == "air_chunk_end":
			t1 = rd.get_captured_timestamp_gpu_time(i)
	if t0 < 0 or t1 < t0:
		return -1.0
	return (t1 - t0) / 1e6


func _fail(msg: String) -> bool:
	error = msg
	push_warning("AirGpuJob: " + msg)
	failed.emit(msg)
	return false


# ---------------------------------------------------------------- для наследников


func _setup() -> bool:
	return true


## Программа шага i (AirGpu.record; обычно одна и та же, записанная заранее).
func _step_program(_i: int) -> Array:
	return []


## Проверка после шага (записывается в порцию, если та кончилась на границе шага).
func _record_check() -> void:
	pass


func _after_sync() -> bool:
	return true


func _total_steps() -> int:
	return -1

