extends TestCase
## TI-3: одно правило фиксированной погоды во всех путях выбора (last_flight, избранное, повтор,
## командная строка, сеть). Фикстура — ti_weather_fixture.gd (копия altai с weather).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=training_island_rule

const Fixture := preload("res://tests/fixtures/ti_weather_fixture.gd")


func _check_fixed(s: FlightSettings, what: String) -> void:
	approx(s.wind_speed_kmh, 21.6, 0.001, what + ": ветер")
	check(not s.wind_into_launch, what + ": не встречный")
	approx(s.wind_from_deg, 270.0, 0.001, what + ": откуда")
	check(s.sky == "partly" and s.month == 7 and s.day == 15, what + ": небо/дата")
	approx(s.start_hour, 12.0, 0.001, what + ": час")
	approx(s.temperature_c, 24.0, 0.001, what + ": температура")


func test_last_flight_restore() -> void:
	var fx := Fixture.new()
	fx.install()
	var path := "user://ti3_last_flight.json"
	UserSettings.save_last_flight(Fixture.settings(), path)
	_check_fixed(UserSettings.load_last_flight(path), "last_flight")
	DirAccess.remove_absolute(path)
	fx.restore()


func test_favorites_and_repeat() -> void:
	var fx := Fixture.new()
	fx.install()
	var path := "user://ti3_favorites.json"
	var id := Favorites.add(Fixture.settings(), path)
	_check_fixed(Favorites.settings_of(id, path), "избранное")
	_check_fixed(FlightSettings.from_dict(Fixture.settings().to_dict()), "повтор (from_dict)")
	DirAccess.remove_absolute(path)
	fx.restore()


func test_command_line_overrides() -> void:
	var fx := Fixture.new()
	fx.install()
	var lo := LaunchOptions.new()
	lo.overrides = {"wind": 1.0, "sky": "clear", "temp": 40.0, "hour": 9.0}
	_check_fixed(lo.apply_to(Fixture.settings()), "командная строка")
	fx.restore()


func test_net_zone_params() -> void:
	var fx := Fixture.new()
	fx.install()
	var scr: NetScreen = (load("res://scenes/ui/net_screen.tscn") as PackedScene).instantiate()
	scr.settings = Fixture.settings()
	_check_fixed(scr.zone_params(), "сеть")
	scr.free()
	fx.restore()


func test_other_site_keeps_pilot_choice() -> void:
	var fx := Fixture.new()
	fx.install()
	var s: FlightSettings = Fixture.settings("tugaya_south")
	var back := FlightSettings.from_dict(s.to_dict())
	approx(back.temperature_c, 5.0, 0.001, "без weather — выбор пилота")
	check(back.sky == "overcast", "sky пилота")
	fx.restore()
