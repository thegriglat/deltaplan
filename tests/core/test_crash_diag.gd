extends TestCase
## Диагностика отчёта о вылете (CrashDiag): разбор синтетических образцов wevtutil и tasklist, окно
## запроса, «недоступно» без Windows, маскировка путей, рубильники в метку и в отчёт. Сами вызовы
## wevtutil/tasklist на Linux не проверяются — только разбор образцов (граница теста).

const WEVT_SAMPLE := """<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='Display'/><EventID Qualifiers='0'>4101</EventID><Level>3</Level><TimeCreated SystemTime='2026-10-23T03:12:44.123456700Z'/><Computer>PILOT-PC</Computer></System><EventData><Data>amdkmdap</Data><Data>C:\\Users\\Ivan\\x</Data></EventData></Event>
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='amdkmdag' Guid='{1}'/><EventID>141</EventID><TimeCreated SystemTime='2026-10-23T03:12:40.001Z'/></System><EventData><Data>a &amp; b</Data></EventData></Event>
"""

const TASKLIST_SAMPLE := """"System Idle Process","0","Services","0","8 K"
"RTSS.exe","4120","Console","1","31,204 K"
"Discord.exe","8800","Console","1","210,000 K"
"notepad.exe","100","Console","1","9,000 K"
"RTSS.exe","4121","Console","1","31,204 K"
"""


func test_parse_wevtutil() -> void:
	var ev := CrashDiag.parse_wevtutil(WEVT_SAMPLE)
	check(ev.size() == 2, "два события: %d" % ev.size())
	check(ev[0]["provider"] == "Display" and ev[0]["id"] == 4101, "провайдер и код")
	check(ev[0]["date"] == "2026-10-23T03:12:44.123456700Z", "время")
	check(ev[0]["desc"] == "amdkmdap", "первая строка данных — имя драйвера")
	check(ev[1]["provider"] == "amdkmdag" and ev[1]["id"] == 141, "второе событие")
	check(ev[1]["desc"] == "a & b", "сущности XML раскрыты")
	check(CrashDiag.parse_wevtutil("").is_empty(), "пустой вывод — нет событий")
	check(CrashDiag.parse_wevtutil("Error: access denied").is_empty(), "не событие — нет событий")
	var raw := CrashDiag.raw_sample("\n  Error: access denied\r\n\n2\n3\n4\n5\n6\n")
	check(raw.size() == 5 and raw[0] == "Error: access denied", "образец непонятного вывода: " + str(raw))


func test_unparsed_output_not_reported_as_none() -> void:
	var d := {"events": [], "events_raw": PackedStringArray(["Event[0]:", "Source: Display"]), "window_note": "окно"}
	var text := "\n".join(CrashDiag.format(d))
	check(text.contains("вывод не разобран") and text.contains("> Source: Display"), "не «нет»: " + text)
	check(not text.contains("(окно): нет"), "ложного «нет» нет")
	var none := "\n".join(CrashDiag.format({"events": []}))
	check(none.contains(": нет"), "пустой разобранный — «нет»")


func test_events_limit() -> void:
	var t := ""
	for i in 15:
		t += "<Event><System><Provider Name='Display'/><EventID>4101</EventID></System></Event>\n"
	check(CrashDiag.parse_wevtutil(t).size() == CrashDiag.MAX_EVENTS, "не больше 10 событий")


func test_wevtutil_args_and_window() -> void:
	var a := CrashDiag.wevtutil_args(123456, 7000)
	check(a[0] == "qe" and a[1] == "System", "журнал System")
	check(a[2].contains("EventID=4101") and a[2].contains("<= 123456") and a[2].contains(">= 7000"), "запрос: " + a[2])
	check("/f:xml" in a and "/c:10" in a, "XML и не больше 10")
	var now := Time.get_unix_time_from_datetime_string("2026-10-23T05:00:00")
	var w := CrashDiag.window("2026-10-23T04:00:00", 0.0, now)
	check(w["max"] == 3600000 + CrashDiag.WINDOW_MARGIN_MS and w["min"] == 0, "час сеанса плюс запас, до сейчас")
	w = CrashDiag.window("2026-10-23 04:00:00", 600.0, now)  # жил 10 мин
	check(w["min"] == 3600000 - 600000 - CrashDiag.WINDOW_TAIL_MS, "до последнего признака жизни + 2 мин: %s" % str(w))
	check(CrashDiag.window("", 0.0, now)["max"] == CrashDiag.WINDOW_DEFAULT_MS, "без метки — по умолчанию")
	check(CrashDiag.window("2026-10-23T06:00:00", 0.0, now)["max"] == CrashDiag.WINDOW_DEFAULT_MS, "метка из будущего")
	check(CrashDiag.window("2020-01-01T00:00:00", 0.0, now)["max"] == CrashDiag.WINDOW_MAX_MS, "предел окна")


func test_parse_tasklist_overlays() -> void:
	var found := CrashDiag.parse_tasklist(TASKLIST_SAMPLE)
	check(found == PackedStringArray(["rtss.exe", "discord.exe"]), "только известные, без повторов: " + str(found))
	check(CrashDiag.parse_tasklist("").is_empty(), "пусто")


func test_unavailable_without_windows() -> void:
	if OS.get_name() == "Windows":
		return
	var d := CrashDiag.collect("")
	check(String(d["events_status"]).begins_with(CrashDiag.UNAVAILABLE), "события: недоступно")
	check(String(d["overlays_status"]).begins_with(CrashDiag.UNAVAILABLE), "оверлеи: недоступно")
	var r := CrashDiag.run_with_timeout("deltaplan-no-such-program", PackedStringArray(), 1.0)
	check(not r["ok"] and String(r["status"]) != "", "нет программы — не падает: " + str(r))
	var text := "\n".join(CrashDiag.format(d))
	check(text.contains("События Windows (сбой видеодрайвера): недоступно"), "в отчёте: " + text)


func test_cancel_stops_process() -> void:
	if OS.get_name() != "Linux":
		return
	CrashDiag.cancel = true
	var t0 := Time.get_ticks_msec()
	var r := CrashDiag.run_with_timeout("sleep", PackedStringArray(["30"]), 20.0)
	CrashDiag.cancel = false
	check(not r["ok"] and Time.get_ticks_msec() - t0 < 1000, "выход не ждёт программу: " + str(r))


func test_run_with_timeout_kills() -> void:
	if OS.get_name() != "Linux":
		return
	var t0 := Time.get_ticks_msec()
	var r := CrashDiag.run_with_timeout("sleep", PackedStringArray(["30"]), 0.5)
	check(not r["ok"] and r["status"] == "таймаут", "таймаут: " + str(r))
	check(Time.get_ticks_msec() - t0 < 5000, "не ждали процесс")
	var ok := CrashDiag.run_with_timeout("echo", PackedStringArray(["привет"]), 3.0)
	check(ok["ok"] and String(ok["text"]).strip_edges() == "привет", "вывод читается: " + str(ok))


func test_format_masks_user_and_limits() -> void:
	var d := {
		"events": CrashDiag.parse_wevtutil(WEVT_SAMPLE),
		"window_note": "x",
		"overlays": PackedStringArray(["rtss.exe"]),
		"logs": PackedStringArray(["x".repeat(20000)]),
		"driver": "AMD 31.0.1",
	}
	var text := "\n".join(CrashDiag.format(d))
	check(text.contains("id 4101") and text.contains("Display") and text.contains("rtss.exe"), "поля есть")
	check(not text.contains("Ivan"), "имя пользователя замаскировано")
	check(text.contains("Display: amdkmdap") or text.contains("amdkmdap"), "имя драйвера в строке")
	check(text.length() <= CrashDiag.MAX_SECTION + 4, "раздел ограничен: %d" % text.length())


func test_logs_summary() -> void:
	var dir := "user://test_diag_logs"
	DirAccess.make_dir_recursive_absolute(dir)
	for n in ["godot.log", "godot2026-10-21T10.00.00.log", "godot2026-10-22T10.00.00.log", "godot2026-10-23T10.00.00.log"]:
		var f := FileAccess.open(dir.path_join(n), FileAccess.WRITE)
		f.store_string("первая\n" + n + " строка\n")
		f.close()
	var s := "\n".join(CrashDiag.logs_summary(dir))
	for n in ["godot.log", "godot2026-10-21T10.00.00.log", "godot2026-10-23T10.00.00.log"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(n)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join("godot2026-10-22T10.00.00.log")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	check(s.contains("файлов godot*.log: 4"), "число файлов: " + s)
	check(s.contains("хвост предыдущего лога godot2026-10-22T10.00.00.log"), "хвост предыдущего (не свежего): " + s)
	check(s.contains("godot2026-10-22T10.00.00.log строка"), "строки хвоста: " + s)


func test_switches_snapshot_in_lock_and_report() -> void:
	var sw := CrashDiag.gpu_switches()
	check(sw.has("clouds.renderer") and sw.has("air_model.enabled"), "ключи CR-К4: " + str(sw.keys()))
	check(sw.has("rendering_driver") and sw.has("safe_reason"), "драйвер и причина безопасного набора")
	var lock := {"version": "1.5.22", "settings": {"graphics": "low"}}
	lock["settings"].merge({"gpu.sun_shadows": false, "clouds.renderer": "boxes"}, true)
	var path := "user://test_diag.lock"
	CrashReport.write_json(path, lock)
	var back := CrashReport.read_json(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var body := CrashReport.build_body(back, {}, "лог")
	check(body.contains("- gpu.sun_shadows: false") and body.contains("- clouds.renderer: boxes"), "рубильники в отчёте: " + body)


func test_body_with_diag_section() -> void:
	var diag := PackedStringArray(["## Диагностика", "- Драйвер видеокарты: AMD 31"])
	var big := "x".repeat(200000)
	var body := CrashReport.build_body({"gpu_driver": "AMD 31.0.1"}, {}, big, CrashReport.MAX_BODY, diag)
	check(body.length() <= CrashReport.MAX_BODY, "тело ≤ лимита")
	check(body.contains("## Диагностика") and body.contains("Версия драйвера видеокарты: AMD 31.0.1"), "раздел и драйвер")
	check(body.find("## Диагностика") < body.find("## Лог прошлого запуска"), "диагностика перед логом")
