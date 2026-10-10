extends TestCase
## Контрактные тесты control-bar (docs/contracts/control-bar.md): CB-К1 настройки устройства трапеции,
## CB-К2 ход ручки → управление (BarAxis). Правка контракта (версия +1) — вместе с этим файлом.
## BarAxis грузится через load(): до CB-2 класса нет, тест красный, но раннер не ломается.

const DOC := "res://docs/contracts/control-bar.md"
const BAR_AXIS := "res://scripts/game/bar_axis.gd"
const GP := {"deadzone": 0.08, "expo": 0.3, "sensitivity": 1.0}


func _bar() -> GDScript:
	if not ResourceLoader.exists(BAR_AXIS):
		return null
	return load(BAR_AXIS) as GDScript


func test_doc_headings() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/control-bar.md читается")
	var re := RegEx.create_from_string("(?m)^## (CB-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	for id in ["CB-К1", "CB-К2"]:
		check(found.get(id, 0) == 1, "%s (v1) в заголовках: %s" % [id, found])


func test_k1_config_defaults() -> void:
	var gp: Dictionary = Config.get_config("controls").get("gamepad", {})
	for k in ["enabled", "roll_axis", "pitch_axis", "deadzone", "expo", "sensitivity", "run_button"]:
		check(gp.has(k), "gamepad.%s" % k)
	check(gp.get("device_guid") is String and String(gp.get("device_guid", "x")) == "", "device_guid = \"\"")
	check(gp.get("device_name") is String, "device_name: String")
	check(gp.get("invert_roll") == false, "invert_roll = false")
	check(gp.get("invert_pitch") == false, "invert_pitch = false")
	var cal: Variant = gp.get("calibration")
	check(cal is Dictionary, "calibration: Dictionary")
	if cal is Dictionary:
		for ax in ["roll", "pitch"]:
			var a: Variant = cal.get(ax)
			check(a is Array and a.size() == 3, "calibration.%s — [min, center, max]" % ax)
			if a is Array and a.size() == 3:
				check(
					is_equal_approx(float(a[0]), -1.0) and is_zero_approx(float(a[1]))
					and is_equal_approx(float(a[2]), 1.0),
					"calibration.%s = [-1, 0, 1]" % ax
				)


func test_k2_shape() -> void:
	var b := _bar()
	check(b != null, "scripts/game/bar_axis.gd есть")
	if b == null:
		return
	for m in ["normalize", "shape", "axis_value", "find_device"]:
		check(b.has_method(m), "BarAxis.%s()" % m)
	check(String(b.get_global_name()) == "BarAxis", "class_name BarAxis")


func test_k2_normalize_invariants() -> void:
	var b := _bar()
	if b == null or not b.has_method("normalize"):
		check(false, "BarAxis.normalize нет")
		return
	var cal := [-0.6, 0.1, 0.8]
	approx(b.normalize(0.1, cal), 0.0, 1e-6, "center → 0")
	approx(b.normalize(-0.6, cal), -1.0, 1e-6, "min → -1")
	approx(b.normalize(0.8, cal), 1.0, 1e-6, "max → 1")
	approx(b.normalize(1.0, cal), 1.0, 1e-6, "за max → 1")
	approx(b.normalize(-1.0, cal), -1.0, 1e-6, "за min → -1")
	var prev := -INF
	for i in range(41):
		var v: float = b.normalize(-1.0 + 0.05 * i, cal)
		check(v >= prev - 1e-9, "монотонно (%d)" % i)
		prev = v
	for bad: Array in [[0.0, 0.0, 0.0], [0.2, 0.2, 0.9], [], [1.0]]:
		for raw in [-1.0, 0.0, 0.2, 0.5, 1.0]:
			var v: float = b.normalize(raw, bad)
			check(is_finite(v) and absf(v) <= 1.0, "конечно при cal=%s raw=%s: %s" % [bad, raw, v])


func test_k2_identity_and_invert() -> void:
	var b := _bar()
	if b == null or not b.has_method("axis_value"):
		check(false, "BarAxis.axis_value нет")
		return
	var ident := [-1.0, 0.0, 1.0]
	for raw in [-1.0, -0.5, -0.05, 0.0, 0.07, 0.3, 0.9, 1.0]:
		var want := _old_stick(raw, GP)
		approx(b.shape(raw, GP), want, 1e-6, "shape = прежний _stick (%s)" % raw)
		approx(b.axis_value(raw, ident, false, GP), want, 1e-6, "без калибровки = прежний _stick (%s)" % raw)
		approx(b.axis_value(raw, ident, true, GP), -want, 1e-6, "invert меняет знак (%s)" % raw)
	check(b.find_device("no-such-guid-control-bar") == -1, "find_device(чужой GUID) = -1")


## Формула _stick из input_controller.gd до CB-2 (эталон «геймпад без калибровки не меняется»).
static func _old_stick(v: float, gp: Dictionary) -> float:
	var dz := float(gp.deadzone)
	if absf(v) < dz:
		return 0.0
	var x := (absf(v) - dz) / (1.0 - dz)
	var e := float(gp.expo)
	x = (1.0 - e) * x + e * x * x * x
	return signf(v) * clampf(x * float(gp.sensitivity), 0.0, 1.0)
