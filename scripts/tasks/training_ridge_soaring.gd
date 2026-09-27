class_name TrainingRidgeSoaring
extends TrainingMode
## Полёт вдоль склона: продержаться duration_s в «полосе склона» — высота над землёй
## от min_agl_m до max_agl_m и не дальше max_distance_m от места взлёта по горизонтали.
## Вне полосы время не идёт; лимит всей попытки — time_limit_s.
## Оценка: время в полосе / max(время попытки, duration_s).

var duration_s: float = 600.0
var time_limit_s: float = 1200.0
var min_agl_m: float = 15.0
var max_agl_m: float = 300.0
var max_distance_m: float = 3000.0

var time_in_band_s: float = 0.0
var max_height_loss_m: float = 0.0


func get_mode_id() -> String:
	return "ridge_soaring"


func _setup_mode() -> void:
	duration_s = float(config.get("duration_s", duration_s))
	time_limit_s = float(config.get("time_limit_s", time_limit_s))
	min_agl_m = float(config.get("min_agl_m", min_agl_m))
	max_agl_m = float(config.get("max_agl_m", max_agl_m))
	max_distance_m = float(config.get("max_distance_m", max_distance_m))
	time_in_band_s = 0.0
	max_height_loss_m = 0.0


func in_band(t: Telemetry) -> bool:
	var d := Vector2(t.position.x - start_position.x, t.position.z - start_position.z).length()
	return t.altitude_agl >= min_agl_m and t.altitude_agl <= max_agl_m and d <= max_distance_m


func _step(t: Telemetry, dt: float) -> void:
	if in_band(t):
		time_in_band_s += dt
	max_height_loss_m = maxf(max_height_loss_m, start_position.y - t.altitude_msl)
	if time_in_band_s >= duration_s:
		_finish(true, _score(), "done", _extra())
	elif elapsed_s >= time_limit_s:
		_finish(false, _score(), "time", _extra())


func _on_ground(_t: Telemetry, _landing: Dictionary) -> void:
	_finish(false, _score(), "landed", _extra())


func _score() -> float:
	return 100.0 * time_in_band_s / maxf(maxf(elapsed_s, duration_s), 0.001)


func _extra() -> Dictionary:
	return {"time_in_band_s": time_in_band_s, "duration_s": duration_s}
