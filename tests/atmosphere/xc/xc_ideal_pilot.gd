class_name XcIdealPilot
extends BotPilot
## Диагностика «идеальный пилот» (карточка 07, флаг xc_run --ideal): знает оси термиков (НЕ
## FR-22 — только для замера, «берётся» ли термик вообще при правильной технике). Летит к
## ближайшему живому термику впереди, кружит вокруг его оси (та же техника виража, что у BotPilot:
## крен circle_bank_deg, скорость мин. снижения, сдвиг круга с учётом ветра), бросает термик
## после двух кругов подряд без набора или у кромки.

## «Нет термика» (id статичных термиков отрицательные).
const NO_ID := -(1 << 62)

## oracle_fn(pos: Vector3) -> Array[Dictionary] {id, center: Vector2 (ось на высоте pos),
## w: сила × огибающая, м/с, top: верх, м} — живые термики рядом.
var oracle_fn: Callable
## Брать термики не слабее (сила ядра × огибающая), м/с.
var min_w: float = 0.8
## Усреднение скорости оси (снос распадающегося термика, наклон), с.
var axis_vel_tau_s: float = 10.0

var _id: int = NO_ID
var _c: Vector2 = Vector2.ZERO
var _skip: Dictionary = {}
var _query_t: float = 0.0
var _c_prev: Vector2 = Vector2.ZERO
var _pos: Vector2 = Vector2.ZERO


func debug_state() -> String:
	var s := super()
	if _id != NO_ID:
		s += " id=%d dc=%.0f" % [_id, _pos.distance_to(_c)]
	return s


## Вне кружения — свой переход: к лучшему термику (ближе и сильнее), по прилёту к оси — вираж.
func _take_over(t: Telemetry, pos: Vector2, dt: float) -> bool:
	_pos = pos
	if mode == Mode.CIRCLE:
		return false
	mode = Mode.CRUISE
	_query_t -= dt
	if _query_t <= 0.0:
		_query_t = 1.0
		_pick(t, pos)
	var target := _c if _id != NO_ID else _line_target(pos)
	_steer_heading(t, _bearing_deg(pos, target), cruise_bank_max_deg)
	_set_speed(_stf(0.0, t.altitude_msl), t)
	if _id != NO_ID and pos.distance_to(_c) < 40.0:
		_dir = 1.0
		_start_circle(t)
	return true


func _pick(t: Telemetry, pos: Vector2) -> void:
	_id = NO_ID
	var best := INF
	var fwd := (goal - route_start).normalized()
	for c: Dictionary in oracle_fn.call(t.position):
		var id := int(c.id)
		var cc: Vector2 = c.center
		if _skip.has(id) or float(c.w) < min_w or t.altitude_msl > float(c.top) - 150.0:
			continue
		var d := pos.distance_to(cc)
		# Назад по маршруту — только совсем рядом.
		if (cc - pos).dot(fwd) < -300.0 or d > 2500.0:
			continue
		var score := d / clampf(float(c.w), 0.5, 5.0)
		if score < best:
			best = score
			_id = id
			_c = cc


func _start_circle(t: Telemetry) -> void:
	super(t)
	_c_prev = _c


## Ось текущего термика на высоте пилота и её скорость (пропал — последний центр, id = NO_ID).
func _circle_target(t: Telemetry) -> Vector2:
	_query_t -= _dt
	if _query_t <= 0.0:
		_query_t = 0.5
		var found := false
		for c: Dictionary in oracle_fn.call(t.position):
			if int(c.id) == _id:
				_c = c.center
				found = true
				break
		if not found:
			_id = NO_ID
	var dt_c := maxf(_dt, 1.0e-3)
	var vel := ((_c - _c_prev) / dt_c).limit_length(_wind_est.length() + 1.0)
	_c_prev = _c
	_lc_vel += (vel - _lc_vel) * (1.0 - exp(-dt_c / axis_vel_tau_s))
	return _c


## Бросает термик, только если два круга подряд без набора (или термик пропал).
func _circle_weak_exit() -> bool:
	_weak_circles = _weak_circles + 1 if _last_climb < 0.0 else 0
	return _weak_circles >= 2 or _id == NO_ID


func _circle_lost(_t: Telemetry) -> bool:
	return false


func _exit_thermal(t: Telemetry, pos: Vector2) -> void:
	_skip[_id] = true
	super(t, pos)
