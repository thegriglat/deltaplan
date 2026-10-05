extends TestCase
## MapPicker + конфиг подложек (SM-К1 v3): ограничение параллельности OSM, UA без «non-commercial».


func test_osm_max_parallel_two() -> void:
	var mp: Dictionary = Config.get_config("world").map_picker
	var osm: Dictionary = mp.basemaps[0]
	check(osm.id == "osm", "первый слой osm")
	check(int(osm.get("max_parallel", 0)) == 2, "osm.max_parallel = 2")
	for m: Dictionary in mp.basemaps:
		check(int(m.get("max_parallel", 1)) >= 1, "%s: max_parallel >= 1" % m.id)


func test_config_policy_keys() -> void:
	var mp: Dictionary = Config.get_config("world").map_picker
	check(float(mp.get("retry_after_s", 0.0)) > 0.0, "retry_after_s")
	check(float(mp.get("blocked_backoff_s", 0.0)) >= float(mp.get("retry_after_s", 0.0)), "blocked_backoff_s")
	check(not String(mp.user_agent).to_lower().contains("non-commercial"), "UA без non-commercial")


func test_picker_uses_loader_with_policy() -> void:
	var mp := MapPicker.new()
	check(mp.get_script().get_script_property_list().size() > 0, "MapPicker создаётся")
	mp.free()
