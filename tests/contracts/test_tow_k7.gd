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
	for k in ["setup_tow", "setup_tow_none", "setup_tow_winch", "setup_tow_aerotow", "setup_tow_mp_off"]:
		check(csv.contains("\n" + k + ","), k)
