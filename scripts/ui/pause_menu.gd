class_name PauseMenu
extends Control
## Пауза (Esc): продолжить, заново, настройки, в меню, выход. В сетевой зоне (NET-52) —
## сверху код зоны, список пилотов зоны (имя, высота, ведущий/вы) и «Выйти из зоны»
## («догнать» — только через меню `=`, вне этой задачи). Список задаёт вызывающий через
## set_net_info (NetPauseInfo.build); пауза дерева его не обновляет сама — за это отвечает
## вызывающий (например, таймер 2 Гц в main.gd). Только сигналы наверх.

signal resume_requested
signal restart_requested
signal look_around_requested
signal settings_requested
signal controls_requested
signal menu_requested
signal quit_requested
signal leave_zone_requested
signal wait_requested

var _net_box: VBoxContainer
var _net_code_label: Label
var _net_peers_box: VBoxContainer
var _net_leave_btn: Button
var _wait_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var box := UiKit.centered_panel(self, 360)
	UiKit.label(box, tr("pause_title"), "TitleLabel")
	UiKit.separator(box)
	_build_net_box(box)
	UiKit.button(box, tr("common_continue"), func() -> void: resume_requested.emit())
	_wait_btn = UiKit.button(box, tr("pause_wait"), func() -> void: wait_requested.emit())
	_wait_btn.visible = false
	UiKit.button(box, tr("pause_look_around"), func() -> void: look_around_requested.emit())
	UiKit.button(box, tr("pause_restart"), func() -> void: restart_requested.emit())
	UiKit.button(box, tr("menu_controls"), func() -> void: controls_requested.emit())
	UiKit.button(box, tr("menu_settings"), func() -> void: settings_requested.emit())
	_net_leave_btn = UiKit.button(box, tr("net_leave"), func() -> void: leave_zone_requested.emit())
	_net_leave_btn.visible = false
	UiKit.button(box, tr("pause_to_menu"), func() -> void: menu_requested.emit())
	UiKit.button(box, tr("menu_quit"), func() -> void: quit_requested.emit())


func _build_net_box(box: VBoxContainer) -> void:
	_net_box = VBoxContainer.new()
	_net_box.add_theme_constant_override("separation", 6)
	_net_box.visible = false
	box.add_child(_net_box)
	var cap := UiKit.label(_net_box, tr("net_zone_code"), "HintLabel")
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_net_code_label = Label.new()
	_net_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_net_code_label.add_theme_font_size_override("font_size", 40)
	_net_box.add_child(_net_code_label)
	UiKit.label(_net_box, tr("net_in_zone"), "HeaderLabel")
	_net_peers_box = VBoxContainer.new()
	_net_peers_box.add_theme_constant_override("separation", 4)
	_net_box.add_child(_net_peers_box)
	UiKit.separator(_net_box)


## «Подождать час» (Q-17): показывать пункт — одиночная игра, пилот стоит на старте.
func set_wait_available(on: bool) -> void:
	_wait_btn.visible = on


func wait_visible() -> bool:
	return _wait_btn.visible


## Данные сетевой зоны (NetPauseInfo.build) — {} вне зоны: блок и «Выйти из зоны» скрыты.
func set_net_info(info: Dictionary) -> void:
	var in_zone := not info.is_empty()
	_net_box.visible = in_zone
	_net_leave_btn.visible = in_zone
	if not in_zone:
		return
	_net_code_label.text = String(info.get("code", ""))
	for c in _net_peers_box.get_children():
		_net_peers_box.remove_child(c)
		c.queue_free()
	for p: Dictionary in info.get("pilots", []):
		var marks: PackedStringArray = []
		if bool(p.get("is_leader", false)):
			marks.append(tr("net_leader"))
		if bool(p.get("is_me", false)):
			marks.append(tr("net_you"))
		var alt: Variant = p.get("alt_m")
		var alt_text := ("%d %s" % [roundi(float(alt)), tr("unit_m")]) if alt != null else "—"
		var text := "%s — %s" % [String(p.get("name", "")), alt_text]
		if not marks.is_empty():
			text += "  (" + ", ".join(marks) + ")"
		var l := UiKit.label(_net_peers_box, text)
		if bool(p.get("is_me", false)):
			l.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))


## Виден ли блок зоны (и «Выйти из зоны») — для тестов/скриншотов.
func net_block_visible() -> bool:
	return _net_box.visible


## Код зоны, как показан ("" — блок скрыт).
func net_code_text() -> String:
	return _net_code_label.text if _net_box.visible else ""


## Строки списка пилотов зоны, как на экране.
func net_peer_lines() -> PackedStringArray:
	var out: PackedStringArray = []
	for c in _net_peers_box.get_children():
		out.append((c as Label).text)
	return out
