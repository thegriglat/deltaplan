extends Node
## «Полёт…»: выбор крыла — класс, потом модель, строка описания (docs/plan/wings_lineup.md §6,
## приёмка 4). Порядок классов — configs/wing_groups.json, моделей — WingCatalog.

const SCENE := "res://scenes/ui/flight_setup_screen.tscn"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _open(wing: String) -> FlightSetupScreen:
	var m: FlightSetupScreen = (load(SCENE) as PackedScene).instantiate()
	add_child(m)
	var s := FlightSettings.defaults()
	s.wing = wing
	m.set_settings(s)
	return m


func _items(opt: OptionButton) -> PackedStringArray:
	var out := PackedStringArray()
	for i in opt.item_count:
		out.append(opt.get_item_text(i))
	return out


func _model_names(group: String) -> PackedStringArray:
	var out := PackedStringArray()
	for w in WingCatalog.wings_in_group(group):
		out.append(tr(String(Config.get_config(w).get("name", ""))))
	return out


func test_class_and_model_order() -> void:
	var m := _open("wings/training")
	var classes := _items(m.get("_class_opt"))
	var groups := WingCatalog.groups()
	check(classes.size() == groups.size(), "классов %d: %s" % [groups.size(), classes])
	for i in mini(classes.size(), groups.size()):
		check(
			classes[i].begins_with(tr(String(groups[i].name)) + " — "),
			"класс %d — %s: %s" % [i, groups[i].id, classes[i]]
		)
	check(classes[1].contains("7") and classes[1].contains("9"), "диапазон учебных: %s" % classes[1])
	check(classes[1].contains(tr("unit_ms")), "ветер в м/с: %s" % classes[1])
	var models := _items(m.get("_wing_opt"))
	check(models == _model_names("trainer"), "модели учебных по WingCatalog: %s" % [models])
	check(models.size() == 2, "Target и Falcon: %s" % [models])
	m.queue_free()


func test_restore_saved_wing() -> void:
	for wing in ["wings/laminar", "wings/combat", "wings/apogee"]:
		var m := _open(wing)
		var group := WingCatalog.group_of(wing)
		var gi := -1
		var groups := WingCatalog.groups()
		for i in groups.size():
			if groups[i].id == group:
				gi = i
		var class_opt: OptionButton = m.get("_class_opt")
		var wing_opt: OptionButton = m.get("_wing_opt")
		check(class_opt.selected == gi, "%s: класс %s (%d)" % [wing, group, class_opt.selected])
		var want := tr(String(Config.value(wing, "name", "")))
		check(
			wing_opt.get_item_text(wing_opt.selected) == want,
			"%s: модель %s" % [wing, wing_opt.get_item_text(wing_opt.selected)]
		)
		var mass: HSlider = m.get("_mass")
		check(
			is_equal_approx(mass.min_value, float(Config.value(wing, "pilot_mass_min_kg", 0.0))),
			"%s: ползунок массы по модели" % wing
		)
		m.queue_free()


func test_change_class_changes_models_and_done() -> void:
	var m := _open("wings/training")
	var got: Array = []
	m.done.connect(func(s: FlightSettings) -> void: got.append(s))
	var class_opt: OptionButton = m.get("_class_opt")
	var wing_opt: OptionButton = m.get("_wing_opt")
	class_opt.select(2)  # мачтовые двухобшивочные
	class_opt.item_selected.emit(2)
	check(_items(wing_opt) == _model_names("kingpost"), "модели мачтовых: %s" % [_items(wing_opt)])
	wing_opt.select(1)
	wing_opt.item_selected.emit(1)
	var second := WingCatalog.wings_in_group("kingpost")[1]
	var info: Label = m.get("_wing_info")
	check(info.text.contains(tr("setup_wing_kingpost")), "описание: %s" % info.text)
	# ушли в другой класс и вернулись — выбрана модель, выбранная там последней
	class_opt.select(3)
	class_opt.item_selected.emit(3)
	check(_items(wing_opt) == _model_names("topless"), "модели безмачтовых")
	class_opt.select(2)
	class_opt.item_selected.emit(2)
	check(wing_opt.selected == 1, "возврат к классу — последняя модель (%d)" % wing_opt.selected)
	m.call("_on_done")
	check(got.size() == 1, "«Готово» шлёт настройки")
	if got.size() == 1:
		check((got[0] as FlightSettings).wing == second, "крыло %s" % (got[0] as FlightSettings).wing)
	m.queue_free()


func test_both_languages_give_text() -> void:
	var was := TranslationServer.get_locale()
	for lang in ["ru", "en"]:
		TranslationServer.set_locale(lang)
		var m := _open("wings/laminar")
		var texts := _items(m.get("_class_opt"))
		texts.append_array(_items(m.get("_wing_opt")))
		var info: String = (m.get("_wing_info") as Label).text
		texts.append(info)
		for t in texts:
			var ok := t != "" and not t.contains("setup_") and not t.contains("wing_")
			check(ok, "%s: %s" % [lang, t])
		var area := "14" + tr("setup_decimal_point") + "5"
		check(info.contains(area), "%s: площадь 14,5: %s" % [lang, info])
		if lang == "ru":
			check(info.contains("14,5 м²") and info.contains("пилот 65–95 кг"), "ru: %s" % info)
		else:
			check(info.contains("14.5 m²") and info.contains("glide 13.2"), "en: %s" % info)
		m.queue_free()
	TranslationServer.set_locale(was)
