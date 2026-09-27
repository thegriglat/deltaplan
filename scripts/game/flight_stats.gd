class_name FlightStats
extends RefCounted
## Итоги полёта для экрана после посадки: время, дистанция, высоты.
## Обновляется телеметрией каждый шаг физики. Отдельно от приборов: это «разбор полёта»
## после посадки, в полёте не показывается (FR-21).

var takeoff_position := Vector3.ZERO
var start_position := Vector3.ZERO
var flight_time_s: float = 0.0
## Путь по земле в полёте, м.
var track_length_m: float = 0.0
var max_altitude_msl_m: float = -INF
var max_climb_ms: float = 0.0
var airborne := false
var took_off := false

var _last_pos := Vector3.ZERO


func reset(start: Vector3) -> void:
	start_position = start
	takeoff_position = start
	flight_time_s = 0.0
	track_length_m = 0.0
	max_altitude_msl_m = start.y
	max_climb_ms = 0.0
	airborne = false
	took_off = false
	_last_pos = start


func update(t: Telemetry, dt: float) -> void:
	var flying := t.phase == "flying"
	if flying and not airborne:
		airborne = true
		if not took_off:
			took_off = true
			takeoff_position = t.position
		_last_pos = t.position
	elif not flying:
		airborne = false
	if airborne:
		flight_time_s += dt
		var d := t.position - _last_pos
		track_length_m += Vector2(d.x, d.z).length()
		max_altitude_msl_m = maxf(max_altitude_msl_m, t.altitude_msl)
		max_climb_ms = maxf(max_climb_ms, t.vario)
	_last_pos = t.position


## Расстояние по прямой от точки взлёта до p (по горизонтали), м.
func distance_from_takeoff(p: Vector3) -> float:
	return Vector2(p.x - takeoff_position.x, p.z - takeoff_position.z).length()


## Сводка для экрана итога.
func summary(end_position: Vector3) -> Dictionary:
	return {
		"flight_time_s": flight_time_s,
		"distance_m": distance_from_takeoff(end_position) if took_off else 0.0,
		"track_length_m": track_length_m,
		"max_altitude_msl_m": max_altitude_msl_m,
		"height_gain_m": max_altitude_msl_m - takeoff_position.y if took_off else 0.0,
		"max_climb_ms": max_climb_ms,
		"took_off": took_off,
	}
