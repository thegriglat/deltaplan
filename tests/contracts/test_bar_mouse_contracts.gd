extends TestCase
## Контрактные тесты bar-mouse (docs/contracts/bar-mouse.md): BM-К1 мышь → штанга (MouseBar, ключи mouse.*),
## BM-К2 — только заголовок (поведение камер проверяет tests/game/). Правка контракта (версия +1) — вместе с этим файлом.
## MouseBar грузится через load(): до BM-3 класса нет, тест красный, но раннер не ломается.

const DOC := "res://docs/contracts/bar-mouse.md"
const MOUSE_BAR := "res://scripts/game/mouse_bar.gd"


func _mb() -> GDScript:
	if not ResourceLoader.exists(MOUSE_BAR):
		return null
	return load(MOUSE_BAR) as GDScript


func test_doc_headings() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/bar-mouse.md читается")
	var re := RegEx.create_from_string("(?m)^## (BM-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("BM-К1", 0) == 1, "BM-К1 (v1) в заголовках: %s" % found)
	check(found.get("BM-К2", 0) == 1, "BM-К2 (v1) в заголовках: %s" % found)


func test_k1_config_defaults() -> void:
	var m: Dictionary = Config.get_config("controls").get("mouse", {})
	approx(float(m.get("bar_travel_px", -1.0)), 2500.0, 1e-6, "mouse.bar_travel_px = 2500")
	approx(float(m.get("bar_sensitivity", -1.0)), 1.0, 1e-6, "mouse.bar_sensitivity = 1")
	approx(float(m.get("bar_deadzone", -1.0)), 0.02, 1e-6, "mouse.bar_deadzone = 0.02")
	for k in ["bar_travel_px", "bar_sensitivity", "bar_deadzone"]:
		check(m.has(k + "_doc"), "mouse.%s_doc" % k)
	var r: Variant = Config.get_config("ui").get("bar_sensitivity_range")
	check(r is Array and r.size() == 2, "ui.bar_sensitivity_range — [min, max]")
	if r is Array and r.size() == 2:
		approx(float(r[0]), 0.25, 1e-6, "bar_sensitivity_range[0] = 0.25")
		approx(float(r[1]), 4.0, 1e-6, "bar_sensitivity_range[1] = 4")


func test_k1_shape() -> void:
	var b := _mb()
	check(b != null, "scripts/game/mouse_bar.gd есть")
	if b == null:
		return
	for f in ["travel_px", "accumulate", "apply_deadzone"]:
		check(b.has_method(f), "MouseBar.%s()" % f)
	check(String(b.get_global_name()) == "MouseBar", "class_name MouseBar")


func test_k1_travel_and_accumulate() -> void:
	var b := _mb()
	if b == null or not b.has_method("accumulate") or not b.has_method("travel_px"):
		check(false, "MouseBar.travel_px/accumulate нет")
		return
	var m := {"bar_travel_px": 2500.0, "bar_sensitivity": 1.0, "bar_deadzone": 0.02}
	approx(b.travel_px(m), 2500.0, 1e-6, "travel_px при ×1")
	approx(b.travel_px({"bar_travel_px": 2500.0, "bar_sensitivity": 2.0}), 1250.0, 1e-6, "travel_px при ×2")
	approx(b.travel_px({}), 2500.0, 1e-6, "travel_px без ключей — по умолчанию")
	var o: Vector2 = b.accumulate(Vector2.ZERO, Vector2(2500.0, -1250.0), m)
	approx(o.x, 1.0, 1e-6, "полный ход по x")
	approx(o.y, -0.5, 1e-6, "половина хода по y, знак сохраняется")
	o = b.accumulate(o, Vector2(5000.0, -5000.0), m)
	approx(o.x, 1.0, 1e-6, "зажим +1")
	approx(o.y, -1.0, 1e-6, "зажим -1")
	# Порциями — то же, что разом (не зависит от разбиения на события/кадры).
	var p := Vector2.ZERO
	for i in 10:
		p = b.accumulate(p, Vector2(100.0, 50.0), m)
	var q: Vector2 = b.accumulate(Vector2.ZERO, Vector2(1000.0, 500.0), m)
	approx(p.x, q.x, 1e-6, "порциями = разом (x)")
	approx(p.y, q.y, 1e-6, "порциями = разом (y)")


func test_k1_deadzone_continuous() -> void:
	var b := _mb()
	if b == null or not b.has_method("apply_deadzone"):
		check(false, "MouseBar.apply_deadzone нет")
		return
	var dz := 0.02
	approx(b.apply_deadzone(0.0, dz), 0.0, 1e-9, "0 → 0")
	approx(b.apply_deadzone(dz, dz), 0.0, 1e-9, "порог → 0")
	approx(b.apply_deadzone(dz + 1e-4, dz), 1e-4 / (1.0 - dz), 1e-7, "сразу за порогом — без скачка")
	approx(b.apply_deadzone(1.0, dz), 1.0, 1e-9, "+1 → +1")
	approx(b.apply_deadzone(-1.0, dz), -1.0, 1e-9, "-1 → -1")
	approx(b.apply_deadzone(0.5, dz), (0.5 - dz) / (1.0 - dz), 1e-9, "середина")
	approx(b.apply_deadzone(-0.3, dz), -b.apply_deadzone(0.3, dz), 1e-9, "нечётна")
	var prev := -INF
	for i in 201:
		var x := -1.0 + 0.01 * i
		var y: float = b.apply_deadzone(x, dz)
		check(y >= prev - 1e-9, "монотонна при x=%.2f" % x)
		prev = y
	approx(b.apply_deadzone(0.9, 0.9), b.apply_deadzone(0.9, 0.5), 1e-9, "dz зажат в [0, 0.5]")
