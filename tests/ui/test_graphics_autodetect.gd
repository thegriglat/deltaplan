extends Node
## Автовыбор пресета графики по (имя, тип видеокарты): слабое железо -> "low", иначе "" (не выбирать).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_integrated_type_is_low() -> void:
	check(
		GraphicsPresets.detect("Неизвестная", RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU) == "low",
		"встроенная по типу"
	)


func test_cpu_type_is_low() -> void:
	check(GraphicsPresets.detect("X", RenderingDevice.DEVICE_TYPE_CPU) == "low", "программная по типу")


func test_weak_names_are_low() -> void:
	for n: String in ["Intel(R) UHD Graphics 630", "Apple M1", "llvmpipe (LLVM 15)", "AMD Radeon(TM) Graphics"]:
		check(GraphicsPresets.detect(n, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU) == "low", "имя " + n)


func test_discrete_is_not_chosen() -> void:
	for n: String in ["NVIDIA GeForce RTX 3060", "AMD Radeon RX 5600 XT"]:
		check(GraphicsPresets.detect(n, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU) == "", "дискретная " + n)
	check(GraphicsPresets.detect("NVIDIA GeForce GTX 1050") == "", "без типа")
