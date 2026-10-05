extends TestCase
## Контрактные тесты модуля popular-places (docs/contracts/popular-places.md): PP-К1 — файл каталога
## стартов (тестовый и, если есть, настоящий), PP-К2 — интерфейс PopularPlaces и окна. Без сети и GPU.
## Правка контракта (версия +1) — вместе с этим файлом. Скрипты грузятся через load() и методы
## вызываются через call(), чтобы отсутствие файла/метода было падением теста, а не ошибкой разбора.

const DOC := "res://docs/contracts/popular-places.md"
const FIXTURE := "res://tests/ui/fixtures/hg_takeoffs_test.json"
const REAL := "res://data/places/hg_takeoffs.json"
const DATA_SCRIPT := "res://scripts/ui/popular_places.gd"
const WINDOW_SCRIPT := "res://scripts/ui/popular_places_window.gd"
const DIRS: PackedStringArray = [
	"N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
]


func _doc_line(head: String) -> String:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func test_versions_in_doc() -> void:
	check(_doc_line("## PP-К1.").contains("(v1)"), "PP-К1 v1 в документе")
	check(_doc_line("## PP-К2.").contains("(v1)"), "PP-К2 v1 в документе")


## Проверка файла по PP-К1; tag — для сообщений.
func _check_k1(path: String, tag: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	check(text != "", "%s: файл читается" % tag)
	var root: Variant = JSON.parse_string(text)
	check(root is Dictionary, "%s: корень — объект" % tag)
	if not root is Dictionary:
		return
	check(String(root.get("format", "")) == "deltaplan.hg_takeoffs", "%s: format" % tag)
	check(int(root.get("version", 0)) == 1, "%s: version 1" % tag)
	check(String(root.get("source", "")).strip_edges() != "", "%s: source" % tag)
	check(String(root.get("fetch_date_utc", "")).strip_edges() != "", "%s: fetch_date_utc" % tag)
	var countries: Variant = root.get("countries")
	check(countries is Dictionary, "%s: countries — объект" % tag)
	if not countries is Dictionary:
		return
	var re_cc := RegEx.create_from_string("^[A-Z]{2}$")
	for code: String in countries:
		check(re_cc.search(code) != null, "%s: код страны '%s'" % [tag, code])
		var names: Variant = countries[code]
		check(names is Dictionary, "%s: countries[%s] — объект" % [tag, code])
		if names is Dictionary:
			for l in ["en", "ru"]:
				check(String(names.get(l, "")).strip_edges() != "", "%s: countries[%s].%s" % [tag, code, l])
	var takeoffs: Variant = root.get("takeoffs")
	check(takeoffs is Array and not takeoffs.is_empty(), "%s: takeoffs — непустой массив" % tag)
	if not takeoffs is Array:
		return
	var re_id := RegEx.create_from_string("^(node|way|relation)/\\d+$")
	var ids := {}
	var used := {}
	var bad := 0
	for t: Variant in takeoffs:
		if not t is Dictionary:
			bad += 1
			continue
		var keys := (t as Dictionary).keys()
		keys.sort()
		var ok := keys == ["country", "ele", "id", "lat", "lon", "name", "orientation"]
		var id := String(t.get("id", ""))
		ok = ok and re_id.search(id) != null and not ids.has(id)
		ids[id] = true
		ok = ok and t.get("name") is String
		ok = ok and (t.get("lat") is float or t.get("lat") is int) and absf(float(t.lat)) <= 90.0
		ok = ok and (t.get("lon") is float or t.get("lon") is int) and absf(float(t.lon)) <= 180.0
		var cc: Variant = t.get("country")
		ok = ok and cc is String and (cc == "" or (re_cc.search(cc) != null and countries.has(cc)))
		if cc is String and cc != "":
			used[cc] = true
		var ele: Variant = t.get("ele")
		ok = ok and (ele == null or ((ele is float or ele is int) and float(ele) >= -500.0 and float(ele) <= 9000.0))
		var ori: Variant = t.get("orientation")
		ok = ok and ori is Array
		if ori is Array:
			var seen := {}
			for d: Variant in ori:
				ok = ok and d is String and DIRS.has(d) and not seen.has(d)
				seen[d] = true
		if not ok:
			bad += 1
			if bad <= 5:
				check(false, "%s: старт не по PP-К1: %s" % [tag, JSON.stringify(t)])
	check(bad == 0, "%s: стартов не по PP-К1: %d из %d" % [tag, bad, takeoffs.size()])
	for code: String in countries:
		check(used.has(code), "%s: страна %s без стартов" % [tag, code])


func test_k1_fixture() -> void:
	check(FileAccess.file_exists(FIXTURE), "тестовый каталог есть")
	_check_k1(FIXTURE, "fixture")


func test_k1_real_catalog_if_present() -> void:
	# Настоящий каталог появляется в PP-2; до этого файла нет и кнопка скрыта.
	if FileAccess.file_exists(REAL):
		_check_k1(REAL, "data")
		check(
			not FileAccess.get_file_as_string(REAL).contains("Тестовые данные"),
			"в data/ нет тестовых мест"
		)
	var ui: Dictionary = Config.get_config("ui")
	if ui.has("popular_places_path"):
		check(String(ui.popular_places_path) == REAL, "configs/ui.json → popular_places_path = %s" % REAL)


func test_k2_data_api() -> void:
	check(ResourceLoader.exists(DATA_SCRIPT), "есть %s" % DATA_SCRIPT)
	if not ResourceLoader.exists(DATA_SCRIPT):
		return
	var S: Script = load(DATA_SCRIPT)
	for m in ["load_catalog", "lang", "country_name", "group_by_country", "search", "display_name", "orientation_text"]:
		var has := false
		for d in S.get_script_method_list():
			if String(d.name) == m:
				has = true
		check(has, "PopularPlaces.%s" % m)
	var empty: Dictionary = S.call("load_catalog", "res://tests/ui/fixtures/no_such_file.json")
	check(empty.get("takeoffs", null) is Array and empty.takeoffs.is_empty(), "нет файла → пустой каталог")
	var cat: Dictionary = S.call("load_catalog", FIXTURE)
	var n: int = cat.get("takeoffs", []).size()
	check(n == 10, "в тестовом каталоге 10 стартов: %d" % n)
	var groups: Array = S.call("group_by_country", cat, "en")
	var sum := 0
	var names: PackedStringArray = []
	for g: Dictionary in groups:
		sum += int(g.get("count", -1))
		check(int(g.count) == g.get("places", []).size(), "count = числу мест в группе %s" % g.get("code"))
		names.append(String(g.get("name", "")))
	check(sum == n, "сумма count = числу стартов: %d" % sum)
	check(groups.size() == 4 and String(groups[-1].get("code", "?")) == "", "группа без страны — последняя")
	check(names.slice(0, 3) == PackedStringArray(["Austria", "Russia", "Slovenia"]), "страны по алфавиту (en): %s" % names)
	var groups_ru: Array = S.call("group_by_country", cat, "ru")
	check(String(groups_ru[0].get("name", "")) == "Австрия", "страны по алфавиту (ru)")
	check(S.call("country_name", cat, "SI", "ru") == "Словения", "country_name ru")
	check(S.call("country_name", cat, "XX", "ru") == "XX", "country_name: нет страны → код")
	var all: Array = cat.takeoffs
	check(S.call("search", all, "").size() == n, "пустой запрос — все")
	check(S.call("search", all, "  kob ").size() == 1, "поиск без регистра и пробелов по краям")
	check(S.call("search", all, "елочная").size() == 1, "поиск: ё = е")
	var unnamed: Dictionary = {}
	for t: Dictionary in all:
		if String(t.name) == "":
			unnamed = t
	check(String(S.call("display_name", unnamed)) != "", "пустое имя → запасная подпись")
	var with_ori: Dictionary = all[0]
	check(String(S.call("orientation_text", with_ori)) != "", "ориентация → текст")
	var no_ori: Dictionary = all[2]
	check(String(S.call("orientation_text", no_ori)) == "", "нет ориентации → пусто")


func test_k2_window_api() -> void:
	check(ResourceLoader.exists(WINDOW_SCRIPT), "есть %s" % WINDOW_SCRIPT)
	if not ResourceLoader.exists(WINDOW_SCRIPT):
		return
	var W: Script = load(WINDOW_SCRIPT)
	var w: Object = W.new()
	check(w is Control, "PopularPlacesWindow — Control")
	check(w.has_method("open"), "PopularPlacesWindow.open")
	check(w.has_signal("place_chosen") and w.has_signal("closed"), "сигналы place_chosen, closed")
	if w is Node:
		(w as Node).free()


func test_k2_screen_api() -> void:
	var scr: Object = load("res://scripts/ui/flight_setup_screen.gd").new()
	check("popular_places_path" in scr, "flight_setup_screen.popular_places_path")
	if scr is Node:
		(scr as Node).free()
	var key := "setup_popular_places"
	check(tr(key) != key, "перевод %s" % key)
	for k in ["places_country_unknown", "places_unnamed"]:
		check(tr(k) != k, "перевод %s" % k)
