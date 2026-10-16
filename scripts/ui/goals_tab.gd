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
var _tracks_box: VBoxContainer
var _track_msg: Label
var _dialog: FileDialog
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
	_build_tracks_ui()


func _build_row(kind: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	var check := CheckBox.new()
	check.text = tr(KIND_KEYS[kind])
	check.custom_minimum_size.x = 260
	row.add_child(check)
	var r := {"check": check, "row": row}
	var level := OptionButton.new()
	for lv: String in GoalSpec.LEVELS:
		level.add_item(tr(LEVEL_KEYS[lv]))
	level.select(1)
	level.fit_to_longest_item = true
	level.clip_text = false
	level.custom_minimum_size.x = 130
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
	_show_tracks(PackedStringArray())
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
	recheck_tracks(s)
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


# ------------------------------------------------------------ чужие треки (GL-10)

## Сторона детальной зоны места по умолчанию, км (шаблон места на карте).
const DEFAULT_ZONE_KM := 40.0


func _build_tracks_ui() -> void:
	var btn := Button.new()
	btn.text = tr("goals_track_load")
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.pressed.connect(_on_load_pressed)
	add_child(btn)
	_tracks_box = VBoxContainer.new()
	add_child(_tracks_box)
	_track_msg = Label.new()
	_track_msg.add_theme_color_override("font_color", Color(1.0, 0.65, 0.4))
	_track_msg.visible = false
	add_child(_track_msg)


func _on_load_pressed() -> void:
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.use_native_dialog = false  # нативный на Linux зависит от портала; встроенный — везде одинаков
		_dialog.add_filter("*.igc, *.gpx", tr("goals_track_filter"))
		_dialog.files_selected.connect(add_track_files)
		add_child(_dialog)
	_dialog.popup_centered_ratio(0.6)


## Добавить выбранные файлы: годные (читаются и из этого места) — в список, остальные — сообщение.
func add_track_files(paths: PackedStringArray) -> void:
	var s: FlightSettings = context_fn.call() if context_fn.is_valid() else null
	var msgs := PackedStringArray()
	for p in paths:
		if _track_paths.has(p):
			continue
		var e := check_track_file(p, s)
		if e == "":
			_track_paths.append(p)
		else:
			msgs.append("%s: %s" % [p.get_file(), tr(e)])
	_show_tracks(msgs)


## Перепроверить список под текущим местом; чужие убрать с сообщением.
func recheck_tracks(s: FlightSettings) -> void:
	var keep := PackedStringArray()
	var msgs := PackedStringArray()
	for p in _track_paths:
		var e := check_track_file(p, s)
		if e == "":
			keep.append(p)
		else:
			msgs.append("%s: %s" % [p.get_file(), tr(e)])
	if not msgs.is_empty():
		_track_paths = keep
		_show_tracks(msgs)


func _show_tracks(msgs: PackedStringArray) -> void:
	for c in _tracks_box.get_children():
		_tracks_box.remove_child(c)
		c.queue_free()
	for p in _track_paths:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = p.get_file()
		l.tooltip_text = p
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		row.add_child(l)
		var rm := Button.new()
		rm.text = tr("goals_track_remove")
		rm.pressed.connect(_remove_track.bind(p))
		row.add_child(rm)
		_tracks_box.add_child(row)
	_track_msg.text = "\n".join(msgs)
	_track_msg.visible = not msgs.is_empty()


func _remove_track(p: String) -> void:
	var i := _track_paths.find(p)
	if i >= 0:
		_track_paths.remove_at(i)
	_show_tracks(PackedStringArray())


## "" — файл годен; иначе ключ сообщения (goals_track_foreign / goals_track_unreadable).
static func check_track_file(path: String, s: FlightSettings) -> String:
	var t := TrackIO.read(path)
	if t == null:
		return "goals_track_unreadable"
	if s != null and not track_in_place(t, s):
		return "goals_track_foreign"
	return ""


## Детальная зона места без рельефа: {"bounds": Rect2, "fn": Callable(lat, lon) -> Vector2}.
static func place_zone(s: FlightSettings) -> Dictionary:
	var clat := 0.0
	var clon := 0.0
	var size_km := DEFAULT_ZONE_KM
	if s.has_pick():
		var c := LocationCache.snap(s.pick_lat, s.pick_lon)
		clat = c.x
		clon = c.y
		var layers: Variant = Config.value("world", "location_builder.template.dem.layers", [])
		if layers is Array and not (layers as Array).is_empty():
			size_km = float((layers as Array)[0].get("size_km", DEFAULT_ZONE_KM))
	else:
		var loc := Locations.config(s.location_id)
		clat = float(loc.get("center_lat", 0.0))
		clon = float(loc.get("center_lon", 0.0))
		var ls: Variant = loc.get("dem", {}).get("layers", [])
		if ls is Array and not (ls as Array).is_empty():
			size_km = float((ls as Array)[0].get("size_km", DEFAULT_ZONE_KM))
	var half := size_km * 500.0
	return {
		"bounds": Rect2(-half, -half, 2.0 * half, 2.0 * half),
		"fn": TerrainGeo.latlon_to_local.bind(clat, clon),
	}


## Трек «из этого места»: не меньше половины точек в детальной зоне (GL-К5).
static func track_in_place(t: FlightTrack, s: FlightSettings) -> bool:
	var z := place_zone(s)
	return t.inside_fraction(z.bounds, z.fn) >= 0.5


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
