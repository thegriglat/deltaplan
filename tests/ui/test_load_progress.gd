extends Node
## NO-7: счётчик запросов загрузки места «Рельеф: N/M», «Покров: N/M», «Всего: N/M»;
## полоса идёт по счётчику, из кеша засчитывается сразу. Без сети.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _mk() -> LoadProgress:
	var p := LoadProgress.new({"dem": 2.0, "landcover": 2.0})
	p.begin()
	return p


## Счётчик растёт до M, полоса по нему доходит до конца этапа.
func test_counter_grows_to_total() -> void:
	var p := _mk()
	p.stage("dem", "x")
	var last := -1.0
	for i in range(1, 64):
		p.counter("dem", i, 63)
		check(p.fraction >= last, "полоса не идёт назад (i=%d)" % i)
		last = p.fraction
	check(p.counters["dem"] == [63, 63], "N дошло до M")
	check(absf(p.fraction - 0.5) < 1e-6, "конец этапа dem = 0.5 (%f)" % p.fraction)
	check(p.counter_text("dem") == tr("loading_counter_dem") % [63, 63], "текст N/M: " + p.counter_text("dem"))


## Из кеша: контекст сборки засчитывает запрос сразу — N=M без ожидания сети.
func test_cached_counted_immediately() -> void:
	var ctx := LocationBuildContext.new()
	var log: Array = []
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: log.append([s, d, t]))
	ctx.plan("dem", 3)
	for i in 3:
		ctx.tick("dem")
	check(log == [["dem", 0, 3], ["dem", 1, 3], ["dem", 2, 3], ["dem", 3, 3]], "план и тики: " + str(log))
	ctx.plan("dem", 2)  # второй слой — M растёт
	check(log[-1] == ["dem", 3, 5], "M растёт при новом плане")


## Тексты ru/en и общий счётчик по двум стадиям.
func test_texts_and_total() -> void:
	var p := _mk()
	p.counter("dem", 23, 63)
	check(p.total_text() == "", "одна стадия — общий не показываем")
	p.counter("surface", 40, 86)
	check(p.total_text() == tr("loading_counter_total") % [63, 149], "общий: " + p.total_text())
	var old := TranslationServer.get_locale()
	TranslationServer.set_locale("ru")
	check(p.counter_text("dem") == "Рельеф: 23/63", "ru: " + p.counter_text("dem"))
	check(p.counter_text("surface") == "Покров: 40/86", "ru: " + p.counter_text("surface"))
	TranslationServer.set_locale("en")
	check(p.counter_text("dem") == "Terrain: 23/63", "en: " + p.counter_text("dem"))
	TranslationServer.set_locale(old)
	check(p.counter_text("rivers") == "", "стадия без счётчика — пусто")


## Экран загрузки показывает строку счётчика; без запросов (всё готово/нет стадии) — скрыта.
func test_screen_shows_counter() -> void:
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	add_child(l)
	var p := _mk()
	l.open(p, "")
	check(l.counter_line() == "", "до запросов строки нет")
	p.stage("dem", "x")
	p.counter("dem", 5, 10)
	check(l.counter_line() == p.counter_text("dem"), "строка: " + l.counter_line())
	l.queue_free()
