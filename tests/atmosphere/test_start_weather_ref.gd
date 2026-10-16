extends TestCase
## TI-8, TI-К2 v2: weather.wind_ref — разбор StartWeather и условия воздуха AirRuntime (без GPU).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_weather_ref

const Fixture := preload("res://tests/fixtures/ti_weather_fixture.gd")


class Stub:
	extends RefCounted
	var weather := {"wind_speed_kmh": 32.4, "wind_from_deg": 270.0}
	var hour := 12.0
	var temperature_c := 24.0
	var sky := "clear"
	var location_id := Fixture.LOC
	var site_id := Fixture.SITE


func test_parse_wind_ref() -> void:
	check(String(StartWeather.parse(Fixture.WEATHER).wind_ref) == "start", "по умолчанию start")
	var w: Dictionary = Fixture.WEATHER.duplicate()
	w.wind_ref = "inflow"
	check(String(StartWeather.parse(w).wind_ref) == "inflow", "inflow разобран")
	w.wind_ref = "bogus"
	check(StartWeather.parse(w).is_empty(), "недопустимый wind_ref — без фиксации")
	w.wind_ref = 3
	check(StartWeather.parse(w).is_empty(), "wind_ref не строка")


func test_conditions_carry_wind_ref() -> void:
	var fx := Fixture.new()
	var w: Dictionary = Fixture.WEATHER.duplicate()
	w.wind_ref = "inflow"
	fx.install(w)
	var s: FlightSettings = Fixture.settings()
	check(StartWeather.wind_ref_of(s) == "inflow", "wind_ref_of")
	var st := Stub.new()
	var c := AirRuntime.conditions_of(st, st, s)
	check(String(c.wind_ref) == "inflow", "conditions_of.wind_ref")
	fx.restore()
	fx.install()
	check(String(AirRuntime.conditions_of(st, st, Fixture.settings()).wind_ref) == "start", "набор без wind_ref — start")
	check(String(AirRuntime.conditions_of(st, st, Fixture.settings("")).wind_ref) == "start", "старт без набора — start")
	fx.restore()


func test_wind_ref_change_recomputes() -> void:
	var a := {hour = 12.0, u10 = 9.0, wdir = 270.0, t_max = 24.0, sky = "clear", wind_ref = "start"}
	var b: Dictionary = a.duplicate()
	check(AirRuntime.needs_recompute(a, b, 15.0) == "", "то же — без пересчёта")
	b.wind_ref = "inflow"
	check(AirRuntime.needs_recompute(a, b, 15.0) != "", "смена wind_ref — пересчёт")
	var legacy := {hour = 12.0, u10 = 9.0, wdir = 270.0, t_max = 24.0, sky = "clear"}
	check(AirRuntime.needs_recompute(legacy, a, 15.0) == "", "без поля = start")
