class_name TrainingMenu
extends Control
## Окно «Тренировка» (TI-16, VI-К2): вкладки по местам (группы configs/training.json), в каждой — карточки стартов:
## название, «что отрабатываем», цель словами. Клик — chosen(карточка с location) и закрытие; «Отмена» — closed.
## Окно ничего не запускает: FlightSettings собирает settings_for, запуск — у главного меню.

signal chosen(card: Dictionary)
signal closed

const CONFIG_PATH := "res://configs/training.json"

var groups: Array = []  ## показанные группы (место существует, карточки есть)
var _panel: PanelContainer
var _tabs: TabContainer
var _buttons: Array = []  ## по группам: Array[Array[Button]]


## Группы из configs/training.json: {"groups": [...]}; каждой карточке добавлено "location" её группы.
static func load_cards() -> Dictionary:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		push_error("TrainingMenu: нет %s" % CONFIG_PATH)
		return {"groups": []}
	var d: Variant = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary):
		push_error("TrainingMenu: %s — не словарь" % CONFIG_PATH)
		return {"groups": []}
	for g: Dictionary in d.get("groups", []):
		var cs: Array = g.get("cards", [])
		for c: Dictionary in cs:
			c["location"] = String(g.get("location", ""))
	return d


## Группы, которые показывает окно: место существует и есть карточки.
static func visible_groups() -> Array:
	var out := []
	for g: Dictionary in load_cards().get("groups", []):
		if Locations.exists(String(g.get("location", ""))) and not (g.get("cards", []) as Array).is_empty():
			out.append(g)
	return out


## Цель карточки как GoalSpec (GL-К1).
static func goal_of(card: Dictionary) -> Dictionary:
	var g: Dictionary = card.get("goal", {})
	return GoalSpec.make(String(g.get("kind", "")), String(g.get("level", "custom")), float(g.get("value", 0.0)))


## Цель словами тем же форматом, что список целей в полёте: «Время в воздухе 10:00».
static func goal_text(card: Dictionary) -> String:
	var g := goal_of(card)
	return "%s %s" % [GoalList.goal_name(g), GoalList.fmt_value(String(g.kind), float(g.value))]


## FlightSettings для клика по карточке: крыло, масса и аппарат — из base (последний выбор пилота),
## место — из карточки (card.location), старт — карточки, точка с карты и точный старт сброшены, цель — карточки, погода — набор старта (TI-К2).
static func settings_for(card: Dictionary, base: FlightSettings) -> FlightSettings:
	var s := base.duplicate()
	s.location_id = String(card.get("location", ""))
	s.site_id = String(card.get("site", ""))
	s.pick_lat = NAN
	s.pick_lon = NAN
	s.start_lat = NAN
	s.start_lon = NAN
	s.start_heading_deg = NAN
	s.goals = [goal_of(card)]
	s.show_last_track = false
	s.track_paths = PackedStringArray()
	StartWeather.apply(s)
	return s


func _ready() -> void:
	groups = visible_groups()
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.12, 1.0)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(16)
	sb.border_color = Color(0.25, 0.3, 0.38)
	sb.set_border_width_all(1)
	_panel.add_theme_stylebox_override("panel", sb)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_panel.add_child(box)
	UiKit.label(box, tr("menu_training"), "HeaderLabel")
	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	box.add_child(_tabs)
	for g: Dictionary in groups:
		var grid := GridContainer.new()
		grid.name = String(g.get("id", ""))
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		_tabs.add_child(grid)
		_tabs.set_tab_title(_tabs.get_tab_count() - 1, tr(String(g.get("title_key", ""))))
		var bs: Array[Button] = []
		for c: Dictionary in g.get("cards", []):
			bs.append(_card_button(grid, c))
		_buttons.append(bs)
	UiKit.button(box, tr("common_cancel"), func() -> void: closed.emit())


func _card_button(parent: Control, card: Dictionary) -> Button:
	var b := Button.new()
	b.name = "Card_" + String(card.get("id", ""))
	b.custom_minimum_size = Vector2(340, 150)
	b.pressed.connect(func() -> void: chosen.emit(card))
	parent.add_child(b)
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	b.add_child(m)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(v)
	var t := UiKit.label(v, tr(String(card.get("title_key", ""))), "HeaderLabel")
	var w := UiKit.label(v, tr(String(card.get("what_key", ""))), "HintLabel")
	var g := UiKit.label(v, "🎯 " + goal_text(card))
	for l: Label in [t, w, g]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


## Нажать карточку по номеру (тесты, съёмка).
func press_card(i: int, group: int = 0) -> void:
	(_buttons[group][i] as Button).pressed.emit()
