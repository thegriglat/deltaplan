class_name FKeyHint
extends CanvasLayer
## Подсказка по F-клавишам в полёте: вверху по центру, мелко, белым полупрозрачным текстом
## («F1 — частота кадров · F5 — ветер · F6 — термики»). Показаны только слои, которые сейчас
## выключены: включил — пункт пропал, выключил — вернулся; включены все — подсказки нет.
## Клавиша берётся из InputMap (configs/controls.json → debug.keys), состояние — из DebugOverlays.
## Скрыты как не для пилотов: F2 (меню аддона с графиками), F3 (старый слой стрелок поля —
## дублирует F5), F4 (карта фаз модели воздуха). F12 (снимок) — не режим, он на экране «Управление».

## Пункты подсказки: действие InputMap, поле DebugOverlays с состоянием, ключ перевода.
const ITEMS := [
	["debug_perf", "perf_on", "fkey_hint_perf"],
	["debug_wind", "wind_on", "fkey_hint_wind"],
	["debug_thermals", "thermals_on", "fkey_hint_thermals"],
]
const SEPARATOR := " · "

var overlays: DebugOverlays
var _label: Label


func _ready() -> void:
	layer = 90
	_label = Label.new()
	_label.name = "Hint"
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.offset_top = 6.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.35))
	_label.add_theme_constant_override("outline_size", 3)
	add_child(_label)
	refresh()


func _process(_dt: float) -> void:
	refresh()


func refresh() -> void:
	if _label == null:
		return
	var t := text_for(overlays)
	if _label.text != t:
		_label.text = t
	_label.visible = t != ""


## Пункты, чей слой выключен: [{key: "F5", label: "ветер"}, …]. Клавиша без назначения пропускается.
static func visible_items(o: DebugOverlays) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if o == null:
		return out
	for it: Array in ITEMS:
		if bool(o.get(it[1])):
			continue
		var k := key_text(it[0])
		if k != "":
			out.append({"key": k, "label": TranslationServer.translate(it[2])})
	return out


static func text_for(o: DebugOverlays) -> String:
	var parts: PackedStringArray = []
	for d in visible_items(o):
		parts.append("%s — %s" % [d.key, d.label])
	return SEPARATOR.join(parts)


## Название первой клавиши действия («F5») или "".
static func key_text(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			var code: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
			return OS.get_keycode_string(code)
	return ""
