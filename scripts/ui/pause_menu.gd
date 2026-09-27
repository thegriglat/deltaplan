class_name PauseMenu
extends Control
## Пауза (Esc): продолжить, заново, настройки, в меню, выход. Только сигналы наверх.

signal resume_requested
signal restart_requested
signal settings_requested
signal controls_requested
signal menu_requested
signal quit_requested


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var box := UiKit.centered_panel(self, 360)
	UiKit.label(box, tr("pause_title"), "TitleLabel")
	UiKit.separator(box)
	UiKit.button(box, tr("common_continue"), func() -> void: resume_requested.emit())
	UiKit.button(box, tr("pause_restart"), func() -> void: restart_requested.emit())
	UiKit.button(box, tr("menu_controls"), func() -> void: controls_requested.emit())
	UiKit.button(box, tr("menu_settings"), func() -> void: settings_requested.emit())
	UiKit.button(box, tr("pause_to_menu"), func() -> void: menu_requested.emit())
	UiKit.button(box, tr("menu_quit"), func() -> void: quit_requested.emit())
