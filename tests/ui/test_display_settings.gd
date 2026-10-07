extends Node
## QL-13: VSync, предел кадров, режим и разрешение окна (game.json → display, машинные
## настройки в user://local/configs). Профиль тестового запуска временный; локальный game.json
## всё равно сохраняется и восстанавливается.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_defaults_vsync_on() -> void:
	var lpath := UserSettings.local_dir().path_join("game.json")
	var backup := FileAccess.get_file_as_string(lpath) if FileAccess.file_exists(lpath) else ""
	if FileAccess.file_exists(lpath):
		DirAccess.remove_absolute(lpath)
	Config.reload()
	check(bool(Config.value("game", "display.vsync", false)), "по умолчанию VSync вкл")
	check(int(Config.value("game", "display.max_fps", -1)) == 0, "по умолчанию без предела")
	GraphicsPresets.apply_display(true)
	check(_vsync_is(DisplayServer.VSYNC_ENABLED), "VSYNC_ENABLED")
	_restore(lpath, backup)
	Config.reload()


func test_limit_vsync_saved_and_applied() -> void:
	var lpath := UserSettings.local_dir().path_join("game.json")
	var backup := FileAccess.get_file_as_string(lpath) if FileAccess.file_exists(lpath) else ""
	if FileAccess.file_exists(lpath):
		DirAccess.remove_absolute(lpath)
	Config.reload()
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	var vsync: CheckBox = sp.get("_vsync")
	var fps: OptionButton = sp.get("_fps_limit")
	var opts: Array = sp.get("_fps_options")
	check(vsync != null and fps != null, "в настройках есть VSync и предел кадров")
	check(sp.get("_render_scale") != null, "масштаб 3D виден в настройках")
	check(sp.get("_window_mode") != null and sp.get("_resolution") != null, "режим и разрешение")
	vsync.button_pressed = false
	fps.select(opts.find(60))
	check(sp.save(), "сохранилось")
	check(Engine.max_fps == 60, "max_fps == 60, было %d" % Engine.max_fps)
	check(_vsync_is(DisplayServer.VSYNC_DISABLED), "VSYNC_DISABLED")
	var gj := UserSettings.read_json(lpath)
	check(
		int(gj.get("display", {}).get("max_fps", 0)) == 60,
		"max_fps в user://local/configs: %s" % gj
	)
	# «перезапуск сцены»: сброс и повторное чтение/применение
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	Config.reload()
	sp.queue_free()
	GraphicsPresets.apply_viewport(get_viewport())
	check(Engine.max_fps == 60, "после перезапуска max_fps == 60")
	check(_vsync_is(DisplayServer.VSYNC_DISABLED), "после перезапуска VSYNC_DISABLED")
	var sp2: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp2)
	var fps2: OptionButton = sp2.get("_fps_limit")
	check(int((sp2.get("_fps_options") as Array)[fps2.selected]) == 60, "панель показывает 60: sel %d opts %s cfg %s" % [fps2.selected, sp2.get("_fps_options"), Config.value("game", "display.max_fps")])
	check(not (sp2.get("_vsync") as CheckBox).button_pressed, "панель показывает VSync выкл")
	sp2.queue_free()
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	_restore(lpath, backup)
	Config.reload()


## Заглушка headless всегда отвечает VSYNC_ENABLED (режим не хранит) — там сверяем только
## «включён»; выключенный VSync проверяется в окне (tools/gpu_tests.sh).
func _vsync_is(mode: DisplayServer.VSyncMode) -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	return DisplayServer.window_get_vsync_mode() == mode


func _restore(path: String, content: String) -> void:
	if content == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
