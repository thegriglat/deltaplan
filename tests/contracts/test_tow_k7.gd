extends TestCase
## Контракт TW-К7 (docs/contracts/tow.md): выбор буксировки при старте.


func test_roundtrip() -> void:
	var s := FlightSettings.defaults()
	check(s.tow_kind == "", "умолчание — без буксировки")
	for k in ["winch_static", "aerotow", ""]:
		s.tow_kind = k
		check(FlightSettings.from_dict(s.to_dict()).tow_kind == k, "круг %s" % k)
	check(FlightSettings.from_dict({"tow_kind": "xyz"}).tow_kind == "", "неизвестное → пусто")


func test_cli() -> void:
	var o := LaunchOptions.parse(PackedStringArray(["--tow=winch_static"]))
	check(o.apply_to(FlightSettings.defaults()).tow_kind == "winch_static", "--tow=winch_static")
	o = LaunchOptions.parse(PackedStringArray(["--tow=xyz"]))
	check(o.apply_to(FlightSettings.defaults()).tow_kind == "", "--tow=xyz")
	o = LaunchOptions.parse(PackedStringArray(["--tow=none"]))
	var base := FlightSettings.defaults()
	base.tow_kind = "aerotow"
	check(o.apply_to(base).tow_kind == "", "--tow=none")


func test_defaults_and_kinds() -> void:
	var site := {"tow": {"kinds": ["aerotow"]}}
	check(FlightSetupScreen.default_tow_kind(site) == "aerotow", "умолчание площадки с tow")
	check(FlightSetupScreen.default_tow_kind(site, true) == "", "мультиплеер → пусто")
	check(FlightSetupScreen.default_tow_kind({}) == "", "без tow — Нет")
	check(FlightSetupScreen.tow_kinds_for_site(site) == ["aerotow"], "виды площадки")
	check(FlightSetupScreen.tow_kinds_for_site({}).size() == 2, "без tow — все виды")


func test_locale_keys() -> void:
	var csv := FileAccess.get_file_as_string("res://locale/ui.csv")
	for k in [
		"setup_tow", "setup_tow_none", "setup_tow_winch", "setup_tow_aerotow", "setup_tow_mp_off"
	]:
		check(csv.contains("\n" + k + ","), k)


func test_refresh_same_place_keeps_choice() -> void:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	# в дерево — под узел раннера (окно root занято, пока раннер в _ready); допущение: раннер — последний узел root
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	tree_root.get_child(tree_root.get_child_count() - 1).add_child(m)
	var s := FlightSettings.defaults()
	s.location_id = "altai"
	s.site_id = "tugaya_south"
	m.set_settings(s)
	var opt: OptionButton = m.get("_tow_opt")
	opt.select(2)  # вид из списка площадки без tow (все виды)
	var chosen := String(m.call("_tow_selected"))
	check(chosen != "", "вид выбран (%s)" % chosen)
	(m.get("_row") as PlacePickRow).refresh()  # то же место → changed
	check(String(m.call("_tow_selected")) == chosen, "повторный refresh того же места не сбрасывает выбор")
	s.site_id = "sinyukha_west"
	(m.get("_row") as PlacePickRow).settings = s
	(m.get("_row") as PlacePickRow).refresh()
	check(String(m.call("_tow_selected")) == "", "смена места → умолчание (без tow — Нет)")
	m.queue_free()


func test_tow_option() -> void:
	var o := LaunchOptions.parse(PackedStringArray(["--tow=winch_static"]))
	check(o.apply_to(FlightSettings.defaults()).tow_kind == "winch_static", "--tow работает")
