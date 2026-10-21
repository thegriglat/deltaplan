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
		"setup_tow", "setup_tow_none", "setup_tow_winch", "setup_tow_aerotow", "setup_tow_mp_off", "setup_tow_mode_off"
	]:
		check(csv.contains("\n" + k + ","), k)


func test_refresh_same_place_keeps_choice() -> void:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(m)
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


func _set_mode(mode: String) -> void:
	Config.reload()
	Config.get_config("controls")["roll_control_mode"] = mode


func test_mode_not_pendulum() -> void:
	for mode in ["weight_shift", "rate"]:
		_set_mode(mode)
		var o := LaunchOptions.parse(PackedStringArray(["--tow=winch_static"]))
		check(o.apply_to(FlightSettings.defaults()).tow_kind == "", "--tow отклонён в %s" % mode)
		var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
		(Engine.get_main_loop() as SceneTree).root.add_child(m)
		var s := FlightSettings.defaults()
		s.tow_kind = "winch_static"
		m.set_settings(s)
		var opt: OptionButton = m.get("_tow_opt")
		check(opt.disabled, "строка неактивна в %s" % mode)
		check(String(m.call("_tow_selected")) == "", "значение пусто в %s" % mode)
		check((m.get("_tow_hint") as Label).visible, "подпись видна в %s" % mode)
		check(String(Config.value("controls", "roll_control_mode")) == mode, "режим не переключён")
		m.queue_free()
	_set_mode("pendulum")
	var o2 := LaunchOptions.parse(PackedStringArray(["--tow=winch_static"]))
	check(o2.apply_to(FlightSettings.defaults()).tow_kind == "winch_static", "в Маятнике --tow работает")
	Config.reload()
