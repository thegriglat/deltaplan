class_name CrashReport
extends RefCounted
## Отчёт об оборвавшемся запуске (docs/guide/crash-report.md): чистая логика без сети — метка
## сессии, выбор лога прошлого запуска, замена путей пользователя, обрезка, сборка markdown.
## Жизненный цикл и отправка — автозагрузка CrashReporter.

const LOCK_PATH := "user://session.lock"
const PENDING_PATH := "user://crash_report.json"
const LOG_DIR := "user://logs"
## Тело issue ≤ 60 000 знаков (предел GitHub — 65 536).
const MAX_BODY := 60000
const MAX_ATTEMPTS := 3
const TRUNC_MARK := "…(начало лога обрезано)\n"


## Метка сессии → словарь; {} — нет метки или она битая.
static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func write_json(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	return true


## Лог прошлого запуска среди имён файлов в user://logs: Godot при старте переименовывает
## godot.log в godotГГГГ-ММ-ДДTчч.мм.сс.log, поэтому прошлый запуск — самый новый датированный
## файл (godot.log — текущий запуск). "" — нет.
static func pick_previous_log(names: PackedStringArray) -> String:
	var best := ""
	for n in names:
		if n == "godot.log" or not n.begins_with("godot") or n.get_extension() != "log":
			continue
		if n > best:
			best = n
	return best


## Лог прошлого запуска из каталога (текст; "" — нет).
static func read_previous_log(dir: String = LOG_DIR) -> String:
	var name := pick_previous_log(DirAccess.get_files_at(dir))
	return FileAccess.get_file_as_string(dir.path_join(name)) if name != "" else ""


## Путь пользователя → «~»: C:\Users\<имя>, /home/<имя>, /Users/<имя>.
static func sanitize(text: String) -> String:
	var out := text
	for pat in [
		"(?i)[A-Z]:[\\\\/]+Users[\\\\/]+[^\\\\/\"'\\r\\n:*?<>|]+",
		"/home/[^/\\s\"']+",
		"/Users/[^/\\s\"']+",
	]:
		var re := RegEx.create_from_string(pat)
		out = re.sub(out, "~", true)
	return out


## Хвост лога не длиннее max_chars знаков (по границе строки); начало обрезано — пометка.
static func trim_log(log_text: String, max_chars: int) -> String:
	if max_chars <= 0:
		return ""
	if log_text.length() <= max_chars:
		return log_text
	var keep := maxi(max_chars - TRUNC_MARK.length(), 0)
	var tail := log_text.substr(log_text.length() - keep)
	var nl := tail.find("\n")
	if nl >= 0 and nl < tail.length() - 1:
		tail = tail.substr(nl + 1)
	return (TRUNC_MARK + tail).substr(0, max_chars)


static func title(lock: Dictionary, sysinfo: Dictionary, prefix := "Вылет") -> String:
	return (
		"%s %s — %s, %s"
		% [
			prefix,
			String(lock.get("version", sysinfo.get("version", "?"))),
			String(sysinfo.get("gpu", "?")),
			String(sysinfo.get("os", "?")),
		]
	)


## Тело issue (markdown): сведения о системе и настройках + хвост лога; всего ≤ limit знаков.
static func build_body(lock: Dictionary, sysinfo: Dictionary, log_text: String, limit := MAX_BODY) -> String:
	var lines: PackedStringArray = []
	lines.append("## Система")
	lines.append("- Версия: %s" % String(lock.get("version", sysinfo.get("version", "?"))))
	for pair in [
		["ОС", "os"],
		["Видеокарта", "gpu"],
		["Производитель", "gpu_vendor"],
		["Драйвер / API", "gpu_api"],
		["Рендер", "renderer"],
		["Процессор", "cpu"],
		["RAM", "ram"],
		["VRAM (занято перед обрывом)", "vram"],
	]:
		var key: String = pair[1]
		var v: String = String(lock.get(key, sysinfo.get(key, "")))
		if v != "":
			lines.append("- %s: %s" % [pair[0], v])
	lines.append("")
	lines.append("## Настройки прошлого запуска")
	var settings: Dictionary = lock.get("settings", {})
	if settings.is_empty():
		lines.append("- (не успели выбрать)")
	for k in settings:
		lines.append("- %s: %s" % [k, str(settings[k])])
	var stage := String(lock.get("stage", ""))
	lines.append("- стадия: %s" % (stage if stage != "" else "меню"))
	var started := String(lock.get("started", ""))
	if started != "":
		lines.append("- запуск: %s" % started)
	lines.append("")
	lines.append("## Лог прошлого запуска (хвост)")
	var head := sanitize("\n".join(lines)) + "\n````\n"
	var foot := "\n````\n"
	var room := limit - head.length() - foot.length()
	var body := trim_log(sanitize(log_text).replace("````", "'''"), room)
	return head + body + foot


## Один раз при каждой отправке: заготовка в файл ожидающих отправки.
static func make_pending(lock: Dictionary, sysinfo: Dictionary, log_text: String, prefix := "Вылет") -> Dictionary:
	return {
		"title": sanitize(title(lock, sysinfo, prefix)),
		"body": build_body(lock, sysinfo, log_text),
		"attempts": 0,
	}


## Системные сведения этого компьютера (в окне; в headless часть пустая).
static func system_info() -> Dictionary:
	var mem := OS.get_memory_info()
	var ram_b := float(mem.get("physical", 0))
	return {
		"version": BuildInfo.version() + (" (%s)" % BuildInfo.commit() if BuildInfo.commit() != "" else ""),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"gpu_api": "%s %s" % [RenderingServer.get_video_adapter_api_version(), _device_type()],
		"renderer":
		(
			"%s / %s"
			% [
				RenderingServer.get_current_rendering_driver_name(),
				RenderingServer.get_current_rendering_method()
			]
		),
		"cpu": OS.get_processor_name(),
		"ram": "%.1f ГБ" % (ram_b / 1073741824.0) if ram_b > 0.0 else "",
	}


static func vram_text() -> String:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return ""
	var used := float(rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL))
	return "%.0f МБ" % (used / 1048576.0)


static func _device_type() -> String:
	var names := ["other", "integrated", "discrete", "virtual", "cpu"]
	var t := int(RenderingServer.get_video_adapter_type())
	return names[t] if t >= 0 and t < names.size() else ""
