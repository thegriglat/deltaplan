extends TestCase
## Контракт GL-К2 (docs/contracts/goals.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

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
	check(found.get("GL-К2", 0) == VERSION, "GL-К2 (v%d) в заголовках: %s" % [VERSION, found])


func test_estimator_interface() -> void:
	var scr: Script = load("res://scripts/goals/goal_estimator.gd")
	check(scr != null, "goal_estimator.gd грузится")
	if scr == null:
		return
	var methods := {}
	for m in scr.get_script_method_list():
		methods[m.name] = m
	var want := {
		"weather_for": ["s"],
		"suggest": ["kind", "level", "wx", "route_m"],
		"suggest_all": ["wx", "route_m"],
	}
	for name in want:
		check(methods.has(name), "GoalEstimator.%s" % name)
		if not methods.has(name):
			continue
		var args: Array = methods[name].args.map(func(a: Dictionary) -> String: return a.name)
		check(args == want[name], "%s(%s): %s" % [name, ", ".join(want[name]), args])
		check(methods[name].flags & METHOD_FLAG_STATIC, "%s — static" % name)
	check(methods.suggest.default_args == [0.0], "suggest: route_m = 0.0")
	check(methods.suggest_all.default_args == [0.0], "suggest_all: route_m = 0.0")


func test_estimate_config_docs() -> void:
	var c := Config.get_config("goals/estimate")
	check(not c.is_empty(), "configs/goals/estimate.json читается")
	check(c.has("_doc"), "estimate.json: _doc")
	for kind in ["height", "duration", "distance", "return", "triangle", "speed", "landing"]:
		check(c.has(kind), "estimate.json: раздел %s" % kind)
	var missing := []
	_collect_undocumented(c, "", missing)
	check(missing.is_empty(), "ключи без _doc: %s" % [missing])


## Каждый ключ словаря-раздела — с key_doc (или сам раздел — с _doc), рекурсивно по разделам.
func _collect_undocumented(d: Dictionary, path: String, out: Array) -> void:
	if not d.has("_doc") and path != "":
		out.append(path + "._doc")
	for k in d:
		var key := String(k)
		if key.begins_with("_") or key.ends_with("_doc"):
			continue
		if d[k] is Dictionary and (d[k] as Dictionary).has("_doc"):
			_collect_undocumented(d[k], path + "." + key, out)
		elif not d.has(key + "_doc"):
			out.append(path + "." + key)
