extends TestCase
## Контракт SPF-К4 (docs/contracts/speed-feel.md): тангаж крыла → голова в кабине.

const DOC := "res://docs/contracts/speed-feel.md"


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "speed-feel.md читается")
	var re := RegEx.create_from_string("(?m)^## (SPF-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("SPF-К4", 0) == 2, "SPF-К4 (v2) в заголовках: %s" % found)


func test_cockpit_keys() -> void:
	var c: Dictionary = Config.get_config("camera").cockpit
	for k in ["head_pitch_follow", "head_pitch_follow_s", "head_pitch_max_deg"]:
		check(c.has(k) and c.has(k + "_doc"), "cockpit.%s с _doc" % k)
	check(is_equal_approx(float(c.head_pitch_follow), 0.3), "head_pitch_follow = 0,3")
	check(is_equal_approx(float(c.head_pitch_follow_s), 2.0), "head_pitch_follow_s = 2,0")


func test_trim_pitch_method() -> void:
	check(FlightModel.new().has_method("trim_pitch"), "FlightModel.trim_pitch()")


func test_pendulum_trim_pitch_method() -> void:
	check(PendulumModel.new().has_method("trim_pitch"), "PendulumModel.trim_pitch()")
