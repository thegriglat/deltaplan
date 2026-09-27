class_name ThermalAssistant
extends RefCounted
## Помощник центровки (страница 5, FR-25) — как thermal assistant у XCSoar.
## Только данные прибора: отфильтрованный вариометр своего датчика и курс (компас).
## Атмосфера не читается.
##
## В установившемся вираже (в системе воздуха) крыло находится относительно центра круга
## по пеленгу heading − 90° при правом вираже и heading + 90° при левом. Каждый замер вариометра
## относится к точке круга, где крыло было τ секунд назад (задержка датчика). Замеры копятся
## по секторам за последние 1–2 круга. Выход — подъём по секторам, среднее за круг и
## вектор асимметрии: в какую сторону от центра круга подъём сильнее (туда сдвигать круг).
## Снос ветром не мешает: термик сносится вместе с воздухом, а курс — величина в системе воздуха.

## Идёт кружение (помощник активен).
var circling: bool = false
## Направление виража: +1 — вправо, −1 — влево, 0 — прямо.
var turn_dir: int = 0
## Среднее за учтённые круги, м/с.
var circle_average_ms: float = 0.0
## Средний вариометр по секторам (сектор k — пеленг от центра круга k·360/N°), NAN — нет замеров.
var sectors: PackedFloat32Array = PackedFloat32Array()
## Пеленг от центра круга туда, где подъём сильнее, градусы (0 — север).
var strong_bearing_deg: float = 0.0
## Асимметрия подъёма (первая гармоника по кругу), м/с: насколько сильная сторона сильнее средней.
var asymmetry_ms: float = 0.0

var _min_rate: float = 8.0
var _rate_tau: float = 2.0
var _confirm_s: float = 4.0
var _window_circles: float = 1.5
var _max_window_s: float = 60.0
var _lag_s: float = 0.7
var _n: int = 36
var _interval_s: float = 0.25

var _time: float = 0.0
var _rate_dps: float = 0.0
var _prev_heading: float = NAN
var _unwrapped: float = 0.0
var _circling_for_s: float = 0.0
var _since_sample: float = 0.0
# История курса для учёта задержки: время, развёрнутый курс.
var _h_t: PackedFloat64Array = PackedFloat64Array()
var _h_v: PackedFloat64Array = PackedFloat64Array()
# Замеры: время, пеленг от центра круга (°), вариометр.
var _s_t: PackedFloat64Array = PackedFloat64Array()
var _s_b: PackedFloat32Array = PackedFloat32Array()
var _s_v: PackedFloat32Array = PackedFloat32Array()


## cfg — весь instruments.json (раздел thermal_assistant); vario_tau_s — постоянная времени
## фильтра вариометра (для sensor_lag_s = −1).
func setup(cfg: Dictionary = {}, vario_tau_s: float = 0.7) -> void:
	if cfg.is_empty():
		cfg = Config.get_config("instruments")
	var c: Dictionary = cfg.get("thermal_assistant", {})
	_min_rate = float(c.get("min_turn_rate_dps", _min_rate))
	_rate_tau = float(c.get("turn_rate_smoothing_s", _rate_tau))
	_confirm_s = float(c.get("circling_confirm_s", _confirm_s))
	_window_circles = float(c.get("window_circles", _window_circles))
	_max_window_s = float(c.get("max_window_s", _max_window_s))
	var lag := float(c.get("sensor_lag_s", -1.0))
	_lag_s = vario_tau_s if lag < 0.0 else lag
	_n = maxi(int(c.get("sectors", _n)), 4)
	_interval_s = float(c.get("sample_interval_s", _interval_s))
	reset()


func reset() -> void:
	circling = false
	turn_dir = 0
	circle_average_ms = 0.0
	asymmetry_ms = 0.0
	sectors = PackedFloat32Array()
	sectors.resize(_n)
	sectors.fill(NAN)
	_time = 0.0
	_rate_dps = 0.0
	_prev_heading = NAN
	_unwrapped = 0.0
	_circling_for_s = 0.0
	_since_sample = 0.0
	_h_t.clear()
	_h_v.clear()
	_clear_samples()


func get_sensor_lag_s() -> float:
	return _lag_s


## heading_deg — курс (компас), vario_ms — ОТФИЛЬТРОВАННЫЙ вариометр прибора, dt — шаг, с.
func update(heading_deg: float, vario_ms: float, dt: float, on_ground: bool = false) -> void:
	if dt <= 0.0:
		return
	_time += dt
	if on_ground:
		reset()
		return
	if is_nan(_prev_heading):
		_prev_heading = heading_deg
		_unwrapped = heading_deg
	var d := wrapf(heading_deg - _prev_heading, -180.0, 180.0)
	_prev_heading = heading_deg
	_unwrapped += d
	_rate_dps = lerpf(_rate_dps, d / dt, 1.0 - exp(-dt / _rate_tau))
	_h_t.append(_time)
	_h_v.append(_unwrapped)
	_trim_history()
	var turning := absf(_rate_dps) >= _min_rate
	var dir := int(signf(_rate_dps)) if turning else 0
	if not turning or (turn_dir != 0 and dir != turn_dir):
		# Прямая или смена направления виража — всё заново.
		_circling_for_s = 0.0
		if circling or not _s_t.is_empty():
			_clear_samples()
		circling = false
		turn_dir = dir
		return
	turn_dir = dir
	_circling_for_s += dt
	_since_sample += dt
	if _since_sample >= _interval_s:
		_since_sample = 0.0
		# Замер относится к положению крыла τ секунд назад.
		var h_then := _heading_at(_time - _lag_s)
		var bearing := fposmod(h_then - 90.0 * float(turn_dir), 360.0)
		_s_t.append(_time)
		_s_b.append(bearing)
		_s_v.append(vario_ms)
		_trim_samples()
	circling = _circling_for_s >= _confirm_s
	_recompute()


## Пеленг сильного подъёма относительно текущего курса, градусы (0 — впереди, 90 — справа).
func strong_relative_deg(current_heading_deg: float) -> float:
	return wrapf(strong_bearing_deg - current_heading_deg, -180.0, 180.0)


func _heading_at(t: float) -> float:
	var n := _h_t.size()
	if n == 0:
		return _unwrapped
	if t <= _h_t[0]:
		return _h_v[0]
	var i := n - 1
	while i > 0 and _h_t[i - 1] > t:
		i -= 1
	if i == 0:
		return _h_v[0]
	var k := (t - _h_t[i - 1]) / maxf(_h_t[i] - _h_t[i - 1], 1e-9)
	return lerpf(_h_v[i - 1], _h_v[i], clampf(k, 0.0, 1.0))


func _trim_history() -> void:
	var keep := _lag_s + 2.0
	var cut := 0
	while cut < _h_t.size() - 2 and _time - _h_t[cut + 1] > keep:
		cut += 1
	if cut > 256:
		_h_t = _h_t.slice(cut)
		_h_v = _h_v.slice(cut)


func _window_s() -> float:
	var period := 360.0 / maxf(absf(_rate_dps), 1.0)
	return minf(period * _window_circles, _max_window_s)


func _trim_samples() -> void:
	var w := _window_s()
	var cut := 0
	while cut < _s_t.size() and _time - _s_t[cut] > w:
		cut += 1
	if cut > 0:
		_s_t = _s_t.slice(cut)
		_s_b = _s_b.slice(cut)
		_s_v = _s_v.slice(cut)


func _clear_samples() -> void:
	_s_t.clear()
	_s_b.clear()
	_s_v.clear()
	sectors.fill(NAN)
	asymmetry_ms = 0.0
	circle_average_ms = 0.0


func _recompute() -> void:
	var sum := PackedFloat32Array()
	var cnt := PackedInt32Array()
	sum.resize(_n)
	cnt.resize(_n)
	var total := 0.0
	for i in _s_t.size():
		var k := int(floor(_s_b[i] / 360.0 * float(_n))) % _n
		sum[k] += _s_v[i]
		cnt[k] += 1
		total += _s_v[i]
	if _s_t.is_empty():
		return
	circle_average_ms = total / float(_s_t.size())
	# Первая гармоника по секторам (каждый сектор — с равным весом, чтобы неравномерная
	# скорость разворота не смещала оценку).
	var vec := Vector2.ZERO
	var used := 0
	for k in _n:
		if cnt[k] == 0:
			sectors[k] = NAN
			continue
		var avg := sum[k] / float(cnt[k])
		sectors[k] = avg
		var a := deg_to_rad((float(k) + 0.5) * 360.0 / float(_n))
		vec += Vector2(sin(a), -cos(a)) * (avg - circle_average_ms)
		used += 1
	if used == 0:
		return
	vec *= 2.0 / float(used)
	asymmetry_ms = vec.length()
	strong_bearing_deg = fposmod(rad_to_deg(atan2(vec.x, -vec.y)), 360.0)
