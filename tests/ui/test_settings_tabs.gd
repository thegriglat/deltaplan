extends Node
## MR-4: панель настроек разделена на вкладки (TabContainer); все элементы настроек лежат внутри
## одной из вкладок, вкладки не пустые и не однострочные.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _find_tabs(n: Node) -> TabContainer:
	if n is TabContainer:
		return n
	for c in n.get_children():
		var r := _find_tabs(c)
		if r != null:
			return r
	return null


func _controls_count(n: Node) -> int:
	var k := 0
	for c in n.get_children():
		if c is HBoxContainer and c.get_child_count() >= 2:
			k += 1
		k += _controls_count(c)
	return k


func test_settings_tabs() -> void:
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	var tabs := _find_tabs(sp)
	check(tabs != null, "есть TabContainer")
	if tabs == null:
		return
	check(tabs.get_tab_count() >= 3, "вкладок >= 3: %d" % tabs.get_tab_count())
	for i in tabs.get_tab_count():
		var title := tabs.get_tab_title(i)
		check(title != "" and not title.begins_with("settings_tab_"), "название вкладки %d переведено: %s" % [i, title])
		check(_controls_count(tabs.get_tab_control(i)) >= 2, "во вкладке «%s» не меньше двух строк" % title)
	var members := [
		"_volume", "_sens", "_invert", "_roll_mode", "_roll_input", "_sound", "_graphics",
		"_render_scale_auto", "_render_scale", "_vsync", "_fps_limit", "_window_mode", "_resolution",
		"_time_speed", "_fov", "_helmet", "_eye_mode", "_bots", "_names", "_grass", "_wind_model",
		"_language", "_pilot_name", "_motion_on", "_motion_addr", "_motion_rate", "_motion_format",
	]
	for m: String in members:
		var c: Control = sp.get(m)
		if c == null:
			check(m == "_sound", "элемент %s создан" % m)  # _sound — только если есть пресеты
			continue
		check(tabs.is_ancestor_of(c), "%s внутри вкладок" % m)
	for k: String in sp.get("_motion_signs"):
		check(tabs.is_ancestor_of(sp.get("_motion_signs")[k]), "знак %s внутри вкладок" % k)
	# платформа — на своей вкладке целиком
	var rig_tab: Control = null
	for i in tabs.get_tab_count():
		if (tabs.get_tab_control(i) as Control).is_ancestor_of(sp.get("_motion_on")):
			rig_tab = tabs.get_tab_control(i)
	check(rig_tab != null and rig_tab.is_ancestor_of(sp.get("_motion_addr")), "платформа на одной вкладке")
	sp.queue_free()
