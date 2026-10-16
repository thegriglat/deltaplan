extends TestCase
## Контракт TI-К2 (docs/contracts/training-island.md): start_sites[].weather → FlightSettings.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=training_island_k2

const Fixture := preload("res://tests/fixtures/ti_weather_fixture.gd")


func test_parse_all_fields() -> void:
	var w := StartWeather.parse(Fixture.WEATHER)
	check(not w.is_empty(), "корректный набор разобран")
	approx(float(w.wind_from_deg), 270.0, 0.001, "wind_from_deg")
	approx(float(w.wind_speed_ms), 6.0, 0.001, "wind_speed_ms")
	approx(float(w.start_hour), 12.0, 0.001, "start_hour")
	check(int(w.month) == 7 and int(w.day) == 15, "дата")
	check(String(w.sky) == "partly", "sky")
	approx(float(w.temperature_c), 24.0, 0.001, "temperature_c")


func test_parse_invalid_gives_empty() -> void:
	var bad_hour: Dictionary = Fixture.WEATHER.duplicate()
	bad_hour.start_hour = 13.0
	check(StartWeather.parse(bad_hour).is_empty(), "час не из start_hours")
	var bad_sky: Dictionary = Fixture.WEATHER.duplicate()
	bad_sky.sky = "storm"
	check(StartWeather.parse(bad_sky).is_empty(), "недопустимый sky")
	var no_temp: Dictionary = Fixture.WEATHER.duplicate()
	no_temp.erase("temperature_c")
	check(StartWeather.parse(no_temp).is_empty(), "нет поля — без фиксации")
	var bad_date: Dictionary = Fixture.WEATHER.duplicate()
	bad_date.month = 2
	bad_date.day = 31
	check(StartWeather.parse(bad_date).is_empty(), "31 февраля")
	check(StartWeather.parse("x").is_empty(), "не словарь")


func test_apply_maps_to_flight_settings() -> void:
	var fx := Fixture.new()
	fx.install()
	var s: FlightSettings = Fixture.settings()
	check(StartWeather.apply(s), "apply → true")
	approx(s.wind_speed_kmh, 6.0 * 3.6, 0.001, "м/с → км/ч ×3,6")
	check(not s.wind_into_launch, "wind_into_launch = false")
	approx(s.wind_from_deg, 270.0, 0.001, "wind_from_deg")
	approx(s.start_hour, 12.0, 0.001, "start_hour")
	check(s.month == 7 and s.day == 15, "дата")
	check(s.sky == "partly", "sky")
	approx(s.temperature_c, 24.0, 0.001, "температура")
	fx.restore()


func test_empty_site_id_is_first_start() -> void:
	var fx := Fixture.new()
	fx.install()
	var cfg: Dictionary = Config.get_config("locations/" + Fixture.LOC)
	var first_id := String(cfg.start_sites[0].id)
	cfg.start_sites[0]["weather"] = Fixture.WEATHER
	var s: FlightSettings = Fixture.settings("")
	check(StartWeather.has_fixed(s) == (first_id != ""), "пустой site_id — первый старт места")
	fx.restore()


func test_no_weather_leaves_fields() -> void:
	var fx := Fixture.new()
	fx.install()
	var s: FlightSettings = Fixture.settings("tugaya_south")
	var before := s.to_dict()
	check(not StartWeather.apply(s), "нет weather → false")
	check(JSON.stringify(before) == JSON.stringify(s.to_dict()), "поля не меняются")
	fx.restore()


func test_pick_point_has_no_fixed_weather() -> void:
	var fx := Fixture.new()
	fx.install()
	var s: FlightSettings = Fixture.settings()
	s.pick_lat = 51.0
	s.pick_lon = 85.0
	check(not StartWeather.apply(s), "точка с карты — без фиксированной погоды")
	approx(s.temperature_c, 5.0, 0.001, "температура не тронута")
	fx.restore()


func test_invalid_weather_in_config_not_fixed() -> void:
	var fx := Fixture.new()
	fx.install({"wind_from_deg": 270, "wind_speed_ms": 6.0, "start_hour": 11.0, "month": 7, "day": 15,
		"sky": "partly", "temperature_c": 24.0})
	var s: FlightSettings = Fixture.settings()
	check(not StartWeather.apply(s), "недопустимый час → без фиксации")
	fx.restore()
