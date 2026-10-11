extends TestCase
## Контрактный тест PD-К6 (docs/contracts/pendulum.md): касание земли — оценка посадки не меняется
## (пороги flight.json → landing и LandingJudge.evaluate по скорости первого касания).
## Пики удельной силы на касании проверяют тесты владельца (PD-38). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"
const FLIGHT := "res://configs/flight.json"


func _text(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return text


func test_doc_heading() -> void:
	var text := _text(DOC)
	check(not text.is_empty(), "docs/contracts/pendulum.md читается")
	var re := RegEx.create_from_string("(?m)^## PD-К6\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 1, "заголовок «## PD-К6. … (v1)»")


func _landing() -> Dictionary:
	var d: Variant = JSON.parse_string(_text(FLIGHT))
	check(d is Dictionary and (d as Dictionary).has("landing"), "flight.json → landing")
	return (d as Dictionary).get("landing", {}) if d is Dictionary else {}


func test_thresholds_unchanged() -> void:
	var c := _landing()
	var want := {
		"hard_vertical_ms": 5.0,
		"crash_vertical_ms": 7.0,
		"soft_horizontal_ms": 3.0,
		"crash_horizontal_ms": 12.0,
		"soft_bank_deg": 15.0,
		"crash_bank_deg": 35.0,
	}
	for k: String in want:
		check(
			c.has(k) and is_equal_approx(float(c[k]), float(want[k])),
			"landing.%s = %s (%s)" % [k, want[k], c.get(k, "нет")]
		)


func test_judge_grades() -> void:
	var c := _landing()
	if c.is_empty():
		return
	var up := Vector3.UP
	check(LandingJudge.evaluate(Vector3(0, -1.0, -2.0), up, 0.0, c).grade == "soft", "1 м/с — мягко")
	check(LandingJudge.evaluate(Vector3(0, -3.5, -2.0), up, 0.0, c).grade == "soft", "3,5 м/с — мягко")
	check(LandingJudge.evaluate(Vector3(0, -5.5, -1.0), up, 0.0, c).grade == "hard", "5,5 м/с — жёстко")
	check(LandingJudge.evaluate(Vector3(0, -8.0, -1.0), up, 0.0, c).grade == "crash", "8 м/с — авария")
	check(LandingJudge.evaluate(Vector3(0, -1.0, -8.0), up, 0.0, c).grade == "hard", "гор. 8 м/с — жёстко")
	check(LandingJudge.evaluate(Vector3(0, -1.0, -2.0), up, 40.0, c).grade == "crash", "крен 40° — авария")
