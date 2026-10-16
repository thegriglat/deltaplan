class_name GoalTracker
extends RefCounted
## Цели в полёте (GL-К3, docs/contracts/goals.md): засчитывает цели GoalSpec по телеметрии и посадке.
## Маршрутные цели (route, triangle, return) идут через TaskTracker; ведущий маршрут отдаётся
## прибору, цилиндрам и итогу. Только логика, без нод: update(t) каждый шаг физики, после планера.

signal goal_done(index: int)
signal goal_failed(index: int)

const ROUTE_KINDS := ["route", "triangle", "return"]  # порядок ведущего маршрута

var _cfg: Dictionary = {}
var _ctx: Dictionary = {}
var _items: Array[Dictionary] = []
## kind -> TaskTracker (только доступные маршрутные цели).
var _trackers: Dictionary = {}
var _start_pos := Vector3.ZERO

var _landed := false
var _airborne := false
var _air_start_s := 0.0
var _last_pos := Vector3.ZERO
var _distance_best_m := 0.0
## Скользящий минимум набора за hold_s: времена, значения (возрастающие), начало окна.
var _win_t: Array[float] = []
var _win_v: Array[float] = []
var _win_head := 0
var _win_first_s := NAN
var _height_best_m := 0.0


func setup(goals: Array, ctx: Dictionary) -> void:
	_cfg = Config.get_config("goals/tracker")
	_ctx = ctx
	_start_pos = ctx.get("start_pos", Vector3.ZERO)
	_items.clear()
	_trackers.clear()
	var route_cfg: Dictionary = _cfg.get("route", {})
	for g: Variant in goals:
		var d: Dictionary = g if g is Dictionary else {}
		var item := {
			"kind": String(d.get("kind", "")),
			"value": float(d.get("value", 0.0)),
			"task_name": "",
			"status": "pending",
			"current": 0.0,
			"best": 0.0,
			"reason": "",
		}
		_build_item(item, d, route_cfg)
		_items.append(item)
	# предел времени без маршрута — недоступен
	for item in _items:
		if item.kind == "speed" and item.status == "pending" and _trackers.is_empty():
			_set_unavailable(item, "нет маршрута для предела времени")
	reset()


## Новая попытка: те же цели и точки, всё «pending».
func reset() -> void:
	_landed = false
	_airborne = false
	_air_start_s = 0.0
	_last_pos = _start_pos
	_distance_best_m = 0.0
	_win_t.clear()
	_win_v.clear()
	_win_head = 0
	_win_first_s = NAN
	_height_best_m = 0.0
	for item in _items:
		if item.status != "unavailable":
			item.status = "pending"
			item.current = 0.0
			item.best = 0.0
			item.reason = ""
	for k: String in _trackers:
		_trackers[k].reset()
	for item in _items:
		if _trackers.has(item.kind):
			item.best = _trackers[item.kind].task_distance_m


func update(t: Telemetry) -> void:
	if _landed:
		return
	_last_pos = t.position
	var flying := t.phase == "flying" or (
		_airborne and not t.on_ground and t.phase != "landed" and t.phase != "failed"
	)
	if flying and not _airborne:
		_airborne = true
		_air_start_s = t.time_s
	var lead_before := _lead_kind()
	for k: String in _trackers:
		_trackers[k].update(t)
	for i in _items.size():
		var item := _items[i]
		if item.status != "pending":
			continue
		match item.kind:
			"height":
				_update_height(i, t, flying)
			"duration":
				if _airborne:
					item.current = t.time_s - _air_start_s
					if item.current >= item.value:
						_finish(i, true)
			"distance":
				if flying:
					item.current = Vector2(t.position.x - _start_pos.x, t.position.z - _start_pos.z).length()
					_distance_best_m = maxf(_distance_best_m, item.current)
					item.best = _distance_best_m
					if _distance_best_m >= item.value:
						_finish(i, true)
			"route", "triangle", "return":
				_update_route(i)
			"speed":
				_update_speed(i, lead_before)


## Посадка (LandingJudge.evaluate): позиция — последняя телеметрия. Оставшиеся цели — «failed».
func on_landed(landing: Dictionary) -> void:
	if _landed:
		return
	_landed = true
	var grade := String(landing.get("grade", "soft"))
	for i in _items.size():
		var item := _items[i]
		if item.status != "pending" or item.kind != "landing":
			continue
		var target: Variant = _ctx.get("landing_target", null)
		if not target is Vector3:
			continue
		var dist := Vector2(_last_pos.x - target.x, _last_pos.z - target.z).length()
		item.current = dist
		item.best = dist
		if dist <= item.value and grade != "crash":
			_finish(i, true)
		else:
			item.reason = "crash" if grade == "crash" else "мимо круга"
			_finish(i, false)
	for i in _items.size():
		if _items[i].status == "pending":
			_items[i].reason = "посадка"
			_finish(i, false)


func items() -> Array:
	var out := []
	for item in _items:
		out.append(item.duplicate())
	return out


## Ведущий маршрут: первый не завершённый в порядке route → triangle → return;
## все завершены — последний из доступных; маршрутов нет — null.
func lead_tracker() -> TaskTracker:
	var k := _lead_kind()
	return _trackers[k] if k != "" else null


func instrument_points() -> Array:
	var lead := lead_tracker()
	return Array(lead.instrument_points()) if lead != null else []


func instrument_active_index() -> int:
	var lead := lead_tracker()
	return lead.instrument_active_index() if lead != null else -1


func instrument_state() -> Dictionary:
	var lead := lead_tracker()
	return lead.get_state() if lead != null else {}


## Пункты ведущего маршрута для цилиндров в мире (без взлёта).
func world_points() -> Array:
	var lead := lead_tracker()
	if lead == null:
		return []
	var out := []
	var task := lead.task
	for i in task.points.size():
		var p := task.points[i]
		if p.kind == TaskPoint.Kind.TAKEOFF:
			continue
		out.append(
			{
				"name": p.name,
				"position": p.position,
				"radius_m": p.radius_m,
				"active": i == lead.next_index and not lead.is_finished(),
			}
		)
	return out


## Итог: done/total считают только доступные цели.
func result() -> Dictionary:
	var done := 0
	var total := 0
	for item in _items:
		if item.status == "unavailable":
			continue
		total += 1
		if item.status == "done":
			done += 1
	var lead := lead_tracker()
	return {
		"goals": items(),
		"done": done,
		"total": total,
		"route": lead.result() if lead != null else {},
	}


# --- построение ---


func _build_item(item: Dictionary, d: Dictionary, route_cfg: Dictionary) -> void:
	var kind: String = item.kind
	match kind:
		"height", "duration", "distance", "speed":
			if not item.value > 0.0:
				_set_unavailable(item, "значение должно быть больше нуля")
		"landing":
			var target: Variant = _ctx.get("landing_target", null)
			if not target is Vector3:
				_set_unavailable(item, "нет круга посадки")
			elif not item.value > 0.0:
				_set_unavailable(item, "значение должно быть больше нуля")
		"return", "triangle":
			if not item.value > 0.0:
				_set_unavailable(item, "значение должно быть больше нуля")
				return
			var td: Dictionary
			if kind == "return":
				td = GoalRouteBuilder.build_return(item.value, _ctx, route_cfg)
			else:
				td = GoalRouteBuilder.build_triangle(item.value, _ctx, route_cfg)
			if td.is_empty():
				_set_unavailable(item, "не помещается в зону с картой")
				return
			_attach(item, Task.from_dict(td, _ctx.get("latlon_fn", Callable()), _ctx.get("height_fn", Callable())))
		"route":
			_attach(item, _load_route(String(d.get("task", ""))))
		_:
			_set_unavailable(item, "неизвестный вид цели")


func _load_route(task_id: String) -> Task:
	var latlon_fn: Callable = _ctx.get("latlon_fn", Callable())
	var height_fn: Callable = _ctx.get("height_fn", Callable())
	if task_id.is_empty():
		return null
	if task_id.begins_with("user://") or task_id.begins_with("res://") or task_id.is_absolute_path():
		return Task.load_file(task_id, latlon_fn, height_fn)
	for e in Task.list_available():
		if e.source == "config" and e.id == task_id:
			return Task.load_config(task_id, latlon_fn, height_fn)
		if e.source == "file" and e.id == task_id:
			return Task.load_file(e.path, latlon_fn, height_fn)
	return null


func _attach(item: Dictionary, task: Task) -> void:
	if task == null:
		_set_unavailable(item, "задание не загружено")
		return
	if not task.errors.is_empty():
		_set_unavailable(item, "; ".join(task.errors))
		return
	if task.is_open_distance() or not task.has_goal():
		_set_unavailable(item, "в задании нет гоула")
		return
	var tr := TaskTracker.new()
	tr.setup(task)
	_trackers[item.kind] = tr
	if item.kind == "route":
		item.task_name = task.name


func _set_unavailable(item: Dictionary, reason: String) -> void:
	item.status = "unavailable"
	item.reason = reason


# --- засчёт ---


func _finish(i: int, ok: bool) -> void:
	_items[i].status = "done" if ok else "failed"
	if ok:
		goal_done.emit(i)
	else:
		goal_failed.emit(i)


func _lead_kind() -> String:
	var last := ""
	for k: String in ROUTE_KINDS:
		if not _trackers.has(k):
			continue
		last = k
		if _trackers[k].phase != TaskTracker.Phase.GOAL:
			return k
	return last


func _update_route(i: int) -> void:
	var item := _items[i]
	var tr: TaskTracker = _trackers[item.kind]
	item.current = float(tr.reached.size())
	item.best = tr.best_remaining_m if not is_inf(tr.best_remaining_m) else tr.task_distance_m
	if tr.phase == TaskTracker.Phase.GOAL:
		item.best = 0.0
		_finish(i, true)
	elif tr.phase == TaskTracker.Phase.FAILED:
		item.reason = tr.fail_reason
		_finish(i, false)


## Предел времени ведущего (на начало шага) маршрута: гоул вовремя — done, иначе failed.
func _update_speed(i: int, lead_kind: String) -> void:
	var item := _items[i]
	if lead_kind == "":
		return
	var tr: TaskTracker = _trackers[lead_kind]
	if is_nan(tr.start_time_s):
		item.current = 0.0
		return
	var has_ess := not is_nan(tr.ess_time_s)
	if has_ess:
		item.current = tr.ess_time_s - tr.start_time_s
	elif tr.phase == TaskTracker.Phase.GOAL:
		item.current = tr.goal_time_s - tr.start_time_s
	else:
		item.current = float(tr.get_state().elapsed_s)
	if item.current > item.value:
		item.reason = "позже предела"
		_finish(i, false)
	elif tr.phase == TaskTracker.Phase.GOAL:
		_finish(i, true)  # гоул взят, время до ESS (нет ESS — до гоула) в пределе


## Набор над стартом, удержанный hold_s: скользящий минимум за окно.
func _update_height(i: int, t: Telemetry, flying: bool) -> void:
	var item := _items[i]
	if not flying:
		_win_t.clear()
		_win_v.clear()
		_win_head = 0
		_win_first_s = NAN
		item.current = 0.0
		return
	var hold := float((_cfg.get("height", {}) as Dictionary).get("hold_s", 10.0))
	var gain := t.position.y - _start_pos.y
	item.current = gain
	if is_nan(_win_first_s):
		_win_first_s = t.time_s
	while _win_v.size() > _win_head and _win_v[_win_v.size() - 1] >= gain:
		_win_v.pop_back()
		_win_t.pop_back()
	_win_t.append(t.time_s)
	_win_v.append(gain)
	while _win_t[_win_head] < t.time_s - hold - 1e-9:
		_win_head += 1
	if _win_head > 256:  # не копить хвост
		_win_t = _win_t.slice(_win_head)
		_win_v = _win_v.slice(_win_head)
		_win_head = 0
	if t.time_s - _win_first_s >= hold - 1e-9:
		_height_best_m = maxf(_height_best_m, _win_v[_win_head])
	item.best = _height_best_m
	if _height_best_m >= item.value:
		_finish(i, true)
