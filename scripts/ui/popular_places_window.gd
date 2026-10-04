class_name PopularPlacesWindow
extends Control
## Окно «Популярные места» (PP-К2): страны с числом мест → места страны; поиск по названию
## (на уровне стран — по всем странам, внутри страны — по ней). Окно не выходит за экран, списки
## прокручиваются. Выбор места — place_chosen(старт PP-К1) и закрытие; «Отмена» — closed.

signal place_chosen(place: Dictionary)
signal closed

const MAX_W := 760.0
const MAX_H := 820.0
const MARGIN := 0.92  ## доля экрана, которую окно занимает не больше

var _catalog: Dictionary = {}
var _groups: Array = []
var _lang := "ru"
var _country := "<none>"  ## "<none>" — уровень стран; иначе код страны ("" — без страны)

var _panel: PanelContainer
var _title: Label
var _search: LineEdit
var _scroll: ScrollContainer
var _list: VBoxContainer
var _back: Button
var _cancel: Button


func _ready() -> void:
	_build()


func _build() -> void:
	if _panel != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()  # непрозрачная подложка: экран под окном не просвечивает
	sb.bg_color = Color(0.07, 0.09, 0.12, 1.0)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(16)
	sb.border_color = Color(0.25, 0.3, 0.38)
	sb.set_border_width_all(1)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)
	_title = UiKit.label(box, "", "HeaderLabel")
	_search = LineEdit.new()
	_search.placeholder_text = tr("places_search_hint")
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _refresh())
	box.add_child(_search)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)
	var bar := UiKit.button_bar(box)
	_back = UiKit.button(bar, tr("common_back"), _go_back)
	_cancel = UiKit.button(bar, tr("common_cancel"), func() -> void: _close(false))
	resized.connect(_layout)
	_layout()


## Окно по центру: не больше MAX_W × MAX_H и не больше MARGIN от размера области.
func _layout() -> void:
	if _panel == null:
		return
	var w := minf(MAX_W, size.x * MARGIN)
	var h := minf(MAX_H, size.y * MARGIN)
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.size = Vector2(w, h)
	_panel.position = (size - _panel.size) * 0.5


func open(catalog: Dictionary) -> void:
	_build()
	_catalog = catalog
	_lang = PopularPlaces.lang()
	_groups = PopularPlaces.group_by_country(catalog, _lang)
	_country = "<none>"
	_search.text = ""
	visible = true
	_layout()
	_refresh()


## Прямоугольник окна (для теста и кадра).
func panel_rect() -> Rect2:
	return Rect2(_panel.position, _panel.size)


func _group(code: String) -> Dictionary:
	for g: Dictionary in _groups:
		if g.code == code:
			return g
	return {}


func _go_back() -> void:
	if _country == "<none>":
		_close(false)
		return
	_country = "<none>"
	_search.text = ""
	_refresh()


func _close(chosen: bool) -> void:
	visible = false
	if not chosen:
		closed.emit()


## Войти в страну (из строки списка стран).
func enter_country(code: String) -> void:
	_country = code
	_search.text = ""
	_refresh()


func _choose(p: Dictionary) -> void:
	_close(true)
	place_chosen.emit(p)


func _refresh() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var query := _search.text
	var at_countries := _country == "<none>"
	if at_countries:
		_title.text = tr("places_title")
		if query.strip_edges() == "":
			for g: Dictionary in _groups:
				_add_row(tr("places_country_row") % [g.name, g.count], enter_country.bind(g.code))
		else:
			var all: Array = []
			for g: Dictionary in _groups:
				all.append_array(g.places)
			_fill_places(PopularPlaces.search(all, query), true)
	else:
		var g := _group(_country)
		_title.text = String(g.get("name", ""))
		_fill_places(PopularPlaces.search(g.get("places", []), query), false)
	_scroll.scroll_vertical = 0


func _fill_places(places: Array, with_country: bool) -> void:
	if places.is_empty():
		UiKit.label(_list, tr("places_no_results"), "HintLabel")
		return
	for p: Dictionary in places:
		_add_row(_place_text(p, with_country), _choose.bind(p))


func _place_text(p: Dictionary, with_country: bool) -> String:
	var parts: PackedStringArray = [PopularPlaces.display_name(p)]
	if with_country:
		parts.append(PopularPlaces.country_name(_catalog, String(p.get("country", "")), _lang))
	var ele: Variant = p.get("ele")
	parts.append(tr("places_ele") % roundi(float(ele)) if ele != null else "—")
	var ori := PopularPlaces.orientation_text(p)
	if ori != "":
		parts.append(tr("places_wind") % ori)
	return " · ".join(parts)


func _add_row(text: String, on_pressed: Callable) -> void:
	var b := UiKit.button(_list, text, on_pressed)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Подписи строк списка (для тестов).
func row_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	for c in _list.get_children():
		if c is Button and not c.is_queued_for_deletion():
			out.append((c as Button).text)
	return out


## Нажать строку номер i (для тестов).
func press_row(i: int) -> void:
	var n := 0
	for c in _list.get_children():
		if c is Button and not c.is_queued_for_deletion():
			if n == i:
				(c as Button).pressed.emit()
				return
			n += 1
