class_name InstrumentOverlay
extends CanvasLayer
## Изображение прибора в углу экрана для внешних камер (FR-21): не HUD, а картинка того же
## прибора в корпусе. Размер, угол, наклон — configs/instruments.json → overlay.

@onready var instrument: FlightInstrument = $FlightInstrument
@onready var root: Control = $Root
@onready var frame: Panel = $Root/Frame
@onready var picture: TextureRect = $Root/Frame/Picture

var _cfg: Dictionary = {}
var _aspect: float = 0.75


func _ready() -> void:
	var cfg: Dictionary = Config.get_config("instruments")
	_cfg = cfg.get("overlay", {})
	var scr: Dictionary = cfg.get("screen", {})
	_aspect = float(scr.get("width_px", 480)) / float(scr.get("height_px", 640))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(String(_cfg.get("bezel_color", "#23262a")))
	var bz := int(_cfg.get("bezel_px", 12))
	style.set_corner_radius_all(bz)
	frame.add_theme_stylebox_override("panel", style)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	root.modulate.a = float(_cfg.get("opacity", 1.0))
	use_instrument(instrument)
	get_viewport().size_changed.connect(_layout)
	_layout()


func update(t: Telemetry, dt: float = -1.0) -> void:
	instrument.update(t, dt)


func set_page(i: int) -> void:
	instrument.set_page(i)


## Показывать экран другого FlightInstrument (общий с 3D-корпусом); свой отключается.
func use_instrument(fi: FlightInstrument) -> void:
	if fi != instrument and instrument != null:
		instrument.process_mode = Node.PROCESS_MODE_DISABLED
		instrument.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	instrument = fi
	picture.texture = fi.get_texture()


func _layout() -> void:
	var win := get_viewport().get_visible_rect().size
	var bz := float(_cfg.get("bezel_px", 12))
	var margin := float(_cfg.get("margin_px", 18))
	var h := win.y * float(_cfg.get("height_frac", 0.34))
	var w := h * _aspect
	var outer := Vector2(w + 2.0 * bz, h + 2.0 * bz)
	var corner := String(_cfg.get("corner", "bottom_right"))
	var pos := Vector2(margin, margin)
	if corner.ends_with("right"):
		pos.x = win.x - margin - outer.x
	if corner.begins_with("bottom"):
		pos.y = win.y - margin - outer.y
	frame.position = pos
	frame.size = outer
	frame.pivot_offset = outer * 0.5
	frame.rotation = deg_to_rad(float(_cfg.get("rotation_deg", 0.0)))
	picture.position = Vector2(bz, bz)
	picture.size = Vector2(w, h)
