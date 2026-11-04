extends TestCase
## Контрактные тесты pilot-handling (docs/contracts/pilot-handling.md): PHD-К1 v2 — неизменные ключи хода мыши, удалённый center_time_s и темп руки arms.cmd_tau_s
## и боковой модели; PHD-К2 — только заголовок (формат итогов исследования, файлы в tools/research).
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-handling.md"


func test_doc_headings() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/pilot-handling.md читается")
	var re := RegEx.create_from_string("(?m)^## (PHD-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("PHD-К1", 0) == 2, "PHD-К1 (v2) в заголовках: %s" % found)
	check(found.get("PHD-К2", 0) == 1, "PHD-К2 (v1) в заголовках: %s" % found)


func test_k1_mouse() -> void:
	var m: Dictionary = Config.get_config("controls").get("mouse", {})
	approx(float(m.get("bar_travel_px", -1.0)), 4000.0, 1e-6, "mouse.bar_travel_px = 4000 (PHD-К1)")
	var r: Variant = Config.get_config("ui").get("bar_sensitivity_range")
	check(r is Array and r.size() == 2, "ui.bar_sensitivity_range — [min, max]")
	if r is Array and r.size() == 2:
		approx(float(r[0]), 0.1, 1e-6, "bar_sensitivity_range[0] = 0.1")
		approx(float(r[1]), 4.0, 1e-6, "bar_sensitivity_range[1] = 4")


func test_k1_yaw() -> void:
	var y: Dictionary = Config.get_config("pendulum").get("yaw", {})
	approx(float(y.get("cn_beta", -99.0)), 0.05, 1e-6, "yaw.cn_beta = 0.05 (PD-К2)")
	approx(float(y.get("cn_p_add", -99.0)), 0.15, 1e-6, "yaw.cn_p_add = 0.15 (PD-К2)")
	approx(float(y.get("cn_r_add", -99.0)), -0.03, 1e-6, "yaw.cn_r_add = -0.03 (PD-К2)")


func test_k1_v2_hand_rate() -> void:
	var kb: Dictionary = Config.get_config("controls").get("keyboard", {})
	check(not kb.has("center_time_s"), "keyboard.center_time_s удалён (PHD-К1 v2)")
	var a: Dictionary = Config.get_config("pendulum").get("arms", {})
	approx(float(a.get("cmd_tau_s", -1.0)), 0.15, 1e-6, "arms.cmd_tau_s = 0.15 (PD-К2 v10)")
