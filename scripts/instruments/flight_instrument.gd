class_name FlightInstrument
extends Node
## Полётный компьютер на трапеции (FR-21, FR-23…FR-25).
## Держит Vario (обработка сигнала) и экран InstrumentDisplay в SubViewport.
## Текстура экрана идёт на 3D-корпус (instrument_3d.tscn) и в угол экрана (instrument_overlay.tscn).
##
## Использование:
##   glider.telemetry_updated.connect(instrument.update)
##   vario_audio.set_vario(instrument.get_vario().vario_ms)
##   mesh_material.albedo_texture = instrument.get_texture()

signal page_changed(page: int)

@onready var viewport: SubViewport = $Screen
@onready var display: InstrumentDisplay = $Screen/Display

var vario := Vario.new()
var _cfg: Dictionary = {}
var _redraw_interval_s: float = 1.0 / 15.0
var _since_redraw_s: float = 0.0
var _dirty: bool = true


func _ready() -> void:
	_cfg = Config.get_config("instruments")
	vario.setup(_cfg)
	var scr: Dictionary = _cfg.get("screen", {})
	viewport.size = Vector2i(int(scr.get("width_px", 480)), int(scr.get("height_px", 640)))
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_redraw_interval_s = 1.0 / maxf(float(scr.get("update_hz", 15)), 1.0)
	display.vario = vario
	display.setup(_cfg)
	_request_redraw()


## Новые данные полёта. dt — шаг, с; по умолчанию — шаг физики (сигнал планера идёт из _physics_process).
func update(t: Telemetry, dt: float = -1.0) -> void:
	if dt < 0.0:
		dt = get_physics_process_delta_time() if is_inside_tree() else 1.0 / float(Engine.physics_ticks_per_second)
	vario.update(t, dt)
	_dirty = true


## Текстура экрана (для материалов и TextureRect).
func get_texture() -> ViewportTexture:
	return viewport.get_texture()


func get_vario() -> Vario:
	return vario


func get_page() -> int:
	return display.page


func get_page_count() -> int:
	return int(_cfg.get("screen", {}).get("pages", 2))


## Переключить страницу: 0 — вариометр, 1 — карта.
func set_page(i: int) -> void:
	var n := get_page_count()
	display.page = posmod(i, n)
	_request_redraw()
	page_changed.emit(display.page)


func next_page() -> void:
	set_page(display.page + 1)


## Поворотные пункты для карты: [{name, position: Vector3, radius_m}].
func set_turnpoints(points: Array) -> void:
	display.turnpoints = points
	_request_redraw()


## Новый полёт.
func reset() -> void:
	vario.reset()
	_request_redraw()


func _process(delta: float) -> void:
	_since_redraw_s += delta
	if _dirty and _since_redraw_s >= _redraw_interval_s:
		_request_redraw()


func _request_redraw() -> void:
	_since_redraw_s = 0.0
	_dirty = false
	if display == null:
		return
	display.queue_redraw()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
