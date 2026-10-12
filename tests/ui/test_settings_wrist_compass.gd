extends Node
## Флажок «Компас» в настройках (PH-7, PH-К2): сохраняется в ui.json → compass.enabled рядом с «Часы».

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])



func test_settings_compass_saved() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_wrist_compass_cfg")
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("ui.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("ui.json"))
	var sp: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	sp.config_dir = dir
	add_child(sp)
	var cb: CheckBox = sp.get("_compass")
	check(cb != null, "в настройках есть флажок «Компас»")
	if cb:
		cb.button_pressed = false
		check(sp.save(), "сохранилось")
		var j := UserSettings.read_json(dir.path_join("ui.json"))
		check(j.get("compass", {}).get("enabled", true) == false, "compass.enabled=false: %s" % [j])
		check(j.get("clock", {}).has("enabled"), "флажок «Часы» сохранён рядом")
	sp.free()
	DirAccess.remove_absolute(dir.path_join("ui.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("ui.json"))
