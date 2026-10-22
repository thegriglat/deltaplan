extends Node
## RenderDriver (CR-К3): альтернатива по ОС, файл переопределения, аргументы перезапуска,
## решение «показать окно после обрыва», пометка «ветер упрощён после обрыва».


var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _tmp() -> String:
	var d := "user://test_render_driver_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(d)
	return d


func test_alternative_by_os() -> void:
	check(RenderDriver.alternative("vulkan", "Windows") == "d3d12", "win vulkan")
	check(RenderDriver.alternative("d3d12", "Windows") == "vulkan", "win d3d12")
	check(RenderDriver.alternative("metal", "macOS") == "vulkan", "mac metal")
	check(RenderDriver.alternative("vulkan", "macOS") == "metal", "mac vulkan")
	check(RenderDriver.alternative("vulkan", "Linux") == "", "linux: нет")
	check(RenderDriver.alternative("opengl3", "Windows") == "", "неизвестный: нет")


func test_options_by_os() -> void:
	check(RenderDriver.options("Windows") == PackedStringArray(["auto", "vulkan", "d3d12"]), "win")
	check(RenderDriver.options("macOS") == PackedStringArray(["auto", "metal", "vulkan"]), "mac")
	check(RenderDriver.options("Linux") == PackedStringArray(["auto"]), "linux скрыт")


func test_override_text() -> void:
	check(RenderDriver.override_text("auto", "Windows") == "", "auto — пусто")
	var t := RenderDriver.override_text("d3d12", "Windows")
	check(t.contains("[rendering]") and t.contains('rendering_device/driver.windows="d3d12"'), t)
	check(RenderDriver.override_text("metal", "macOS").contains("driver.macos"), "macos")
	var cf := ConfigFile.new()
	check(cf.parse(t) == OK, "файл разбирается как ConfigFile")
	check(cf.get_value("rendering", "rendering_device/driver.windows") == "d3d12", "значение")


func test_save_and_remove_override() -> void:
	var dir := _tmp()
	var ov := dir.path_join("render_driver.cfg")
	check(RenderDriver.save("d3d12", dir.path_join("configs"), ov, "Windows"), "save d3d12")
	check(FileAccess.file_exists(ov), "файл есть")
	check(FileAccess.get_file_as_string(ov).contains('driver.windows="d3d12"'), "строка")
	var saved := UserSettings.read_json(
		UserSettings.local_dir(dir.path_join("configs")).path_join("game.json")
	)
	check(saved.get("display", {}).get("rendering_driver") == "d3d12", "машинная настройка: %s" % saved)
	check(RenderDriver.save("auto", dir.path_join("configs"), ov, "Windows"), "save auto")
	check(not FileAccess.file_exists(ov), "auto удаляет файл")
	check(not RenderDriver.save("metal", dir.path_join("configs"), ov, "Windows"), "чужой драйвер — отказ")
	check(not FileAccess.file_exists(ov), "отказ ничего не пишет")
	Config.reload()


func test_restart_args_drop_rendering_driver() -> void:
	var a := RenderDriver.restart_args(
		PackedStringArray(["--path", ".", "--rendering-driver", "vulkan", "--windowed", "--rendering-driver=d3d12", "x"])
	)
	check(a == PackedStringArray(["--path", ".", "--windowed", "x"]), str(a))
	check(RenderDriver.restart_args(PackedStringArray()).is_empty(), "пусто")


func test_offer_after_crash_once() -> void:
	var p := {"body": "## Система\n- Версия: 1\n\n- стадия: wind\n- запуск: 2026-10-23T10:00:00\n"}
	check(RenderDriver.should_offer_after_crash(p, ""), "wind, не предлагали")
	var key := RenderDriver.crash_key(p)
	check(not RenderDriver.should_offer_after_crash(p, key), "тот же обрыв — один раз")
	var p2 := {"body": "- стадия: wind\n- запуск: 2026-10-24T10:00:00\n"}
	check(RenderDriver.should_offer_after_crash(p2, key), "новый обрыв — снова")
	check(not RenderDriver.should_offer_after_crash({"body": "- стадия: trees\n"}, ""), "другая стадия")
	check(not RenderDriver.should_offer_after_crash({}, ""), "отчёта нет")


func test_offered_key_roundtrip() -> void:
	var path := _tmp().path_join("offer.json")
	check(RenderDriver.offered_key(path) == "", "пусто")
	RenderDriver.mark_offered("abc", path)
	check(RenderDriver.offered_key(path) == "abc", "запомнили")


func test_dialog_text() -> void:
	check(GpuFailureDialog.text_for("vulkan", "d3d12").contains("DirectX 12"), "предлагает D3D12")
	check(not GpuFailureDialog.text_for("vulkan", "").contains("DirectX"), "Linux: без переключения")


func _dialog(alt: String, dir: String, ov: String) -> GpuFailureDialog:
	var d := GpuFailureDialog.new()
	d.restart_fn = func(_t: SceneTree) -> void: d.set_meta("restarted", true)
	d.override_path = ov
	d.os_name = "Windows"
	add_child(d)
	d.setup("vulkan", alt, dir)
	return d


func _local(dir: String, cfg: String) -> Dictionary:
	return UserSettings.read_json(UserSettings.local_dir(dir).path_join(cfg + ".json"))


func test_dialog_switch_saves_driver_and_restarts() -> void:
	var dir := _tmp().path_join("configs")
	var ov := _tmp().path_join("render_driver.cfg")
	var d := _dialog("d3d12", dir, ov)
	var got: Array = []
	d.choice_made.connect(func(c: String) -> void: got.append(c))
	d._finish(GpuFailureDialog.SWITCH)
	check(got == ["switch"], str(got))
	check(_local(dir, "game").get("display", {}).get("rendering_driver") == "d3d12", "драйвер сохранён")
	check(FileAccess.get_file_as_string(ov).contains('driver.windows="d3d12"'), "файл переопределения")
	check(_local(dir, "atmosphere").is_empty(), "безопасная графика не тронута")
	Config.reload()


func test_dialog_safe_applies_safe_set() -> void:
	var dir := _tmp().path_join("configs")
	var d := _dialog("d3d12", dir, _tmp().path_join("render_driver.cfg"))
	d._finish(GpuFailureDialog.SAFE)
	var g := _local(dir, "game")
	check(g.display.safe_reason == "crash" and g.display.gpu.sun_shadows == false, str(g))
	check(not g.display.has("rendering_driver"), "драйвер не менялся")
	var a := _local(dir, "atmosphere")
	check(a.clouds.renderer == "boxes" and a.air_model.enabled == "off", str(a))
	check(not d.has_meta("restarted"), "без перезапуска")
	Config.reload()


func test_dialog_retry_changes_nothing() -> void:
	var dir := _tmp().path_join("configs")
	var ov := _tmp().path_join("render_driver.cfg")
	var d := _dialog("d3d12", dir, ov)
	d._finish(GpuFailureDialog.RETRY)
	check(_local(dir, "game").is_empty() and _local(dir, "atmosphere").is_empty(), "настройки не тронуты")
	check(not FileAccess.file_exists(ov) and not d.has_meta("restarted"), "ни файла, ни перезапуска")


func test_start_menu_note_only_for_crash() -> void:
	GpuSafety.restore()
	var menu: StartMenu = StartMenu.new()
	add_child(menu)
	var note: Control = menu.get_node("WindNote")
	check(not note.visible, "по умолчанию строки нет")
	GpuSafety.apply_safe("manual")
	menu.refresh_wind_note()
	check(not note.visible, "safe_reason не crash — строки нет")
	GpuSafety.apply_safe("crash")
	menu.refresh_wind_note()
	check(note.visible, "safe_reason=crash — строка есть")
	(note.get_node("WindRestoreButton") as Button).pressed.emit()
	check(not note.visible and not GpuSafety.is_safe_by_crash(), "«Вернуть» убирает пометку")
	check(String(Config.value("atmosphere", "air_model.enabled", "")) == "auto", "ветер вернулся")
	menu.free()


func test_gpu_health_in_session_triggers_dialog() -> void:
	# Main опрашивает _gpu_failed() == GpuHealth.is_failed() раз в секунду и показывает окно один раз
	GpuHealth.reset()
	check(not GpuHealth.is_failed(), "здорова")
	GpuHealth.report_failure("AirGpu.buffer", "тест")
	check(GpuHealth.is_failed(), "отказ виден опросу")
	GpuHealth.reset()
