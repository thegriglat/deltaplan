class_name StartPickPanel
extends PanelContainer
## Панель выбора старта в осмотре (SP-2): координаты, высота, уклон, курс, «Лететь отсюда».
## Сама ничего не решает: показывает pick из Game и сообщает о нажатиях сигналами.

signal turn_requested(delta_deg: float)
signal downhill_requested
signal reset_requested
signal fly_requested

var info_label: Label
var heading_label: Label
var reason_label: Label
var fly_button: Button
var _spot_box: HBoxContainer
var _hint: Label


func _init() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = 40
	offset_right = -40
	offset_bottom = -24
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	add_child(v)
	_hint = UiKit.label(v, tr("start_pick_hint"), "HintLabel")
	_spot_box = HBoxContainer.new()
	_spot_box.add_theme_constant_override("separation", 12)
	v.add_child(_spot_box)
	info_label = UiKit.label(_spot_box, "")
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiKit.button(_spot_box, "−5°", func() -> void: turn_requested.emit(-5.0))
	heading_label = UiKit.label(_spot_box, "")
	UiKit.button(_spot_box, "+5°", func() -> void: turn_requested.emit(5.0))
	UiKit.button(_spot_box, tr("start_pick_downhill"), func() -> void: downhill_requested.emit())
	UiKit.button(_spot_box, tr("start_pick_reset"), func() -> void: reset_requested.emit())
	fly_button = UiKit.button(_spot_box, tr("menu_fly_from_here"), func() -> void: fly_requested.emit())
	reason_label = UiKit.label(_spot_box, "")
	reason_label.add_theme_color_override("font_color", StartMarker.BAD_COLOR)
	show_pick({})


## pick — Game.pick ({} — точки нет).
func show_pick(pick: Dictionary) -> void:
	var has := not pick.is_empty()
	_hint.visible = not has
	_spot_box.visible = has
	if not has:
		return
	var ok: bool = pick.ok
	var ll := Vector2.ZERO
	if pick.has("lat"):
		ll = Vector2(pick.lat, pick.lon)
	info_label.text = (
		(tr("start_pick_coords") % [ll.x, ll.y]) + " · " + (tr("start_pick_height") % int(round(float(pick.height_m))))
		+ " · " + (tr("start_pick_slope") % int(round(float(pick.slope_deg))))
	)
	heading_label.text = tr("start_pick_heading") % int(round(float(pick.heading)))
	fly_button.visible = ok
	reason_label.visible = not ok
	reason_label.text = tr("start_pick_bad_" + String(pick.reason)) if not ok else ""
