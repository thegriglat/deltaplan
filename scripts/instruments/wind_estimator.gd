class_name WindEstimator
extends RefCounted
## Оценка ветра по сносу (FR-25, страница 3) — только из того, что есть у настоящего прибора:
## путевая скорость (GPS: Telemetry.velocity), курс (компас: heading_deg) и воздушная скорость.
## Истинный ветер из атмосферы не используется.
##
## Метод «по кругам» (как circling wind у XCSoar): за полный вираж векторы путевой скорости
## лежат на окружности радиусом = воздушная скорость, её центр — ветер. Нужен только GPS.
## Метод «по курсу»: ветер = путевая скорость − воздушная скорость вдоль курса; сглаживается.
## Векторы — в плоскости (x — восток, y — юг = мировая z), м/с, «куда дует».

const METHOD_NONE := "none"
const METHOD_CIRCLING := "circling"
const METHOD_HEADING := "heading"

## Оценка ветра «куда дует», м/с (x — восток, y — мировая z, юг).
var wind: Vector2 = Vector2.ZERO
## Каким методом последний раз обновлялась оценка.
var method: String = METHOD_NONE
## Сколько секунд назад обновлялась оценка.
var age_s: float = INF
## Сколько кругов учтено.
var circles: int = 0

var _interval_s: float = 0.5
var _min_turn_dps: float = 6.0
var _max_residual: float = 1.5
var _circle_w: float = 0.6
var _heading_tau_s: float = 40.0
var _heading_w: float = 0.3
var _min_airspeed: float = 4.0
var _stale_s: float = 600.0

var _since_sample_s: float = 0.0
var _samples: PackedVector2Array = PackedVector2Array()  # векторы путевой скорости за текущий круг
var _turned_deg: float = 0.0  # накопленный разворот текущего круга (со знаком)
var _prev_heading: float = NAN
var _heading_est: Vector2 = Vector2.ZERO
var _heading_have: bool = false


## cfg — весь configs/instruments.json (раздел wind); пустой — из Config.
func setup(cfg: Dictionary = {}) -> void:
	if cfg.is_empty():
		cfg = Config.get_config("instruments")
	var w: Dictionary = cfg.get("wind", {})
	_interval_s = float(w.get("sample_interval_s", _interval_s))
	_min_turn_dps = float(w.get("circle_min_turn_rate_dps", _min_turn_dps))
	_max_residual = float(w.get("circle_fit_max_residual_ms", _max_residual))
	_circle_w = float(w.get("circle_weight", _circle_w))
	_heading_tau_s = float(w.get("heading_tau_s", _heading_tau_s))
	_heading_w = float(w.get("heading_weight", _heading_w))
	_min_airspeed = Units.kmh(float(w.get("min_airspeed_kmh", 15.0)))
	_stale_s = float(w.get("stale_s", _stale_s))
	reset()


func reset() -> void:
	wind = Vector2.ZERO
	method = METHOD_NONE
	age_s = INF
	circles = 0
	_samples.clear()
	_turned_deg = 0.0
	_prev_heading = NAN
	_heading_have = false
	_since_sample_s = 0.0


## Есть ли годная (не устаревшая) оценка.
func is_valid() -> bool:
	return method != METHOD_NONE and age_s <= _stale_s


func speed_ms() -> float:
	return wind.length()


## Откуда дует, градусы (0 — с севера, по часовой) — как принято у пилотов и метеорологов.
func direction_from_deg() -> float:
	var from := -wind
	return fposmod(rad_to_deg(atan2(from.x, -from.y)), 360.0)


## Встречная (+) / попутная (−) составляющая для путевого угла track_deg, м/с.
func headwind_ms(track_deg: float) -> float:
	var a := deg_to_rad(track_deg)
	return -wind.dot(Vector2(sin(a), -cos(a)))


func update(t: Telemetry, dt: float) -> void:
	age_s += dt
	if t.on_ground or t.airspeed < _min_airspeed:
		_samples.clear()
		_turned_deg = 0.0
		_prev_heading = NAN
		return
	_since_sample_s += dt
	if _since_sample_s < _interval_s:
		return
	var step_s := _since_sample_s
	_since_sample_s = 0.0
	var vg := Vector2(t.velocity.x, t.velocity.z)
	_heading_method(t, vg, step_s)
	_circling_method(t.heading_deg, vg, step_s)


func _heading_method(t: Telemetry, vg: Vector2, step_s: float) -> void:
	# Горизонтальная воздушная скорость: убираем вертикальную составляющую (по GPS).
	var vz := t.velocity.y
	var va_h := sqrt(maxf(t.airspeed * t.airspeed - vz * vz, 0.0))
	var a := deg_to_rad(t.heading_deg)
	var sample := vg - Vector2(sin(a), -cos(a)) * va_h
	if not _heading_have:
		_heading_est = sample
		_heading_have = true
	else:
		_heading_est = _heading_est.lerp(sample, 1.0 - exp(-step_s / _heading_tau_s))
	if method == METHOD_NONE:
		wind = _heading_est
	else:
		wind = wind.lerp(_heading_est, (1.0 - exp(-step_s / _heading_tau_s)) * _heading_w)
	if method != METHOD_CIRCLING or age_s > _stale_s:
		method = METHOD_HEADING
		age_s = 0.0


func _circling_method(heading_deg: float, vg: Vector2, step_s: float) -> void:
	if is_nan(_prev_heading):
		_prev_heading = heading_deg
		_samples = PackedVector2Array([vg])
		return
	var d := wrapf(heading_deg - _prev_heading, -180.0, 180.0)
	_prev_heading = heading_deg
	# Слишком медленный разворот или смена направления виража — круг начинается заново.
	var slow := absf(d) / step_s < _min_turn_dps
	var reversed := _turned_deg != 0.0 and signf(d) != signf(_turned_deg)
	if slow or reversed:
		_samples = PackedVector2Array([vg])
		_turned_deg = 0.0
		return
	_turned_deg += d
	_samples.append(vg)
	if absf(_turned_deg) < 360.0:
		return
	var fit := fit_circle(_samples)
	if fit.ok and float(fit.residual) <= _max_residual:
		var center: Vector2 = fit.center
		wind = center if method == METHOD_NONE else wind.lerp(center, _circle_w)
		method = METHOD_CIRCLING
		age_s = 0.0
		circles += 1
	_samples = PackedVector2Array([vg])
	_turned_deg = 0.0


## Окружность по точкам методом наименьших квадратов (Каса):
## {ok, center: Vector2, radius, residual — средняя невязка, м/с}.
static func fit_circle(pts: PackedVector2Array) -> Dictionary:
	var n := pts.size()
	if n < 6:
		return {"ok": false}
	# Решаем x² + y² + D·x + E·y + F = 0 нормальными уравнениями 3×3.
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var sx := 0.0
	var sy := 0.0
	var sxz := 0.0
	var syz := 0.0
	var sz := 0.0
	for p in pts:
		var z := p.x * p.x + p.y * p.y
		sxx += p.x * p.x
		sxy += p.x * p.y
		syy += p.y * p.y
		sx += p.x
		sy += p.y
		sxz += p.x * z
		syz += p.y * z
		sz += z
	var m := Basis(Vector3(sxx, sxy, sx), Vector3(sxy, syy, sy), Vector3(sx, sy, float(n)))
	if absf(m.determinant()) < 1e-9:
		return {"ok": false}
	var sol := m.inverse() * Vector3(-sxz, -syz, -sz)
	var center := Vector2(-sol.x * 0.5, -sol.y * 0.5)
	var r2 := center.length_squared() - sol.z
	if r2 <= 0.0:
		return {"ok": false}
	var radius := sqrt(r2)
	var res := 0.0
	for p in pts:
		res += absf(p.distance_to(center) - radius)
	return {"ok": true, "center": center, "radius": radius, "residual": res / float(n)}
