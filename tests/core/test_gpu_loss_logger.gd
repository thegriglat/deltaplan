extends TestCase
## GpuLossLogger (CR-К2 v2): классификатор строк журнала движка (образцы — отчёты #4–#10, #18 и
## исходники 4.7.2, прототип CR-11) и связь с GpuHealth.


func _cases() -> Array:
	return [
		["ERROR: Can't create buffer of size: 96, error 0x887a0005.", "DXGI_ERROR_DEVICE_REMOVED", false],
		["ERROR: Can't create buffer of size: 96, error 0x887A0005.", "DXGI_ERROR_DEVICE_REMOVED", false],
		["ERROR: Present failed with error 0x887a0006.", "DXGI_ERROR_DEVICE_HUNG", true],
		["x error 0x887a0007", "DXGI_ERROR_DEVICE_RESET", true],
		["x error 0x887a0020", "DXGI_ERROR_DRIVER_INTERNAL_ERROR", true],
		["Vulkan device was lost. This could be due to a driver issue", "VK_ERROR_DEVICE_LOST", false],
		["Couldn't wait for Vulkan fence (VkResult error -4).", "", false],
		["** Report from VK_EXT_device_fault **", "device_fault_report", true],
		["VK_EXT_device_fault not available.", "device_fault_unavailable", false],
		["ERROR: Reset failed with error 0x80070057.", "", false],
		["ERROR: Condition \"!buffer.driver_id\" is true. Returning: RID()", "", false],
	]


func test_classify_line() -> void:
	for c: Array in _cases():
		var r := GpuLossLogger.classify_line(c[0])
		check(String(r.get("name", "")) == c[1], "%s -> %s" % [c[0], r])
		if c[1] != "":
			check(bool(r.reason_known) == c[2], "reason_known: %s" % c[0])


func test_summarize() -> void:
	var log_text := "Godot Engine v4.7.2\nERROR: Can't create buffer of size: 96, error 0x887a0005.\n   at: buffer_create (x)\nERROR: Reset failed with error 0x80070057.\nERROR: Close failed with error 0x80004005.\n"
	var s := GpuLossLogger.summarize(log_text)
	check(s.lost and s.api == "d3d12" and not s.reason_known and s.aftermath == 2, str(s))
	check(not GpuLossLogger.summarize("ERROR: something else\n").lost, "ложное срабатывание")
	check(
		not GpuLossLogger.summarize("VK_EXT_device_fault not available.\n").lost,
		"недоступное расширение — не потеря"
	)
	check(
		not GpuLossLogger.summarize("[gpu-loss] api=d3d12 code=0x887a0005 name=X reason=unknown").lost,
		"свои строки не разбираем"
	)


func test_handle_reports_to_gpu_health() -> void:
	GpuHealth.reset()
	GpuLossLogger.reset()
	check(not GpuLossLogger.handle("ERROR: ordinary engine error"), "без признака — нет")
	check(not GpuHealth.is_failed(), "здоров")
	check(GpuLossLogger.handle("ERROR: Can't create buffer of size: 96, error 0x887a0005."), "признак")
	check(GpuHealth.is_failed() and GpuHealth.source() == "engine", "GpuHealth: engine")
	check(GpuHealth.detail().contains("0x887a0005"), GpuHealth.detail())
	check(not GpuLossLogger.handle("GPU: отказ ресурса: engine: error 0x887a0005"), "своя строка")
	GpuHealth.reset()
	GpuLossLogger.reset()


func test_logger_gets_engine_error() -> void:
	GpuHealth.reset()
	GpuLossLogger.reset()
	GpuLossLogger.install()
	push_error("Can't create buffer of size: 96, error 0x887a0005.")
	check(GpuHealth.is_failed(), "push_error дошёл до логгера")
	GpuHealth.reset()
	GpuLossLogger.reset()


func test_tail_with_loss_offers_dialog() -> void:
	var p := {"body": "- стадия: trees\n````\nERROR: error 0x887a0005.\n````\n"}
	check(RenderDriver.should_offer_after_crash(p, ""), "хвост с потерей — окно")
	check(not RenderDriver.should_offer_after_crash(p, RenderDriver.crash_key(p)), "один раз")
	var q := {"body": "- стадия: trees\n````\nERROR: other\n````\n"}
	check(not RenderDriver.should_offer_after_crash(q, ""), "без признака на trees — нет")
	check(RenderDriver.should_offer_after_crash({"body": "- стадия: меню\n"}, ""), "обрыв в меню")


func test_gpu_safety() -> void:
	var dir := "user://test_gpu_safety_%d/configs" % Time.get_ticks_usec()
	check("sun_shadows" in GpuSafety.gpu_keys(), "ключи из умолчаний")
	check(GpuSafety.apply_safe("crash", dir), "apply")
	var g := UserSettings.read_json(UserSettings.local_dir(dir).path_join("game.json"))
	check(g.display.safe_reason == "crash" and g.display.gpu.sun_shadows == false, str(g))
	var a := UserSettings.read_json(UserSettings.local_dir(dir).path_join("atmosphere.json"))
	check(a.clouds.renderer == "boxes" and a.air_model.enabled == "off", str(a))
	check(GpuSafety.restore(dir), "restore")
	g = UserSettings.read_json(UserSettings.local_dir(dir).path_join("game.json"))
	check(not g.display.has("safe_reason") and g.display.gpu.sun_shadows == true, str(g))
	Config.reload()
