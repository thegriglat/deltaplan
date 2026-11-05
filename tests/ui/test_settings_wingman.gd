extends Node
## Пункт «Напарники» в настройках (WMN-2): bots.json → wingman.count, count не теряется.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_settings_wingman_saved() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_wingman_cfg")
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("bots.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("bots.json"))
	var sp: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	sp.config_dir = dir
	add_child(sp)
	var sl: HSlider = sp.get("_wingman")
	check(sl != null, "в настройках есть слайдер «Напарники»")
	if sl:
		sl.value = 2.0
		check(sp.save(), "сохранилось")
		var j := UserSettings.read_json(dir.path_join("bots.json"))
		check(int(j.get("wingman", {}).get("count", -1)) == 2, "wingman.count=2: %s" % [j])
		check(j.has("count"), "count ботов не потерян: %s" % [j])
	sp.free()
	DirAccess.remove_absolute(dir.path_join("bots.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("bots.json"))
