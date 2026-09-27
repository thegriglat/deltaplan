class_name FlightInstrument
extends Node
## Полётный компьютер-планшет на центре базовой штанги (FR-21, FR-23…FR-25), 5 страниц:
## 0 — полёт, 1 — карта, 2 — ветер и глиссада, 3 — задание и настройки звука, 4 — центровка.
## Держит Vario, WindEstimator, InstrumentTask и экран InstrumentDisplay в SubViewport.
## Текстура экрана идёт на 3D-корпус (instrument_3d.tscn) и в угол экрана (instrument_overlay.tscn).
##
## Использование (главная сцена):
##   glider.telemetry_updated.connect(instrument.update)
##   клавиши 1–5 → instrument.set_page(0..4)
##   vario_audio.set_vario(instrument.get_vario().vario_ms)
##   instrument.set_sound_settings(vario_audio.get_settings())
##   instrument.settings_requested.connect(<меню/настройки>)

## Страница переключилась.
signal page_changed(page: int)
## Пилот просит изменить настройку прибора (ключ, значение) — применяет главная сцена.
## Ключи: "vario_volume_db", "vario_climb_on_ms", "vario_sink_on_ms", "vario_enabled",
## "vario_preset".
signal settings_requested(key: String, value: Variant)

var vario := Vario.new()
var wind := WindEstimator.new()
var task := InstrumentTask.new()
var thermal := ThermalAssistant.new()
var _cfg: Dictionary = {}
var _redraw_interval_s: float = 0.1
var _since_redraw_s: float = 0.0
var _dirty: bool = true

@onready var viewport: SubViewport = $Screen
@onready var display: InstrumentDisplay = $Screen/Display


func _ready() -> void:
	_cfg = Config.get_config("instruments")
	vario.setup(_cfg)
	wind.setup(_cfg)
	task.setup(_cfg)
	thermal.setup(_cfg, vario.get_filter_time_constant_s())
	var scr: Dictionary = _cfg.get("screen", {})
	viewport.size = Vector2i(int(scr.get("width_px", 720)), int(scr.get("height_px", 960)))
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_redraw_interval_s = 1.0 / maxf(float(scr.get("update_hz", 10)), 1.0)
	display.vario = vario
	display.wind = wind
	display.task = task
	display.thermal = thermal
	display.setup(_cfg)
	_request_redraw()


## Новые данные полёта. dt — шаг, с; по умолчанию — шаг физики
## (сигнал планера идёт из _physics_process).
func update(t: Telemetry, dt: float = -1.0) -> void:
	if dt < 0.0:
		dt = get_physics_process_delta_time()
	vario.update(t, dt)
	wind.update(t, dt)
	thermal.update(t.heading_deg, vario.vario_ms, dt, t.on_ground)
	_dirty = true


## Текстура экрана (для материалов и TextureRect).
func get_texture() -> ViewportTexture:
	return viewport.get_texture()


func get_vario() -> Vario:
	return vario


func get_wind() -> WindEstimator:
	return wind


func get_task() -> InstrumentTask:
	return task


func get_thermal() -> ThermalAssistant:
	return thermal


func get_page() -> int:
	return display.page


func page_count() -> int:
	return InstrumentDisplay.PAGE_COUNT


## Переключить страницу 0..4 (клавиши 1–5 привязывает главная сцена).
func set_page(i: int) -> void:
	var p := posmod(i, page_count())
	var changed := p != display.page
	display.page = p
	_request_redraw()
	if changed:
		page_changed.emit(p)


func next_page() -> void:
	set_page(display.page + 1)


## Задание: [{name, position: Vector3 (y — высота земли у пункта), radius_m}], активный пункт.
func set_task(points: Array, active_index: int = 0) -> void:
	task.set_points(points, active_index)
	_request_redraw()


## Совместимость: поворотные пункты = задание с первым пунктом активным.
func set_turnpoints(points: Array) -> void:
	set_task(points, 0)


## Показать настройки звука на странице 4:
## {enabled, volume_db, climb_on_ms, sink_on_ms, preset, preset_title}.
func set_sound_settings(settings: Dictionary) -> void:
	display.sound = settings.duplicate()
	_request_redraw()


## Попросить изменить настройку (кнопки прибора/меню) — наверх уходит сигнал settings_requested.
func request_setting(key: String, value: Variant) -> void:
	settings_requested.emit(key, value)


## Новый полёт.
func reset() -> void:
	vario.reset()
	wind.reset()
	thermal.reset()
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
