class_name ScrollPanel
extends RefCounted
## Панель по центру экрана с прокруткой содержимого (колесо мыши) и «подвалом» (кнопки)
## вне прокрутки — всегда видимым. Высота панели — по содержимому, но не выше экрана
## (QL-13: на 1024×600 длинные «Настройки» и «Полёт…» не должны вылезать за экран).

const MARGIN_PX := 16.0


## Возвращает {"box": колонка в прокрутке, "footer": колонка под ней (вне прокрутки),
## "scroll": ScrollContainer}.
static func build(parent: Control, width_px: float) -> Dictionary:
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = MARGIN_PX
	row.offset_right = -MARGIN_PX
	row.offset_top = MARGIN_PX
	row.offset_bottom = -MARGIN_PX
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	for side in 3:
		if side == 1:
			var panel := PanelContainer.new()
			panel.custom_minimum_size.x = width_px
			panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(panel)
		else:
			var sp := Control.new()
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(sp)
	var panel_node: PanelContainer = row.get_child(1)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel_node.add_child(outer)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var footer := VBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	outer.add_child(footer)
	var fitter := Fitter.new()
	fitter.scroll = scroll
	fitter.box = box
	fitter.footer = footer
	fitter.host = parent
	outer.add_child(fitter)
	box.minimum_size_changed.connect(fitter.fit)
	footer.minimum_size_changed.connect(fitter.fit)
	parent.resized.connect(fitter.fit)
	fitter.fit.call_deferred()
	return {"box": box, "footer": footer, "scroll": scroll}


## Подгоняет высоту прокрутки под содержимое, но не выше экрана. Нода живёт в панели —
## сигналы отключаются вместе с ней.
class Fitter:
	extends Node
	var scroll: ScrollContainer
	var box: Control
	var footer: Control
	var host: Control

	func fit() -> void:
		var avail := host.size.y - 2.0 * MARGIN_PX - footer.get_combined_minimum_size().y - 40.0
		scroll.custom_minimum_size.y = clampf(
			box.get_combined_minimum_size().y, 0.0, maxf(avail, 80.0)
		)
