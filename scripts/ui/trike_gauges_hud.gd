class_name TrikeGaugesHud
extends CanvasLayer
## HUD-приборы дельталёта от третьего лица (TP-К4): тахометр и указатель топлива слева от планшета
## InstrumentOverlay, низ на одной линии с ним (часы ClockLabel — выше). Видимость задаёт игра (TP-8):
## set_active(true) только в "trike" и при camera.mode != "cockpit". Настройки — instruments.json → trike_gauges.hud.

var _sc: Dictionary = {}
var _root: Control
var _rpm: GaugeDial
var _fuel: GaugeDial
var _active := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _root != null:
		return
	layer = 9  # как у ClockLabel
	_sc = GaugeDial.scales()
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.modulate.a = float((_sc["hud"] as Dictionary).get("opacity", 0.85))
	add_child(_root)
	_rpm = GaugeDial.new()
	_rpm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rpm.setup_rpm(_sc)
	_fuel = GaugeDial.new()
	_fuel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fuel.setup_fuel(_sc)
	_root.add_child(_rpm)
	_root.add_child(_fuel)
	visible = false
	if is_inside_tree():
		get_viewport().size_changed.connect(_layout)
	_layout()


func set_active(on: bool) -> void:
	_build()
	_active = on
	visible = on


func is_shown() -> bool:
	return visible


## Общий вход приборов (TP-К4), как у TrikeGauges3D.
func update_readout(engine_rpm: float, fuel_l: float, tank_l: float, _running: bool) -> void:
	_build()
	_rpm.set_value(engine_rpm)
	_fuel.v_max = tank_l if tank_l > 0.0 else _fuel.v_max
	_fuel.set_value(fuel_l)


## Диаметр одного прибора, px.
static func dial_px(win: Vector2, hud: Dictionary) -> float:
	return win.y * float(hud.get("dial_height_frac", 0.13))


## Размер блока из двух приборов, px.
static func block_size(win: Vector2, hud: Dictionary) -> Vector2:
	var d := dial_px(win, hud)
	return Vector2(2.0 * d + float(hud.get("gap_px", 8)), d)


## Правый нижний угол блока приборов, px. Планшет overlay справа внизу — слева от его рамки, низ на
## линии рамки (часы стоят над рамкой — не пересекаются); иначе — у правого нижнего угла окна левее часов.
static func anchor_px(win: Vector2, hud: Dictionary, overlay: Dictionary) -> Vector2:
	var gap := float(hud.get("gap_px", 8))
	if String(overlay.get("corner", "bottom_right")) == "bottom_right":
		var bz := float(overlay.get("bezel_px", 12))
		var om := float(overlay.get("margin_px", 18))
		var h := win.y * float(overlay.get("height_frac", 0.34)) + 2.0 * bz
		var scr: Dictionary = Config.get_config("instruments").get("screen", {})
		var w := (h - 2.0 * bz) * float(scr.get("width_px", 720)) / float(scr.get("height_px", 960)) + 2.0 * bz
		return Vector2(win.x - om - w - gap, win.y - om)
	var m := float(hud.get("margin_px", 18))
	# Часы справа внизу занимают win.x*0.2 × win.y*0.06 (ClockLabel._layout) — приборы левее.
	return Vector2(win.x - m - win.x * 0.2 - gap, win.y - m)


func _win() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1920, 1080)


## Прямоугольник блока приборов, px (для теста и раскладки).
static func rect_px(win: Vector2, hud: Dictionary, overlay: Dictionary) -> Rect2:
	var sz := block_size(win, hud)
	return Rect2(anchor_px(win, hud, overlay) - sz, sz)


func _layout() -> void:
	if _rpm == null:
		return
	var win := _win()
	var hud: Dictionary = _sc["hud"]
	var ov: Dictionary = Config.get_config("instruments").get("overlay", {})
	var rc := rect_px(win, hud, ov)
	var d := dial_px(win, hud)
	_rpm.position = rc.position
	_rpm.size = Vector2(d, d)
	_fuel.position = rc.position + Vector2(d + float(hud.get("gap_px", 8)), 0.0)
	_fuel.size = Vector2(d, d)
