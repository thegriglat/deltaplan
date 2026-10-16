extends TestCase
## Контракт GL-К1 (docs/contracts/goals.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/goals.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (GL-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("GL-К1", 0) == VERSION, "GL-К1 (v%d) в заголовках: %s" % [VERSION, found])


func test_interface() -> void:
	var script: Script = load("res://scripts/goals/goal_spec.gd")
	check(script != null, "goal_spec.gd загружается")
	if script == null:
		return
	var methods := []
	for m in script.get_script_method_list():
		methods.append(String(m.name))
	for need: String in ["make","validate"]:
		check(need in methods, "метод %s" % need)
	var kinds: Array = script.get_script_constant_map().get("KINDS", [])
	check(kinds == ["height", "duration", "distance", "return", "triangle", "route", "speed", "landing"], "KINDS в порядке контракта")
	check(script.get_script_constant_map().get("LEVELS", []) == ["easy", "medium", "hard", "custom"], "LEVELS")
