extends TestCase
## Контракт GL-К3 (docs/contracts/goals.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

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
	check(found.get("GL-К3", 0) == VERSION, "GL-К3 (v%d) в заголовках: %s" % [VERSION, found])


func test_interface() -> void:
	var script: Script = load("res://scripts/goals/goal_tracker.gd")
	check(script != null, "goal_tracker.gd загружается")
	if script == null:
		return
	var methods := []
	for m in script.get_script_method_list():
		methods.append(String(m.name))
	for need: String in ["setup","reset","update","on_landed","items","lead_tracker","instrument_points","instrument_active_index","instrument_state","world_points","result"]:
		check(need in methods, "метод %s" % need)

	var sigs := []
	for s in script.get_script_signal_list():
		sigs.append(String(s.name))
	check("goal_done" in sigs and "goal_failed" in sigs, "сигналы: %s" % [sigs])
