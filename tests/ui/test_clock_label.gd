extends Node
## Часы текстом от 3-го лица (PH-2, PH-К2): формат, время из SunClock (только чтение), видимость по
## флажку и «активности» (3-е лицо), расположение над угловым прибором, флажок в настройках.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _make(clock: SunClock, enabled := true) -> ClockLabel:
	var l := ClockLabel.new()
	l.clock = clock
	add_child(l)
	l._cfg["enabled"] = enabled
	l._apply_visibility()
	return l


func test_clock_label_text_and_visibility() -> void:
	var c := SunClock.new()
	c.hour = 13.0
	var l := _make(c)
	check(not l.is_shown(), "до set_active скрыт")
	l.set_active(true)
	check(l.is_shown(), "активен и включён — виден")
	check(l.text() == "13:00", "формат ЧЧ:ММ: " + l.text())
	c.hour = 6.5
	l._process(0.0)
	check(l._label.text == "06:30", "обновление из часов: " + l._label.text)
	check(c.hour == 6.5, "время не продвигается")
	l.set_active(false)
	check(not l.is_shown(), "кабина/меню/пауза — скрыт")
	l.free()
	var off := _make(c, false)
	off.set_active(true)
	check(not off.is_shown(), "флажок выключен — текста нет")
	off.free()
	var nc := _make(null)
	nc.set_active(true)
	check(not nc.is_shown() and nc.text() == "", "без часов — скрыт")
	nc.free()


func test_clock_label_above_overlay() -> void:
	var win := Vector2(1920, 1080)
	var ov := {"corner": "bottom_right", "height_frac": 0.38, "margin_px": 18, "bezel_px": 12}
	var p := ClockLabel.anchor_px(win, 18.0, ov, 8.0)
	var top := win.y - 18.0 - (win.y * 0.38 + 24.0)
	check(is_equal_approx(p.x, 1902.0) and p.y < top, "над рамкой прибора: %s < %s" % [p.y, top])
	var q := ClockLabel.anchor_px(win, 18.0, {"corner": "top_left"}, 8.0)
	check(q == Vector2(1902.0, 1062.0), "прибор не справа внизу — у нижнего края: %s" % q)


func test_clock_setting_saved() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_clock_cfg")
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("ui.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("ui.json"))
	var sp: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	sp.config_dir = dir
	add_child(sp)
	var cb: CheckBox = sp.get("_clock")
	check(cb != null, "в настройках есть флажок «Часы»")
	if cb:
		cb.button_pressed = false
		check(sp.save(), "сохранилось")
		var j := UserSettings.read_json(dir.path_join("ui.json"))
		check(j.get("clock", {}).get("enabled", true) == false, "clock.enabled=false в ui.json: %s" % [j])
		check(j.get("pilot_shift", {}).has("enabled"), "флажок подвески сохранён рядом")
	sp.free()
	DirAccess.remove_absolute(dir.path_join("ui.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("ui.json"))
