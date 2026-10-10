class_name PlacePickRow
extends HBoxContainer
## Выбор места старта: «Выбрать на карте», «Популярные места» и подпись текущего выбора. Общий для
## «Настроек полёта» и экрана сети. Работает на общем объекте settings (pick_lat/lon либо
## location_id/site_id); о любом изменении сообщает changed.

signal changed

var settings: FlightSettings
## Название места из «Популярных мест» — идёт в «Недавние» вместо геокодера.
var picked_place_name := ""
var pick_elev_m: float = NAN
var catalog: Dictionary = {}
var places_btn: Button
var places_window: PopularPlacesWindow
var pick_label: Label

var _overlay: Control
var _map_layer: Control
var _map: MapPicker
var _elev_asked := Vector2(NAN, NAN)
var _elev_loader: TerrariumLoader


## Кнопки и подпись — в этот ряд; окна карты и каталога — в overlay (во весь экран, не в контейнер).
## path — каталог «Популярных мест» (пусто — из configs/ui.json).
func build(overlay: Control, path: String = "") -> void:
	_overlay = overlay
	add_theme_constant_override("separation", 12)
	UiKit.button(self, tr("setup_pick_on_map"), _open_map)
	places_btn = UiKit.button(self, tr("setup_popular_places"), _open_places)
	places_btn.visible = _load_places(path)
	pick_label = UiKit.label(self, "", "HintLabel")
	pick_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER


## Старт встроенного места из settings (пустой site_id — первый); точка с карты — {}.
func builtin_site() -> Dictionary:
	if settings == null or settings.has_pick():
		return {}
	var starts: Array = Locations.config(settings.location_id).get("start_sites", [])
	for st: Dictionary in starts:
		if String(st.get("id", "")) == settings.site_id:
			return st
	return starts[0] if not starts.is_empty() else {}


## Подпись по текущим settings (и запрос высоты точки, если её ещё нет).
func refresh() -> void:
	if settings.has_pick() and is_nan(pick_elev_m) and _elev_asked != Vector2(settings.pick_lat, settings.pick_lon):
		_lookup_elevation()
	if settings.has_pick():
		pick_label.text = (
			tr("setup_map_point")
			% [settings.pick_lat, settings.pick_lon, MapPicker.elevation_text(pick_elev_m)]
		)
	else:
		var st := builtin_site()
		pick_label.text = tr(String(st.get("name", ""))) if not st.is_empty() else ""
	changed.emit()


## Выбрана точка не картой и не каталогом (например, «Недавние места»).
func set_pick(lat: float, lon: float) -> void:
	picked_place_name = ""
	pick_elev_m = NAN
	settings.pick_lat = lat
	settings.pick_lon = lon
	refresh()


# ---------------------------------------------------------------- карта


func _open_map() -> void:
	if _map_layer == null:
		_build_map()
	var loc: Dictionary = Locations.config(settings.location_id)
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
	_overlay.add_child(_map_layer)
	var v := VBoxContainer.new()
	_map_layer.add_child(v)
	UiKit.label(v, tr("map_hint"), "HintLabel")
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
	settings.pick_lat = _map.picked.x
	settings.pick_lon = _map.picked.y
	picked_place_name = ""
	pick_elev_m = _map.picked_elevation_m
	_map_layer.visible = false
	refresh()


## Высота пришла после «Выбрать эту точку» — обновить подпись, если точка та же.
func _on_map_elevation(lat: float, lon: float, h_m: float) -> void:
	if settings.has_pick() and is_equal_approx(settings.pick_lat, lat) and is_equal_approx(settings.pick_lon, lon):
		pick_elev_m = h_m
		refresh()


## Высота точки из recent/сохранённых настроек: запрос по Terrarium (сеть/кеш), устаревший ответ отбрасывается.
func _lookup_elevation() -> void:
	var ll := Vector2(settings.pick_lat, settings.pick_lon)
	_elev_asked = ll
	if _elev_loader == null:
		_elev_loader = TerrariumLoader.new()
		add_child(_elev_loader)
	var h: float = await _elev_loader.elevation_at(ll.x, ll.y)
	if _elev_asked == ll and settings.has_pick() and Vector2(settings.pick_lat, settings.pick_lon) == ll:
		pick_elev_m = h
		refresh()


# ------------------------------------------------------- популярные места


## Каталог из path (пусто — путь из configs/ui.json); true, если в нём есть места.
func _load_places(path: String) -> bool:
	if path == "":
		path = String(Config.get_config("ui").get("popular_places_path", ""))
	catalog = PopularPlaces.load_catalog(path) if FileAccess.file_exists(path) else {"takeoffs": []}
	return not (catalog.get("takeoffs", []) as Array).is_empty()


func _open_places() -> void:
	if places_window == null:
		places_window = PopularPlacesWindow.new()
		places_window.place_chosen.connect(choose_place)
		_overlay.add_child(places_window)
	places_window.open(catalog)


## Выбор места каталога. Встроенное (location+site) — его рельеф и точный старт; остальное — точка
## старта, как с карты и из «Недавних мест» (высоту подтянет подпись).
func choose_place(p: Dictionary) -> void:
	pick_elev_m = NAN
	if p.has("location") and p.has("site"):
		picked_place_name = ""
		settings.location_id = String(p.location)
		settings.site_id = String(p.site)
		settings.pick_lat = NAN
		settings.pick_lon = NAN
		refresh()
		return
	settings.pick_lat = float(p.get("lat", 0.0))
	settings.pick_lon = float(p.get("lon", 0.0))
	picked_place_name = String(p.get("name", ""))
	refresh()
