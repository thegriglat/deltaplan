class_name ClockLabel
extends CanvasLayer
## Часы текстом от 3-го лица (PH-2, PH-К2): «ЧЧ:ММ» справа внизу, время — SunClock.hour той же
## sky.clock, что ведёт солнце (только чтение, не продвигаем). Видимость: флажок ui.clock.enabled
## и камера не «cockpit» (set_active задаёт game.gd вместе с режимом камеры). Настройки — configs/ui.json → clock.

var clock: SunClock  ## источник времени (Game.sky.clock)
var _cfg: Dictionary = {}
var _active := false  ## идёт полёт, ввод включён, камера не «cockpit» (задаёт game.gd)
var _label: Label


func _ready() -> void:
	layer = 9
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)
	get_viewport().size_changed.connect(_layout)
	reload()


## Перечитать configs/ui.json (после сохранения настроек).
func reload() -> void:
	_cfg = Config.get_config("ui").get("clock", {})
	if _label != null:
		var a := float(_cfg.get("opacity", 0.8))
		_label.add_theme_color_override("font_color", Color(String(_cfg.get("color", "#e8eef2")), a))
		_label.add_theme_font_size_override("font_size", maxi(8, roundi(_win().y * float(_cfg.get("font_frac", 0.026)))))
	_apply_visibility()
	_refresh()
	_layout()


func set_active(on: bool) -> void:
	_active = on
	_apply_visibility()
	_refresh()


func is_enabled() -> bool:
	return bool(_cfg.get("enabled", true))


## Видим ли текст сейчас.
func is_shown() -> bool:
	return _label != null and _label.visible


## Текст «ЧЧ:ММ» из часов солнца; без часов — пусто.
func text() -> String:
	return SunClock.format_hour(clock.hour) if clock != null else ""


func _process(_dt: float) -> void:
	_refresh()


func _refresh() -> void:
	if _label != null and _label.visible:
		var t := text()
		if _label.text != t:
			_label.text = t


func _apply_visibility() -> void:
	if _label != null:
		_label.visible = _active and is_enabled() and clock != null


func _win() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1920, 1080)


## Правый нижний угол текста, px: по правому краю окна; если угловой прибор overlay справа внизу —
## над его рамкой, иначе у нижнего края.
static func anchor_px(win: Vector2, margin_px: float, overlay: Dictionary, gap_px: float) -> Vector2:
	var p := Vector2(win.x - margin_px, win.y - margin_px)
	if String(overlay.get("corner", "bottom_right")) == "bottom_right":
		var bz := float(overlay.get("bezel_px", 12))
		var h := win.y * float(overlay.get("height_frac", 0.34)) + 2.0 * bz
		p.y = win.y - float(overlay.get("margin_px", 18)) - h - gap_px
	return p


func _layout() -> void:
	if _label == null:
		return
	var win := _win()
	var ov: Dictionary = Config.get_config("instruments").get("overlay", {})
	var br := anchor_px(win, float(_cfg.get("margin_px", 18)), ov, float(_cfg.get("gap_px", 8)))
	var sz := Vector2(win.x * 0.2, win.y * 0.06)
	_label.size = sz
	_label.position = br - sz
