class_name CrashDiag
extends RefCounted
## Диагностика для отчёта о вылете (CR-13): без участия пилота собирает события сбоя видеодрайвера
## из журнала Windows (wevtutil, без прав администратора), сводку и хвост прошлых логов, драйвер
## видеокарты, известные оверлеи (tasklist), значения рубильников GPU (CR-К4). Разбор текста — чистые
## статические функции (тестируются на образцах); запуск внешних программ — collect() в рабочем потоке
## (OS.execute блокирует), каждая программа с таймаутом. Системные настройки не меняются. В отчёт идут
## только провайдер, код, время, первая строка описания; пути с именем пользователя маскируются.

## События System: 4101 — Display «драйвер перестал отвечать и был восстановлен» (TDR); 141 — LiveKernelEvent
## (сброс GPU); 117 — таймаут TDR; 4097 — сбой драйвера (nvlddmkm/amdkmdag). Имя провайдера пишут сами драйверы.
const EVENT_IDS := [4101, 141, 117, 4097]
const MAX_EVENTS := 10
const WEVT_TIMEOUT_S := 3.0
const TASKLIST_TIMEOUT_S := 3.0
## Запас к окну: от начала прошлого сеанса, мс.
const WINDOW_MARGIN_MS := 300000
const WINDOW_MAX_MS := 7 * 86400 * 1000
const WINDOW_DEFAULT_MS := 3600 * 1000
const LOG_TAIL_LINES := 20
const MAX_LOG_LIST := 10
const MAX_DESC := 160
## Предел раздела диагностики в теле отчёта, знаков (тело ≤ CrashReport.MAX_BODY).
const MAX_SECTION := 8000
## Имена процессов (нижний регистр) — оверлеи и утилиты, известные поводы сбоев D3D12/Vulkan. Полный
## список процессов в отчёт не попадает.
const OVERLAY_PROCESSES := [
	"rtss.exe",
	"rtsshooksloader64.exe",
	"msiafterburner.exe",
	"discord.exe",
	"gamebar.exe",
	"gamebarftserver.exe",
	"radeonsoftware.exe",
	"amdrssrcext.exe",
	"nvcontainer.exe",
	"nvidia share.exe",
	"nvsphelper64.exe",
	"gameoverlayui.exe",
	"steamwebhelper.exe",
	"overwolf.exe",
	"obs64.exe",
	"medal.exe",
	"geforce experience.exe",
]
const UNAVAILABLE := "недоступно"


# ---------- события Windows ----------


## Аргументы wevtutil: события System с кодами EVENT_IDS за последние ms_back мс, текстом.
static func wevtutil_args(ms_back: int) -> PackedStringArray:
	var ids: PackedStringArray = []
	for id in EVENT_IDS:
		ids.append("EventID=%d" % id)
	var q := "*[System[(%s) and TimeCreated[timediff(@SystemTime) <= %d]]]" % [" or ".join(ids), ms_back]
	return PackedStringArray(["qe", "System", "/q:" + q, "/f:text", "/c:%d" % MAX_EVENTS])


## Окно запроса, мс: от начала прошлого сеанса (started — «ГГГГ-ММ-ДДTчч:мм:сс» местного времени,
## now_local — тот же вид, Unix-секунды «как есть») плюс запас; метки нет или время странное — час.
static func window_ms(started: String, now_local: float) -> int:
	if started == "":
		return WINDOW_DEFAULT_MS
	var t0 := Time.get_unix_time_from_datetime_string(started)
	if t0 <= 0.0 or now_local <= t0:
		return WINDOW_DEFAULT_MS
	return clampi(int((now_local - t0) * 1000.0) + WINDOW_MARGIN_MS, 60000, WINDOW_MAX_MS)


## Текущее местное время тем же видом, что started (Time.get_datetime_string_from_system(false, true)).
static func now_local_unix() -> float:
	return Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system(false))


## Разбор вывода `wevtutil qe … /f:text`: блоки «Event[N]:» с полями Source, Date, Event ID и Description
## (описание — в той же строке или в следующих). Метки полей wevtutil печатает по-английски, описание
## локализовано, а в консольной кодировке — возможны «?» вместо букв. → [{provider, id, date, desc}].
static func parse_wevtutil(text: String) -> Array:
	var out: Array = []
	var cur: Dictionary = {}
	var want_desc := false
	for raw in text.replace("\r", "").split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("Event["):
			if not cur.is_empty():
				out.append(cur)
			cur = {"provider": "", "id": 0, "date": "", "desc": ""}
			want_desc = false
			continue
		if cur.is_empty():
			continue
		if want_desc:
			if line != "":
				cur["desc"] = _clip(line)
				want_desc = false
			continue
		if line.begins_with("Source:"):
			cur["provider"] = line.substr(7).strip_edges()
		elif line.begins_with("Event ID:"):
			cur["id"] = int(line.substr(9).strip_edges())
		elif line.begins_with("Date:"):
			cur["date"] = line.substr(5).strip_edges()
		elif line.begins_with("Description:"):
			var rest := line.substr(12).strip_edges()
			if rest != "":
				cur["desc"] = _clip(rest)
			else:
				want_desc = true
	if not cur.is_empty():
		out.append(cur)
	return out.slice(0, MAX_EVENTS)


static func _clip(s: String) -> String:
	return s.substr(0, MAX_DESC)


static func event_line(e: Dictionary) -> String:
	var s := "- %s, %s, id %d" % [String(e.get("date", "?")), String(e.get("provider", "?")), int(e.get("id", 0))]
	var d := String(e.get("desc", ""))
	return s + (": " + d if d != "" else "")


# ---------- оверлеи ----------


## Разбор вывода `tasklist /fo csv /nh` → имена процессов из OVERLAY_PROCESSES (без повторов, как в списке).
static func parse_tasklist(text: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for raw in text.replace("\r", "").split("\n"):
		var line := raw.strip_edges()
		if not line.begins_with("\""):
			continue
		var name := line.substr(1).get_slice("\"", 0).to_lower()
		if name in OVERLAY_PROCESSES and not name in found:
			found.append(name)
	return found


# ---------- логи ----------


## Сводка каталога логов: число godot*.log, у каждого размер и время (новые первыми, не больше MAX_LOG_LIST).
## Хвост самого свежего прошлого лога в отчёт уже идёт отдельно — здесь последние LOG_TAIL_LINES строк
## предыдущего (по возрасту следующего) лога, чтобы видеть, повторяется ли обрыв.
static func logs_summary(dir: String = CrashReport.LOG_DIR) -> PackedStringArray:
	var names: PackedStringArray = []
	for n in DirAccess.get_files_at(dir):
		if n.begins_with("godot") and n.get_extension() == "log":
			names.append(n)
	names.sort()
	names.reverse()  # новые первыми (godot.log — текущий — окажется последним: «.» < цифр, но он без даты)
	var out: PackedStringArray = []
	out.append("- файлов godot*.log: %d" % names.size())
	for i in mini(names.size(), MAX_LOG_LIST):
		var p := dir.path_join(names[i])
		out.append(
			(
				"  - %s: %.1f КБ, изменён %s"
				% [
					names[i],
					float(_file_size(p)) / 1024.0,
					Time.get_datetime_string_from_unix_time(FileAccess.get_modified_time(p)),
				]
			)
		)
	var prev := CrashReport.pick_previous_log(names)
	var older := ""
	for n in names:  # убывающий порядок: следующий после prev — более старый
		if n < prev and n != "godot.log":
			older = n
			break
	if older != "":
		var lines := FileAccess.get_file_as_string(dir.path_join(older)).split("\n")
		var tail := lines.slice(maxi(lines.size() - LOG_TAIL_LINES - 1, 0))
		out.append("- хвост предыдущего лога %s (%d строк):" % [older, LOG_TAIL_LINES])
		out.append("````")
		out.append("\n".join(CrashReport.fold_repeats("\n".join(tail)).replace("````", "'''").split("\n")))
		out.append("````")
	return out


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else 0


# ---------- драйвер, рубильники ----------


## Видеокарта и драйвер этого запуска: «имя версия» из OS.get_video_adapter_driver_info.
static func driver_text() -> String:
	var info := OS.get_video_adapter_driver_info()
	var parts: PackedStringArray = []
	for s in info:
		if s != "":
			parts.append(s)
	return " ".join(parts)


## Рубильники GPU-нагрузки (CR-К4) → {ключ: значение} для метки сессии (по строке в отчёте).
## Нет ключа в конфиге — «нет». Пишется при старте, пока настройки прошлого запуска ещё в силе.
static func gpu_switches() -> Dictionary:
	var out: Dictionary = {}
	var gpu: Variant = Config.value("game", "display.gpu", {})
	if gpu is Dictionary:
		for k in gpu:
			if not String(k).begins_with("_"):
				out["gpu." + String(k)] = gpu[k]
	out["clouds.renderer"] = Config.value("atmosphere", "clouds.renderer", "нет")
	out["air_model.enabled"] = Config.value("atmosphere", "air_model.enabled", "нет")
	out["rendering_driver"] = Config.value("game", "display.rendering_driver", "нет")
	out["safe_reason"] = Config.value("game", "display.safe_reason", "нет")
	return out


# ---------- запуск внешних программ ----------


## Запуск exe с таймаутом: {ok, text, status}. Чтение канала execute_with_pipe не блокирует, поэтому
## опрашиваем его до конца процесса; по таймауту процесс убивается. Вызывать из рабочего потока.
## status — «нет программы», «таймаут», «код N» (процесс ушёл с ошибкой) или "".
static func run_with_timeout(exe: String, args: PackedStringArray, timeout_s: float) -> Dictionary:
	var proc: Dictionary = OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return {"ok": false, "text": "", "status": "нет программы %s" % exe}
	var stdio: FileAccess = proc["stdio"]
	var pid := int(proc["pid"])
	var buf := PackedByteArray()
	var t_end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var timed_out := false
	while true:
		var running := OS.is_process_running(pid)
		var chunk := stdio.get_buffer(65536)
		buf.append_array(chunk)
		if not running and chunk.is_empty():
			break
		if Time.get_ticks_msec() >= t_end:
			timed_out = true
			OS.kill(pid)
			break
		if chunk.is_empty():
			OS.delay_msec(20)
	var text := buf.get_string_from_utf8()
	if timed_out:
		return {"ok": false, "text": text, "status": "таймаут"}
	var code := OS.get_process_exit_code(pid)
	if code != 0:
		return {"ok": false, "text": text, "status": "код %d" % code}
	return {"ok": true, "text": text, "status": ""}


# ---------- сборка ----------


## Всё сразу: вызывать в рабочем потоке. Состав: events (Array), events_status (""|причина), overlays,
## overlays_status, logs (строки), driver (запуск, отправивший отчёт). started — метка прошлого сеанса.
static func collect(started: String) -> Dictionary:
	var d := {
		"events": [],
		"events_status": "",
		"overlays": PackedStringArray(),
		"overlays_status": "",
		"logs": logs_summary(),
		"driver": driver_text(),
	}
	if OS.get_name() != "Windows":
		d["events_status"] = "%s (не Windows)" % UNAVAILABLE
		d["overlays_status"] = "%s (не Windows)" % UNAVAILABLE
		return d
	var r := run_with_timeout("wevtutil", wevtutil_args(window_ms(started, now_local_unix())), WEVT_TIMEOUT_S)
	if r["ok"]:
		d["events"] = parse_wevtutil(String(r["text"]))
	else:
		d["events_status"] = "%s (%s)" % [UNAVAILABLE, String(r["status"])]
	var t := run_with_timeout("tasklist", PackedStringArray(["/fo", "csv", "/nh"]), TASKLIST_TIMEOUT_S)
	if t["ok"]:
		d["overlays"] = parse_tasklist(String(t["text"]))
	else:
		d["overlays_status"] = "%s (%s)" % [UNAVAILABLE, String(t["status"])]
	return d


## Раздел «Диагностика» тела отчёта (markdown, ≤ MAX_SECTION знаков, пути пользователя замаскированы).
static func format(d: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	out.append("## Диагностика")
	var drv := String(d.get("driver", ""))
	out.append("- Драйвер видеокарты (запуск, отправивший отчёт): %s" % (drv if drv != "" else UNAVAILABLE))
	var st := String(d.get("events_status", ""))
	if st != "":
		out.append("- События Windows (сбой видеодрайвера): %s" % st)
	else:
		var evs: Array = d.get("events", [])
		out.append("- События Windows 4101/141/117/4097 за время сеанса: %s" % ("нет" if evs.is_empty() else str(evs.size())))
		for e in evs:
			out.append("  " + event_line(e))
	var ost := String(d.get("overlays_status", ""))
	if ost != "":
		out.append("- Оверлеи и утилиты (сейчас запущены): %s" % ost)
	else:
		var ov: PackedStringArray = d.get("overlays", PackedStringArray())
		out.append("- Оверлеи и утилиты (сейчас запущены): %s" % (", ".join(ov) if not ov.is_empty() else "из списка не найдено"))
	out.append_array(d.get("logs", PackedStringArray()))
	var text := CrashReport.sanitize("\n".join(out))
	if text.length() > MAX_SECTION:
		text = text.substr(0, MAX_SECTION - 2) + "…\n"
		if text.count("````") % 2 == 1:
			text += "````\n"
	return PackedStringArray(text.split("\n"))
