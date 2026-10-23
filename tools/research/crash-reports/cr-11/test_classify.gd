extends SceneTree
## Запуск: godot --headless --path <каталог cr-11> -s test_classify.gd  (код выхода 0 — все проверки прошли)
## Образцы строк — тексты ошибок движка из отчётов #4–#10, #18 и исходников 4.7.2-stable.

const Cls := preload("res://tools/research/crash-reports/cr-11/device_loss_classifier.gd")

func _init() -> void:
	var fails := 0
	var cases := [
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
	for c in cases:
		var r: Dictionary = Cls.classify_line(c[0])
		var name_got: String = r.get("name", "")
		if name_got != c[1] or (name_got != "" and r["reason_known"] != c[2]):
			fails += 1
			printerr("FAIL: ", c[0], " -> ", r)
	var log_text := "Godot Engine v4.7.2\nERROR: Can't create buffer of size: 96, error 0x887a0005.\n   at: buffer_create (x)\nERROR: Reset failed with error 0x80070057.\nERROR: Close failed with error 0x80004005.\n"
	var s: Dictionary = Cls.summarize(log_text)
	if not (s["lost"] and s["api"] == "d3d12" and not s["reason_known"] and s["aftermath"] == 2):
		fails += 1
		printerr("FAIL summarize: ", s)
	if Cls.summarize("ERROR: something else\n")["lost"]:
		fails += 1
		printerr("FAIL: ложное срабатывание")
	print(JSON.stringify({"cases": cases.size() + 2, "fails": fails, "line": s["line"]}))
	quit(1 if fails > 0 else 0)
