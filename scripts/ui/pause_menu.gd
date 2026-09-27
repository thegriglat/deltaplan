class_name PauseMenu
extends Control
## Пауза (Esc): продолжить, заново, настройки, в меню, выход. Только сигналы наверх.

signal resume_requested
signal restart_requested
signal settings_requested
signal menu_requested
signal quit_requested


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var box := UiKit.centered_panel(self, 360)
	UiKit.label(box, tr("Пауза"), "TitleLabel")
	UiKit.separator(box)
	UiKit.button(box, tr("Продолжить"), func() -> void: resume_requested.emit())
	UiKit.button(box, tr("Заново"), func() -> void: restart_requested.emit())
	UiKit.button(box, tr("Настройки"), func() -> void: settings_requested.emit())
	UiKit.button(box, tr("В меню"), func() -> void: menu_requested.emit())
	UiKit.button(box, tr("Выход"), func() -> void: quit_requested.emit())
