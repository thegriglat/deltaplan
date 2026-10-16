extends TestCase
## Контракт GL-К6 (docs/contracts/goals.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

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
	check(found.get("GL-К6", 0) == VERSION, "GL-К6 (v%d) в заголовках: %s" % [VERSION, found])


func test_interface() -> void:
	var scr: Script = load("res://scripts/goals/track_ribbon.gd")
	check(scr != null and scr.get_instance_base_type() == &"MeshInstance3D", "TrackRibbon extends MeshInstance3D")
	var m := {}
	for d: Dictionary in scr.get_script_method_list():
		m[d.name] = d
	check(m.has("set_track"), "TrackRibbon.set_track")
	if m.has("set_track"):
		check((m.set_track.args as Array).size() == 2, "set_track(track, latlon_fn)")


func test_config_keys() -> void:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/goals/track.json"))
	check(cfg.has("_doc"), "track.json: _doc")
	for k in ["width_px", "vs_window_s", "climb_full_ms", "sink_full_ms", "dead_band_ms", "alpha_zero",
			"color_climb", "color_sink", "max_points"]:
		check(cfg.has(k), "track.json: %s" % k)
		check(cfg.has(k + "_doc"), "track.json: %s_doc" % k)
