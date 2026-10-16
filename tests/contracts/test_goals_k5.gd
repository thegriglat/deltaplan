extends TestCase
## Контракт GL-К5 (docs/contracts/goals.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/goals.md"
const VERSION := 3


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (GL-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("GL-К5", 0) == VERSION, "GL-К5 (v%d) в заголовках: %s" % [VERSION, found])


func _methods(path: String) -> Array:
	var scr: Script = load(path)
	return scr.get_script_method_list().map(func(m: Dictionary) -> String: return m.name)


func test_interface() -> void:
	var ft := _methods("res://scripts/goals/flight_track.gd")
	for m in ["size", "append", "vertical_speed_ms", "inside_fraction"]:
		check(ft.has(m), "FlightTrack.%s" % m)
	var ft_props: Array = (load("res://scripts/goals/flight_track.gd") as Script).get_script_property_list().map(
		func(p: Dictionary) -> String: return p.name)
	for p in ["lat", "lon", "alt_m", "t_s", "name", "source"]:
		check(ft_props.has(p), "FlightTrack.%s" % p)
	var io := _methods("res://scripts/goals/track_io.gd")
	for m in ["read", "last_error", "read_igc", "write_igc", "read_gpx"]:
		check(io.has(m), "TrackIO.%s" % m)
	var st := _methods("res://scripts/goals/last_track_store.gd")
	for m in ["place_key", "path_for", "save", "load"]:
		check(st.has(m), "LastTrackStore.%s" % m)
	var rec := _methods("res://scripts/goals/track_recorder.gd")
	for m in ["start", "update", "track"]:
		check(rec.has(m), "TrackRecorder.%s" % m)
