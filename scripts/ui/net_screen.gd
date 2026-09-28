class_name NetScreen
extends Control
## Экран «Сетевая игра» (NET-50, docs/plan/multiplayer.md): адрес сервера (запоминается),
## имя пилота (из настроек), «Создать» — зона на выбранном месте (крыло, масса, время, погода —
## из последнего «Полёт…»), «Присоединиться» — по коду зоны. Дальше — «Подключение…»,
## в зоне — код крупно и кто в зоне; ошибки — простым текстом.
## С сетью говорит только через backend (NetUiBackend); в полёт — сигнал fly_requested наверх.

signal closed
## «Лететь» в зоне: параметры полёта зоны.
signal fly_requested(zone_settings: FlightSettings)

enum View { INPUT, CONNECTING, ZONE }

## Вид ошибки (NetUiBackend.ERROR_KINDS) → ключ locale/ui.csv.
const ERROR_KEYS := {
	"unreachable": "net_err_unreachable",
	"zone_not_found": "net_err_zone_not_found",
	"version_mismatch": "net_err_version_mismatch",
	"zone_full": "net_err_zone_full",
	"disconnected": "net_err_disconnected",
	"bad_message": "net_err_bad_message",
	"port_busy": "net_err_port_busy",
	"server_failed": "net_err_server_failed",
}

## Клиент сети; не задан до add_child — NetClient/NetZone (NetUiClientBackend).
var backend: NetUiBackend
## Последний выбор «Полёт…» (крыло, масса, время, погода); место выбирается здесь.
var settings: FlightSettings
var view: View = View.INPUT
## Вид последней ошибки ("" — нет).
var error_kind := ""

var _input_box: VBoxContainer
var _connecting_box: VBoxContainer
var _zone_box: VBoxContainer
var _server: LineEdit
var _place_opt: OptionButton
var _places: Array[Dictionary] = []  ## {location, site} или {pick: true}
var _code_edit: LineEdit
var _create_btn: Button
var _join_btn: Button
var _error: Label
var _connecting_label: Label
var _code_label: Label
var _peers_box: VBoxContainer
var _fly_btn: Button
var _address := ""

## «Рядом» (NET-23/NET-53): зоны в локальной сети, пока на экране ввода.
var _nearby_list: ItemList
var _nearby_empty: Label
var _nearby: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if settings == null:
		settings = UserSettings.load_last_flight()
	if backend == null:
		backend = NetUiClientBackend.new()
	backend.state_changed.connect(_on_state_changed)
	backend.failed.connect(_on_failed)
	backend.zone_joined.connect(_on_zone_joined)
	backend.peers_changed.connect(_fill_peers)
	backend.nearby_changed.connect(_fill_nearby)
	_build()
	_show_view(View.INPUT)
	visibility_changed.connect(_on_visibility_changed)


func _unhandled_input(event: InputEvent) -> void:
	# Esc — как «Назад» (раньше main.gd: экран глубже в дереве и получает ввод первым).
	var esc := event.is_action_pressed("ui_cancel")
	if InputMap.has_action("pause"):
		esc = esc or event.is_action_pressed("pause")
	if visible and esc:
		get_viewport().set_input_as_handled()
		go_back()


## «Назад»/Esc: отменить подключение или выйти из зоны и вернуться в меню.
func go_back() -> void:
	backend.leave()
	_show_view(View.INPUT)
	closed.emit()


func server_text() -> String:
	return _server.text.strip_edges()


func error_text() -> String:
	return _error.text if _error.visible else ""


func code_text() -> String:
	return _code_label.text


## Строки списка «кто в зоне» (как на экране).
func peer_lines() -> PackedStringArray:
	var out: PackedStringArray = []
	for c in _peers_box.get_children():
		out.append((c as Label).text)
	return out


func set_server(addr: String) -> void:
	_server.text = addr
	_update_buttons()


func set_code(zone_code: String) -> void:
	_code_edit.text = zone_code
	_update_buttons()


## «Создать»: зона на выбранном месте, остальное — из последнего «Полёт…».
func create_zone() -> void:
	if _create_btn.disabled:
		return
	_begin()
	backend.connect_and_create(_address, UserSettings.pilot_name(), zone_params())


## «Присоединиться» по коду.
func join_zone() -> void:
	if _join_btn.disabled:
		return
	_begin()
	backend.connect_and_join(_address, UserSettings.pilot_name(), _code_edit.text.strip_edges())


## Параметры новой зоны: последний «Полёт…» + место из списка.
func zone_params() -> FlightSettings:
	var s := settings.duplicate()
	if _place_opt.selected < 0:
		return s
	var k: Variant = _place_opt.get_item_metadata(_place_opt.selected)
	if k == null:
		return s
	var e: Dictionary = _places[int(k)]
	if not e.get("pick", false):
		s.location_id = String(e.location)
		s.site_id = String(e.site)
		s.pick_lat = NAN
		s.pick_lon = NAN
	return s


func _begin() -> void:
	_address = server_text()
	if _address != "":
		UserSettings.save_server_address(_address)
	error_kind = ""
	_connecting_label.text = tr("net_connecting") % (
		_address if _address != "" else tr("net_embedded_server")
	)
	_show_view(View.CONNECTING)


# ---------------------------------------------------------------- вёрстка


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var box := UiKit.centered_panel(self, float(ui.get("panel_width_px", 560)) + 80.0)
	UiKit.label(box, tr("menu_net_game"), "TitleLabel")
	UiKit.separator(box)
	_input_box = _section(box)
	_connecting_box = _section(box)
	_zone_box = _section(box)
	_build_input(_input_box)
	_build_connecting(_connecting_box)
	_build_zone(_zone_box)


func _section(parent: Control) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	parent.add_child(v)
	return v


func _build_input(box: VBoxContainer) -> void:
	_server = LineEdit.new()
	_server.placeholder_text = tr("net_server_placeholder")
	_server.text = UserSettings.server_address()
	_server.text_changed.connect(func(_t: String) -> void: _update_buttons())
	UiKit.row(box, tr("net_server"), _server)
	UiKit.label(box, tr("net_server_hint"), "HintLabel")
	var name_label := Label.new()
	name_label.text = UserSettings.pilot_name()
	UiKit.row(box, tr("settings_pilot_name"), name_label)

	UiKit.separator(box)
	UiKit.label(box, tr("net_nearby_title"), "HeaderLabel")
	UiKit.label(box, tr("net_nearby_hint"), "HintLabel")
	_nearby_list = ItemList.new()
	_nearby_list.custom_minimum_size.y = 96
	_nearby_list.auto_height = false
	_nearby_list.item_activated.connect(_on_nearby_activated)
	box.add_child(_nearby_list)
	_nearby_empty = UiKit.label(box, tr("net_nearby_empty"), "HintLabel")

	UiKit.separator(box)
	UiKit.label(box, tr("net_create_title"), "HeaderLabel")
	_place_opt = OptionButton.new()
	_place_opt.fit_to_longest_item = false
	var place_row := UiKit.row(box, tr("net_place"), _place_opt)
	_create_btn = UiKit.button(place_row, tr("net_create"), create_zone)
	_create_btn.custom_minimum_size.x = 170
	_fill_places()

	UiKit.separator(box)
	UiKit.label(box, tr("net_join_title"), "HeaderLabel")
	_code_edit = LineEdit.new()
	_code_edit.max_length = 4
	_code_edit.placeholder_text = "0000"
	_code_edit.text_changed.connect(_on_code_changed)
	_code_edit.text_submitted.connect(func(_t: String) -> void: join_zone())
	var code_row := UiKit.row(box, tr("net_code"), _code_edit)
	_join_btn = UiKit.button(code_row, tr("net_join"), join_zone)
	_join_btn.custom_minimum_size.x = 170

	_error = UiKit.label(box, "")
	_error.add_theme_color_override("font_color", Color(1.0, 0.62, 0.5))
	_error.visible = false

	UiKit.separator(box)
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("common_back"), go_back)
	_update_buttons()


func _build_connecting(box: VBoxContainer) -> void:
	_connecting_label = UiKit.label(box, "")
	_connecting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiKit.separator(box)
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("common_cancel"), _on_cancel)


func _build_zone(box: VBoxContainer) -> void:
	var cap := UiKit.label(box, tr("net_zone_code"), "HintLabel")
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label = Label.new()
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", 120)
	box.add_child(_code_label)
	UiKit.separator(box)
	UiKit.label(box, tr("net_in_zone"), "HeaderLabel")
	_peers_box = VBoxContainer.new()
	_peers_box.add_theme_constant_override("separation", 6)
	box.add_child(_peers_box)
	UiKit.separator(box)
	var bar := UiKit.button_bar(box)
	_fly_btn = UiKit.button(bar, tr("menu_fly"), _on_fly)
	_fly_btn.custom_minimum_size.x = 170
	UiKit.button(bar, tr("net_leave"), _on_leave)


## Старты всех локаций, сгруппированы по локациям (как в «Полёт…»); точка с карты из
## последнего «Полёт…» — первой строкой.
func _fill_places() -> void:
	_place_opt.clear()
	_places.clear()
	var chosen := -1
	if settings.has_pick():
		_places.append({"pick": true})
		_place_opt.add_item(tr("menu_point") % [settings.pick_lat, settings.pick_lon])
		_place_opt.set_item_metadata(0, 0)
		chosen = 0
	for loc_name in Config.list_configs("locations"):
		var loc: Dictionary = Config.get_config(loc_name)
		var starts: Array = loc.get("start_sites", [])
		if starts.is_empty():
			continue
		_place_opt.add_separator(tr(String(loc.get("name", loc_name.get_file()))))
		for st: Dictionary in starts:
			var site := String(st.get("id", ""))
			_places.append({"location": loc_name.get_file(), "site": site})
			_place_opt.add_item("   " + tr(String(st.get("name", site))))
			var i := _place_opt.item_count - 1
			_place_opt.set_item_metadata(i, _places.size() - 1)
			if (
				not settings.has_pick()
				and loc_name.get_file() == settings.location_id
				and (site == settings.site_id or settings.site_id == "")
				and chosen < 0
			):
				chosen = i
	if chosen < 0:  # место из «Полёт…» не нашлось — первый старт
		for i in _place_opt.item_count:
			if _place_opt.get_item_metadata(i) != null:
				chosen = i
				break
	_place_opt.select(chosen)


func _fill_peers() -> void:
	for c in _peers_box.get_children():
		_peers_box.remove_child(c)
		c.queue_free()
	for p: Dictionary in backend.peers():
		var marks: PackedStringArray = []
		if bool(p.get("is_leader", false)):
			marks.append(tr("net_leader"))
		if bool(p.get("is_me", false)):
			marks.append(tr("net_you"))
		var text := String(p.get("name", ""))
		if not marks.is_empty():
			text += "  —  " + ", ".join(marks)
		var l := UiKit.label(_peers_box, text)
		if bool(p.get("is_me", false)):
			l.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))


## Список «Рядом»: зоны в локальной сети (NET-23); другая версия игры — тускло и не войти.
func _fill_nearby() -> void:
	_nearby = backend.nearby()
	_nearby_list.clear()
	for z: Dictionary in _nearby:
		var same := bool(z.get("same_version", true))
		var text := tr("net_nearby_zone") % [String(z.get("code", "")), String(z.get("host_name", ""))]
		if not same:
			text += "  —  " + tr("net_nearby_other_version")
		var idx := _nearby_list.add_item(text)
		if not same:
			_nearby_list.set_item_custom_fg_color(idx, Color(1, 1, 1, 0.45))
	var is_empty := _nearby.is_empty()
	_nearby_list.visible = not is_empty
	_nearby_empty.visible = is_empty
	if not is_empty:
		_nearby_list.select(0)


## Enter/двойной клик в «Рядом» — войти одним нажатием; другая версия — нельзя.
func _on_nearby_activated(index: int) -> void:
	if index < 0 or index >= _nearby.size():
		return
	var z: Dictionary = _nearby[index]
	if not bool(z.get("same_version", true)):
		return
	var addr := "%s:%d" % [String(z.get("address", "")), int(z.get("port", 0))]
	error_kind = ""
	_connecting_label.text = tr("net_connecting") % addr
	_show_view(View.CONNECTING)
	backend.connect_and_join(addr, UserSettings.pilot_name(), String(z.get("code", "")))


# ---------------------------------------------------------------- состояние


func _show_view(v: View) -> void:
	view = v
	_input_box.visible = v == View.INPUT
	_connecting_box.visible = v == View.CONNECTING
	_zone_box.visible = v == View.ZONE
	_error.text = tr(ERROR_KEYS[error_kind]) if error_kind != "" else ""
	_error.visible = v == View.INPUT and error_kind != ""
	if v == View.INPUT:
		_fill_nearby()
	if v == View.ZONE:
		_code_label.text = backend.code()
		_fill_peers()
	if is_inside_tree() and visible:
		match v:
			View.INPUT:
				# Список «Рядом» не пуст — в фокус первым: чаще всего сценарий «одна комната».
				if not _nearby.is_empty():
					_nearby_list.grab_focus.call_deferred()
				else:
					(_server if server_text() == "" else _create_btn).grab_focus.call_deferred()
			View.ZONE:
				_fly_btn.grab_focus.call_deferred()


func _update_buttons() -> void:
	# «Создать» без адреса — на встроенном сервере (NET-22); адрес нужен только для «Войти».
	var has_server := server_text() != ""
	var c := _code_edit.text.strip_edges()
	_join_btn.disabled = not has_server or c.length() != 4 or not c.is_valid_int()


## В поле кода — только цифры.
func _on_code_changed(t: String) -> void:
	var digits := ""
	for ch in t:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != t:
		var caret := _code_edit.caret_column
		_code_edit.text = digits
		_code_edit.caret_column = mini(caret, digits.length())
	_update_buttons()


func _on_state_changed() -> void:
	# Подключение прервалось без ошибки (leave и т. п.) — назад к вводу.
	if view == View.CONNECTING and not backend.is_busy() and backend.code() == "":
		if error_kind == "":
			_show_view(View.INPUT)


func _on_failed(kind: String) -> void:
	error_kind = kind if ERROR_KEYS.has(kind) else "bad_message"
	_show_view(View.INPUT)


func _on_zone_joined(_code: String) -> void:
	error_kind = ""
	_show_view(View.ZONE)


func _on_cancel() -> void:
	backend.leave()
	error_kind = ""
	_show_view(View.INPUT)


func _on_leave() -> void:
	backend.leave()
	error_kind = ""
	_show_view(View.INPUT)


func _on_fly() -> void:
	var s := backend.zone_settings()
	if s == null:
		s = zone_params()
	fly_requested.emit(s)


## Экран показали/спрятали — слушать/не слушать «Рядом» (NET-23); спрятали в разгаре
## подключения/в зоне — подключение и зону не держим.
func _on_visibility_changed() -> void:
	if visible:
		backend.start_nearby()
	else:
		backend.stop_nearby()
		if view != View.INPUT:
			backend.leave()
			error_kind = ""
			_show_view(View.INPUT)
