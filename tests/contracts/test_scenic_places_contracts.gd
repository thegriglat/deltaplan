extends TestCase
## Контрактные тесты SCP-К3 (docs/contracts/scenic-places.md): интерфейс ScenicPlaces, окна, экрана и
## переводов; конфиг пути каталога. Без сети и GPU.

const DOC := "res://docs/contracts/scenic-places.md"
const FIXTURE := "res://tests/ui/fixtures/scenic_places_test.json"
const DATA_SCRIPT := "res://scripts/ui/scenic_places.gd"
const WINDOW_SCRIPT := "res://scripts/ui/scenic_places_window.gd"
const REAL := "res://data/places/scenic_places.json"
const KINDS: PackedStringArray = [
	"mountain", "canyon", "lake", "coast", "volcano", "glacier", "valley", "fjord", "desert", "island"
]


func _doc_line(head: String) -> String:
	var text := FileAccess.get_file_as_string(DOC)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func test_version_in_doc() -> void:
	check(_doc_line("## SCP-К3.").contains("(v3)"), "SCP-К3 v3 в документе")


func test_data_api() -> void:
	check(ResourceLoader.exists(DATA_SCRIPT), "есть %s" % DATA_SCRIPT)
	if not ResourceLoader.exists(DATA_SCRIPT):
		return
	var S: Script = load(DATA_SCRIPT)
	for m in ["load_catalog", "group_by_country", "name", "why"]:
		var has := false
		for d in S.get_script_method_list():
			if String(d.name) == m:
				has = true
		check(has, "ScenicPlaces.%s" % m)
	var empty: Dictionary = S.call("load_catalog", "res://tests/ui/fixtures/no_such_file.json")
	check(empty.get("places", null) is Array and empty.places.is_empty(), "нет файла → пустой каталог")
	check(empty.get("countries", null) is Dictionary, "в пустом каталоге есть countries")
	var cat: Dictionary = S.call("load_catalog", FIXTURE)
	check(cat.places.size() == 3, "в тестовом каталоге 3 места")
	var groups: Array = S.call("group_by_country", cat, "en")
	var sum := 0
	for g: Dictionary in groups:
		for k in ["code", "name", "count", "places"]:
			check(g.has(k), "в группе есть %s" % k)
		check(int(g.count) == g.places.size(), "count = числу мест")
		sum += int(g.count)
	check(sum == 3, "сумма count = числу мест")
	var p: Dictionary = cat.places[0]
	check(S.call("name", p, "ru") == p.name_ru and S.call("name", p, "en") == p.name_en, "name по языку")
	check(S.call("why", p, "ru") == p.why_ru and S.call("why", p, "en") == p.why_en, "why по языку")


func test_window_api() -> void:
	check(ResourceLoader.exists(WINDOW_SCRIPT), "есть %s" % WINDOW_SCRIPT)
	if not ResourceLoader.exists(WINDOW_SCRIPT):
		return
	var w: Object = (load(WINDOW_SCRIPT) as Script).new()
	check(w is Control, "ScenicPlacesWindow — Control")
	check(w.has_method("open"), "ScenicPlacesWindow.open")
	check(w.has_signal("place_chosen") and w.has_signal("closed"), "сигналы place_chosen, closed")
	if w is Node:
		(w as Node).free()


func test_screen_api_and_translations() -> void:
	var scr: Object = load("res://scripts/ui/flight_setup_screen.gd").new()
	check("scenic_places_path" in scr, "flight_setup_screen.scenic_places_path")
	if scr is Node:
		(scr as Node).free()
	var keys: PackedStringArray = ["setup_scenic_places", "scenic_title"]
	for k in KINDS:
		keys.append("scenic_kind_" + k)
	for key in keys:
		check(tr(key) != key, "перевод %s" % key)
	TranslationServer.set_locale("en")
	check(tr("setup_scenic_places") == "Scenic places…", "en: кнопка")
	TranslationServer.set_locale("ru")
	check(tr("setup_scenic_places") == "Красивые места…", "ru: кнопка")


func test_config_path() -> void:
	var ui: Dictionary = Config.get_config("ui")
	check(String(ui.get("scenic_places_path", "")) == REAL, "configs/ui.json → scenic_places_path = %s" % REAL)
