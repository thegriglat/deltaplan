class_name AirGpuJob
extends RefCounted
## Каркас решателя модели воздуха на GPU порциями (AM-02; API в духе WF-02).
## start() — локальный RD, ядра, буферы (_setup); poll() раз в кадр: если порция отправлена —
## sync() (к этому времени GPU уже закончил: порция ≤ бюджета и ≤ доли интервала между poll),
## проверка (_after_sync), затем запись и submit() следующей порции шагов.
## Главный поток не ждёт GPU.
## Размер порции подбирается по GPU-времени прошлой порции (метки времени), бюджет —
## min(chunk_ms, 0,8 · интервал между poll). Ошибки (нет RD, компиляция, таймаут) — signal failed
## и error, не падение.
## Наследник задаёт: _setup() -> bool, _record_step(i), _record_chunk_end(),
## _after_sync() -> bool (true — готово; читать только скаляры, gpu.read_scalar),
## _total_steps() -> int (оценка для прогресса), _first_step_ms() (оценка первой порции).

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
var chunk_log: Array[Vector3] = []  # (шагов, GPU мс, ожидание sync мс)

var _done := false
var _submitted := false
var _chunk_steps := 0
var _ms_per_step := -1.0
var _t_start := 0
var _t_last_poll := 0
var _poll_interval_ms := -1.0
var _stamps := false


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
	if _t_last_poll > 0:
		var dt := (now - _t_last_poll) / 1000.0
		_poll_interval_ms = dt if _poll_interval_ms < 0.0 else lerpf(_poll_interval_ms, dt, 0.3)
	_t_last_poll = now
	if _submitted:
		var t0 := Time.get_ticks_usec()
		gpu.sync()
		var wait := (Time.get_ticks_usec() - t0) / 1000.0
		_submitted = false
		var gpu_ms := _chunk_gpu_ms()
		chunks += 1
		max_chunk_gpu_ms = maxf(max_chunk_gpu_ms, gpu_ms)
		max_sync_wait_ms = maxf(max_sync_wait_ms, wait)
		chunk_log.append(Vector3(_chunk_steps, gpu_ms, wait))
		if gpu_ms > 0.0:
			var per := gpu_ms / _chunk_steps
			_ms_per_step = per if _ms_per_step < 0.0 else maxf(per, 0.7 * _ms_per_step + 0.3 * per)
		steps_done += _chunk_steps
		if _after_sync():
			_done = true
			finished.emit()
			return 1.0
		if error != "":
			_fail(error)
			return progress()
	if (Time.get_ticks_usec() - _t_start) / 1e6 > timeout_s:
		_fail("таймаут расчёта (%.0f с)" % timeout_s)
		return progress()
	_record_chunk()
	return progress()


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
	var b := chunk_ms
	if _poll_interval_ms > 0.0:
		b = minf(b, 0.8 * _poll_interval_ms)
	return maxf(b, 1.0)


func _record_chunk() -> void:
	var per := _ms_per_step if _ms_per_step > 0.0 else _first_step_ms()
	var n := maxi(1, floori(budget_ms() / maxf(per, 1e-3)))
	var total := _total_steps()
	if total > 0:
		n = mini(n, maxi(1, total - steps_done))
	_stamps = true
	gpu.stamp("air_chunk_begin")
	for i in n:
		_record_step(steps_done + i)
	_record_chunk_end()
	gpu.stamp("air_chunk_end")
	gpu.submit()
	_submitted = true
	_chunk_steps = n


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


func _record_step(_i: int) -> void:
	pass


## Запись в конце порции (например, невязка → скаляр для _after_sync).
func _record_chunk_end() -> void:
	pass


func _after_sync() -> bool:
	return true


func _total_steps() -> int:
	return -1


func _first_step_ms() -> float:
	return 5.0
