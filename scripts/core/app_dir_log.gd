class_name AppDirLog
extends Logger
## Лог в папке игры при установке через itch (рядом с exe лежит .itch.toml): <папка игры>/logs/
## godot.log — пилоту проще найти и прислать, чем %APPDATA%\Deltaplan\logs. Движок по-прежнему
## пишет и в user://logs; начало его лога (до автозагрузки Config) копируется в начало нашего.
## Прошлые логи — godot_<дата>.log, хранятся последние KEEP.

const MARK := ".itch.toml"
const KEEP := 5

var _file: FileAccess
var _mutex := Mutex.new()


## Включить, если игра установлена через itch. Возвращает путь к логу или "".
static func install() -> String:
	if OS.has_feature("editor"):
		return ""
	var dir := OS.get_executable_path().get_base_dir()
	if not FileAccess.file_exists(dir.path_join(MARK)):
		return ""
	var log_dir := dir.path_join("logs")
	var path := log_dir.path_join("godot.log")
	if DirAccess.make_dir_recursive_absolute(log_dir) != OK:
		return ""
	_rotate(log_dir, path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""  # папка только для чтения — остаётся лог движка в user://
	var engine_log := FileAccess.get_file_as_string("user://logs/godot.log")
	if engine_log != "":
		f.store_string(engine_log)
		f.flush()
	var logger := AppDirLog.new()
	logger._file = f
	OS.add_logger(logger)
	return path


static func _rotate(log_dir: String, path: String) -> void:
	if FileAccess.file_exists(path):
		var stamp := Time.get_datetime_string_from_system().replace(":", ".").replace("T", "_")
		DirAccess.rename_absolute(path, log_dir.path_join("godot_%s.log" % stamp))
	var old: Array[String] = []
	for f in DirAccess.get_files_at(log_dir):
		if f.begins_with("godot_") and f.get_extension() == "log":
			old.append(f)
	old.sort()
	while old.size() > KEEP:
		DirAccess.remove_absolute(log_dir.path_join(old.pop_front()))


func _write(text: String) -> void:
	_mutex.lock()
	if _file != null:
		_file.store_string(text)
		_file.flush()
	_mutex.unlock()


func _log_message(message: String, _error: bool) -> void:
	_write(message)


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
	var kind := "ERROR"
	if error_type == ERROR_TYPE_WARNING:
		kind = "WARNING"
	elif error_type == ERROR_TYPE_SCRIPT:
		kind = "SCRIPT ERROR"
	elif error_type == ERROR_TYPE_SHADER:
		kind = "SHADER ERROR"
	var text := rationale if rationale != "" else code
	_write("%s: %s\n   at: %s (%s:%d)\n" % [kind, text, function, file, line])
