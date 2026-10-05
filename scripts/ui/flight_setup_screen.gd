class_name FlightSetupScreen
extends Control
## Экран «Полёт…» (FR-27, FR-34, VR-5): класс и модель крыла (строка описания), масса пилота,
## прогноз погоды (FR-16: температура днём, ветер на старте, откуда ветер, облачность),
## время и дата,
## место старта (площадка локации или точка на карте — MapPicker, FR-17), «Готово» / «Назад».
## Только выбор: в полёт — кнопкой «Лететь» главного меню. «Готово» — выбор наверх (done),
## «Назад» — без изменений. Открывается из главного меню; ничего не запускает само.

## «Готово»: выбранные настройки (главная сцена сохраняет их и возвращает в меню).
signal done(settings: FlightSettings)
signal closed

## Месяцы: ключи locale/ui.csv (по-русски — в родительном падеже, «15 июля»).
const MONTHS: PackedStringArray = [
	"month_1",
	"month_2",
	"month_3",
	"month_4",
	"month_5",
	"month_6",
	"month_7",
	"month_8",
	"month_9",
	"month_10",
	"month_11",
	"month_12",
]
## Румбы «откуда ветер» (0°, 45°, …): ключи locale/ui.csv.
const COMPASS: PackedStringArray = [
	"compass_n",
	"compass_ne",
	"compass_e",
	"compass_se",
	"compass_s",
	"compass_sw",
	"compass_w",
	"compass_nw",
]

## Класс → модель (docs/archive/plan/wings-lineup.md §6): модель, выбранная последней в группе за сеанс.
static var _last_in_group: Dictionary = {}

var settings: FlightSettings
## Путь к списку недавних мест (RecentPlaces) — переопределяется в тестах/скриншотах.
var recent_places_path: String = RecentPlaces.PATH
## Каталог «Популярные места» (PP-К1); файла нет — кнопка скрыта. Тесты подставляют путь до _ready.
var popular_places_path: String = ""

var _groups: Array[Dictionary] = []
var _wings: PackedStringArray = []  ## модели выбранного класса ("wings/<id>")
var _class_opt: OptionButton
var _wing_info: Label
var _skies: Array = []
var _sites: Array[Dictionary] = []
var _wing_opt: OptionButton
var _mass: HSlider
var _temp: HSlider
var _temp_hint: Label
var _wind: HSlider
var _dir_opt: OptionButton
var _dir_hint: Label
var _sky_opt: OptionButton
var _site_opt: OptionButton
var _hour: OptionButton
var _hours: PackedFloat32Array = []  ## start_hours(); индекс совпадает с пунктами _hour
var _month_opt: OptionButton
var _day: SpinBox
var _pick_label: Label
var _done_btn: Button
var _map_layer: Control
var _map: MapPicker
var _pick_elev_m: float = NAN
var _elev_asked := Vector2(NAN, NAN)
var _elev_loader: TerrariumLoader
var _recent_section: VBoxContainer
var _recent_list: VBoxContainer
var _places_catalog: Dictionary = {}
var _places_btn: Button
var _places_window: PopularPlacesWindow
var _picked_place_name := ""  ## название места из «Популярных мест» — идёт в «Недавние» вместо геокодера
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
	_picked_place_name = ""
	if is_node_ready():
		_apply_settings()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var box := UiKit.centered_panel(self, float(ui.get("panel_width_px", 560)))
	UiKit.label(box, tr("setup_title"), "TitleLabel")
	UiKit.separator(box)

	_build_wing(box)

	_mass = UiKit.slider_row(
		box, tr("setup_pilot_mass"), 50, 120, float(ui.get("mass_step_kg", 1.0)), "%.0f " + tr("unit_kg")
	)

	_build_forecast(box)
	_build_time(box)

	UiKit.separator(box)
	_site_opt = OptionButton.new()
	UiKit.row(box, tr("setup_launch"), _site_opt)
	_site_opt.item_selected.connect(func(_i: int) -> void: _clear_pick())
	_site_opt.item_selected.connect(func(_i: int) -> void: _update_dir_hint())
	var pick_row := HBoxContainer.new()
	pick_row.add_theme_constant_override("separation", 12)
	box.add_child(pick_row)
	UiKit.button(pick_row, tr("setup_pick_on_map"), _open_map)
	_places_btn = UiKit.button(pick_row, tr("setup_popular_places"), _open_places)
	_places_btn.visible = _load_places()
	_pick_label = UiKit.label(pick_row, "", "HintLabel")
	_pick_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_build_recent(box)

	UiKit.separator(box)
	var bar := UiKit.button_bar(box)
	_done_btn = UiKit.button(bar, tr("setup_done"), _on_done)
	_done_btn.custom_minimum_size.x = 160
	UiKit.button(bar, tr("common_back"), func() -> void: closed.emit())


func _apply_settings() -> void:
	_select_wing(settings.wing)
	_temp.value = roundf(settings.temperature_c)
	_temp.value_changed.emit(_temp.value)
	_wind.value = roundf(settings.wind_speed_kmh / 3.6)
	_wind.value_changed.emit(_wind.value)
	_dir_opt.select(
		0 if settings.wind_into_launch else 1 + posmod(roundi(settings.wind_from_deg / 45.0), 8)
	)
	_sky_opt.select(maxi(_skies.find(settings.sky), 0))
	_hour.select(maxi(_hours.find(SunClock.nearest_start_hour(settings.start_hour)), 0))
	_month_opt.select(clampi(settings.month, 1, 12) - 1)
	_on_month_selected(_month_opt.selected)
	_day.value = settings.day
	_fill_sites()
	_update_pick_label()
	_fill_recent()


## Класс крыла (группы WingCatalog, с диапазоном качества и ветра), модель и строка описания.
func _build_wing(box: Control) -> void:
	_class_opt = OptionButton.new()
	UiKit.row(box, tr("setup_wing_class"), _class_opt)
	_groups = WingCatalog.groups()
	for g in _groups:
		var id := String(g.get("id", ""))
		var glide := WingCatalog.glide_range(id)
		var wind := WingCatalog.wind_range(id)
		_class_opt.add_item(
			tr("setup_wing_class_item")
			% [
				tr(String(g.get("name", id))),
				tr("setup_wing_glide") % _num_range(glide),
				tr("setup_wing_wind_limit") % [_num_range(wind), tr("unit_ms")],
			]
		)
	_class_opt.item_selected.connect(_on_class_selected)
	_wing_opt = OptionButton.new()
	UiKit.row(box, tr("setup_wing_model"), _wing_opt)
	_wing_opt.item_selected.connect(_on_wing_selected)
	_wing_info = UiKit.label(box, "", "HintLabel")
	_wing_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


## Класс и модель по пути крыла ("wings/<id>"); неизвестное крыло — первая модель первого класса.
func _select_wing(wing: String) -> void:
	var gi := 0
	var group := WingCatalog.group_of(wing)
	for i in _groups.size():
		if String(_groups[i].get("id", "")) == group:
			gi = i
	_class_opt.select(gi)
	_fill_models(gi, wing)


func _on_class_selected(i: int) -> void:
	_fill_models(i, String(_last_in_group.get(String(_groups[i].get("id", "")), "")))


## Модели класса i (порядок WingCatalog); выбрана wing, если она в классе, иначе первая.
func _fill_models(i: int, wing: String) -> void:
	_wing_opt.clear()
	_wings = WingCatalog.wings_in_group(String(_groups[i].get("id", ""))) if i >= 0 else []
	for w in _wings:
		_wing_opt.add_item(tr(String(Config.get_config(w).get("name", w.get_file()))))
	if _wings.is_empty():
		_wing_info.text = ""
		return
	var wi := maxi(_wings.find(wing), 0)
	_wing_opt.select(wi)
	_on_wing_selected(wi)


func _on_wing_selected(i: int) -> void:
	var w: Dictionary = Config.get_config(_wings[i])
	_last_in_group[String(w.get("group", ""))] = _wings[i]
	_wing_info.text = _wing_info_text(w)
	var lo := float(w.get("pilot_mass_min_kg", 50.0))
	var hi := float(w.get("pilot_mass_max_kg", 120.0))
	var m := settings.pilot_mass_kg
	if m <= 0.0:
		m = float(Config.value("pilot", "mass_kg", 80.0))
	_mass.min_value = lo
	_mass.max_value = hi
	_mass.value = clampf(m, lo, hi)
	_mass.value_changed.emit(_mass.value)


## «жёсткая поперечина · качество 13 · ветер 10–12 м/с · 14,5 м² · пилот 65–95 кг · ≈ 2003 · мачтовое»
func _wing_info_text(w: Dictionary) -> String:
	var parts: PackedStringArray = [
		tr(WingCatalog.class_name_key(w)),
		tr("setup_wing_glide") % _num(WingCatalog.best_glide(w)),
		tr("setup_wing_wind_limit") % [_num_range(WingCatalog.wind_limit(w)), tr("unit_ms")],
		tr("setup_wing_area") % _num(float(w.get("area_m2", 0.0))),
		(
			tr("setup_wing_pilot")
			% [
				_num(float(w.get("pilot_mass_min_kg", 0.0))),
				_num(float(w.get("pilot_mass_max_kg", 0.0))),
				tr("unit_kg"),
			]
		),
	]
	var era := String(w.get("era", ""))
	if era != "":
		# «1980-е» в конфиге по-русски; суффикс десятилетия — из перевода («1980s»)
		parts.append(era.replace("-е", tr("setup_wing_decade_suffix")))
	parts.append(tr("setup_wing_kingpost" if bool(w.get("kingpost", true)) else "setup_wing_topless"))
	return " · ".join(parts)


## Число для подписи: без «.0», с десятичным знаком языка («14,5» / «14.5»).
func _num(x: float) -> String:
	var s := "%.1f" % x
	if s.ends_with(".0"):
		s = s.trim_suffix(".0")
	return s.replace(".", tr("setup_decimal_point"))


## Диапазон «7,3–9» (или одно число, если края совпадают).
func _num_range(r: Vector2) -> String:
	return _num(r.x) if is_equal_approx(r.x, r.y) else "%s–%s" % [_num(r.x), _num(r.y)]


## Час старта — фиксированный список (AM-06, world.json → time.start_hours) и дата (месяц, число).
func _build_time(box: Control) -> void:
	_hours = SunClock.start_hours()
	_hour = OptionButton.new()
	for h in _hours:
		_hour.add_item(SunClock.format_hour(h))
	UiKit.row(box, tr("setup_start_time"), _hour)
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
	UiKit.row(box, tr("setup_date"), date_row)


func _on_month_selected(i: int) -> void:
	_day.max_value = SunClock.days_in_month(i + 1)
	# Смена месяца не двигает ползунок (выбор пилота важнее) — только подсказку «обычно…».
	if _temp_hint != null:
		_temp_hint.text = (
			tr("setup_temperature_typical") % roundi(WeatherModel.typical_max_c(i + 1))
		)


## Прогноз (FR-16): температура днём, ветер на старте (м/с), откуда ветер, облачность.
func _build_forecast(box: Control) -> void:
	var ui: Dictionary = WeatherModel.config().get("ui", {})
	var t_range: Array = ui.get("temperature_c", [0, 40, 1])
	_temp = UiKit.slider_row(
		box,
		tr("setup_temperature"),
		float(t_range[0]),
		float(t_range[1]),
		float(t_range[2]),
		tr("setup_temperature_value")
	)
	_temp_hint = UiKit.label(box, "", "HintLabel")
	_temp_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var wr := WingCatalog.wind_menu_range()
	_wind = UiKit.slider_row(
		box, tr("setup_wind"), wr.x, wr.y, wr.z, "%.0f"
	)
	var wind_label: Label = _wind.get_parent().get_child(1)
	wind_label.custom_minimum_size.x = 150
	_wind.value_changed.connect(
		func(x: float) -> void:
			wind_label.text = (
				tr("setup_wind_calm")
				if x < 0.5
				else tr("setup_wind_speed_value") % [roundi(x), roundi(x * 3.6)]
			)
			_dir_opt.disabled = x < 0.5
	)
	_dir_opt = OptionButton.new()
	_dir_opt.add_item(tr("setup_wind_into_launch"))
	for k in COMPASS:
		_dir_opt.add_item(tr(k))
	UiKit.row(box, tr("setup_wind_from"), _dir_opt)
	_dir_hint = UiKit.label(box, "", "HintLabel")
	_dir_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sky_opt = OptionButton.new()
	_skies = WeatherModel.config().get("sky", {}).get("options", ["clear"])
	for k: String in _skies:
		var key := "setup_sky_" + k  # setup_sky_clear / _partly / _overcast
		_sky_opt.add_item(tr(key))
	UiKit.row(box, tr("setup_sky"), _sky_opt)


## Подсказка «встречный для этого старта — З» для выбранной площадки (точка с карты — без неё).
func _update_dir_hint() -> void:
	if _dir_hint == null:
		return
	_dir_hint.text = ""
	if settings.has_pick() or _site_opt.selected < 0:
		return
	var k: Variant = _site_opt.get_item_metadata(_site_opt.selected)
	if k == null:
		return
	var e: Dictionary = _sites[int(k)]
	var loc: Dictionary = Config.get_config("locations/" + String(e.location))
	for st: Dictionary in loc.get("start_sites", []):
		if String(st.get("id", "")) == String(e.site):
			var i := posmod(roundi(float(st.get("heading_deg", 0.0)) / 45.0), 8)
			_dir_hint.text = tr("setup_wind_launch_faces") % tr(COMPASS[i])


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
	_update_dir_hint()


func _collect() -> FlightSettings:
	var s := settings.duplicate()
	s.wing = _wings[_wing_opt.selected]
	s.pilot_mass_kg = _mass.value
	s.temperature_c = _temp.value
	s.wind_speed_kmh = _wind.value * 3.6
	s.wind_into_launch = _dir_opt.selected <= 0
	if not s.wind_into_launch:
		s.wind_from_deg = float(_dir_opt.selected - 1) * 45.0
	s.sky = String(_skies[maxi(_sky_opt.selected, 0)])
	s.start_hour = _hours[maxi(_hour.selected, 0)]
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
		var name := (
			_picked_place_name
			if _picked_place_name != ""
			else RecentPlaces.resolve_osm_name(settings.pick_lat, settings.pick_lon)
		)
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
			"map_hint"
		),
		"HintLabel"
	)
	_map = MapPicker.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_map)
	var bar := UiKit.button_bar(v)
	var ok := UiKit.button(bar, tr("map_pick_this_point"), _on_map_ok)
	ok.disabled = true
	_map.point_picked.connect(func(_la: float, _lo: float) -> void: ok.disabled = false)
	_map.elevation_ready.connect(_on_map_elevation)
	UiKit.button(bar, tr("common_cancel"), func() -> void: _map_layer.visible = false)


func _on_map_ok() -> void:
	if is_nan(_map.picked.x):
		return
	settings = _collect()
	settings.pick_lat = _map.picked.x
	settings.pick_lon = _map.picked.y
	_picked_place_name = ""
	_pick_elev_m = _map.picked_elevation_m
	_map_layer.visible = false
	_update_pick_label()


## Высота пришла после «Выбрать эту точку» — обновить подпись, если точка та же.
func _on_map_elevation(lat: float, lon: float, h_m: float) -> void:
	if settings.has_pick() and is_equal_approx(settings.pick_lat, lat) and is_equal_approx(settings.pick_lon, lon):
		_pick_elev_m = h_m
		_update_pick_label()


func _clear_pick() -> void:
	_picked_place_name = ""
	settings.pick_lat = NAN
	settings.pick_lon = NAN
	_pick_elev_m = NAN
	_update_pick_label()


## Высота точки из recent/сохранённых настроек: запрос по Terrarium (сеть/кеш), устаревший ответ отбрасывается.
func _lookup_pick_elevation() -> void:
	var ll := Vector2(settings.pick_lat, settings.pick_lon)
	_elev_asked = ll
	if _elev_loader == null:
		_elev_loader = TerrariumLoader.new()
		add_child(_elev_loader)
	var h: float = await _elev_loader.elevation_at(ll.x, ll.y)
	if _elev_asked == ll and settings.has_pick() and Vector2(settings.pick_lat, settings.pick_lon) == ll:
		_pick_elev_m = h
		_update_pick_label()


func _update_pick_label() -> void:
	_update_dir_hint()
	if settings.has_pick() and is_nan(_pick_elev_m) and _elev_asked != Vector2(settings.pick_lat, settings.pick_lon):
		_lookup_pick_elevation()
	if settings.has_pick():
		_pick_label.text = (
			tr("setup_map_point")
			% [settings.pick_lat, settings.pick_lon, MapPicker.elevation_text(_pick_elev_m)]
		)
	else:
		_pick_label.text = ""


# ------------------------------------------------------------ недавние места


## Блок «Недавние места» под выбором старта: пусто — блок скрыт (_fill_recent прячет секцию).
func _build_recent(box: Control) -> void:
	_recent_section = VBoxContainer.new()
	_recent_section.add_theme_constant_override("separation", 6)
	box.add_child(_recent_section)
	UiKit.label(_recent_section, tr("recent_title"), "HeaderLabel")
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
	var prefix := (tr("recent_pinned") + ": ") if bool(p.get("pinned", false)) else ""
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
		UiKit.button(row, tr("recent_rename"), _on_recent_rename_start.bind(id))

	var pin_label := tr("recent_unpin") if bool(p.get("pinned", false)) else tr("recent_pin")
	UiKit.button(row, pin_label, _on_recent_toggle_pin.bind(id, not bool(p.get("pinned", false))))
	UiKit.button(row, tr("recent_remove"), _on_recent_remove.bind(id))
	return row


func _select_recent(p: Dictionary) -> void:
	_picked_place_name = ""
	_pick_elev_m = NAN
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


# ------------------------------------------------------- популярные места


## Каталог из popular_places_path (пусто — путь из configs/ui.json); true, если в нём есть места.
func _load_places() -> bool:
	var path := popular_places_path
	if path == "":
		path = String(Config.get_config("ui").get("popular_places_path", ""))
	_places_catalog = (
		PopularPlaces.load_catalog(path) if FileAccess.file_exists(path) else {"takeoffs": []}
	)
	return not (_places_catalog.get("takeoffs", []) as Array).is_empty()


func _open_places() -> void:
	if _places_window == null:
		_places_window = PopularPlacesWindow.new()
		_places_window.place_chosen.connect(_on_place_chosen)
		add_child(_places_window)
	_places_window.open(_places_catalog)


## Выбор места — та же точка старта, что с карты и из «Недавних мест»; высоту подтянет подпись.
func _on_place_chosen(p: Dictionary) -> void:
	_pick_elev_m = NAN
	settings.pick_lat = float(p.get("lat", 0.0))
	settings.pick_lon = float(p.get("lon", 0.0))
	_picked_place_name = String(p.get("name", ""))
	_update_pick_label()
