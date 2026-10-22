extends TestCase
## RenderDriver (CR-К3): альтернатива по ОС, файл переопределения, аргументы перезапуска,
## решение «показать окно после обрыва», пометка «ветер упрощён после обрыва».


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
