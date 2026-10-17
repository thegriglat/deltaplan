extends TestCase
## Контракт CLF-К5 (docs/contracts/cloud-field.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/cloud-field.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (CLF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("CLF-К5", 0) == VERSION, "CLF-К5 (v%d) в заголовках: %s" % [VERSION, found])


func test_config_keys() -> void:
	var c: Dictionary = Config.get_config("atmosphere").get("cloud_field", {})
	check(not c.is_empty() and c.has("_doc"), "atmosphere.json → cloud_field с _doc")
	for k in ["enabled", "step_s", "spinup_s", "depth_max_m", "edge_fade_m", "net_interval_s", "net_blend_s"]:
		check(c.has(k), "ключ %s" % k)
		check(c.has(k + "_doc"), "ключ %s_doc" % k)
	check(c.get("enabled") is bool, "enabled — bool")
	var missing := []
	for k in c:
		var key := String(k)
		if key == "_doc" or key.ends_with("_doc"):
			continue
		if not c.has(key + "_doc"):
			missing.append(key)
	check(missing.is_empty(), "все ключи с _doc: %s" % [missing])
	check(Config.get_config("atmosphere").thermal.has("cloud_shade_factor"), "thermal.cloud_shade_factor остаётся")
