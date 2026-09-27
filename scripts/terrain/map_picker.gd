class_name MapPicker
extends Control
## Карта выбора места старта (FR-17, минимальный вариант): отмывка рельефа из тайлов Terrarium
## (те же, что грузит рельеф; кеш общий), перетаскивание — панорама, колесо — масштаб,
## щелчок — выбор точки, поле ввода «широта, долгота». Параметры — configs/world.json → map_picker.
## Сигнал point_picked(lat, lon). Векторную карту (martin) можно подложить позже вместо отмывки.

signal point_picked(lat: float, lon: float)

const TILE_PX := 256
const SHADER := preload("res://scripts/terrain/map_hillshade.gdshader")

var center_lat: float = 51.87
var center_lon: float = 85.87
var zoom: float = 9.0
## Выбранная точка (NAN — ещё не выбрана).
var picked := Vector2(NAN, NAN)

var _cfg: Dictionary
var _tiles := {}  ## Vector3i(z, x, y) → ImageTexture (null — грузится)
var _loader: TerrariumLoader
var _overlay: Control
var _edit: LineEdit
var _drag_from := Vector2.ZERO
var _drag_moved := 0.0
var _dragging := false


func _ready() -> void:
	_cfg = Config.get_config("world").get("map_picker", {})
	zoom = float(_cfg.start_zoom)
	clip_contents = true
	# RGB-кодированные высоты нельзя интерполировать
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	var az := deg_to_rad(float(_cfg.light_azimuth_deg))
	var el := deg_to_rad(float(_cfg.light_elevation_deg))
	# в координатах экрана: x — восток, y — юг, z — вверх
	mat.set_shader_parameter("light_dir", Vector3(sin(az) * cos(el), -cos(az) * cos(el), sin(el)))
	mat.set_shader_parameter("exaggeration", float(_cfg.exaggeration))
	for k in ["low_color", "high_color", "snow_color", "water_color"]:
		var a: Array = _cfg[k]
		mat.set_shader_parameter(k, Color(float(a[0]), float(a[1]), float(a[2])))
	for k in ["low_height_m", "high_height_m", "snow_height_m"]:
		mat.set_shader_parameter(k, float(_cfg[k]))
	material = mat
	resized.connect(queue_redraw)
	_loader = TerrariumLoader.new()
	add_child(_loader)
	# Маркер и подписи — отдельный узел без шейдера отмывки.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	var box := HBoxContainer.new()
	box.position = Vector2(8, 8)
	add_child(box)
	_edit = LineEdit.new()
	_edit.placeholder_text = tr("map_coords_placeholder")
	_edit.custom_minimum_size.x = 220
	_edit.text_submitted.connect(func(_t: String) -> void: _submit_coords())
	box.add_child(_edit)
	var btn := Button.new()
	btn.text = tr("map_pick")
	btn.pressed.connect(_submit_coords)
	box.add_child(btn)


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
	_edit.text = "%.5f, %.5f" % [lat, lon]
	_overlay.queue_redraw()
	point_picked.emit(lat, lon)


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
	var level := clampi(int(round(zoom)), 0, int(_cfg.max_zoom))
	var scale_f := pow(2.0, zoom - level)
	var tile_size := TILE_PX * scale_f
	var c := latlon_to_world_px(center_lat, center_lon, level) * scale_f
	var top_left := c - size / 2.0
	var n := 1 << level
	(material as ShaderMaterial).set_shader_parameter(
		"m_per_px", TAU * TerrariumLoader.MERCATOR_R_M * cos(deg_to_rad(center_lat)) / (TILE_PX * n)
	)
	var tx0 := floori(top_left.x / tile_size)
	var ty0 := maxi(0, floori(top_left.y / tile_size))
	var tx1 := floori((top_left.x + size.x) / tile_size)
	var ty1 := mini(n - 1, floori((top_left.y + size.y) / tile_size))
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			var key := Vector3i(level, posmod(tx, n), ty)
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
	for k: Vector3i in _tiles.keys():
		if k.x != level and _tiles[k] != null:
			_tiles.erase(k)


func _load_tile(key: Vector3i) -> void:
	var img: Image = await _loader.fetch_tile(key.x, key.y, key.z)
	if img == null:
		_tiles.erase(key)
		return
	_tiles[key] = ImageTexture.create_from_image(img)
	queue_redraw()


func _draw_overlay() -> void:
	if not is_nan(picked.x):
		var p := latlon_to_screen(picked.x, picked.y)
		var a: Array = _cfg.marker_color
		var r := float(_cfg.marker_radius_px)
		_overlay.draw_circle(p, r, Color(float(a[0]), float(a[1]), float(a[2])))
		_overlay.draw_arc(p, r, 0.0, TAU, 24, Color.WHITE, 2.0)
	var font := get_theme_default_font()
	_overlay.draw_string(
		font,
		Vector2(8, size.y - 8),
		tr(String(_cfg.attribution)),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		Color(0, 0, 0, 0.7)
	)


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
