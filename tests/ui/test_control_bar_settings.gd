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
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("controls.json")))
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
