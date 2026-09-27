class_name TaskTracker
extends RefCounted
## Прохождение задания (FR-35) по телеметрии: старт (с учётом окон), цилиндры (с допуском),
## ESS, гоул; оставшаяся оптимизированная дистанция, требуемое качество до гоула, итог.
## Вызывать update(t) каждый шаг физики. Без нод — тестируется headless.

signal start_taken(time_s: float)
signal turnpoint_reached(index: int, point_name: String, time_s: float)
signal ess_reached(time_s: float)
signal goal_reached(result: Dictionary)
signal task_failed(result: Dictionary)

enum Phase { PRE_START, RACING, ESS, GOAL, FAILED }

const PHASE_NAMES := ["pre_start", "racing", "ess", "goal", "failed"]

var task: Task
var phase: Phase = Phase.PRE_START
## Индекс следующего пункта задания (task.points), который нужно взять.
var next_index: int = 0
## Время взятия пунктов, с: index → time_s.
var reached: Dictionary = {}
## Время старта для подсчёта: окно (race) или своё пересечение (elapsed), с. NAN — не стартовал.
var start_time_s: float = NAN
var ess_time_s: float = NAN
var goal_time_s: float = NAN
## Пересечение старта до открытия окна (не засчитано), с. NAN — не было.
var early_start_time_s: float = NAN
var task_distance_m: float = 0.0
var remaining_distance_m: float = 0.0
var distance_to_next_m: float = 0.0
var required_glide: float = INF
## Лучшая (минимальная) оставшаяся дистанция за полёт, м.
var best_remaining_m: float = INF
var fail_reason: String = ""

var _optimizer: RouteOptimizer
var _route_interval_s: float = 0.5
var _safety_m: float = 150.0
var _route_timer_s: float = 0.0
var _warm := PackedVector2Array()
var _prev_pos := Vector3.ZERO
var _has_prev := false
var _airborne := false
var _last_time_s: float = 0.0
## Открытая дальность: маршрут по взятым пунктам, точка отсчёта свободного участка, лучший отлёт.
var _open_route_m: float = 0.0
var _open_anchor := Vector2.ZERO
var _open_best_m: float = 0.0


func setup(t: Task, settings: Dictionary = {}) -> void:
	if settings.is_empty():
		settings = Config.get_config("tasks/settings")
	task = t
	_optimizer = RouteOptimizer.from_settings(settings)
	_route_interval_s = float(settings.get("route_update_interval_s", _route_interval_s))
	_safety_m = float(settings.get("safety_height_m", _safety_m))
	reset()


## Новая попытка (тот же задание).
func reset() -> void:
	phase = Phase.PRE_START
	next_index = task.first_index()
	reached.clear()
	start_time_s = NAN
	ess_time_s = NAN
	goal_time_s = NAN
	early_start_time_s = NAN
	fail_reason = ""
	_warm = PackedVector2Array()
	_has_prev = false
	_airborne = false
	_open_best_m = 0.0
	_open_route_m = 0.0
	task_distance_m = task.task_distance_m(_optimizer)
	remaining_distance_m = task_distance_m
	best_remaining_m = INF
	required_glide = INF
	_route_timer_s = 0.0
	if task.sss_index < 0:
		phase = Phase.RACING  # без стартового цилиндра старт — взлёт


func update(t: Telemetry) -> void:
	if task == null or phase == Phase.GOAL or phase == Phase.FAILED:
		return
	var dt := t.time_s - _last_time_s if _has_prev else 0.0
	_last_time_s = t.time_s
	if not _has_prev:
		_prev_pos = t.position
		_has_prev = true
	if t.phase == "flying" and not _airborne:
		_airborne = true
		_open_anchor = Vector2(t.position.x, t.position.z)
		if task.sss_index < 0 and is_nan(start_time_s):
			_take_start(t.time_s)
	_check_points(_prev_pos, t.position, t.time_s)
	_prev_pos = t.position
	if phase == Phase.GOAL:
		return
	_route_timer_s -= dt
	if _route_timer_s <= 0.0:
		_update_route(t.position)
	_update_glide(t)
	if _airborne and (t.phase == "landed" or t.phase == "failed"):
		_fail("landed", t.time_s)
	elif t.time_s > task.deadline_s:
		_fail("deadline", t.time_s)


func is_finished() -> bool:
	return phase == Phase.GOAL or phase == Phase.FAILED


func phase_name() -> String:
	return PHASE_NAMES[phase]


func next_point() -> TaskPoint:
	return task.points[next_index] if next_index < task.points.size() else null


## Состояние для прибора и меню.
func get_state() -> Dictionary:
	var np := next_point()
	var gate := task.gate_for(_last_time_s)
	return {
		"phase": phase_name(),
		"next_index": next_index,
		"next_name": np.name if np != null else "",
		"instrument_active": task.instrument_index(mini(next_index, task.points.size() - 1)),
		"start_open": not is_nan(gate),
		"time_to_start_s": maxf(task.first_gate_s() - _last_time_s, 0.0),
		"start_time_s": start_time_s,
		"early_start": not is_nan(early_start_time_s) and is_nan(start_time_s),
		"distance_to_next_m": distance_to_next_m,
		"remaining_distance_m": remaining_distance_m,
		"task_distance_m": task_distance_m,
		"required_glide": required_glide,
		"elapsed_s": _elapsed_s(),
	}


## Итог задания (для экрана итога и рекордов).
func result() -> Dictionary:
	var ss_time := ess_time_s - start_time_s if not is_nan(ess_time_s) else NAN
	return {
		"task_id": task.id,
		"task_name": task.name,
		"status": phase_name() if fail_reason == "" else fail_reason,
		"made_goal": phase == Phase.GOAL,
		"reached_ess": not is_nan(ess_time_s),
		"start_time_s": start_time_s,
		"ess_time_s": ess_time_s,
		"goal_time_s": goal_time_s,
		"speed_section_time_s": ss_time,
		"task_distance_m": task_distance_m,
		"distance_m": distance_flown_m(),
		"turnpoints_reached": reached.size(),
	}


## Пройденная дистанция по правилам: дистанция задания − лучшая оставшаяся, м.
## Для открытой дальности — маршрут по взятым пунктам + лучший отлёт от последнего.
func distance_flown_m() -> float:
	if phase == Phase.GOAL:
		return task_distance_m
	if task.is_open_distance():
		return _open_route_m + _open_best_m
	if is_inf(best_remaining_m):
		return 0.0
	return clampf(task_distance_m - best_remaining_m, 0.0, task_distance_m)


## Пункты и активный индекс для FlightInstrument.set_task(points, active).
func instrument_points() -> Array[Dictionary]:
	return task.instrument_points()


func instrument_active_index() -> int:
	return task.instrument_index(mini(next_index, task.points.size() - 1))


func _elapsed_s() -> float:
	if is_nan(start_time_s):
		return 0.0
	return (ess_time_s if not is_nan(ess_time_s) else _last_time_s) - start_time_s


# --- пункты ---


func _check_points(a: Vector3, b: Vector3, time_s: float) -> void:
	# повторный старт: пока не взят пункт после старта, новое пересечение старта обновляет время
	if phase == Phase.RACING and task.sss_index >= 0 and next_index == task.sss_index + 1:
		if _crossed(task.points[task.sss_index], a, b):
			_try_start(time_s)
	var guard := task.points.size()
	while guard > 0 and next_index < task.points.size() and phase != Phase.GOAL:
		guard -= 1
		var p := task.points[next_index]
		if next_index == task.sss_index:
			if not (_crossed(p, a, b) and _try_start(time_s)):
				return
			_advance(time_s)
		elif _achieved(p, a, b):
			_advance(time_s)
		else:
			return


func _try_start(time_s: float) -> bool:
	var gate := task.gate_for(time_s)
	if is_nan(gate):
		early_start_time_s = time_s
		return false
	_take_start(gate if task.type == Task.TYPE_RACE else time_s)
	return true


func _take_start(score_time_s: float) -> void:
	start_time_s = score_time_s
	early_start_time_s = NAN
	phase = Phase.RACING
	start_taken.emit(score_time_s)


func _advance(time_s: float) -> void:
	var i := next_index
	var p := task.points[i]
	reached[i] = time_s
	next_index += 1
	_warm = PackedVector2Array()
	_route_timer_s = 0.0
	if i != task.sss_index:
		turnpoint_reached.emit(i, p.name, time_s)
	if i == task.ess_index and not is_nan(start_time_s):
		ess_time_s = time_s
		phase = Phase.ESS
		ess_reached.emit(time_s)
	if i == task.goal_index:
		goal_time_s = time_s
		phase = Phase.GOAL
		remaining_distance_m = 0.0
		best_remaining_m = 0.0
		required_glide = 0.0
		goal_reached.emit(result())
	elif task.is_open_distance() and _airborne:
		_open_route_m += _open_anchor.distance_to(p.center_2d())
		_open_anchor = p.center_2d()
		_open_best_m = 0.0


## Пересечение границы старта в нужную сторону на отрезке a→b (с допуском).
func _crossed(p: TaskPoint, a: Vector3, b: Vector3) -> bool:
	var tol := task.tolerance_m(p)
	var da := p.center_distance(a)
	var db := p.center_distance(b)
	if p.exit:
		var inner := p.radius_m - tol
		return da < inner and db >= inner
	var outer := p.radius_m + tol
	return da > outer and _segment_distance(p, a, b) <= outer


## Пункт взят: отрезок a→b касается цилиндра (с допуском) или пересекает линию гоула.
func _achieved(p: TaskPoint, a: Vector3, b: Vector3) -> bool:
	if p.kind == TaskPoint.Kind.GOAL and p.is_line:
		var e := p.line_ends(task.leg_direction(next_index))
		var a2 := Vector2(a.x, a.z)
		var b2 := Vector2(b.x, b.z)
		var hit: Variant = Geometry2D.segment_intersects_segment(a2, b2, e[0], e[1])
		return hit != null and (b2 - a2).dot(task.leg_direction(next_index)) > 0.0
	if p.exit:
		return _crossed(p, a, b)
	return _segment_distance(p, a, b) <= p.radius_m + task.tolerance_m(p)


func _segment_distance(p: TaskPoint, a: Vector3, b: Vector3) -> float:
	var c := p.center_2d()
	var q := Geometry2D.get_closest_point_to_segment(c, Vector2(a.x, a.z), Vector2(b.x, b.z))
	return q.distance_to(c)


func _fail(reason: String, time_s: float) -> void:
	fail_reason = reason
	phase = Phase.FAILED
	_last_time_s = time_s
	task_failed.emit(result())


# --- дистанции ---


func _update_route(pos: Vector3) -> void:
	_route_timer_s = _route_interval_s
	var here := Vector2(pos.x, pos.z)
	if task.is_open_distance():
		if _airborne:
			_open_best_m = maxf(_open_best_m, here.distance_to(_open_anchor))
		remaining_distance_m = 0.0
		return
	var targets := task.route_targets(next_index)
	if targets.is_empty():
		remaining_distance_m = 0.0
		return
	var r := _optimizer.solve(here, targets, _warm)
	_warm = r.points
	remaining_distance_m = float(r.distance_m)
	if _airborne:
		best_remaining_m = minf(best_remaining_m, remaining_distance_m)


func _update_glide(t: Telemetry) -> void:
	var np := next_point()
	distance_to_next_m = np.edge_distance(t.position) if np != null else 0.0
	if not task.has_goal():
		required_glide = INF
		return
	var goal := task.points[task.goal_index]
	var usable := t.altitude_msl - goal.position.y - _safety_m
	required_glide = remaining_distance_m / usable if usable > 0.0 else INF
