extends TestCase
## Фикстура самопроверки раннера (имя без test_ — обычный прогон её не видит): намеренная ошибка
## скрипта без единого упавшего check(). Запускается только из test_run_tests_script_error.

func test_null_call() -> void:
	var o: Object = null
	o.call("nope")
	check(true, "сюда ошибка не должна давать пройти")
