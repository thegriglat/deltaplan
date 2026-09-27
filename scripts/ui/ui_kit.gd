class_name UiKit
extends RefCounted
## Мелкие помощники вёрстки меню: панель по центру, подписи, строки «подпись — элемент».
## Цвета и шрифты — scenes/ui/theme.tres (варианты TitleLabel, HeaderLabel, HintLabel).


## Панель по центру экрана с вертикальной колонкой внутри; возвращает колонку.
static func centered_panel(parent: Control, width_px: float) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = width_px
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	return box


static func label(parent: Control, text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


static func button(parent: Control, text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	parent.add_child(b)
	return b


## Строка: подпись слева (фикс. ширина), элемент справа растягивается.
static func row(parent: Control, caption: String, control: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size.x = 190
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	parent.add_child(h)
	return h


## Слайдер с числом справа; fmt — формат числа ("%.0f кг").
static func slider_row(
	parent: Control, caption: String, range_min: float, range_max: float, step: float, fmt: String
) -> HSlider:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	var s := HSlider.new()
	s.min_value = range_min
	s.max_value = range_max
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 90
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(v)
	s.value_changed.connect(func(x: float) -> void: v.text = fmt % x)
	row(parent, caption, box)
	return s


static func separator(parent: Control) -> void:
	var sep := HSeparator.new()
	sep.modulate.a = 0.4
	parent.add_child(sep)


## Ряд кнопок по центру.
static func button_bar(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 12)
	parent.add_child(h)
	return h
