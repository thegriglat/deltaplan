class_name CatchUpMenu
extends Control
## «Догнать» — меню `=` поверх полёта (NET-42, docs/plan/multiplayer.md): список пилотов зоны
## кроме себя (сначала живые, потом боты; внутри — по имени, чтобы строки не прыгали), в строке
## имя, высота над морем (как на варио), расстояние по горизонтали и «на старте»/«на земле»/
## «в воздухе».
## По умолчанию выделен ближайший живой пилот в воздухе — при двоих в зоне хватает `=` → Enter.
## ↑/↓ (ui_up/ui_down: стрелки, крестовина) — выбор; Enter (ui_accept) — catch_up_requested(id)
## и закрыться; Esc (ui_cancel) или повторный `=` (действие catch_up) — закрыться без действия.
## Полёт меню не останавливает. Пока открыто — съедает эти клавиши в _input (до паузы main.gd
## и прочих _unhandled_input), но клавиши крыла опрашиваются через Input.is_action_pressed —
## поэтому вызывающий держит управление нейтральным, пока is_open() (InputController.hands_off:
## трапеция в триме, крыло летит само, как при отпущенной трапеции).
##
## Данные — тонкий источник (тестируемо): set_source(pilots_fn, own_pos_fn)
##   pilots_fn() -> Array[Dictionary] {id: String, name: String, is_bot: bool, pos: Vector3,
##     on_ground: bool, landed: bool (необязательно — сел/разбился: «на земле», не «на старте»)}
##   own_pos_fn() -> Vector3 — своя позиция (для расстояния).
## Готовые источники: remote_pilots_source(RemotePilots), net_pilots_source(NetPilots).
## Список обновляется REFRESH_HZ раз в секунду, пока открыто; ушедший пилот исчезает, ушёл
## выбранный — выделение остаётся на той же позиции списка.
## Для «Продолжить рядом» (окно итога): pick_nearest_airborne_human(), airborne_count().
## Открывает меню вызывающий (по действию catch_up в сетевой зоне): open(); повторный `=`
## при открытом меню ловит само меню.

## Enter: догнать этого пилота. Сразу за ним — closed.
signal catch_up_requested(pilot_id: String)
## Меню закрылось (любым способом: Esc, `=`, Enter, close()).
signal closed

## Действие клавиши «догнать» (configs/controls.json → keys.catch_up).
const ACTION := "catch_up"
## Частота обновления списка, пока меню открыто, Гц.
const REFRESH_HZ := 4.0
const ACCENT := Color(0.95, 0.72, 0.35)

## Свой id — строка с ним в список не попадает (источник может и сам его не отдавать).
var self_id := ""

var _pilots_fn := Callable()
var _own_pos_fn := Callable()
var _rows: Array[Dictionary] = []
var _sel := -1
var _open := false
var _acc := 0.0
var _panel: PanelContainer
var _list: VBoxContainer
var _empty: Label
var _row_style: StyleBoxFlat
var _sel_style: StyleBoxFlat


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_top = 48.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.07, 0.08, 0.1, 0.62)
	bg.border_color = Color(1, 1, 1, 0.1)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(10)
	bg.set_content_margin_all(14)
	bg.content_margin_left = 18
	bg.content_margin_right = 18
	_panel.add_theme_stylebox_override("panel", bg)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)
	var title := UiKit.label(box, tr("catch_up_title"), "HeaderLabel")
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	box.add_child(_list)
	_empty = UiKit.label(box, tr("catch_up_empty"))
	_empty.autowrap_mode = TextServer.AUTOWRAP_OFF
	var hint := UiKit.label(box, tr("catch_up_hint"), "HintLabel")
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	_row_style = StyleBoxFlat.new()
	_row_style.draw_center = false
	_row_style.set_content_margin_all(4)
	_row_style.content_margin_left = 10
	_row_style.content_margin_right = 10
	_sel_style = _row_style.duplicate()
	_sel_style.draw_center = true
	_sel_style.bg_color = Color(ACCENT, 0.28)
	_sel_style.border_color = Color(ACCENT, 0.9)
	_sel_style.set_border_width_all(1)
	_sel_style.set_corner_radius_all(6)


## Источник данных (см. заголовок). own_pos_fn не задан — расстояние от (0, 0, 0).
func set_source(pilots_fn: Callable, own_pos_fn: Callable = Callable()) -> void:
	_pilots_fn = pilots_fn
	_own_pos_fn = own_pos_fn
	if _open:
		refresh()


## Открыть: свежий список, выделение — ближайший живой пилот в воздухе (нет — первая строка).
func open() -> void:
	_open = true
	visible = true
	_acc = 0.0
	_sel = -1
	_rows = _collect()
	var id := pick_nearest_airborne_human(_rows, _own_pos())
	_sel = _index_of(id) if id != "" else (0 if not _rows.is_empty() else -1)
	_render()


## Закрыть без действия (снаружи: например, начался буксир или вышли из зоны).
func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	closed.emit()


func is_open() -> bool:
	return _open


## Открыть, если закрыто, иначе закрыть (для вызывающего, ловящего действие catch_up).
func toggle() -> void:
	if _open:
		close()
	else:
		open()


## Id выделенного пилота ("" — список пуст).
func selected_id() -> String:
	return String(_rows[_sel].id) if _sel >= 0 and _sel < _rows.size() else ""


## Строки, как на экране: [{id, name, is_bot, alt_m, dist_m, on_ground, landed}].
func rows() -> Array[Dictionary]:
	return _rows


## Строки текстом (для тестов/скриншотов): «имя | высота | расстояние | статус».
func row_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	for r in _rows:
		out.append(" | ".join(_cells(r)))
	return out


## Перечитать источник сейчас (сам — REFRESH_HZ, пока открыто).
func refresh() -> void:
	var prev_id := selected_id()
	var prev_sel := _sel
	_rows = _collect()
	if _rows.is_empty():
		_sel = -1
	elif prev_id != "" and _index_of(prev_id) >= 0:
		_sel = _index_of(prev_id)
	else:
		_sel = clampi(prev_sel, 0, _rows.size() - 1)
	_render()


func _process(dt: float) -> void:
	if not _open:
		return
	_acc += dt
	if _acc >= 1.0 / REFRESH_HZ:
		_acc = 0.0
		refresh()


func _input(event: InputEvent) -> void:
	if not _open or event.is_echo() and not _is_nav(event):
		return
	if event.is_action_pressed(ACTION) or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()
	elif event.is_action_pressed("ui_up", true):
		get_viewport().set_input_as_handled()
		move_selection(-1)
	elif event.is_action_pressed("ui_down", true):
		get_viewport().set_input_as_handled()
		move_selection(1)
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		accept()
	elif _swallow(event):
		get_viewport().set_input_as_handled()


func _is_nav(event: InputEvent) -> bool:
	return event.is_action("ui_up") or event.is_action("ui_down")


## Съесть и прочие клавиши меню (←/→, отпускания), чтобы они не ушли в игру.
func _swallow(event: InputEvent) -> bool:
	for a: String in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_cancel", ACTION]:
		if InputMap.has_action(a) and event.is_action(a):
			return true
	return false


## ↑/↓: выделение на step строк (по кругу).
func move_selection(step: int) -> void:
	if _rows.is_empty():
		return
	_sel = posmod(_sel + step, _rows.size())
	_render()


## Enter: догнать выделенного (пустой список — ничего).
func accept() -> void:
	var id := selected_id()
	if id == "":
		return
	catch_up_requested.emit(id)
	close()


func _own_pos() -> Vector3:
	return _own_pos_fn.call() if _own_pos_fn.is_valid() else Vector3.ZERO


func _index_of(id: String) -> int:
	for i in _rows.size():
		if String(_rows[i].id) == id:
			return i
	return -1


## Список из источника: без себя, живые выше ботов, внутри — по имени (потом по id).
func _collect() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _pilots_fn.is_valid():
		return out
	var own := _own_pos()
	for p: Dictionary in _pilots_fn.call():
		var id := String(p.get("id", ""))
		if id == "" or id == self_id:
			continue
		var pos: Vector3 = p.get("pos", Vector3.ZERO)
		(
			out
			. append(
				{
					"id": id,
					"name": String(p.get("name", "")),
					"is_bot": bool(p.get("is_bot", false)),
					"pos": pos,
					"alt_m": pos.y,
					"dist_m": Vector2(own.x, own.z).distance_to(Vector2(pos.x, pos.z)),
					"on_ground": bool(p.get("on_ground", false)),
					"landed": bool(p.get("landed", false)),
				}
			)
		)
	out.sort_custom(_before)
	return out


static func _before(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.is_bot) != bool(b.is_bot):
		return not bool(a.is_bot)
	var na := String(a.name).to_lower()
	var nb := String(b.name).to_lower()
	if na != nb:
		return na < nb
	return String(a.id) < String(b.id)


func _cells(r: Dictionary) -> PackedStringArray:
	var status := "catch_up_air"
	if bool(r.on_ground):
		status = "catch_up_landed" if bool(r.landed) else "catch_up_at_launch"
	var nm := String(r.name)
	if nm == "":
		nm = tr("net_pilot_name_default")
	if bool(r.is_bot):
		nm += " · " + tr("catch_up_bot")
	return [
		nm,
		"%d %s" % [roundi(float(r.alt_m)), tr("unit_m")],
		fmt_distance(float(r.dist_m)),
		tr(status),
	]


## Расстояние: до 1 км — метры (по 10 м), дальше — км с одним знаком (запятая по языку).
func fmt_distance(m: float) -> String:
	if m < 995.0:
		return "%d %s" % [int(roundf(m / 10.0) * 10.0), tr("unit_m")]
	var s := "%.1f" % (m / 1000.0)
	return "%s %s" % [s.replace(".", tr("setup_decimal_point")), tr("unit_km")]


func _render() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_empty.visible = _rows.is_empty()
	var widths := [190.0, 96.0, 96.0, 130.0]
	for i in _rows.size():
		var r := _rows[i]
		var sel := i == _sel
		var line := PanelContainer.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_stylebox_override("panel", _sel_style if sel else _row_style)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 14)
		line.add_child(h)
		var cells := _cells(r)
		for k in cells.size():
			var l := Label.new()
			l.text = cells[k]
			l.custom_minimum_size.x = widths[k]
			l.clip_text = k == 0
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			if k in [1, 2]:
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			var dim := bool(r.is_bot) or bool(r.on_ground)
			if sel:
				l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
			elif dim and k == 3:
				l.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			elif bool(r.is_bot):
				l.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
			h.add_child(l)
		_list.add_child(line)


## --- Источники данных ---


## Из RemotePilots (scripts/game/remote_pilots.gd): pilots() — как их видно в мире.
static func remote_pilots_source(rp: Node) -> Callable:
	return func() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if not is_instance_valid(rp):
			return out
		for p: Dictionary in rp.call("pilots"):
			var phase := String(p.get("phase", ""))
			(
				out
				. append(
					{
						"id": String(p.get("pilot_id", "")),
						"name": String(p.get("name", "")),
						"is_bot": bool(p.get("is_bot", false)),
						"pos": p.get("position", Vector3.ZERO),
						"on_ground": RemotePilots.GROUND_PHASES.has(phase),
						"landed": phase in ["landed", "crashed", "failed"],
					}
				)
			)
		return out


## Из NetPilots (автозагрузка, scripts/net/net_pilots.gd): get_pilot_ids() + sample(id).
static func net_pilots_source(np: Node) -> Callable:
	return func() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if not is_instance_valid(np):
			return out
		for id: String in np.call("get_pilot_ids"):
			var s: Dictionary = np.call("sample", id)
			if s.is_empty():
				continue
			var phase := String(s.get("phase", ""))
			(
				out
				. append(
					{
						"id": id,
						"name": String(s.get("name", "")),
						"is_bot": bool(s.get("is_bot", false)),
						"pos": s.get("pos", Vector3.ZERO),
						"on_ground": not phase in ["FLY", "TOW"],
						"landed": phase in ["LANDED", "CRASHED"],
					}
				)
			)
		return out


## --- «Продолжить рядом» (окно итога) ---


## Ближайший живой пилот в воздухе ("" — таких нет). list — как у источника (pos, on_ground,
## is_bot, id); own_pos — своя позиция.
static func pick_nearest_airborne_human(list: Array, own_pos: Vector3) -> String:
	var best := ""
	var best_d := INF
	for p: Dictionary in list:
		if bool(p.get("is_bot", false)) or bool(p.get("on_ground", false)):
			continue
		var d := own_pos.distance_squared_to(p.get("pos", Vector3.ZERO))
		if d < best_d:
			best_d = d
			best = String(p.get("id", ""))
	return best


## Сколько живых пилотов в воздухе (боты не считаются): 0 — «Продолжить рядом» не показывать,
## 1 — буксир сразу, больше — открыть меню.
static func airborne_count(list: Array) -> int:
	var n := 0
	for p: Dictionary in list:
		if not bool(p.get("is_bot", false)) and not bool(p.get("on_ground", false)):
			n += 1
	return n
