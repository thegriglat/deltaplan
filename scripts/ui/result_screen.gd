class_name ResultScreen
extends Control
## Итог полёта (FR-27b): оценка посадки (FR-10) или причина срыва взлёта (FR-9). Игровая сессия
## всегда заканчивается на касании земли (мягкая/жёсткая посадка, авария) или срывом взлёта —
## возврата к полёту нет, поэтому главная кнопка — «В главное меню», «Ещё раз» — вторичная.
## Не HUD: показывается после окончания полёта, игра на паузе.

signal restart_requested
## Оставлен для совместимости сигнатуры (FR-27b: сессия всегда завершена — не эмитится).
signal continue_requested
signal menu_requested
## Сеть (NET-40): «Продолжить рядом» — к другу в воздухе; «На старт» — снова на старт.
signal continue_near_requested
signal to_start_requested

var _title: Label
var _lines: Label
var _continue: Button
var _again: Button
var _near: Button
var _to_start: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var box := UiKit.centered_panel(self, 440)
	_title = UiKit.label(box, "", "TitleLabel")
	UiKit.separator(box)
	_lines = UiKit.label(box, "")
	var bar := UiKit.button_bar(box)
	_near = UiKit.button(
		bar, tr("result_continue_near"), func() -> void: continue_near_requested.emit()
	)
	_near.visible = false
	_to_start = UiKit.button(bar, tr("result_to_start"), func() -> void: to_start_requested.emit())
	_to_start.visible = false
	_again = UiKit.button(bar, tr("result_fly_again"), func() -> void: restart_requested.emit())
	_continue = UiKit.button(bar, tr("common_continue"), func() -> void: continue_requested.emit())
	_continue.visible = false
	UiKit.button(bar, tr("result_to_menu"), func() -> void: menu_requested.emit())


## kind/info — из сигнала Game.flight_ended.
func show_result(kind: String, info: Dictionary) -> void:
	_title.text = title_for(kind, info)
	_lines.text = "\n".join(lines_for(kind, info))
	visible = true
	if _to_start.visible:
		(_near if _near.visible else _to_start).grab_focus.call_deferred()


## Сеть (NET-40): вместо «Ещё раз» — «Продолжить рядом» (главная, в фокусе; только если
## кто-то из друзей в воздухе, near) и «На старт». on = false — как в одиночной игре.
func set_net_mode(on: bool, near: bool) -> void:
	var lost_focus := _near.has_focus() and not (on and near)
	var appeared := on and near and not _near.visible
	_near.visible = on and near
	_to_start.visible = on
	_again.visible = not on
	if lost_focus:
		_to_start.grab_focus.call_deferred()
	elif appeared and visible:
		_near.grab_focus.call_deferred()  # друг взлетел, пока окно открыто — главная кнопка


func is_near_shown() -> bool:
	return _near.visible


static func title_for(kind: String, info: Dictionary) -> String:
	if kind == "takeoff_failed":
		return _t("result_launch_failed")
	match String(info.get("grade", "")):
		"soft":
			return _t("result_soft_landing")
		"hard":
			return _t("result_hard_landing")
		"crash":
			return _t("result_crash")
	return _t("result_landing")


static func lines_for(kind: String, info: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if kind == "takeoff_failed":
		out.append(String(info.get("text", info.get("reason", ""))))
		return out
	var vs := float(info.get("vertical_speed_ms", 0.0))
	var hs := float(info.get("horizontal_speed_ms", 0.0))
	out.append(_t("result_touchdown_speed") % [vs, hs])
	out.append(_t("result_touchdown_bank") % absf(float(info.get("bank_deg", 0.0))))
	out.append(_t("result_flight_time") % format_time(float(info.get("flight_time_s", 0.0))))
	var dist_km := float(info.get("distance_m", 0.0)) / 1000.0
	out.append(_t("result_distance") % dist_km)
	var track_km := float(info.get("track_length_m", 0.0)) / 1000.0
	out.append(_t("result_track_length") % track_km)
	if info.has("max_altitude_msl_m"):
		out.append(_t("result_max_altitude_msl") % float(info.max_altitude_msl_m))
	var gain := maxf(float(info.get("height_gain_m", 0.0)), 0.0)
	out.append(_t("result_max_height_over_launch") % gain)
	if info.has("avg_speed_ms"):
		out.append(_t("result_avg_ground_speed") % (float(info.avg_speed_ms) * 3.6))
	if info.has("total_climb_m"):
		out.append(_t("result_total_climb") % float(info.total_climb_m))
	if info.has("best_thermal_climb_ms") and float(info.best_thermal_climb_ms) > 0.0:
		out.append(_t("result_best_thermal") % float(info.best_thermal_climb_ms))
	if info.has("max_climb_ms"):
		out.append(_t("result_max_climb") % float(info.max_climb_ms))
	if info.has("max_sink_ms"):
		out.append(_t("result_max_sink") % float(info.max_sink_ms))
	if info.has("circling_fraction"):
		out.append(_t("result_circling_pct") % (float(info.circling_fraction) * 100.0))
	if info.has("avg_glide_ratio") and float(info.avg_glide_ratio) > 0.0:
		out.append(_t("result_avg_glide") % float(info.avg_glide_ratio))
	return out


static func format_time(s: float) -> String:
	var t := int(round(s))
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


static func _t(s: String) -> String:
	return TranslationServer.translate(s)
