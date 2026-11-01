extends TestCase
## Контрактные тесты pilot-feedback-trim (docs/contracts/pilot-feedback-trim.md): PFT-К1 — умолчания управления и аппарата,
## которые модуль может поменять; PFT-К2 — только заголовок (формат итогов исследования, файлы в tools/research).
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-feedback-trim.md"


func test_doc_headings() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/pilot-feedback-trim.md читается")
	var re := RegEx.create_from_string("(?m)^## (PFT-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("PFT-К1", 0) == 2, "PFT-К1 (v2) в заголовках: %s" % found)
	check(found.get("PFT-К2", 0) == 1, "PFT-К2 (v1) в заголовках: %s" % found)


func test_k1_controls() -> void:
	var c: Dictionary = Config.get_config("controls")
	var m: Dictionary = c.get("mouse", {})
	approx(float(m.get("bar_travel_px", -1.0)), 4000.0, 1e-6, "mouse.bar_travel_px = 4000 (PFT-К1 v2)")
	approx(float(m.get("bar_sensitivity", -1.0)), 1.0, 1e-6, "mouse.bar_sensitivity = 1")
	approx(float(m.get("bar_deadzone", -1.0)), 0.02, 1e-6, "mouse.bar_deadzone = 0.02")
	approx(float(m.get("bar_return_to_center_per_s", -1.0)), 0.0, 1e-6, "mouse.bar_return_to_center_per_s = 0")
	var kb: Dictionary = c.get("keyboard", {})
	approx(float(kb.get("center_time_s", -1.0)), 0.2, 1e-6, "keyboard.center_time_s = 0.2")
	var r: Variant = Config.get_config("ui").get("bar_sensitivity_range")
	check(r is Array and r.size() == 2, "ui.bar_sensitivity_range — [min, max]")
	if r is Array and r.size() == 2:
		approx(float(r[0]), 0.1, 1e-6, "bar_sensitivity_range[0] = 0.1 (PFT-К1 v2)")
		approx(float(r[1]), 4.0, 1e-6, "bar_sensitivity_range[1] = 4")


func test_k1_apparatus() -> void:
	var a: Dictionary = Config.get_config("pendulum").get("apparatus_defaults", {})
	approx(float(a.get("hang_shift_cm", -99.0)), 0.0, 1e-6, "apparatus_defaults.hang_shift_cm = 0")
	var spec: Array = FlightSettings.APPARATUS_SPEC.get("hang_shift_cm", [])
	check(spec.size() == 4, "APPARATUS_SPEC.hang_shift_cm — [мин, макс, шаг, умолчание]")
	if spec.size() == 4:
		approx(float(spec[0]), -4.0, 1e-6, "hang_shift_cm мин −4")
		approx(float(spec[1]), 4.0, 1e-6, "hang_shift_cm макс +4")
		approx(float(spec[2]), 0.5, 1e-6, "hang_shift_cm шаг 0,5")
