class_name ResultScreen
extends Control
## Итог полёта: оценка посадки (FR-10) или причина срыва взлёта (FR-9), время, дистанция.
## Не HUD: показывается после окончания полёта, игра на паузе.

signal restart_requested
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
	UiKit.button(bar, tr("Ещё раз"), func() -> void: restart_requested.emit())
	_continue = UiKit.button(bar, tr("Продолжить"), func() -> void: continue_requested.emit())
	UiKit.button(bar, tr("В меню"), func() -> void: menu_requested.emit())


## kind/info — из сигнала Game.flight_ended.
func show_result(kind: String, info: Dictionary) -> void:
	_title.text = title_for(kind, info)
	_lines.text = "\n".join(lines_for(kind, info))
	# После аварии или срыва дальше идти некуда — только заново.
	_continue.visible = kind == "landed" and String(info.get("grade", "")) != "crash"
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
	out.append(_t("Дистанция от взлёта: %.2f км") % dist_km)
	var track_km := float(info.get("track_length_m", 0.0)) / 1000.0
	out.append(_t("Пройдено по следу: %.2f км") % track_km)
	var gain := maxf(float(info.get("height_gain_m", 0.0)), 0.0)
	out.append(_t("Набор над стартом: %.0f м") % gain)
	return out


static func format_time(s: float) -> String:
	var t := int(round(s))
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


static func _t(s: String) -> String:
	return TranslationServer.translate(s)
