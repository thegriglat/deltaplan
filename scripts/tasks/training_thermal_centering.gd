class_name TrainingThermalCentering
extends TrainingMode
## Центровка в термике: набрать target_gain_m за time_limit_s, держась в подъёме
## (усреднённый вариометр ≥ lift_threshold_ms) не меньше required_lift_time_s.
## Оценка: доля набора (вес score_gain_weight) + доля времени в подъёме (score_lift_weight).

var time_limit_s: float = 600.0
var target_gain_m: float = 300.0
var required_lift_time_s: float = 120.0
var lift_threshold_ms: float = 0.3
var vario_average_s: float = 5.0
var gain_weight: float = 0.7
var lift_weight: float = 0.3

var gain_m: float = 0.0
var time_in_lift_s: float = 0.0
var avg_vario_ms: float = 0.0
var _start_alt: float = 0.0


func get_mode_id() -> String:
	return "thermal_centering"


func _setup_mode() -> void:
	time_limit_s = float(config.get("time_limit_s", time_limit_s))
	target_gain_m = float(config.get("target_gain_m", target_gain_m))
	required_lift_time_s = float(config.get("required_lift_time_s", required_lift_time_s))
	lift_threshold_ms = float(config.get("lift_threshold_ms", lift_threshold_ms))
	vario_average_s = float(config.get("vario_average_s", vario_average_s))
	gain_weight = float(config.get("score_gain_weight", gain_weight))
	lift_weight = float(config.get("score_lift_weight", lift_weight))
	gain_m = 0.0
	time_in_lift_s = 0.0
	avg_vario_ms = 0.0


func _on_takeoff(t: Telemetry) -> void:
	_start_alt = t.altitude_msl


func _step(t: Telemetry, dt: float) -> void:
	# экспоненциальное среднее вариометра за vario_average_s
	var k := 1.0 - exp(-dt / maxf(vario_average_s, 0.001))
	avg_vario_ms += (t.vario - avg_vario_ms) * k
	if avg_vario_ms >= lift_threshold_ms:
		time_in_lift_s += dt
	gain_m = maxf(gain_m, t.altitude_msl - _start_alt)
	if gain_m >= target_gain_m and time_in_lift_s >= required_lift_time_s:
		_finish(true, _score(), "done", _extra())
	elif elapsed_s >= time_limit_s:
		_finish(false, _score(), "time", _extra())


func _on_ground(_t: Telemetry, _landing: Dictionary) -> void:
	_finish(false, _score(), "landed", _extra())


func _score() -> float:
	var g := clampf(gain_m / maxf(target_gain_m, 0.001), 0.0, 1.0)
	var l := clampf(time_in_lift_s / maxf(elapsed_s, 0.001), 0.0, 1.0)
	return 100.0 * (gain_weight * g + lift_weight * l) / maxf(gain_weight + lift_weight, 0.001)


func _extra() -> Dictionary:
	return {"gain_m": gain_m, "time_in_lift_s": time_in_lift_s, "target_gain_m": target_gain_m}
