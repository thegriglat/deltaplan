class_name Vario
extends RefCounted
## Вычислитель вариометра (FR-23…FR-25), без нод — тестируется headless.
##
## Вход: Telemetry каждый шаг физики (update) или просто вертикальная скорость (update_raw).
## Выход: мгновенный вариометр с инерцией датчика (фильтр 1-го порядка), среднее за окно
## (интегратор, как у реальных приборов: изменение высоты за окно / длительность окна),
## текущее качество за окно, время полёта, расстояние от точки взлёта, след.
## Все параметры — configs/instruments.json (разделы vario и track).

## Мгновенный вариометр после фильтра датчика, м/с.
var vario_ms: float = 0.0
## Среднее за окно average_window_s, м/с.
var average_ms: float = 0.0
## Текущее качество за окно glide_window_s; INF — если снижения нет (набор или горизонт).
var glide_ratio: float = INF
var altitude_msl_m: float = 0.0
var altitude_agl_m: float = 0.0
var airspeed_ms: float = 0.0
var groundspeed_ms: float = 0.0
var heading_deg: float = 0.0
var track_deg: float = 0.0
## Время полёта с момента отрыва, с.
var flight_time_s: float = 0.0
## Полёт начался (был отрыв).
var in_flight: bool = false
## Точка взлёта (мир).
var takeoff_position: Vector3 = Vector3.ZERO
## Текущая позиция (мир).
var position: Vector3 = Vector3.ZERO
## Расстояние по прямой от точки взлёта, м (по горизонтали).
var distance_from_takeoff_m: float = 0.0
## След: горизонтальные точки мира (x, z), не чаще track.sample_interval_s.
var track: PackedVector2Array = PackedVector2Array()

var _tau_s: float = 0.7
var _avg_window_s: float = 25.0
var _glide_window_s: float = 20.0
var _sample_interval_s: float = 0.25
var _glide_min_sink_ms: float = 0.1
var _track_interval_s: float = 2.0
var _track_max: int = 3000
var _takeoff_airspeed_ms: float = 4.0

var _time_s: float = 0.0  # внутреннее время прибора
var _height_int_m: float = 0.0  # интеграл вариометра (высота «по датчику»)
var _dist_int_m: float = 0.0  # пройденный путь по земле
var _has_prev_pos: bool = false
var _prev_pos: Vector3 = Vector3.ZERO
var _next_sample_s: float = 0.0
var _next_track_s: float = 0.0
# История для среднего и качества: время, интеграл высоты, интеграл пути.
var _hist_t: PackedFloat64Array = PackedFloat64Array()
var _hist_h: PackedFloat64Array = PackedFloat64Array()
var _hist_d: PackedFloat64Array = PackedFloat64Array()
var _hist_start: int = 0
var _initialized: bool = false


## cfg — весь configs/instruments.json (нужны разделы vario и track). Пустой — берётся из Config.
func setup(cfg: Dictionary = {}) -> void:
	if cfg.is_empty():
		cfg = Config.get_config("instruments")
	var v: Dictionary = cfg.get("vario", {})
	var tr_cfg: Dictionary = cfg.get("track", {})
	_tau_s = float(v.get("filter_time_constant_s", _tau_s))
	_avg_window_s = float(v.get("average_window_s", _avg_window_s))
	_glide_window_s = float(v.get("glide_window_s", _glide_window_s))
	_sample_interval_s = float(v.get("sample_interval_s", _sample_interval_s))
	_glide_min_sink_ms = float(v.get("glide_min_sink_ms", _glide_min_sink_ms))
	_track_interval_s = float(tr_cfg.get("sample_interval_s", _track_interval_s))
	_track_max = int(tr_cfg.get("max_points", _track_max))
	_takeoff_airspeed_ms = Units.kmh(
		float(tr_cfg.get("takeoff_min_airspeed_kmh", Units.to_kmh(_takeoff_airspeed_ms)))
	)
	reset()


## Сброс (новый полёт).
func reset() -> void:
	vario_ms = 0.0
	average_ms = 0.0
	glide_ratio = INF
	flight_time_s = 0.0
	in_flight = false
	distance_from_takeoff_m = 0.0
	track = PackedVector2Array()
	_time_s = 0.0
	_height_int_m = 0.0
	_dist_int_m = 0.0
	_has_prev_pos = false
	_next_sample_s = 0.0
	_next_track_s = 0.0
	_hist_t = PackedFloat64Array()
	_hist_h = PackedFloat64Array()
	_hist_d = PackedFloat64Array()
	_hist_start = 0
	_initialized = false


func get_filter_time_constant_s() -> float:
	return _tau_s


func get_average_window_s() -> float:
	return _avg_window_s


## Полное обновление от телеметрии, dt — шаг физики, с.
func update(t: Telemetry, dt: float) -> void:
	altitude_msl_m = t.altitude_msl
	altitude_agl_m = t.altitude_agl
	airspeed_ms = t.airspeed
	groundspeed_ms = t.groundspeed
	heading_deg = t.heading_deg
	track_deg = t.track_deg
	position = t.position
	if not in_flight and not t.on_ground and t.airspeed >= _takeoff_airspeed_ms:
		in_flight = true
		takeoff_position = t.position
		flight_time_s = 0.0
		_next_track_s = _time_s
	var step_m := 0.0
	if _has_prev_pos:
		step_m = Vector2(t.position.x - _prev_pos.x, t.position.z - _prev_pos.z).length()
	_prev_pos = t.position
	_has_prev_pos = true
	if in_flight:
		distance_from_takeoff_m = (
			Vector2(t.position.x - takeoff_position.x, t.position.z - takeoff_position.z).length()
		)
	_advance(t.vario, dt, step_m)
	if in_flight:
		if not t.on_ground:
			flight_time_s += dt
		if _time_s >= _next_track_s:
			_next_track_s = _time_s + _track_interval_s
			track.append(Vector2(t.position.x, t.position.z))
			if track.size() > _track_max:
				track = track.slice(track.size() - _track_max)


## Обновление только по вертикальной скорости (для тестов и простых стендов), м/с.
func update_raw(raw_vario_ms: float, dt: float, ground_step_m: float = 0.0) -> void:
	_advance(raw_vario_ms, dt, ground_step_m)


func _advance(raw: float, dt: float, step_m: float) -> void:
	if dt <= 0.0:
		return
	if not _initialized:
		# Первый отсчёт: прибор «включился», фильтр стартует с нуля, как у настоящего.
		_initialized = true
		_push_sample()
	# Точная дискретизация фильтра 1-го порядка: не зависит от шага.
	var alpha := 1.0 - exp(-dt / _tau_s) if _tau_s > 0.0 else 1.0
	vario_ms += (raw - vario_ms) * alpha
	_time_s += dt
	_height_int_m += raw * dt
	_dist_int_m += step_m
	if _time_s + 1e-9 >= _next_sample_s:
		_push_sample()
	_update_averages()


func _push_sample() -> void:
	_hist_t.append(_time_s)
	_hist_h.append(_height_int_m)
	_hist_d.append(_dist_int_m)
	_next_sample_s = _time_s + _sample_interval_s
	# Выкидываем то, что старше самого длинного окна (с запасом в один отсчёт).
	var keep_s := maxf(_avg_window_s, _glide_window_s) + _sample_interval_s
	while _hist_start < _hist_t.size() - 1 and _time_s - _hist_t[_hist_start + 1] >= keep_s:
		_hist_start += 1
	# Изредка уплотняем массивы, чтобы не расти бесконечно.
	if _hist_start > 1024:
		_hist_t = _hist_t.slice(_hist_start)
		_hist_h = _hist_h.slice(_hist_start)
		_hist_d = _hist_d.slice(_hist_start)
		_hist_start = 0


## Индекс самого позднего отсчёта истории не моложе, чем window_s назад (или самый старый).
func _sample_before(window_s: float) -> int:
	var target := _time_s - window_s
	var i := _hist_t.size() - 1
	while i > _hist_start and _hist_t[i] > target + 1e-9:
		i -= 1
	return i


func _update_averages() -> void:
	var i := _sample_before(_avg_window_s)
	var span := _time_s - _hist_t[i]
	if span > 1e-6:
		# Высота в момент ровно (t − окно) — линейная интерполяция между отсчётами.
		var h0 := _hist_h[i]
		var t0 := _hist_t[i]
		var target := _time_s - _avg_window_s
		if t0 < target and i + 1 < _hist_t.size():
			var t1 := _hist_t[i + 1]
			var k := (target - t0) / maxf(t1 - t0, 1e-9)
			h0 = lerpf(h0, _hist_h[i + 1], clampf(k, 0.0, 1.0))
			t0 = target
		average_ms = (_height_int_m - h0) / (_time_s - t0)
	var j := _sample_before(_glide_window_s)
	var gspan := _time_s - _hist_t[j]
	if gspan > 1e-6:
		var sink := -(_height_int_m - _hist_h[j]) / gspan
		if sink >= _glide_min_sink_ms:
			glide_ratio = (_dist_int_m - _hist_d[j]) / (sink * gspan)
		else:
			glide_ratio = INF
