class_name ErrorCatcher
extends Logger
## Ловит ошибки и предупреждения движка и скриптов во время теста (OS.add_logger).
## Вызывается из любых потоков — под мьютексом.

var errors: PackedStringArray = []
var warnings: PackedStringArray = []
## Подстроки сообщений, которые не считаются (известные чужие проблемы окружения).
var ignore: PackedStringArray = []

var _mutex := Mutex.new()


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array[ScriptBacktrace]
) -> void:
	var msg := "%s (%s:%d %s) %s" % [code, file, line, function, rationale]
	for s in ignore:
		if msg.contains(s):
			return
	_mutex.lock()
	if error_type == ERROR_TYPE_WARNING:
		warnings.append(msg)
	else:
		errors.append(msg)
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass
