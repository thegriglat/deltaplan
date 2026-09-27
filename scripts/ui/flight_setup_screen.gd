class_name FlightSetupScreen
extends Control
## Экран «Полёт…» (FR-27, FR-34, VR-5): крыло, масса пилота, погода, ветер, время и дата,
## место старта (площадка локации или точка на карте — MapPicker, FR-17), «Готово» / «Назад».
## Только выбор: в полёт — кнопкой «Лететь» главного меню. «Готово» — выбор наверх (done),
## «Назад» — без изменений. Открывается из главного меню; ничего не запускает само.

## «Готово»: выбранные настройки (главная сцена сохраняет их и возвращает в меню).
signal done(settings: FlightSettings)
signal closed

## Месяцы в родительном падеже («15 июля»).
const MONTHS: PackedStringArray = [
	"января",
	"февраля",
	"марта",
	"апреля",
	"мая",
	"июня",
	"июля",
	"августа",
	"сентября",
	"октября",
	"ноября",
	"декабря",
]

var settings: FlightSettings
## Путь к списку недавних мест (RecentPlaces) — переопределяется в тестах/скриншотах.
var recent_places_path: String = RecentPlaces.PATH

var _wings: PackedStringArray = []
var _weathers: PackedStringArray = []
var _sites: Array[Dictionary] = []
var _wing_opt: OptionButton
var _mass: HSlider
var _weather_opt: OptionButton
var _wind_opt: OptionButton
var _site_opt: OptionButton
var _hour: HSlider
var _month_opt: OptionButton
var _day: SpinBox
var _pick_label: Label
var _done_btn: Button
var _map_layer: Control
var _map: MapPicker
var _recent_section: VBoxContainer
var _recent_list: VBoxContainer
var _recent_edit_id: int = -1  ## запись, для которой сейчас открыт LineEdit переименования


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if settings == null:
		settings = FlightSettings.defaults()
	_build()
	_apply_settings()


## Показать выбор: settings — последний выбор или значения по умолчанию.
func set_settings(s: FlightSettings) -> void:
	settings = s.duplicate()
	if is_node_ready():
		_apply_settings()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var box := UiKit.centered_panel(self, float(ui.get("panel_width_px", 560)))
	UiKit.label(box, tr("Полёт"), "TitleLabel")
	UiKit.separator(box)

	_wing_opt = OptionButton.new()
	UiKit.row(box, tr("Крыло"), _wing_opt)
	_wings = Config.list_configs("wings")
	for w in _wings:
		_wing_opt.add_item(tr(String(Config.get_config(w).get("name", w.get_file()))))
	_wing_opt.item_selected.connect(_on_wing_selected)

	_mass = UiKit.slider_row(
		box, tr("Масса пилота"), 50, 120, float(ui.get("mass_step_kg", 1.0)), "%.0f " + tr("кг")
	)

	_weather_opt = OptionButton.new()
	UiKit.row(box, tr("Погода"), _weather_opt)
	_weathers = Config.list_configs("weather")
	for w in _weathers:
		_weather_opt.add_item(tr(String(Config.get_config(w).get("name", w.get_file()))))

	_wind_opt = OptionButton.new()
	UiKit.row(box, tr("Ветер"), _wind_opt)
	_wind_opt.add_item(tr("В лоб старту"))
	_wind_opt.add_item(tr("Направление из пресета"))
	_build_time(box)

	UiKit.separator(box)
	_site_opt = OptionButton.new()
	UiKit.row(box, tr("Старт"), _site_opt)
	_site_opt.item_selected.connect(func(_i: int) -> void: _clear_pick())
	var pick_row := HBoxContainer.new()
	pick_row.add_theme_constant_override("separation", 12)
	box.add_child(pick_row)
	UiKit.button(pick_row, tr("Выбрать на карте…"), _open_map)
	_pick_label = UiKit.label(pick_row, "", "HintLabel")
	_pick_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_build_recent(box)

	UiKit.separator(box)
	var bar := UiKit.button_bar(box)
	_done_btn = UiKit.button(bar, tr("Готово"), _on_done)
	_done_btn.custom_minimum_size.x = 160
	UiKit.button(bar, tr("Назад"), func() -> void: closed.emit())


func _apply_settings() -> void:
	var wi := maxi(_wings.find(settings.wing), 0)
	_wing_opt.select(wi)
	_on_wing_selected(wi)
	_weather_opt.select(maxi(_weathers.find(settings.weather), 0))
	_wind_opt.select(0 if settings.wind_mode == "into_site" else 1)
	_hour.value = SunClock.clamp_hour(settings.start_hour)
	_hour.value_changed.emit(_hour.value)
	_month_opt.select(clampi(settings.month, 1, 12) - 1)
	_on_month_selected(_month_opt.selected)
	_day.value = settings.day
	_fill_sites()
	_update_pick_label()
	_fill_recent()


func _on_wing_selected(i: int) -> void:
	var w: Dictionary = Config.get_config(_wings[i])
	var lo := float(w.get("pilot_mass_min_kg", 50.0))
	var hi := float(w.get("pilot_mass_max_kg", 120.0))
	var m := settings.pilot_mass_kg
	if m <= 0.0:
		m = float(Config.value("pilot", "mass_kg", 80.0))
	_mass.min_value = lo
	_mass.max_value = hi
	_mass.value = clampf(m, lo, hi)
	_mass.value_changed.emit(_mass.value)


## Время старта (шаг 15 мин, world.json → time.min_hour..max_hour) и дата (месяц, число).
func _build_time(box: Control) -> void:
	var t: Dictionary = Config.get_config("world").get("time", {})
	_hour = UiKit.slider_row(
		box,
		tr("Время старта"),
		float(t.get("min_hour", 6.0)),
		float(t.get("max_hour", 20.0)),
		0.25,
		"%.2f"
	)
	# подпись «13:00» вместо числа (обработчик UiKit подключён раньше — этот перезаписывает)
	var hour_label: Label = _hour.get_parent().get_child(1)
	_hour.value_changed.connect(func(x: float) -> void: hour_label.text = SunClock.format_hour(x))
	var date_row := HBoxContainer.new()
	date_row.add_theme_constant_override("separation", 10)
	_day = SpinBox.new()
	_day.min_value = 1
	_day.max_value = 31
	date_row.add_child(_day)
	_month_opt = OptionButton.new()
	_month_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for m in MONTHS:
		_month_opt.add_item(tr(m))
	_month_opt.item_selected.connect(_on_month_selected)
	date_row.add_child(_month_opt)
	UiKit.row(box, tr("Дата"), date_row)


func _on_month_selected(i: int) -> void:
	_day.max_value = SunClock.days_in_month(i + 1)


## Все старты всех локаций (Config.list_configs("locations")), сгруппированы по локациям.
func _fill_sites() -> void:
	_site_opt.clear()
	_sites.clear()
	for loc_name in Config.list_configs("locations"):
		var loc: Dictionary = Config.get_config(loc_name)
		var starts: Array = loc.get("start_sites", [])
		if starts.is_empty():
			continue
		_site_opt.add_separator(tr(String(loc.get("name", loc_name.get_file()))))
		for st: Dictionary in starts:
			_sites.append({"location": loc_name.get_file(), "site": String(st.get("id", ""))})
			_site_opt.add_item("   " + tr(String(st.get("name", st.get("id")))))
			_site_opt.set_item_metadata(_site_opt.item_count - 1, _sites.size() - 1)
	for i in _site_opt.item_count:
		var k: Variant = _site_opt.get_item_metadata(i)
		if k == null:
			continue
		var e: Dictionary = _sites[int(k)]
		if e.location == settings.location_id and e.site == settings.site_id:
			_site_opt.select(i)


func _collect() -> FlightSettings:
	var s := settings.duplicate()
	s.wing = _wings[_wing_opt.selected]
	s.pilot_mass_kg = _mass.value
	s.weather = _weathers[_weather_opt.selected]
	s.wind_mode = "into_site" if _wind_opt.selected == 0 else "preset"
	s.start_hour = _hour.value
	s.month = _month_opt.selected + 1
	s.day = int(_day.value)
	var k: Variant = null
	if _site_opt.selected >= 0:
		k = _site_opt.get_item_metadata(_site_opt.selected)
	if k != null:
		s.location_id = String(_sites[int(k)].location)
		s.site_id = String(_sites[int(k)].site)
	return s


func _on_done() -> void:
	settings = _collect()
	if settings.has_pick():
		var name := RecentPlaces.resolve_osm_name(settings.pick_lat, settings.pick_lon)
		RecentPlaces.add(settings.pick_lat, settings.pick_lon, name, recent_places_path)
	done.emit(settings)


# ---------------------------------------------------------------- карта


func _open_map() -> void:
	if _map_layer == null:
		_build_map()
	settings = _collect()
	var loc: Dictionary = Config.get_config("locations/" + settings.location_id)
	if settings.has_pick():
		_map.center_on(settings.pick_lat, settings.pick_lon)
	else:
		_map.center_on(float(loc.get("center_lat", 51.87)), float(loc.get("center_lon", 85.87)))
	_map_layer.visible = true


func _build_map() -> void:
	_map_layer = PanelContainer.new()
	_map_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_layer.offset_left = 40
	_map_layer.offset_top = 40
	_map_layer.offset_right = -40
	_map_layer.offset_bottom = -40
	add_child(_map_layer)
	var v := VBoxContainer.new()
	_map_layer.add_child(v)
	UiKit.label(
		v,
		tr(
			"Щёлкните по карте или введите координаты. Старт — на ближайшем склоне, вниз по склону."
		),
		"HintLabel"
	)
	_map = MapPicker.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_map)
	var bar := UiKit.button_bar(v)
	var ok := UiKit.button(bar, tr("Выбрать эту точку"), _on_map_ok)
	ok.disabled = true
	_map.point_picked.connect(func(_la: float, _lo: float) -> void: ok.disabled = false)
	UiKit.button(bar, tr("Отмена"), func() -> void: _map_layer.visible = false)


func _on_map_ok() -> void:
	if is_nan(_map.picked.x):
		return
	settings = _collect()
	settings.pick_lat = _map.picked.x
	settings.pick_lon = _map.picked.y
	_map_layer.visible = false
	_update_pick_label()


func _clear_pick() -> void:
	settings.pick_lat = NAN
	settings.pick_lon = NAN
	_update_pick_label()


func _update_pick_label() -> void:
	if settings.has_pick():
		_pick_label.text = tr("точка на карте: %.4f, %.4f") % [settings.pick_lat, settings.pick_lon]
	else:
		_pick_label.text = ""


# ------------------------------------------------------------ недавние места


## Блок «Недавние места» под выбором старта: пусто — блок скрыт (_fill_recent прячет секцию).
func _build_recent(box: Control) -> void:
	_recent_section = VBoxContainer.new()
	_recent_section.add_theme_constant_override("separation", 6)
	box.add_child(_recent_section)
	UiKit.label(_recent_section, tr("Недавние места"), "HeaderLabel")
	_recent_list = VBoxContainer.new()
	_recent_list.add_theme_constant_override("separation", 4)
	_recent_section.add_child(_recent_list)


func _fill_recent(reset_edit: bool = true) -> void:
	RecentPlaces.refresh_missing_names(recent_places_path)
	if reset_edit:
		_recent_edit_id = -1
	for c in _recent_list.get_children():
		c.queue_free()
	var places := RecentPlaces.list(recent_places_path)
	_recent_section.visible = not places.is_empty()
	for p: Dictionary in places:
		_recent_list.add_child(_build_recent_row(p))


func _build_recent_row(p: Dictionary) -> Control:
	var id := int(p.get("id", -1))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_btn := Button.new()
	var prefix := (tr("закреплено") + ": ") if bool(p.get("pinned", false)) else ""
	name_btn.text = prefix + RecentPlaces.display_name(p)
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.clip_text = true
	name_btn.pressed.connect(_select_recent.bind(p))
	row.add_child(name_btn)

	if _recent_edit_id == id:
		var edit := LineEdit.new()
		edit.text = RecentPlaces.display_name(p)
		edit.custom_minimum_size.x = 160
		edit.text_submitted.connect(_on_recent_rename.bind(id))
		row.add_child(edit)
		edit.grab_focus()
	else:
		UiKit.button(row, tr("Переименовать"), _on_recent_rename_start.bind(id))

	var pin_label := tr("Открепить") if bool(p.get("pinned", false)) else tr("Закрепить")
	UiKit.button(row, pin_label, _on_recent_toggle_pin.bind(id, not bool(p.get("pinned", false))))
	UiKit.button(row, tr("Убрать"), _on_recent_remove.bind(id))
	return row


func _select_recent(p: Dictionary) -> void:
	settings.pick_lat = float(p.get("lat", 0.0))
	settings.pick_lon = float(p.get("lon", 0.0))
	_update_pick_label()


func _on_recent_rename_start(id: int) -> void:
	_recent_edit_id = id
	_fill_recent(false)


func _on_recent_rename(new_name: String, id: int) -> void:
	RecentPlaces.rename(id, new_name, recent_places_path)
	_fill_recent()


func _on_recent_toggle_pin(id: int, pinned: bool) -> void:
	RecentPlaces.set_pinned(id, pinned, recent_places_path)
	_fill_recent()


func _on_recent_remove(id: int) -> void:
	RecentPlaces.remove(id, recent_places_path)
	_fill_recent()
