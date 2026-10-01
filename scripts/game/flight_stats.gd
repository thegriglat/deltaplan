class_name FlightStats
extends RefCounted
## Итоги полёта для экрана после посадки (FR-27b): время, дистанция, высоты, скорость,
## термики, качество. Обновляется телеметрией каждый шаг физики. Отдельно от приборов —
## это «разбор полёта» после посадки, в полёте не показывается (FR-21).

## Порог угловой скорости (°/с путевого угла), с которого считаем полёт кружением (термик).
const CIRCLING_TURN_RATE_DEG_S := 8.0
## Минимальное время в кружении, чтобы засчитать термик в «лучший» (отсекает шум разворотов).
const MIN_THERMAL_S := 3.0

## «Взведение» полёта (FR-27b): случайный подскок/чирк по склону сразу после отрыва —
## не конец полёта. Полёт взведён, когда поднялся ≥ ARM_MIN_HEIGHT_AGL_M над землёй ИЛИ отошёл
## ≥ ARM_MIN_HORIZ_M от отрыва (только геометрия, без порога по времени — К3 v3).
const ARM_MIN_HEIGHT_AGL_M := 10.0
const ARM_MIN_HORIZ_M := 50.0
## Касание земли засчитывается как конец полёта, только если пилот остался на земле
## дольше этого времени (короткий подскок-касание полёт не завершает).
const LANDING_CONFIRM_S := 1.5

var takeoff_position := Vector3.ZERO
var start_position := Vector3.ZERO
var flight_time_s: float = 0.0
## Путь по земле в полёте, м.
var track_length_m: float = 0.0
var max_altitude_msl_m: float = -INF
var max_climb_ms: float = 0.0
## Макс. скорость снижения (модуль, м/с).
var max_sink_ms: float = 0.0
## Лучший термик: средний набор за кружение, м/с.
var best_thermal_climb_ms: float = 0.0
## Суммарное время в кружении (термиках), с.
var circling_time_s: float = 0.0
## Суммарный набор высоты — сумма всех участков подъёма, м (не то же самое, что высота-старт).
var total_climb_m: float = 0.0
var airborne := false
var took_off := false
## Полёт «взведён» — набрал высоту/удаление, случайные касания больше не считаются посадкой.
var armed := false
## Был хотя бы один подскок-касание после взлёта (для статистики, полёт не завершает).
var touched := false

var _last_pos := Vector3.ZERO
var _air_time_total_s: float = 0.0
var _grounded_s: float = 0.0
var _was_on_ground := false
var _finished := false
var _finish_reason := ""
var _last_track_deg: float = 0.0
var _has_last_track := false
var _circling := false
var _thermal_time_s: float = 0.0
var _thermal_alt_start: float = 0.0
var _glide_horiz_m: float = 0.0
var _glide_alt_lost_m: float = 0.0


func reset(start: Vector3) -> void:
	start_position = start
	takeoff_position = start
	flight_time_s = 0.0
	track_length_m = 0.0
	max_altitude_msl_m = start.y
	max_climb_ms = 0.0
	max_sink_ms = 0.0
	best_thermal_climb_ms = 0.0
	circling_time_s = 0.0
	total_climb_m = 0.0
	airborne = false
	took_off = false
	armed = false
	touched = false
	_air_time_total_s = 0.0
	_grounded_s = 0.0
	_was_on_ground = false
	_finished = false
	_finish_reason = ""
	_last_pos = start
	_has_last_track = false
	_circling = false
	_thermal_time_s = 0.0
	_thermal_alt_start = start.y
	_glide_horiz_m = 0.0
	_glide_alt_lost_m = 0.0


func update(t: Telemetry, dt: float) -> void:
	var flying := t.phase == "flying"
	if flying and not airborne:
		airborne = true
		if not took_off:
			took_off = true
			takeoff_position = t.position
		_last_pos = t.position
		_has_last_track = false
	elif not flying:
		airborne = false
	if airborne and dt > 0.0:
		flight_time_s += dt
		var d := t.position - _last_pos
		var horiz := Vector2(d.x, d.z).length()
		track_length_m += horiz
		max_altitude_msl_m = maxf(max_altitude_msl_m, t.altitude_msl)
		max_climb_ms = maxf(max_climb_ms, t.vario)
		max_sink_ms = maxf(max_sink_ms, -t.vario)
		if t.vario > 0.0:
			total_climb_m += t.vario * dt
		var turn_rate := 0.0
		if _has_last_track:
			turn_rate = absf(wrapf(t.track_deg - _last_track_deg, -180.0, 180.0)) / dt
		var was_circling := _circling
		_circling = turn_rate >= CIRCLING_TURN_RATE_DEG_S
		if _circling:
			if not was_circling:
				_thermal_time_s = 0.0
				_thermal_alt_start = t.altitude_msl
			_thermal_time_s += dt
			circling_time_s += dt
		elif was_circling:
			_end_thermal(t.altitude_msl)
		if not _circling and t.vario < 0.0:
			_glide_horiz_m += horiz
			_glide_alt_lost_m += -d.y
		_last_track_deg = t.track_deg
		_has_last_track = true
	_last_pos = t.position
	if took_off:
		_update_finish(t, dt)


## Взведение полёта и «настоящее» окончание (посадка) с отсечкой случайных касаний.
## Считает только после первого отрыва (took_off); до этого «взлёт не удался» решает GroundRun.
func _update_finish(t: Telemetry, dt: float) -> void:
	if _finished:
		return
	if not t.on_ground:
		_air_time_total_s += dt
		_grounded_s = 0.0
		_was_on_ground = false
	else:
		if not _was_on_ground:
			_grounded_s = 0.0
		_grounded_s += dt
		_was_on_ground = true
		if armed:
			touched = true
	if not armed and not t.on_ground:
		var far_enough := distance_from_takeoff(t.position) >= ARM_MIN_HORIZ_M
		if t.altitude_agl >= ARM_MIN_HEIGHT_AGL_M or far_enough:
			armed = true
	if _was_on_ground and _grounded_s >= LANDING_CONFIRM_S:
		_finished = true
		_finish_reason = "landed" if armed else "takeoff_failed"


## true, когда полёт можно считать законченным (посадка удержана, а не подскок).
func is_finished() -> bool:
	return _finished


## "" пока не закончен; иначе "landed" (после взведения) или "takeoff_failed"
## (сел обратно, не успев взвестись — например, слабый отрыв со склона).
func finish_reason() -> String:
	return _finish_reason


func _end_thermal(alt_now: float) -> void:
	if _thermal_time_s >= MIN_THERMAL_S:
		var avg := (alt_now - _thermal_alt_start) / _thermal_time_s
		best_thermal_climb_ms = maxf(best_thermal_climb_ms, avg)
	_thermal_time_s = 0.0


## Расстояние по прямой от точки взлёта до p (по горизонтали), м.
func distance_from_takeoff(p: Vector3) -> float:
	return Vector2(p.x - takeoff_position.x, p.z - takeoff_position.z).length()


## Сводка для экрана итога.
func summary(end_position: Vector3) -> Dictionary:
	if _circling:
		_end_thermal(max_altitude_msl_m if end_position.y < _thermal_alt_start else end_position.y)
	return {
		"flight_time_s": flight_time_s,
		"distance_m": distance_from_takeoff(end_position) if took_off else 0.0,
		"track_length_m": track_length_m,
		"max_altitude_msl_m": max_altitude_msl_m,
		"height_gain_m": max_altitude_msl_m - takeoff_position.y if took_off else 0.0,
		"avg_speed_ms": track_length_m / flight_time_s if flight_time_s > 0.0 else 0.0,
		"max_climb_ms": max_climb_ms,
		"max_sink_ms": max_sink_ms,
		"best_thermal_climb_ms": best_thermal_climb_ms,
		"total_climb_m": total_climb_m,
		"circling_time_s": circling_time_s,
		"circling_fraction": circling_time_s / flight_time_s if flight_time_s > 0.0 else 0.0,
		"avg_glide_ratio": _glide_horiz_m / _glide_alt_lost_m if _glide_alt_lost_m > 0.0 else 0.0,
		"took_off": took_off,
	}
