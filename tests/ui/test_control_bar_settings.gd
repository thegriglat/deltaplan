extends Node
## CB-2: раздел «Трапеция / джойстик» в настройках: сборка headless, калибровка кнопками на подставных
## значениях, сохранение в config_dir теста.

var failures: PackedStringArray = []
var raw := {0: 0.0, 1: 0.0}


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f, получено %.4f" % [msg, expected, actual])


func _raw(axis: int) -> float:
	return float(raw.get(axis, 0.0))


func _panel(dir: String) -> SettingsPanel:
	var sp: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	sp.config_dir = dir
	add_child(sp)
	var cb: ControlBarSettings = sp.get("_bar_ui")
	cb.devices_fn = func() -> Array: return [{"id": 0, "guid": "g1", "name": "Bar one"}]
	cb.raw_fn = _raw
	cb.refresh_devices()
	return sp


func test_calibration_and_save() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_control_bar_cfg")
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.remove_absolute(dir.path_join("controls.json"))
	DirAccess.remove_absolute(UserSettings.local_dir(dir).path_join("controls.json"))
	var sp := _panel(dir)
	var cb: ControlBarSettings = sp.get("_bar_ui")
	check(cb != null, "раздел собран")
	var dev: OptionButton = cb.get("_device")
	check(dev.item_count == 2, "«Первое подключённое» + устройство")
	dev.select(1)
	dev.item_selected.emit(1)
	raw[0] = 0.1
	raw[1] = -0.2
	cb.set_neutral()
	cb.toggle_range()
	for v in [-0.6, 0.9, 0.1]:
		raw[0] = v
		raw[1] = v
		cb.update_indicator()
	cb.toggle_range()
	var p: Dictionary = cb.patch()
	check(p.device_guid == "g1" and p.device_name == "Bar one", "устройство выбрано")
	approx(float(p.calibration.roll[1]), 0.1, 1e-6, "нейтраль крена")
	approx(float(p.calibration.pitch[1]), -0.2, 1e-6, "нейтраль тангажа")
	approx(float(p.calibration.roll[0]), -0.6, 1e-6, "мин крена")
	approx(float(p.calibration.roll[2]), 0.9, 1e-6, "макс крена")
	check(sp.save(), "сохранение")
	var saved: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(UserSettings.local_dir(dir).path_join("controls.json"))
	)
	check(saved is Dictionary and saved.gamepad.device_guid == "g1", "gamepad.device_guid записан: %s" % [saved])
	approx(float(saved.gamepad.calibration.roll[2]), 0.9, 1e-6, "калибровка записана")
	cb.reset_calibration()
	check(cb.patch().calibration.roll == [-1.0, 0.0, 1.0], "сброс")
	sp.queue_free()
	Config.reload()


func test_missing_device_label() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_control_bar_cfg2")
	DirAccess.make_dir_recursive_absolute(dir)
	var sp := _panel(dir)
	var cb: ControlBarSettings = sp.get("_bar_ui")
	cb.set("_guid", "gone")
	cb.set("_name", "Old bar")
	cb.refresh_devices()
	var dev: OptionButton = cb.get("_device")
	check(dev.get_item_text(dev.selected).contains("Old bar"), "«не подключено: Old bar»: %s" % dev.get_item_text(dev.selected))
	sp.queue_free()


## CB-К1 v2: машинные листья gamepad — в local/configs, общие — в configs; Config читает оба.
func test_save_patch_split() -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/test_control_bar_split/configs")
	DirAccess.make_dir_recursive_absolute(dir)
	var local := UserSettings.local_dir(dir).path_join("controls.json")
	DirAccess.remove_absolute(local)
	DirAccess.remove_absolute(dir.path_join("controls.json"))
	var ok := UserSettings.save_patch(
		"controls", {"gamepad": {"device_guid": "g9", "deadzone": 0.2, "calibration": {"roll": [-0.5, 0.0, 0.5]}}}, dir
	)
	check(ok, "save_patch")
	var l: Variant = JSON.parse_string(FileAccess.get_file_as_string(local))
	var c: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("controls.json")))
	check(l is Dictionary and l.gamepad.device_guid == "g9" and l.gamepad.has("calibration"), "машинные в local: %s" % [l])
	check(l is Dictionary and not l.gamepad.has("deadzone"), "deadzone не в local")
	check(c is Dictionary and c.gamepad.deadzone == 0.2 and not c.gamepad.has("device_guid"), "общие в configs: %s" % [c])
