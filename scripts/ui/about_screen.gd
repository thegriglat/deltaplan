class_name AboutScreen
extends Control
## «Об игре» (FR-27a): атрибуция ассетов и данных из ASSETS.md, тексты лицензий.
## Источники — configs/ui.json → about_sources, license_files.

signal closed

var _text: RichTextLabel


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 60
	panel.offset_top = 40
	panel.offset_right = -60
	panel.offset_bottom = -40
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	UiKit.label(box, tr("Об игре"), "TitleLabel")
	UiKit.label(
		box,
		tr("Симулятор дельтаплана. Некоммерческий проект. Ниже — авторы и лицензии материалов."),
		"HintLabel"
	)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.selection_enabled = true
	box.add_child(_text)
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("Назад"), func() -> void: closed.emit())
	var ui: Dictionary = Config.get_config("ui")
	_text.text = AssetsCredits.build_text(
		ui.get("about_sources", ["res://ASSETS.md"]), ui.get("license_files", [])
	)


func get_text() -> String:
	return _text.get_parsed_text()
