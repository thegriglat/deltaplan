class_name PilotShiftIndicator
extends CanvasLayer
## Индикатор смещения пилота (FB-1, FB-К1): круг с перекрестием, светящаяся точка — Telemetry.pilot_shift
## (вперёд — вверх, назад — вниз, вбок — по горизонтали; край круга — предел хода). Внизу по центру
## экрана, один для всех камер. Размер и цвета — configs/ui.json → pilot_shift; флажок — enabled.

var _cfg: Dictionary = {}
var _shift := Vector2.ZERO
var _force := 0.0  ## |усилие рук|, Н (PH-К1) — только толщина рамки
var _active := false  ## идёт полёт/разбег и ввод включён (задаёт game.gd)
var _canvas: Control


func _ready() -> void:
	layer = 9
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_indicator)
	add_child(_canvas)
	get_viewport().size_changed.connect(_canvas.queue_redraw)
	reload()


## Перечитать configs/ui.json (после сохранения настроек).
func reload() -> void:
	_cfg = Config.get_config("ui").get("pilot_shift", {})
	_apply_visibility()


func set_active(on: bool) -> void:
	_active = on
	_apply_visibility()


func update(t: Telemetry) -> void:
	_shift = clamp_shift(t.pilot_shift)
	_force = t.bar_force.length() if t.bar_force.is_finite() else 0.0
	if _canvas != null and _canvas.visible:
		_canvas.queue_redraw()


func is_enabled() -> bool:
	return bool(_cfg.get("enabled", true))


func _apply_visibility() -> void:
	if _canvas != null:
		_canvas.visible = _active and is_enabled()


## Точка не дальше края круга (за пределом хода прижата к краю); нечисловое — в центр.
static func clamp_shift(v: Vector2) -> Vector2:
	if not v.is_finite():
		return Vector2.ZERO
	return v.limit_length(1.0)


## Толщина рамки круга диаметром d_px при усилии рук force_n (PH-К1): w = w0 + (w_max − w0)·clamp(|F|/F_full, 0, 1),
## w0 — прежняя толщина max(1, 0,015·d), w_max = force_ring_max_frac·d (конфиг pilot_shift). Нечисловое — как без усилия.
static func ring_width(d_px: float, force_n: float, cfg: Dictionary) -> float:
	var w0 := maxf(1.0, d_px * 0.015)
	var w_max := maxf(w0, d_px * float(cfg.get("force_ring_max_frac", 0.07)))
	var f := absf(force_n) if is_finite(force_n) else 0.0
	return w0 + (w_max - w0) * clampf(f / maxf(float(cfg.get("force_full_n", 120.0)), 1.0e-3), 0.0, 1.0)


## Положение точки относительно центра круга, px: вперёд (y+) — вверх по экрану.
static func dot_offset(shift: Vector2, radius_px: float) -> Vector2:
	var s := clamp_shift(shift)
	return Vector2(s.x, -s.y) * radius_px


func _draw_indicator() -> void:
	var win := get_viewport().get_visible_rect().size
	var d := win.y * float(_cfg.get("diameter_frac", 0.09))
	var r := d * 0.5
	var c := Vector2(win.x * 0.5, win.y - win.y * float(_cfg.get("bottom_margin_frac", 0.035)) - r)
	var line_w := maxf(1.0, d * 0.015)
	var a := float(_cfg.get("opacity", 0.55))
	var rim := Color(String(_cfg.get("ring_color", "#d8e4ec")))
	var glow := Color(String(_cfg.get("dot_color", "#7fe8ff")))
	_canvas.draw_circle(c, r, Color(0.0, 0.0, 0.0, a * 0.45))
	# рамка: толщина — усилие рук (PH-К1); перекрестие остаётся прежней толщины
	_canvas.draw_arc(c, r, 0.0, TAU, 48, Color(rim, a), ring_width(d, _force, _cfg), true)
	var cross := Color(rim, a * 0.7)
	_canvas.draw_line(c + Vector2(-r, 0.0), c + Vector2(r, 0.0), cross, line_w)
	_canvas.draw_line(c + Vector2(0.0, -r), c + Vector2(0.0, r), cross, line_w)
	var dr := d * 0.07
	var p := c + dot_offset(_shift, r - dr)
	_canvas.draw_circle(p, dr * 2.2, Color(glow, a * 0.25))
	_canvas.draw_circle(p, dr * 1.5, Color(glow, a * 0.45))
	_canvas.draw_circle(p, dr, Color(glow.lightened(0.5), minf(1.0, a + 0.35)))
