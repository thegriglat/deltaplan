class_name GoalsTab
extends VBoxContainer
## Вкладка «Цели» окна «Полёт…» (GL-3, контракты GL-К1/К2/К5): 8 целей галочками с уровнем
## и числом (GoalEstimator), выбор маршрута, «след прошлой попытки». Выбор уходит в
## FlightSettings.goals / show_last_track через collect().
##
## Окно задаёт context_fn — Callable без аргументов, возвращающий текущий FlightSettings (место,
## погода, время). Числа пересчитываются при смене контекста (mark_dirty), пока пилот не правил
## число руками (уровень «своя»). Недоступная строка — серая и без галочки.

## Единицы показа: множитель «значение в К1 (СИ) → число в окне», шаг, максимум.
const UNITS := {
	"height": {"k": 1.0, "step": 10.0, "max": 5000.0, "unit": "unit_m"},
	"duration": {"k": 1.0 / 60.0, "step": 5.0, "max": 600.0, "unit": "unit_min"},
	"distance": {"k": 0.001, "step": 1.0, "max": 1000.0, "unit": "unit_km"},
	"return": {"k": 0.001, "step": 1.0, "max": 500.0, "unit": "unit_km"},
	"triangle": {"k": 0.001, "step": 1.0, "max": 1000.0, "unit": "unit_km"},
	"speed": {"k": 1.0 / 60.0, "step": 1.0, "max": 1200.0, "unit": "unit_min"},
	"landing": {"k": 1.0, "step": 5.0, "max": 500.0, "unit": "unit_m"},
}

const KIND_KEYS := {
	"height": "goals_kind_height",
	"duration": "goals_kind_duration",
	"distance": "goals_kind_distance",
	"return": "goals_kind_return",
	"triangle": "goals_kind_triangle",
	"route": "goals_kind_route",
	"speed": "goals_kind_speed",
	"landing": "goals_kind_landing",
}
const LEVEL_KEYS := {
	"easy": "goals_level_easy",
	"medium": "goals_level_medium",
	"hard": "goals_level_hard",
	"custom": "goals_level_custom",
}

var context_fn: Callable  ## () -> FlightSettings (без обязательных целей)

var _rows: Dictionary = {}  ## kind → {check, level, spin, route, row}
var _last_track: CheckBox
var _dirty := true
var _refreshing := false
var _loading := false
var _track_paths := PackedStringArray()
var _routes: Array = []  ## [{id, task, name}] для места, GoalsTab._load_routes
var _route_len: Dictionary = {}  ## task → длина, м (кэш)


## Вкладку не показывать в сетевой зоне: цели там не работают.
static func net_blocked() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var z: Node = tree.root.get_node_or_null("NetZone") if tree != null else null
	return z != null and bool(z.get("in_zone"))


func _init() -> void:
	add_theme_constant_override("separation", 8)
	visibility_changed.connect(
		func() -> void:
			if is_visible_in_tree() and _dirty:
				refresh()
	)
	for kind: String in GoalSpec.KINDS:
		_build_row(kind)
	UiKit.separator(self)
	_last_track = CheckBox.new()
	_last_track.text = tr("goals_last_track")
	add_child(_last_track)


func _build_row(kind: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var check := CheckBox.new()
	check.text = tr(KIND_KEYS[kind])
	check.custom_minimum_size.x = 190
	row.add_child(check)
	var r := {"check": check, "row": row}
	var level := OptionButton.new()
	for lv: String in GoalSpec.LEVELS:
		level.add_item(tr(LEVEL_KEYS[lv]))
	level.select(1)
	row.add_child(level)
	r["level"] = level
	if kind == "route":
		var route := OptionButton.new()
		route.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		route.clip_text = true
		row.add_child(route)
		r["route"] = route
		level.visible = false
		route.item_selected.connect(func(_i: int) -> void: _changed())
	else:
		var spin := SpinBox.new()
		var u: Dictionary = UNITS[kind]
		spin.min_value = float(u.step)
		spin.max_value = float(u.max)
		spin.step = float(u.step)
		spin.suffix = " " + tr(String(u.unit))
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spin)
		r["spin"] = spin
		spin.value_changed.connect(_on_spin.bind(kind))
		level.item_selected.connect(_on_level.bind(kind))
	check.toggled.connect(func(_on: bool) -> void: _changed())
	_rows[kind] = r


func _on_spin(_v: float, kind: String) -> void:
	if _loading:
		return
	(_rows[kind].level as OptionButton).select(GoalSpec.LEVELS.find("custom"))
	_changed()


func _on_level(_i: int, _kind: String) -> void:
	if not _loading:
		_changed()


## Изменение внутри вкладки: пересчёт зависимых (скорость от маршрута, доступность).
func _changed() -> void:
	if not _loading:
		refresh()


## Контекст (погода, время, место) поменялся: пересчитать числа, когда вкладка видна.
func mark_dirty() -> void:
	_dirty = true
	if is_visible_in_tree():
		refresh()


## Восстановить выбор из настроек (последний выбор, избранное) и пересчитать.
func load_settings(s: FlightSettings) -> void:
	_loading = true
	for kind: String in _rows:
		(_rows[kind].check as CheckBox).button_pressed = false
	_track_paths = s.track_paths.duplicate()
	_last_track.button_pressed = s.show_last_track
	_load_routes(s)
	for g: Variant in s.goals:
		if not g is Dictionary or not _rows.has(String(g.get("kind", ""))):
			continue
		var kind := String(g.kind)
		var r: Dictionary = _rows[kind]
		(r.check as CheckBox).button_pressed = true
		var li := GoalSpec.LEVELS.find(String(g.get("level", "medium")))
		(r.level as OptionButton).select(maxi(li, 0))
		if r.has("spin"):
			(r.spin as SpinBox).value = float(g.get("value", 0.0)) * float(UNITS[kind].k)
		else:
			var idx := _route_index(String(g.get("task", "")))
			if idx >= 0:
				(r.route as OptionButton).select(idx)
			else:
				(r.check as CheckBox).button_pressed = false
	_loading = false
	_dirty = true
	_refresh_from(s)


func refresh() -> void:
	if _refreshing:
		return
	var s: FlightSettings = null
	if context_fn.is_valid():
		_refreshing = true
		s = context_fn.call()
		_refreshing = false
	if s == null:
		return
	_load_routes(s)
	_refresh_from(s)


func _refresh_from(s: FlightSettings) -> void:
	_refreshing = true
	_dirty = false
	_loading = true
	var wx := GoalEstimator.weather_for(s)
	_update_availability(s)
	# длина маршрута: маршрут → треугольник → возврат
	var route_m := 0.0
	var chosen := _chosen_task()
	if _checked("route") and chosen != "":
		route_m = _route_length(chosen, s)
	for kind: String in GoalSpec.KINDS:
		if kind == "route" or kind == "speed":
			continue
		_suggest(kind, wx, 0.0)
	if route_m <= 0.0 and _checked("triangle"):
		route_m = _value_m("triangle")
	if route_m <= 0.0 and _checked("return"):
		route_m = 2.0 * _value_m("return")
	_suggest("speed", wx, route_m)
	var has_track := LastTrackStore.load(LastTrackStore.place_key(s)) != null
	_last_track.disabled = not has_track
	if not has_track:
		_last_track.button_pressed = false
	_loading = false
	_refreshing = false


func _suggest(kind: String, wx: Dictionary, route_m: float) -> void:
	var r: Dictionary = _rows[kind]
	var lv: String = GoalSpec.LEVELS[(r.level as OptionButton).selected]
	if lv == "custom":
		return
	var v := GoalEstimator.suggest(kind, lv, wx, route_m)
	var u: Dictionary = UNITS[kind]
	(r.spin as SpinBox).value = maxf(v * float(u.k), float(u.step))


func _checked(kind: String) -> bool:
	var r: Dictionary = _rows[kind]
	return (r.check as CheckBox).button_pressed and not (r.check as CheckBox).disabled


func _value_m(kind: String) -> float:
	return (_rows[kind].spin as SpinBox).value / float(UNITS[kind].k)


## Серая строка — цель недоступна здесь (без объяснений).
func _update_availability(s: FlightSettings) -> void:
	var has_route := not _routes.is_empty()
	_set_available("route", has_route)
	_set_available("landing", _has_landing(s))
	var route_like := _checked("route") or _checked("triangle") or _checked("return")
	_set_available("speed", route_like)


func _set_available(kind: String, ok: bool) -> void:
	var r: Dictionary = _rows[kind]
	var check: CheckBox = r.check
	check.disabled = not ok
	if not ok:
		check.button_pressed = false
	for k: String in ["level", "spin", "route"]:
		if r.has(k):
			(r[k] as Control).modulate = Color.WHITE if ok else Color(1, 1, 1, 0.4)
			if r[k] is OptionButton:
				(r[k] as OptionButton).disabled = not ok
			elif r[k] is SpinBox:
				(r[k] as SpinBox).editable = ok
	(r.row as Control).modulate = Color.WHITE if ok else Color(1, 1, 1, 0.55)


static func _has_landing(s: FlightSettings) -> bool:
	if s.has_pick() or not Locations.is_builtin(s.location_id):
		return false
	var sites: Variant = Locations.config(s.location_id).get("landing_sites")
	if sites is Array and not (sites as Array).is_empty():
		return true
	var t: Dictionary = Config.get_config("tasks/training_spot_landing")
	return (t.get("targets", {}) as Dictionary).has(s.location_id)


# ------------------------------------------------------------ маршруты


func _load_routes(s: FlightSettings) -> void:
	var keep := _chosen_task()
	_routes = []
	if not s.has_pick():
		for e: Dictionary in Task.list_available():
			var key := String(e.id) if e.source == "config" else String(e.path)
			if _task_location(e) == s.location_id:
				_routes.append({"task": key, "name": String(e.name)})
	var opt: OptionButton = _rows["route"].route
	var was := _loading
	_loading = true
	opt.clear()
	for e: Dictionary in _routes:
		opt.add_item(e.name)
	var idx := _route_index(keep)
	if idx >= 0:
		opt.select(idx)
	_loading = was


func _route_index(task: String) -> int:
	for i in _routes.size():
		if _routes[i].task == task:
			return i
	return 0 if not _routes.is_empty() and task == "" else -1


func _chosen_task() -> String:
	var opt: OptionButton = _rows["route"].route
	var i := opt.selected
	if i < 0 or i >= _routes.size():
		return ""
	return String(_routes[i].task)


static func _task_location(e: Dictionary) -> String:
	if e.source == "config":
		return String(Config.get_config("tasks/" + String(e.id)).get("location", ""))
	var t := Task.load_file(String(e.path))
	return t.location if t != null else ""


func _route_length(task: String, s: FlightSettings) -> float:
	if _route_len.has(task):
		return float(_route_len[task])
	var loc := Locations.config(s.location_id)
	var clat := float(loc.get("center_lat", 0.0))
	var clon := float(loc.get("center_lon", 0.0))
	var fn := func(lat: float, lon: float) -> Vector2:
		return TerrainGeo.latlon_to_local(lat, lon, clat, clon)
	var t: Task
	if task.begins_with("user://") or task.is_absolute_path():
		t = Task.load_file(task, fn)
	else:
		t = Task.load_config(task, fn)
	var m := t.task_distance_m() if t != null else 0.0
	_route_len[task] = m
	return m


# ------------------------------------------------------------ итог


## Выбранные цели (GL-К1), в порядке GoalSpec.KINDS; для FlightSettings.goals.
func collect() -> Array:
	if _dirty and not _refreshing:
		refresh()
	var out: Array = []
	for kind: String in GoalSpec.KINDS:
		if not _checked(kind):
			continue
		var r: Dictionary = _rows[kind]
		if kind == "route":
			out.append(GoalSpec.make("route", "medium", 0.0, _chosen_task()))
			continue
		var lv: String = GoalSpec.LEVELS[(r.level as OptionButton).selected]
		out.append(GoalSpec.make(kind, lv, snappedf(_value_m(kind), 0.001)))
	return out


func collect_show_last_track() -> bool:
	return _last_track.button_pressed and not _last_track.disabled


func collect_track_paths() -> PackedStringArray:
	return _track_paths
