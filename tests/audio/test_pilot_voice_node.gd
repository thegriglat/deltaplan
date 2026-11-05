extends TestCase
## Узел PilotVoice (PV-К3/К4): голос, язык, путь файла, молчание без файлов, пасхалки в поле зрения.


func _node() -> PilotVoice:
	var v := PilotVoice.new()
	v.setup(Config.get_config("pilot_voice"), 3)
	return v


func _queued(v: PilotVoice) -> bool:
	for e: Dictionary in v.logic._pending:
		if e.id == "egg_eagle":
			return true
	return v.logic._egg_done.has("egg_eagle")


func test_set_voice_values() -> void:
	var v := _node()
	check(v.voice == "male", "по умолчанию male")
	v.set_voice("female")
	check(v.voice == "female", "female")
	v.set_voice("robot")
	check(v.voice == "off" and not v.is_active(), "неизвестное значение = off")
	v.set_voice("male")
	v.set_suppressed(true)
	check(not v.is_active(), "подавлен — неактивен")
	v.free()


func test_language_by_locale() -> void:
	var v := _node()
	var old := TranslationServer.get_locale()
	TranslationServer.set_locale("ru")
	check(v.lang() == "ru", "ru")
	TranslationServer.set_locale("en_US")
	check(v.lang() == "en", "en")
	TranslationServer.set_locale("de")
	check(v.lang() == "en", "иначе en")
	TranslationServer.set_locale(old)
	v.free()


func test_missing_files_are_silent() -> void:
	var v := _node()
	var t := Telemetry.new()
	t.phase = "flying"
	t.altitude_agl = 100.0
	t.altitude_msl = 1000.0
	v.on_event("took_off", {"altitude_msl": 1000.0})
	for i in 40:
		v.update(t, 0.0, 0.0, 0.1)
	check(v.current_line() == "", "файлов голосов нет: ничего не звучит, ошибок нет")
	v.on_event("goal")
	for i in 5:
		v.update(t, 0.0, 0.0, 0.1)
	check(v.current_line() == "", "и на событии")
	v.free()


func test_off_and_suppressed_ignore_events() -> void:
	var v := _node()
	v.set_voice("off")
	v.on_event("goal")
	v.set_voice("male")
	var t := Telemetry.new()
	t.phase = "flying"
	var line := v.logic.update(0.1, {"phase": "flying"})
	check(line == "", "события при off не копятся")
	v.free()


func test_egg_in_view() -> void:
	var cam := Transform3D.IDENTITY  # смотрит в −Z
	check(PilotVoice.egg_in_view(cam, Vector3(0, 0, -100), 30.0, 150.0), "прямо по курсу")
	check(not PilotVoice.egg_in_view(cam, Vector3(0, 0, -100), 30.0, 90.0), "дальше max_dist_m")
	check(not PilotVoice.egg_in_view(cam, Vector3(0, 0, 100), 30.0, 150.0), "сзади")
	check(PilotVoice.egg_in_view(cam, Vector3(50, 0, -100), 30.0, 150.0), "26,6° — в конусе 30°")
	check(not PilotVoice.egg_in_view(cam, Vector3(70, 0, -100), 30.0, 150.0), "35° — вне конуса")


## Пасхалка в поле зрения hold_s -> реплика; за рельефом — нет.
func test_watch_eggs_hold_and_terrain() -> void:
	var v := _node()
	var cam := Camera3D.new()  # вне дерева: transform = global_transform
	var egg := EasterEgg.new()
	egg.id = "eagle"
	egg.position = Vector3(0, 0, -100)
	v.on_event("took_off", {"altitude_msl": 0.0})
	v.logic.update(30.0, {"phase": "flying"})  # позади quiet_after_takeoff_s и gap
	for i in 20:  # 5 с по 0,25
		v.watch_eggs(cam, [egg], 0.25)
	check(_queued(v), "пасхалка в конусе 1,5 с -> egg_seen (событие в очереди)")
	var w := _node()
	w.height_fn = func(_x: float, _z: float) -> float: return 50.0  # холм выше глаза (y = 0)
	w.on_event("took_off", {"altitude_msl": 0.0})
	w.logic.update(30.0, {"phase": "flying"})
	for i in 20:
		w.watch_eggs(cam, [egg], 0.25)
	check(not _queued(w), "за рельефом — не видна")
	var x := _node()
	x.on_event("took_off", {"altitude_msl": 0.0})
	x.logic.update(30.0, {"phase": "flying"})
	egg.position = Vector3(0, 0, -400)  # eagle: max_dist_m 150
	for i in 20:
		x.watch_eggs(cam, [egg], 0.25)
	check(not _queued(x), "дальше max_dist_m — нет")
	egg.free()
	cam.free()
	v.free()
	w.free()
	x.free()
