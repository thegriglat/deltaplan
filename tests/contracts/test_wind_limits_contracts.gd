extends TestCase
## Контрактные тесты модуля wind-limits (docs/contracts/wind-limits.md), WL-К1: класс крыла по
## поперечине и предел ветра класса. Без GPU. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/wind-limits.md"
const CLASSES := "wing_classes"
const FORBIDDEN := ["однообшив", "двухобшив", "single-surface", "double-surface", "single surface", "double surface"]


func test_k1_version_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	check(not text.is_empty(), "нет " + DOC)
	var at := text.find("## WL-К1.")
	var line := text.substr(at, text.find("\n", at) - at) if at >= 0 else ""
	check(line.contains("(v1)"), "WL-К1 v1 в документе: %s" % line)


func test_class_table_complete() -> void:
	var classes: Dictionary = Config.get_config(CLASSES).get("classes", {})
	check(classes.size() == 4, "четыре класса: %d" % classes.size())
	var prev_hi := 0.0
	for i in range(1, 5):
		var c: Dictionary = classes.get(str(i), {})
		check(not c.is_empty(), "класс %d есть" % i)
		var key := String(c.get("name_key", ""))
		check(key != "" and tr(key) != key, "класс %d: перевод %s" % [i, key])
		var lim: Array = c.get("wind_limit_ms", [])
		check(lim.size() == 2 and float(lim[0]) < float(lim[1]), "класс %d: lo < hi %s" % [i, lim])
		if lim.size() == 2:
			check(float(lim[1]) >= prev_hi, "класс %d: hi не убывает" % i)
			prev_hi = float(lim[1])
		check(String(c.get("_doc", "")) != "", "класс %d: _doc" % i)


func test_every_wing_has_class() -> void:
	var wings := Config.list_configs("wings")
	check(wings.size() == 48, "крыльев: %d" % wings.size())
	var counts := {1: 0, 2: 0, 3: 0, 4: 0}
	for w in wings:
		var cfg := Config.get_config(w)
		var wc: Variant = cfg.get("wind_class")
		check(wc is float or wc is int, "%s: wind_class задан" % w)
		var ci := WingCatalog.wind_class(cfg)
		check(ci >= 1 and ci <= 4, "%s: класс %d" % [w, ci])
		if counts.has(ci):
			counts[ci] += 1
		var lim := WingCatalog.wind_limit(cfg)
		check(lim.x > 0.0 and lim.x < lim.y, "%s: предел %s" % [w, lim])
		check(String(cfg.get("wind_class_doc", "")) != "", "%s: wind_class_doc" % w)
		check(not cfg.has("wind_max_ms") and not cfg.has("wind_max_ms_doc"), "%s: нет wind_max_ms" % w)
		var ds := float(cfg.get("double_surface_pct", -1.0))
		check(ds >= 0.0 and ds <= 100.0, "%s: double_surface_pct %s" % [w, ds])
		var src := String(cfg.get("double_surface_src", ""))
		check(src == "passport" or src == "pilot_estimate", "%s: double_surface_src %s" % [w, src])
		var doc := String(cfg.get("wind_class_doc", "")) + String(cfg.get("double_surface_pct_doc", ""))
		check(doc.contains("двойной обшивки"), "%s: источник доли обшивки в doc" % w)
	for i in counts:
		check(counts[i] > 0, "в классе %d есть крылья" % i)


func test_catalog_api() -> void:
	var cfg := Config.get_config("wings/training")
	check(WingCatalog.wind_class(cfg) == 1, "training — класс 1")
	check(WingCatalog.wind_limit(cfg) == Vector2(7, 10), "предел класса 1: %s" % WingCatalog.wind_limit(cfg))
	check(WingCatalog.wind_limit({}) == Vector2.ZERO, "нет класса — нулевой предел")
	check(WingCatalog.wind_class({}) == 0, "нет класса — 0")
	var src := FileAccess.get_file_as_string("res://scripts/game/wing_catalog.gd")
	check(not src.contains("func wind_max"), "wind_max удалён")


func test_no_surface_labels_in_ui() -> void:
	var csv := FileAccess.get_file_as_string("res://locale/ui.csv").to_lower()
	for f in FORBIDDEN:
		check(not csv.contains(f), "locale/ui.csv: нет «%s»" % f)
	var ui := FileAccess.get_file_as_string("res://scripts/ui/flight_setup_screen.gd")
	check(not ui.contains("double_surface") and not ui.contains("single_surface"), "меню не выводит обшивку")
	for f in FORBIDDEN:
		check(not ui.to_lower().contains(f), "flight_setup_screen.gd: нет «%s»" % f)
