extends Node
## Контракт VI-К2 (docs/contracts/volcano-island.md): окно «Тренировка» — группы мест, вкладки, место из карточки.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=volcano_island_k2

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_config_groups() -> void:
	var gs: Array = TrainingMenu.load_cards().get("groups", [])
	check(gs.size() == 2, "две группы")
	check(String(gs[0].id) == "training_island" and gs[0].cards.size() == 4, "первая — учебный остров, 4 карточки")
	check(String(gs[1].id) == "volcano_island" and gs[1].cards.size() == 3, "вторая — вулканический остров, 3 карточки")
	var want := {"cliffs": ["east_cliffs", "duration", 600], "crater": ["crater_ridge", "duration", 600], "landing": ["plateau_landing", "landing", 25]}
	var sites := []
	for s: Dictionary in Locations.config("volcano_island").get("start_sites", []):
		sites.append(String(s.id))
	for c: Dictionary in gs[1].cards:
		var w: Array = want[c.id]
		check(c.site == w[0] and c.goal.kind == w[1] and c.goal.value == w[2] and c.goal.level == "custom", "карточка " + String(c.id))
		check(c.location == "volcano_island" and String(c.site) in sites, "место и старт карточки " + String(c.id))
		check(String(c.title_key) == "training_volcano_" + String(c.id) and String(c.what_key) == String(c.title_key) + "_what", "ключи " + String(c.id))
		check(GoalSpec.validate([TrainingMenu.goal_of(c)]).is_empty(), "цель годна " + String(c.id))
	for g: Dictionary in gs:
		check(tr(String(g.title_key)) != String(g.title_key), "заголовок вкладки переведён")
		for c: Dictionary in g.cards:
			check(String(c.get("location", "")) == String(g.location), "location добавлен при чтении")
	for lang in ["ru", "en"]:
		Language.apply(lang)
		for c: Dictionary in gs[1].cards:
			check(tr(String(c.title_key)) != String(c.title_key) and tr(String(c.what_key)) != String(c.what_key), "%s: тексты %s" % [lang, c.id])
	Language.apply("ru")


func test_window_tabs_and_settings() -> void:
	var m: TrainingMenu = (load("res://scenes/ui/training_menu.tscn") as PackedScene).instantiate()
	add_child(m)
	var tabs: TabContainer = m.find_child("Tabs", true, false)
	check(tabs != null and tabs.get_tab_count() == 2 and tabs.current_tab == 0, "две вкладки, открыта первая")
	if tabs != null:
		check(tabs.get_tab_title(0) == tr("loc_training_island") and tabs.get_tab_title(1) == tr("loc_volcano_island"), "заголовки вкладок")
	var got: Array = []
	m.chosen.connect(func(c: Dictionary) -> void: got.append(c))
	m.press_card(2, 1)
	check(got.size() == 1 and got[0].location == "volcano_island" and got[0].site == "plateau_landing", "chosen с location")
	var base := FlightSettings.defaults()
	base.location_id = "altai"
	base.pick_lat = 50.0
	base.pick_lon = 86.0
	var s := TrainingMenu.settings_for(got[0], base)
	check(s.location_id == "volcano_island" and s.site_id == "plateau_landing" and not s.has_pick(), "место из карточки")
	check(s.goals.size() == 1 and s.goals[0].kind == "landing", "цель")
	check(base.location_id == "altai", "исходные настройки не тронуты")
	m.press_card(0)
	check(got.size() == 2 and got[1].location == "training_island", "первая вкладка — учебный остров")
	m.queue_free()
