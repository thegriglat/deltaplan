extends Node
## Автоматический отчёт о вылете (docs/guide/crash-report.md). При старте кладёт метку
## user://session.lock, при штатном выходе (закрытие окна, «Выход», quit) удаляет. Нашли метку
## от прошлого запуска — он оборвался: собираем отчёт (CrashReport) и отправляем issue в GitHub
## фоном, не больше CrashReport.MAX_ATTEMPTS раз. Токен — res://data/crash_report_token.txt
## (кладёт tools/build.sh; нет файла — функция выключена). Включена только в экспортной сборке
## с окном; --crash-report-test — пробный отчёт в любом запуске.

signal report_sent

const TOKEN_PATH := "res://data/crash_report_token.txt"
const API_URL := "https://api.github.com/repos/thegriglat/deltaplan-reports/issues"
## Запуски без пилота (проверки, снимки, замеры) метку не ведут.
const SKIP_ARGS := ["--smoke", "--autostart", "--prefetch", "--screenshot", "--perf"]

## Отчёт отправлен в этом запуске — меню показывает строку.
var sent := false

var _lock: Dictionary = {}
var _active := false
var _token := ""
var _http: HTTPRequest
var _test := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_token = read_token()
	var args := OS.get_cmdline_user_args()
	_test = "--crash-report-test" in args
	_active = should_track(
		OS.has_feature("template"), DisplayServer.get_name() == "headless", args
	)
	if _test:
		_send_test()
	if not _active:
		return
	var old := CrashReport.read_json(CrashReport.LOCK_PATH)
	if not old.is_empty() and _other_instance(old):
		_active = false  # игра уже запущена в другом окне — её метку не трогаем
		return
	if not old.is_empty() and _token != "":
		CrashReport.write_json(
			CrashReport.PENDING_PATH,
			CrashReport.make_pending(old, CrashReport.system_info(), CrashReport.read_previous_log())
		)
	var info := CrashReport.system_info()
	_lock = {
		"version": info.version,
		"started": Time.get_datetime_string_from_system(false, true),
		"pid": OS.get_process_id(),
		"stage": "",
		"settings": {"graphics": GraphicsPresets.current()},
	}
	_write()
	_try_send_pending()


## Нужно ли вести метку: экспортная сборка, окно есть, не служебный запуск.
static func should_track(is_template: bool, is_headless: bool, args: PackedStringArray) -> bool:
	if not is_template or is_headless:
		return false
	for a in args:
		for s in SKIP_ARGS:
			if a.begins_with(s):
				return false
	return true


static func read_token() -> String:
	if not FileAccess.file_exists(TOKEN_PATH):
		return ""
	return FileAccess.get_file_as_string(TOKEN_PATH).strip_edges()


func _other_instance(old: Dictionary) -> bool:
	var pid := int(old.get("pid", 0))
	if pid <= 0 or pid == OS.get_process_id():
		return false
	# на unix OS.is_process_running видит только дочерние процессы (и пишет ошибку в лог)
	match OS.get_name():
		"Windows":
			return OS.is_process_running(pid)
		"Linux":
			return DirAccess.dir_exists_absolute("/proc/%d" % pid)
	return false


## Запомнить пару в метке (настройка, стадия).
func note(key: String, value: Variant) -> void:
	if _active:
		_lock[key] = value
		_write()


func note_setting(key: String, value: Variant) -> void:
	if _active:
		var s: Dictionary = _lock.get("settings", {})
		s[key] = value
		_lock["settings"] = s
		_write()


## Смена стадии: строка в лог со сбросом на диск (CrashReport.log_stage_line) и снимок
## времени/памяти в метку — по ним видно, на чём и в каком состоянии оборвалась игра.
func note_stage(stage: String) -> void:
	if _active and _lock.get("stage", "") != stage:
		_lock["stage"] = stage
		_lock["vram"] = CrashReport.vram_text()
		_lock.merge(CrashReport.stage_snapshot(), true)
		CrashReport.log_stage_line(stage, _lock)
		_write()


func _write() -> void:
	CrashReport.write_json(CrashReport.LOCK_PATH, _lock)


func _clear() -> void:
	if _active and FileAccess.file_exists(CrashReport.LOCK_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CrashReport.LOCK_PATH))
	_active = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_clear()


func _exit_tree() -> void:
	_clear()


func _try_send_pending() -> void:
	if _token == "":
		return
	var p := CrashReport.read_json(CrashReport.PENDING_PATH)
	if p.is_empty():
		return
	var attempts := int(p.get("attempts", 0))
	if attempts >= CrashReport.MAX_ATTEMPTS:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CrashReport.PENDING_PATH))
		return
	p["attempts"] = attempts + 1
	CrashReport.write_json(CrashReport.PENDING_PATH, p)  # попытка считается до отправки
	_post(p, func(ok: bool) -> void:
		if ok:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(CrashReport.PENDING_PATH))
			sent = true
			report_sent.emit()
	)


func _send_test() -> void:
	if _token == "":
		print("crash-report-test: токена нет (data/crash_report_token.txt), отправлять нечем")
		return
	var info := CrashReport.system_info()
	var lock := {
		"version": info.version,
		"stage": "проба",
		"vram": CrashReport.vram_text(),
		"settings": {"graphics": GraphicsPresets.current()},
	}
	# текущий запуск: его лог — godot.log
	var log_text := FileAccess.get_file_as_string(CrashReport.LOG_DIR.path_join("godot.log"))
	var p := CrashReport.make_pending(lock, info, log_text, "Проба")
	_post(p, func(ok: bool) -> void:
		print("crash-report-test: %s" % ("отправлено" if ok else "не отправлено"))
		if ok:
			sent = true
			report_sent.emit()
	)


## POST issue; done(ok) по ответу. Сеть не задерживает игру (HTTPRequest асинхронный).
func _post(p: Dictionary, done: Callable) -> void:
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	var payload := {"title": String(p.title), "body": String(p.body)}
	if not _test:
		payload["labels"] = ["crash"]
	var headers := [
		"Authorization: Bearer " + _token,
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28",
		"User-Agent: deltaplan-crash-report",
		"Content-Type: application/json",
	]
	var h := _http
	h.request_completed.connect(
		func(result: int, code: int, _hd: PackedStringArray, _b: PackedByteArray) -> void:
			print("crash-report: HTTP %d (result %d)" % [code, result])
			h.queue_free()
			done.call(result == HTTPRequest.RESULT_SUCCESS and code == 201)
	)
	if h.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(payload)) != OK:
		h.queue_free()
		done.call(false)
