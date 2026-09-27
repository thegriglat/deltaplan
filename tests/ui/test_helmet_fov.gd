extends Node
## Настройки «Каска» и «Поле зрения»: пишутся в user://configs (helmet.json, camera.json),
## применяются сразу после сохранения (Config.reloaded): поле зрения — к камере, каска — к
## SunGlare, и каска видна только в кабине.
## Пишем в настоящий user://configs (Config читает только его) и восстанавливаем прежнее.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_helmet_and_fov_saved_and_applied() -> void:
	var paths := [
		UserSettings.DEFAULT_DIR.path_join("camera.json"),
		UserSettings.DEFAULT_DIR.path_join("helmet.json"),
	]
	var backup := []
	for p: String in paths:
		backup.append(FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else "")

	var cam := CameraRig.new()
	add_child(cam)
	var glare := SunGlare.new()
	add_child(glare)
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	var fov: HSlider = sp.get("_fov")
	var helmet: OptionButton = sp.get("_helmet")
	var modes: Array = sp.get("_helmet_modes")
	check(fov != null and helmet != null, "в настройках есть поле зрения и каска")
	fov.value = 80.0
	helmet.select(modes.find("visor"))
	check(sp.save(), "сохранилось")

	var cj := UserSettings.read_json(paths[0])
	var hj := UserSettings.read_json(paths[1])
	check(is_equal_approx(float(cj.get("fov_deg", 0.0)), 80.0), "fov_deg записан")
	check(String(hj.get("mode", "")) == "visor", "каска записана")
	check(is_equal_approx(cam.fov, 80.0), "поле зрения применилось сразу: %.1f" % cam.fov)
	check(glare.helmet_mode == "visor", "каска применилась сразу")
	cam.set_mode("cockpit")
	check(glare.active_helmet(cam) == "visor", "в кабине каска видна")
	cam.set_mode("chase")
	check(glare.active_helmet(cam) == "none", "снаружи каски нет")
	cam.set_mode("free")
	check(glare.active_helmet(cam) == "none", "в свободной камере каски нет")

	sp.queue_free()
	cam.queue_free()
	glare.queue_free()
	for i in paths.size():
		_restore(paths[i], backup[i])
	Config.reload()


func _restore(path: String, content: String) -> void:
	if content == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
