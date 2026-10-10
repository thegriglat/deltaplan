class_name MotionSource
extends RefCounted
## Источник величин движения (MR-К1): из последовательности (pilot_position, pilot_velocity, pilot_basis, dt)
## считает MotionSample за интервал между вызовами sample(). Среднее по интервалу = разность состояний / время.

## Выше этой удельной величины ускорение — разрыв (телепорт), а не движение.
const TELEPORT_G := 50.0

var _have_start: bool = false
var _v0: Vector3
var _b0: Basis
var _v1: Vector3
var _b1: Basis
var _air_velocity: Vector3
var _on_ground: bool = false
var _span: float = 0.0
var _t: float = 0.0
var _last: MotionSample = null


## Разрыв: старт, перезапуск, телепорт, снимок. Следующий sample() — valid = false.
func reset() -> void:
	_have_start = false
	_span = 0.0
	_t = 0.0
	_last = null


## Шаг физики (dt, с).
func push(tel: Telemetry, dt: float) -> void:
	_v1 = tel.pilot_velocity
	_b1 = tel.pilot_basis.orthonormalized()
	_air_velocity = tel.air_velocity
	_on_ground = tel.on_ground
	if not _have_start:
		_have_start = true
		_v0 = _v1
		_b0 = _b1
		_span = 0.0
		return
	_span += dt
	_t += dt


## Величины за интервал от прошлого sample() до текущего состояния.
func sample() -> MotionSample:
	var s := MotionSample.new()
	if not _have_start:
		return s  # ни одного push после reset(): нули, valid = false
	var u := _b1.y
	var g_vec := Vector3(0.0, -Units.G, 0.0)
	var f := Vector3(0.0, Units.G, 0.0)  # = −g_vec; плюс a ниже
	s.t = _t
	s.on_ground = _on_ground
	s.valid = false
	if _span > 0.0:
		var a := (_v1 - _v0) / _span
		if a.length() > TELEPORT_G * Units.G:
			# разрыв: как reset(), но состояние остаётся стартом следующего интервала
			_v0 = _v1
			_b0 = _b1
			_span = 0.0
		else:
			f = a - g_vec
			var rel := (_b0.transposed() * _b1).orthonormalized()
			var q := rel.get_rotation_quaternion()
			var w := q.get_axis() * (q.get_angle() / _span) if q.get_angle() > 1e-9 else Vector3.ZERO
			s.pitch_rate = rad_to_deg(w.x)
			s.yaw_rate = rad_to_deg(-w.y)
			s.roll_rate = rad_to_deg(-w.z)
			s.valid = true
			_v0 = _v1
			_b0 = _b1
			_span = 0.0
	elif _last != null:
		return _last  # два sample() подряд без push: тот же результат
	var fwd := -_b1.z
	var right := _b1.x
	s.surge = f.dot(fwd)
	s.sway = f.dot(right)
	s.heave = f.dot(u)
	s.pitch = rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	s.yaw = fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	s.roll = rad_to_deg(atan2(-right.y, u.y))
	s.airspeed = _air_velocity.length()
	s.air_lateral = _air_velocity.dot(right)
	_last = s
	return s
