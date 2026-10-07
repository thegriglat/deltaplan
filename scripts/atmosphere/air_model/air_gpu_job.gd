class_name AirGpuJob
extends RefCounted
## Каркас решателя модели воздуха на GPU порциями (AM-02; API в духе WF-02).
## start() — локальный RD, ядра, буферы (_setup). poll() раз в кадр: если порция отправлена —
## sync() — только если с submit() прошло не меньше ожидаемого GPU-времени порции (иначе poll
## просто возвращается), так что sync не ждёт; проверка на границе шага
## (_after_sync), затем запись и submit() следующей порции. Главный поток не ждёт GPU.
## Шаг — программа запусков ядер (AirGpu.record, записывается один раз); порция — сколько
## запусков влезает в бюджет по GPU-цене из прошлых порций (метки времени). Цена запуска —
## вес (AirGpu.LAUNCH_WEIGHT + группы × вес ядра), по порциям уточняется «мс на единицу веса».
## На быстрой карте — целые шаги (порция кончается на границе шага), на медленной шаг режется
## между кадрами. Первая порция — first_chunk_weight.
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
## Не больше стольких шагов в порции (0 — сколько влезет): 1 — проверка после каждого шага
## читается до следующего (решатель останавливается ровно на шаге проверки).
var max_steps_per_chunk := 0
## Бюджет порции ограничен промежутком между кадрами (игра идёт: GPU делится с отрисовкой).
## false — только chunk_ms (экран загрузки / меню: порция может идти несколько кадров, poll
## просто ждёт её готовности, главный поток всё равно не ждёт в sync).
var frame_gap_limit := true
## Вес первой порции (цена запусков ещё не измерена), единицы AirGpu.LAUNCH_WEIGHT·…
var first_chunk_weight := 150000.0
## Одна отправка на GPU должна быть короткой: Windows сбрасывает карту (TDR), если она занята
## > 2 с (у пилота RX 5600 XT, в разы слабее RTX 4070 SUPER в счёте). Два предела поверх бюджета:
## вес порции ≤ max_chunk_weight при любой оценке цены (худшая цена веса на RTX 4070 SUPER —
## 7,3e-5 мс, замер 07.10: ≤ 0,18 с там, ≤ 1,8 с на карте в 10 раз слабее) и ≤ guard_ms по худшей
## цене веса, замеченной на этом устройстве (AirGpu.worst_ms_per_w: смесь ядер с самой дорогой
## единицей веса — запас 10× до TDR).
var max_chunk_weight := 2.5e6
var guard_ms := 200.0
var gpu: AirGpu
var error := ""
var steps_done := 0
## Статистика порций: число, наибольшее GPU-время, наибольшее ожидание в sync (главный поток), мс.
var chunks := 0
var max_chunk_gpu_ms := 0.0
var max_sync_wait_ms := 0.0
var chunk_log: Array[Vector3] = []  # (запусков, GPU мс, ожидание sync мс)
## Время главного потока в poll() (запись порций, sync, проверки), мс — сумма и наибольшее.
var poll_cpu_ms := 0.0
## Из них: запись порций (run программ + submit) и ожидание в sync, мс.
var record_cpu_ms := 0.0
var sync_wait_ms := 0.0
var max_poll_cpu_ms := 0.0

var _done := false
var _submitted := false
var _prog: Array = []
var _cursor := 0
var _chunk_items := 0
var _chunk_steps := 0
var _chunk_boundary := false
var _chunk_w := 1.0
var _w_max := 0.0
var _ms_per_w := -1.0
var _prog_w := PackedFloat64Array([0.0])
var _t_submit := 0
var _expected_ms := 0.0
var _t_start := 0
var _t_poll_end := 0
var _gap_ms := -1.0
# замер порций (исследование TDR, docs/research): DP_AIR_CHUNK_LOG=путь.jsonl — строка на порцию;
# DP_AIR_PROBE=1 — по одному запуску в порции (GPU-цена каждого ядра против его веса)
var _log_path := OS.get_environment("DP_AIR_CHUNK_LOG")
var _probe := OS.get_environment("DP_AIR_PROBE") == "1"
var _chunk_first := 0


## Запуск: RD, ядра, данные. false — error/failed (расчёт не начат).
func start(g: AirGpu = null) -> bool:
	gpu = g if g != null else AirGpu.new()
	if gpu.rd == null and not gpu.init(_shaders()):
		return _fail(gpu.error)
	if not _setup():
		return _fail(error if error != "" else "не удалось подготовить расчёт")
	_t_start = Time.get_ticks_usec()
	return true


## Шаг опроса (раз в кадр). Возвращает прогресс 0..1.
func poll() -> float:
	if _done or error != "":
		return progress()
	var t_in := Time.get_ticks_usec()
	var p := _poll()
	var dt := (Time.get_ticks_usec() - t_in) / 1000.0
	poll_cpu_ms += dt
	max_poll_cpu_ms = maxf(max_poll_cpu_ms, dt)
	return p


func _poll() -> float:
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
	sync_wait_ms += wait
	_submitted = false
	var gpu_ms := _chunk_gpu_ms()
	chunks += 1
	max_chunk_gpu_ms = maxf(max_chunk_gpu_ms, gpu_ms)
	max_sync_wait_ms = maxf(max_sync_wait_ms, wait)
	chunk_log.append(Vector3(_chunk_items, gpu_ms, wait))
	if _log_path != "":
		_log_chunk(gpu_ms)
	if gpu_ms > 0.0:
		# цена единицы веса запусков (с запасом вверх: рост — сразу, спад — плавно)
		var per := gpu_ms / _chunk_w
		_ms_per_w = per if _ms_per_w < 0.0 else maxf(per, 0.7 * _ms_per_w + 0.3 * per)
		# худшая цена — по порциям не меньше WORST_MIN_W (в мелких цену задаёт сам запуск)
		if _chunk_w >= AirGpu.WORST_MIN_W:
			gpu.worst_ms_per_w = maxf(gpu.worst_ms_per_w, per)
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


## Экран загрузки / меню: за кадр — несколько порций подряд (sync + следующая) в пределах
## slice_ms главного потока; последняя порция идёт на GPU, пока рисуется кадр. GPU почти не
## простаивает, интерфейс обновляется раз в ~slice_ms. RD локального устройства в Godot 4.7 —
## только из потока отрисовки (из рабочего потока нельзя), поэтому так, а не в потоке.
func poll_slice(slice_ms: float) -> float:
	if _done or error != "":
		return progress()
	frame_gap_limit = false
	var t_in := Time.get_ticks_usec()
	while not _done and error == "":
		if _submitted and not _finish_chunk():
			break
		if (Time.get_ticks_usec() - _t_start) / 1e6 > timeout_s:
			_fail("таймаут расчёта (%.0f с)" % timeout_s)
			break
		_record_chunk()
		if (Time.get_ticks_usec() - t_in) / 1000.0 + 0.5 * _expected_ms >= slice_ms:
			break
	var dt := (Time.get_ticks_usec() - t_in) / 1000.0
	poll_cpu_ms += dt
	max_poll_cpu_ms = maxf(max_poll_cpu_ms, dt)
	return progress()


## Весь расчёт подряд (инструменты без кадров). true — готово.
func run_blocking() -> bool:
	while not _done and error == "":
		poll_slice(1e9)
	return _done


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
	if frame_gap_limit or _ms_per_w < 0.0:
		b = minf(b, 0.8 * _gap_ms if _gap_ms > 0.0 else 8.0)
	return maxf(b, 1.0)


func _record_chunk() -> void:
	var t_rec := Time.get_ticks_usec()
	_record_chunk_inner()
	record_cpu_ms += (Time.get_ticks_usec() - t_rec) / 1000.0


func _record_chunk_inner() -> void:
	var total := _total_steps()
	if _cursor >= _prog.size():
		if total > 0 and steps_done >= total:
			_fail("не сошлось за %d шагов" % steps_done)
			return
		_set_prog(_step_program(steps_done))
	# цена — в весах запусков (AirGpu.LAUNCH_WEIGHT): бюджет / (мс на единицу веса); пока цена
	# не измерена — first_chunk_weight
	var cap := first_chunk_weight
	if _ms_per_w > 0.0:
		# цена ещё уточняется по первым порциям — рост не больше чем вдвое за порцию
		cap = minf(budget_ms() / _ms_per_w, 2.0 * _w_max)
	cap = minf(cap, max_chunk_weight)
	if gpu.worst_ms_per_w > 0.0:
		cap = minf(cap, guard_ms / gpu.worst_ms_per_w)
	if _probe:
		cap = 0.0
	_chunk_first = _cursor
	var items := 0
	var steps := 0
	var wsum := 0.0
	gpu.stamp("air_chunk_begin")
	while true:
		if _cursor >= _prog.size():
			if total > 0 and steps_done + steps >= total:
				break
			if max_steps_per_chunk > 0 and steps >= max_steps_per_chunk:
				break
			var next := _step_program(steps_done + steps)
			# следующий шаг целиком не влезает, а порция не пуста — закончить на границе шага
			if next.is_empty() or wsum + _program_weight(next) > cap:
				break
			_set_prog(next)
		var take := 0
		var wt := 0.0
		while _cursor + take < _prog.size():
			var w := _prog_w[_cursor + take + 1] - _prog_w[_cursor + take]
			if items + take > 0 and wsum + wt + w > cap:
				break
			wt += w
			take += 1
		if take == 0:
			break
		gpu.run(_prog, _cursor, _cursor + take)
		wsum += wt
		_cursor += take
		items += take
		if _cursor < _prog.size():
			break
		steps += 1
	_chunk_boundary = _cursor >= _prog.size() and steps > 0
	if _chunk_boundary:
		_record_check()
	gpu.stamp("air_chunk_end")
	gpu.submit()
	_t_submit = Time.get_ticks_usec()
	_submitted = true
	_expected_ms = _ms_per_w * wsum if _ms_per_w > 0.0 else 0.0
	_chunk_items = maxi(items, 1)
	_chunk_w = maxf(wsum, 1.0)
	_w_max = maxf(_w_max, wsum)
	_chunk_steps = steps


func _log_chunk(gpu_ms: float) -> void:
	var row := {
		job = get_script().get_global_name(), items = _chunk_items, w = _chunk_w, gpu_ms = gpu_ms,
		steps = _chunk_steps, ms_per_w = _ms_per_w,
	}
	if _probe and _chunk_items == 1 and _chunk_first < _prog.size():
		var it: Array = _prog[_chunk_first]
		for key: String in gpu._pipe:
			if gpu._pipe[key] == it[0]:
				row.kernel = key
		row.groups = int(it[3]) * int(it[4])
		row.pc = Array((it[2] as PackedByteArray).slice(0, 32).to_int32_array())
	var f := FileAccess.open(_log_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_log_path, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(JSON.stringify(row))


## Цена программы (сумма весов запусков, AirGpu.LAUNCH_WEIGHT).
static func _program_weight(program: Array) -> float:
	var s := 0.0
	for it: Array in program:
		s += float(it[5]) if it.size() > 5 else 1.0
	return s


func _set_prog(prog: Array) -> void:
	_prog = prog
	_cursor = 0
	_prog_w = PackedFloat64Array()
	_prog_w.resize(prog.size() + 1)
	var s := 0.0
	for i in prog.size():
		_prog_w[i] = s
		s += float(prog[i][5]) if prog[i].size() > 5 else 1.0
	_prog_w[prog.size()] = s


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


## Ядра, которые нужны наследнику (AirGpu.init).
func _shaders() -> Array:
	return AirGpu.SHADERS


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

