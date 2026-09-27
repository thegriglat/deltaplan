class_name TrainingMode
extends RefCounted
## Общий интерфейс тренировки (FR-36). Логика без нод, тестируется headless.
## Порядок: setup(config) → update(t) каждый шаг физики (+ on_landed(r) из Glider.landed) →
## is_finished() → result(). Тренировка начинается с первого шага в воздухе (phase "flying").
## Результат: {mode, title, success: bool, score: 0..100, reason, …поля режима}.

signal finished(result: Dictionary)

var config: Dictionary = {}
var title: String = ""
## Перевод lat/lon → Vector2(x, z) мира (Terrain.latlon_to_local), для целей из конфига.
var latlon_fn: Callable = Callable()
var elapsed_s: float = 0.0
var airborne: bool = false
var start_position := Vector3.ZERO

var _finished := false
var _result: Dictionary = {}
var _last_time_s := NAN


func setup(cfg: Dictionary) -> void:
	config = cfg
	title = String(cfg.get("title", ""))
	elapsed_s = 0.0
	airborne = false
	_finished = false
	_result = {}
	_last_time_s = NAN
	_setup_mode()


func update(t: Telemetry) -> void:
	if _finished:
		return
	var dt := 0.0 if is_nan(_last_time_s) else maxf(t.time_s - _last_time_s, 0.0)
	_last_time_s = t.time_s
	if not airborne:
		if t.phase != "flying":
			return
		airborne = true
		start_position = t.position
		_on_takeoff(t)
		dt = 0.0
	elapsed_s += dt
	_step(t, dt)
	if not _finished and (t.phase == "landed" or t.phase == "failed"):
		_on_ground(t, {})


## Результат посадки из Glider.landed (LandingJudge: grade, скорости, position).
func on_landed(landing: Dictionary) -> void:
	if airborne and not _finished:
		var t := Telemetry.new()
		t.position = landing.get("position", start_position)
		t.phase = "landed"
		_on_ground(t, landing)


func is_finished() -> bool:
	return _finished


func result() -> Dictionary:
	return _result


## Для наследников: закончить с результатом.
func _finish(success: bool, score: float, reason: String, extra: Dictionary = {}) -> void:
	_finished = true
	_result = {
		"mode": get_mode_id(),
		"title": title,
		"success": success,
		"score": clampf(roundf(score), 0.0, 100.0),
		"reason": reason,
		"elapsed_s": elapsed_s,
	}
	_result.merge(extra)
	finished.emit(_result)


## --- переопределяют наследники ---


func get_mode_id() -> String:
	return ""


func _setup_mode() -> void:
	pass


func _on_takeoff(_t: Telemetry) -> void:
	pass


func _step(_t: Telemetry, _dt: float) -> void:
	pass


## Приземлился до выполнения. landing — результат LandingJudge ({} — неизвестен).
func _on_ground(_t: Telemetry, _landing: Dictionary) -> void:
	_finish(false, 0.0, "landed")
