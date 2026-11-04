extends Node
## PHD-1: подпись ползунка «Чувствительность штанги» — ход до упора в см и направление.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_label_and_hint() -> void:
	var sp: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	sp.config_dir = ProjectSettings.globalize_path("res://.godot/test_bar_label_cfg")
	add_child(sp)
	var s: HSlider = sp.get("_bar_sens")
	var lbl: Label = s.get_parent().get_child(1)
	check(s.tooltip_text == tr("settings_bar_direction_hint"), "подсказка направления на ползунке")
	check(tr("settings_bar_direction_hint") != "settings_bar_direction_hint", "ключ подсказки переведён")
	if sp.call("_bar_cm_valid"):
		var travel := float(Config.value("controls", "mouse.bar_travel_px", 4000.0))
		s.value = 1.0
		s.value_changed.emit(1.0)
		check(lbl.text.contains("до упора") or lbl.text.contains("to the stop"), "в подписи «до упора»: " + lbl.text)
		check(lbl.text.contains("%.1f" % (travel / 315.0)), "ход при ×1: " + lbl.text)
		var t1 := lbl.text
		s.value = 2.0
		s.value_changed.emit(2.0)
		check(lbl.text != t1 and lbl.text.contains("%.1f" % (travel / 2.0 / 315.0)), "вправо — меньше ход: " + lbl.text)
