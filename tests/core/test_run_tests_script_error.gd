extends TestCase
## Раннер засчитывает ошибку скрипта (SCRIPT ERROR) как падение теста и выходит с кодом 1.

func test_run_tests_script_error() -> void:
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/run_tests.tscn", "--",
		"--file=res://tests/fixtures/script_error/script_error_case.gd"], out, true)
	var text := String(out[0]) if out.size() > 0 else ""
	check(code != 0, "ненулевой код выхода (получен %d)" % code)
	check(text.contains("1 упало"), "в итоге «1 упало»: " + text.right(300))
	check(text.contains("SCRIPT ERROR"), "причина в выводе")
