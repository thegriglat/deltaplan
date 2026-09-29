class_name TestCase
extends RefCounted
## Базовый класс тестов. Методы test_* вызываются раннером tests/run_tests.tscn.

var failures: PackedStringArray = []


## Переопределить в тесте, которому для работы нужен настоящий RenderingDevice (compute-шейдеры
## и т. п.). В headless-прогоне (tools/check.sh) такой тест пропускается, не падает; запускается
## в tools/gpu_tests.sh (окно, не headless). См. tests/run_tests.gd.
func needs_gpu() -> bool:
	return false


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])
