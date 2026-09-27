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

var _title: Label
var _lines: Label
var _continue: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var box := UiKit.centered_panel(self, 440)
	_title = UiKit.label(box, "", "TitleLabel")
	UiKit.separator(box)
	_lines = UiKit.label(box, "")
	var bar := UiKit.button_bar(box)
	UiKit.button(bar, tr("Ещё раз (R)"), func() -> void: restart_requested.emit())
	_continue = UiKit.button(bar, tr("Продолжить"), func() -> void: continue_requested.emit())
	_continue.visible = false
	UiKit.button(bar, tr("В главное меню"), func() -> void: menu_requested.emit())


## kind/info — из сигнала Game.flight_ended.
func show_result(kind: String, info: Dictionary) -> void:
	_title.text = title_for(kind, info)
	_lines.text = "\n".join(lines_for(kind, info))
	visible = true


static func title_for(kind: String, info: Dictionary) -> String:
	if kind == "takeoff_failed":
		return _t("Взлёт сорван")
	match String(info.get("grade", "")):
		"soft":
			return _t("Мягкая посадка")
		"hard":
			return _t("Жёсткая посадка")
		"crash":
			return _t("Авария")
	return _t("Посадка")


static func lines_for(kind: String, info: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if kind == "takeoff_failed":
		out.append(String(info.get("text", info.get("reason", ""))))
		return out
	var vs := float(info.get("vertical_speed_ms", 0.0))
	var hs := float(info.get("horizontal_speed_ms", 0.0))
	out.append(_t("Скорость касания: вертикальная %.1f м/с, горизонтальная %.1f м/с") % [vs, hs])
	out.append(_t("Крен при касании: %.0f°") % absf(float(info.get("bank_deg", 0.0))))
	out.append(_t("Время полёта: %s") % format_time(float(info.get("flight_time_s", 0.0))))
	var dist_km := float(info.get("distance_m", 0.0)) / 1000.0
	out.append(_t("Дистанция от старта по прямой: %.2f км") % dist_km)
	var track_km := float(info.get("track_length_m", 0.0)) / 1000.0
	out.append(_t("Пройдено по следу: %.2f км") % track_km)
	if info.has("max_altitude_msl_m"):
		out.append(_t("Макс. высота над морем: %.0f м") % float(info.max_altitude_msl_m))
	var gain := maxf(float(info.get("height_gain_m", 0.0)), 0.0)
	out.append(_t("Макс. высота над стартом: %.0f м") % gain)
	if info.has("avg_speed_ms"):
		out.append(_t("Средняя путевая скорость: %.0f км/ч") % (float(info.avg_speed_ms) * 3.6))
	if info.has("total_climb_m"):
		out.append(_t("Суммарный набор высоты: %.0f м") % float(info.total_climb_m))
	if info.has("best_thermal_climb_ms") and float(info.best_thermal_climb_ms) > 0.0:
		out.append(_t("Лучший термик: %.1f м/с") % float(info.best_thermal_climb_ms))
	if info.has("max_climb_ms"):
		out.append(_t("Макс. подъём: %.1f м/с") % float(info.max_climb_ms))
	if info.has("max_sink_ms"):
		out.append(_t("Макс. снижение: %.1f м/с") % float(info.max_sink_ms))
	if info.has("circling_fraction"):
		out.append(_t("В кружении: %.0f%% времени") % (float(info.circling_fraction) * 100.0))
	if info.has("avg_glide_ratio") and float(info.avg_glide_ratio) > 0.0:
		out.append(_t("Среднее качество: %.1f") % float(info.avg_glide_ratio))
	return out


static func format_time(s: float) -> String:
	var t := int(round(s))
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


static func _t(s: String) -> String:
	return TranslationServer.translate(s)
