class_name MapPicker
extends Control
## Карта выбора места старта (FR-17, SM-К1/К2): растровая подложка OpenTopoMap (по умолчанию) или
## OSM standard с дисковым кешем, перетаскивание — панорама, колесо — масштаб, щелчок — выбор
## точки, поле ввода «широта, долгота». У выбранной точки — высота над уровнем моря (Terrarium z12).
## Параметры — configs/world.json → map_picker. Сигналы point_picked(lat, lon), elevation_ready.

signal point_picked(lat: float, lon: float)
## Высота выбранной точки получена (h_m — NAN, если данных нет). Для устаревшей точки не приходит.
signal elevation_ready(lat: float, lon: float, h_m: float)

const TILE_PX := 256

var center_lat: float = 51.87
var center_lon: float = 85.87
var zoom: float = 9.0
## Выбранная точка (NAN — ещё не выбрана).
var picked := Vector2(NAN, NAN)
## Высота выбранной точки, м над уровнем моря (NAN — не известна или точка не выбрана).
var picked_elevation_m: float = NAN

var _cfg: Dictionary
var _tiles := {}  ## Vector4i(слой, z, x, y) → ImageTexture (null — грузится)
var _loader: TerrariumLoader
var _raster: RasterTileLoader
var _basemaps: Array = []
var _layer := 0
var _layer_btn: OptionButton
var _overlay: Control
var _edit: LineEdit
var _drag_from := Vector2.ZERO
var _drag_moved := 0.0
var _dragging := false


func _ready() -> void:
	_cfg = Config.get_config("world").get("map_picker", {})
	zoom = float(_cfg.start_zoom)
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_basemaps = _cfg.get("basemaps", [])
	resized.connect(queue_redraw)
	_loader = TerrariumLoader.new()
	add_child(_loader)
	_raster = RasterTileLoader.new()
	add_child(_raster)
	# Маркер и подписи — отдельный узел поверх тайлов.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	# тёмная плашка: поле и кнопки читаются на светлой карте
	var bar := PanelContainer.new()
	bar.position = Vector2(8, 8)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.12, 0.16, 0.9)
	sb.set_content_margin_all(4)
	sb.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("panel", sb)
	add_child(bar)
	var box := HBoxContainer.new()
	bar.add_child(box)
	_edit = LineEdit.new()
	_edit.placeholder_text = tr("map_coords_placeholder")
	_edit.custom_minimum_size.x = 220
	_edit.text_submitted.connect(func(_t: String) -> void: _submit_coords())
	box.add_child(_edit)
	var btn := Button.new()
	btn.text = tr("map_pick")
	btn.pressed.connect(_submit_coords)
	box.add_child(btn)
	_layer_btn = OptionButton.new()
	for m: Dictionary in _basemaps:
		_layer_btn.add_item(tr(String(m.name_key)))
	_layer_btn.item_selected.connect(_on_layer_selected)
	box.add_child(_layer_btn)


## Показать точку на карте (без выбора).
func center_on(lat: float, lon: float, new_zoom: float = -1.0) -> void:
	center_lat = lat
	center_lon = lon
	if new_zoom > 0.0:
		zoom = clampf(new_zoom, float(_cfg.min_zoom), float(_cfg.max_zoom))
	queue_redraw()
	_overlay.queue_redraw()


## Выбрать точку (как щелчком).
func pick(lat: float, lon: float) -> void:
	picked = Vector2(lat, lon)
	picked_elevation_m = NAN
	_edit.text = "%.5f, %.5f" % [lat, lon]
	_overlay.queue_redraw()
	point_picked.emit(lat, lon)
	var h: float = await _loader.elevation_at(lat, lon)
	if picked != Vector2(lat, lon):
		return  # точку сменили, пока шёл запрос
	picked_elevation_m = h
	_overlay.queue_redraw()
	elevation_ready.emit(lat, lon, h)


## Подпись высоты: «<h> м» (целое) или «—».
static func elevation_text(h_m: float) -> String:
	return "—" if is_nan(h_m) else "%d м" % roundi(h_m)


func _on_layer_selected(i: int) -> void:
	_layer = i
	queue_redraw()


# ---------- проекция web-mercator: мировые пиксели на уровне z ----------


static func latlon_to_world_px(lat: float, lon: float, z: float) -> Vector2:
	var world := TILE_PX * pow(2.0, z)
	var lat_r := deg_to_rad(clampf(lat, -85.05, 85.05))
	return Vector2(
		(lon + 180.0) / 360.0 * world, (1.0 - log(tan(lat_r) + 1.0 / cos(lat_r)) / PI) / 2.0 * world
	)


static func world_px_to_latlon(p: Vector2, z: float) -> Vector2:
	var world := TILE_PX * pow(2.0, z)
	var lon := p.x / world * 360.0 - 180.0
	var lat := rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * p.y / world))))
	return Vector2(lat, lon)


func screen_to_latlon(sp: Vector2) -> Vector2:
	var c := latlon_to_world_px(center_lat, center_lon, zoom)
	return world_px_to_latlon(c + sp - size / 2.0, zoom)


func latlon_to_screen(lat: float, lon: float) -> Vector2:
	var c := latlon_to_world_px(center_lat, center_lon, zoom)
	return latlon_to_world_px(lat, lon, zoom) - c + size / 2.0


# ---------- отрисовка ----------


func _draw() -> void:
	if _basemaps.is_empty():
		return
	var level := clampi(int(round(zoom)), 0, int(_cfg.max_zoom))
	var scale_f := pow(2.0, zoom - level)
	var tile_size := TILE_PX * scale_f
	var c := latlon_to_world_px(center_lat, center_lon, level) * scale_f
	var top_left := c - size / 2.0
	var n := 1 << level
	var tx0 := floori(top_left.x / tile_size)
	var ty0 := maxi(0, floori(top_left.y / tile_size))
	var tx1 := floori((top_left.x + size.x) / tile_size)
	var ty1 := mini(n - 1, floori((top_left.y + size.y) / tile_size))
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			var key := Vector4i(_layer, level, posmod(tx, n), ty)
			var rect := Rect2(Vector2(tx, ty) * tile_size - top_left, Vector2(tile_size, tile_size))
			if _tiles.has(key):
				if _tiles[key] != null:
					draw_texture_rect(_tiles[key], rect, false)
			else:
				_evict_if_needed(level)
				_tiles[key] = null
				_load_tile(key)


## Не держать в памяти слишком много тайлов: выбросить тайлы других масштабов.
func _evict_if_needed(level: int) -> void:
	if _tiles.size() < int(_cfg.max_tiles_in_memory):
		return
	for k: Vector4i in _tiles.keys():
		if (k.x != _layer or k.y != level) and _tiles[k] != null:
			_tiles.erase(k)


func _load_tile(key: Vector4i) -> void:
	var img: Image = await _raster.fetch_tile(_basemaps[key.x], key.y, key.z, key.w)
	if img == null:
		_tiles.erase(key)
		return
	_tiles[key] = ImageTexture.create_from_image(img)  # без мипов: LINEAR
	queue_redraw()


func _draw_overlay() -> void:
	if not is_nan(picked.x):
		var p := latlon_to_screen(picked.x, picked.y)
		var a: Array = _cfg.marker_color
		var r := float(_cfg.marker_radius_px)
		_overlay.draw_circle(p, r, Color(float(a[0]), float(a[1]), float(a[2])))
		_overlay.draw_arc(p, r, 0.0, TAU, 24, Color.WHITE, 2.0)
	var font := get_theme_default_font()
	if not is_nan(picked.x):
		var p := latlon_to_screen(picked.x, picked.y)
		var t := "%.4f, %.4f · %s" % [picked.x, picked.y, elevation_text(picked_elevation_m)]
		_label(font, p + Vector2(12, -10), t, 15)
	if not _basemaps.is_empty():
		var att := String(_basemaps[_layer].attribution)
		var w := font.get_string_size(att, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		_label(font, Vector2(size.x - w - 14, size.y - 8), att, 12)


## Подпись на полупрозрачной светлой подложке (читается на любой карте).
func _label(font: Font, at: Vector2, text: String, fs: int) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_overlay.draw_rect(Rect2(at + Vector2(-4, -fs - 1), Vector2(w + 8, fs + 7)), Color(1, 1, 1, 0.8))
	_overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.9))


# ---------- ввод ----------


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_from = mb.position
				_drag_moved = 0.0
			else:
				_dragging = false
				if _drag_moved <= float(_cfg.click_max_drag_px):
					var ll := screen_to_latlon(mb.position)
					pick(ll.x, ll.y)
			accept_event()
		elif (
			mb.pressed
			and (
				mb.button_index == MOUSE_BUTTON_WHEEL_UP
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
			)
		):
			var step := (
				float(_cfg.zoom_step) * (1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
			)
			_zoom_at(mb.position, zoom + step)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_drag_moved += mm.relative.length()
		var c := latlon_to_world_px(center_lat, center_lon, zoom) - mm.relative
		var ll := world_px_to_latlon(c, zoom)
		center_on(ll.x, ll.y)
		accept_event()


func _zoom_at(sp: Vector2, new_zoom: float) -> void:
	new_zoom = clampf(new_zoom, float(_cfg.min_zoom), float(_cfg.max_zoom))
	var anchor := screen_to_latlon(sp)
	zoom = new_zoom
	# точка под курсором остаётся на месте
	var c := latlon_to_world_px(anchor.x, anchor.y, zoom) - (sp - size / 2.0)
	var ll := world_px_to_latlon(c, zoom)
	center_on(ll.x, ll.y)


func _submit_coords() -> void:
	var parts := _edit.text.replace(";", ",").split(",", false)
	if (
		parts.size() != 2
		or not parts[0].strip_edges().is_valid_float()
		or not parts[1].strip_edges().is_valid_float()
	):
		_edit.modulate = Color(1, 0.5, 0.5)
		return
	_edit.modulate = Color.WHITE
	var lat := clampf(float(parts[0]), -85.0, 85.0)
	var lon := wrapf(float(parts[1]), -180.0, 180.0)
	center_on(lat, lon)
	pick(lat, lon)
