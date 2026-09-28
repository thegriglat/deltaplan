extends TestCase
## Имена над ботами (BotPilots.pick_names, configs/bot_names.json, BotGlider → NameTag):
## в полёте без повторов, из пула текущего языка, повторяются при том же сиде; смена языка —
## имена из нового пула; настройка bots.json → names.show прячет и показывает имена.


func _pool(lang: String) -> Array:
	return Config.get_config("bot_names").get(lang, [])


func _make(count: int, seed_value: int) -> BotPilots:
	var b := BotPilots.new()
	b.visuals_enabled = false
	b.setup(
		{
			"ground_fn": func(_x: float, _z: float) -> float: return 300.0,
			"air_fn": func(_p: Vector3) -> Vector3: return Vector3.ZERO,
			"start": Vector3(0, 300, 0),
			"count": count,
			"seed": seed_value,
		}
	)
	return b


func test_pools() -> void:
	for lang: String in ["ru", "en"]:
		var p := _pool(lang)
		check(p.size() >= 30, "пул %s ≥ 30 имён: %d" % [lang, p.size()])
		var u := {}
		for n: Variant in p:
			u[n] = true
		check(u.size() == p.size(), "в пуле %s нет повторов" % lang)


func test_unique_from_current_language() -> void:
	var saved := TranslationServer.get_locale()
	for lang: String in ["ru", "en"]:
		TranslationServer.set_locale(lang)
		var b := _make(20, 7)
		var seen := {}
		for a in b.agents:
			check(_pool(lang).has(a.pilot_name), "%s: «%s» из пула" % [lang, a.pilot_name])
			check(not seen.has(a.pilot_name), "%s: «%s» не повторяется" % [lang, a.pilot_name])
			seen[a.pilot_name] = true
		var again := _make(20, 7)
		for i in b.agents.size():
			check(b.agents[i].pilot_name == again.agents[i].pilot_name, "тот же сид — те же имена")
		b.free()
		again.free()
	TranslationServer.set_locale(saved)


func test_language_switch_refreshes() -> void:
	var saved := TranslationServer.get_locale()
	TranslationServer.set_locale("ru")
	var b := _make(6, 3)
	check(_pool("ru").has(b.agents[0].pilot_name), "сначала по-русски")
	TranslationServer.set_locale("en")
	b.refresh_names()
	for a in b.agents:
		check(_pool("en").has(a.pilot_name), "после смены языка — английское: " + a.pilot_name)
	b.free()
	TranslationServer.set_locale(saved)


func test_more_bots_than_pool() -> void:
	var names := BotPilots.pick_names(_pool("en").size() + 3, "en", 1)
	var u := {}
	for n in names:
		u[n] = true
	check(u.size() == names.size(), "пул кончился — всё равно без повторов")


func test_setting_toggles_tag() -> void:
	# Раннер тестов (корень занят его _ready — добавляем к нему).
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	var root := tree_root.get_child(tree_root.get_child_count() - 1)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	var a := BotAgent.new()
	a.pilot_name = "Саша"
	a.state = BotAgent.State.FLY
	var g := BotGlider.new()
	g.agent = a
	root.add_child(g)
	g.position = Vector3(0, 0, -100)
	g.call("_build_name_tag")
	var nc: Dictionary = Config.get_config("bots").get("names", {}).duplicate()
	nc.show = true
	g.set_name_config(nc)
	g.call("_update_name_tag", cam, 100.0, true)
	check(g.name_tag.visible and g.name_tag.text == "Саша", "имя видно вблизи")
	g.call("_update_name_tag", cam, 5000.0, true)
	check(not g.name_tag.visible, "далеко — не видно")
	nc.show = false
	g.set_name_config(nc)
	g.call("_update_name_tag", cam, 100.0, true)
	check(not g.name_tag.visible, "настройка выключена — не видно")
	check(not g.name_tag.no_depth_test, "за рельефом не видно (проверка глубины)")
	var f: Font = g.name_tag.font
	check(f != null and f.has_char("Ж".unicode_at(0)), "шрифт с кириллицей")
	g.free()
	cam.free()
