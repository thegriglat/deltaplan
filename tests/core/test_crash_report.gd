extends TestCase
## Сборка отчёта о вылете без сети (CrashReport): метка, лог прошлого запуска, пути, обрезка, лимит.


func test_pick_previous_log() -> void:
	var names := PackedStringArray(
		["godot.log", "godot2026-10-13T10.00.00.log", "godot2026-10-14T09.30.00.log", "other.txt", "x.log"]
	)
	check(CrashReport.pick_previous_log(names) == "godot2026-10-14T09.30.00.log", "самый новый датированный")
	check(CrashReport.pick_previous_log(PackedStringArray(["godot.log"])) == "", "только текущий — нет прошлого")


func test_lock_detected() -> void:
	var path := "user://test_session.lock"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(CrashReport.read_json(path).is_empty(), "метки нет — прошлый запуск штатный")
	check(CrashReport.write_json(path, {"version": "1.2.3", "stage": "weather"}), "метка записана")
	var d := CrashReport.read_json(path)
	check(d.get("version") == "1.2.3" and d.get("stage") == "weather", "метка читается")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(CrashReport.read_json(path).is_empty(), "метка снята — штатный выход")


func test_sanitize_paths() -> void:
	var t := CrashReport.sanitize(
		"open C:\\Users\\Иван Петров\\AppData\\Roaming\\Deltaplan\\a.log and /home/greg/.local/x and /Users/bob/Library/y"
	)
	check(not t.contains("Иван") and not t.contains("greg") and not t.contains("bob"), "имена убраны: " + t)
	check(t.contains("~\\AppData") and t.contains("~/.local/x") and t.contains("~/Library/y"), "путь после имени цел: " + t)


func test_trim_log() -> void:
	var lines: PackedStringArray = []
	for i in 1000:
		lines.append("строка номер %d" % i)
	var log := "\n".join(lines)
	var t := CrashReport.trim_log(log, 2000)
	check(t.length() <= 2000, "влезло в лимит")
	check(t.begins_with(CrashReport.TRUNC_MARK), "пометка об обрезке")
	check(t.ends_with("строка номер 999"), "конец лога сохранён")
	check(t.split("\n")[1].begins_with("строка номер"), "начало — целая строка")
	check(CrashReport.trim_log("коротко", 2000) == "коротко", "короткий не трогаем")


func test_body_limit_and_content() -> void:
	var big := "x".repeat(200000) + "\nконец /home/secret/y\n````"
	var lock := {
		"version": "1.5.14",
		"stage": "weather",
		"started": "2026-10-14T10:00:00",
		"settings": {"graphics": "low", "bots": 3, "place": "altai"},
	}
	var info := {"os": "Windows 11", "gpu": "AMD RX 5600 XT", "cpu": "Ryzen 5 4500", "ram": "16.0 ГБ"}
	var body := CrashReport.build_body(lock, info, big)
	check(body.length() <= CrashReport.MAX_BODY, "тело ≤ лимита: %d" % body.length())
	check(body.contains("AMD RX 5600 XT") and body.contains("graphics: low") and body.contains("стадия: weather"), "поля есть")
	check(body.contains("конец ~/y"), "путь в логе заменён")
	check(not body.contains("secret"), "имя пользователя не просочилось")
	check(body.count("````") == 2, "ограда лога одна")
	var small := CrashReport.build_body(lock, info, "короткий лог")
	check(small.contains("короткий лог") and not small.contains(CrashReport.TRUNC_MARK), "короткий лог целиком")
	check(CrashReport.title(lock, info) == "Вылет 1.5.14 — AMD RX 5600 XT, Windows 11", "заголовок")


func test_should_track() -> void:
	check(not CrashReporter.should_track(false, false, PackedStringArray()), "из редактора — нет")
	check(not CrashReporter.should_track(true, true, PackedStringArray()), "headless — нет")
	check(not CrashReporter.should_track(true, false, PackedStringArray(["--smoke"])), "smoke — нет")
	check(CrashReporter.should_track(true, false, PackedStringArray()), "обычный запуск сборки — да")
