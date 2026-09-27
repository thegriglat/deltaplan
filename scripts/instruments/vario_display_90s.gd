class_name VarioDisplay90s
extends Node
## Отдельный вариометр в стиле 1990-х на стойке трапеции (FR-25a): свой Vario (датчик медленнее),
## экран Vario90sFace в SubViewport → текстура для модели корпуса (делает агент models).
## Звук к нему — VarioAudio с пресетом "classic_90s":
##   vario_audio.set_vario(vario90s.get_vario().vario_ms)
## Параметры — configs/instruments.json → vario90s.

var vario := Vario.new()
var _redraw_interval_s: float = 0.125
var _since_redraw_s: float = 0.0
var _dirty: bool = true

@onready var viewport: SubViewport = $Screen
@onready var face: Vario90sFace = $Screen/Face


func _ready() -> void:
	var c: Dictionary = Config.get_config("instruments").get("vario90s", {})
	# Vario читает разделы vario и track — отдаём ему свои.
	vario.setup(
		{"vario": c.get("vario", {}), "track": Config.get_config("instruments").get("track", {})}
	)
	viewport.size = Vector2i(int(c.get("width_px", 480)), int(c.get("height_px", 360)))
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_redraw_interval_s = 1.0 / maxf(float(c.get("update_hz", 8)), 1.0)
	face.vario = vario
	face.setup(c)
	_request_redraw()


## Данные полёта; dt по умолчанию — шаг физики.
func update(t: Telemetry, dt: float = -1.0) -> void:
	if dt < 0.0:
		dt = get_physics_process_delta_time()
	vario.update(t, dt)
	_dirty = true


func get_texture() -> ViewportTexture:
	return viewport.get_texture()


func get_vario() -> Vario:
	return vario


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
	if face == null:
		return
	face.queue_redraw()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
