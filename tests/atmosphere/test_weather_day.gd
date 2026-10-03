extends TestCase
## Погода из прогноза в атмосфере (docs/archive/plan/weather-by-temperature.md): ветер прогноза — на старте
## и растёт с высотой над стартом (пилот, 28.09.2026); ход дня — мягкое обновление погоды без
## пересоздания поля термиков.


static func _flat(_x: float, _z: float) -> float:
	return 1000.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo(w: Dictionary) -> Atmosphere:
	var a := Atmosphere.new()
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	return a


func _day(hour: float) -> Dictionary:
	return WeatherModel.derive(
		{"temperature_c": 26.0, "wind_speed_kmh": 11.0, "wind_from_deg": 270.0},
		WeatherModel.reference_context(),
		WeatherModel.config(),
		hour
	)


func test_wind_grows_above_launch() -> void:
	var a := _atmo(_day(14.0))
	var wc: Dictionary = Config.get_config("atmosphere").wind
	a.set_wind(18.0, 270.0, 1000.0)  # 5 м/с на старте (1000 м)
	var at_launch := a.mean_wind_at(Vector3(0, 1000.0 + float(wc.reference_height_m), 0)).length()
	approx(at_launch, 5.0, 0.05, "на старте — ветер прогноза")
	var above := a.mean_wind_at(Vector3(0, 2000.0, 0)).length()
	check(above > 12.0 and above < 16.0, "на 1 км выше старта %.1f м/с (пилот: до 15)" % above)
	a.set_wind(18.0, 270.0, 1600.0)  # старт выше — в долине (1000 м) слабее
	check(a.mean_wind_at(Vector3(0, 1010.0, 0)).length() < 5.0, "ниже старта ветер слабее")
	a.set_wind(18.0, 270.0)  # без опорной высоты — только профиль над рельефом
	var plain := a.mean_wind_at(Vector3(0, 2000.0, 0)).length()
	check(plain < above, "без опоры — как раньше (%.1f)" % plain)
	a.free()


func test_soft_update_keeps_thermals() -> void:
	var a := _atmo(_day(10.0))
	a.set_wind(11.0, 270.0)
	for i in 60:
		a.step(1.0)
	var ids_before: Array = a.field.thermals.keys()
	check(not ids_before.is_empty(), "термики есть")
	var cb0 := a.get_cloudbase_msl()
	var target := _day(14.0)
	var spacing := float(a.weather.thermal_spacing_m)
	a.set_weather(target, 300.0)
	a.step(1.0)
	var kept := 0
	for id in ids_before:
		if a.field.thermals.has(id):
			kept += 1
	check(kept > 0, "живые термики доживают (%d из %d)" % [kept, ids_before.size()])
	var cb_goal := 1000.0 + float(target.cloudbase_agl_m)
	var cb1 := a.get_cloudbase_msl()
	check(absf(cb1 - cb0) < absf(cb_goal - cb0) * 0.1, "кромка не прыгает сразу")
	for i in 900:
		a.step(1.0)
	approx(a.get_cloudbase_msl(), cb_goal, 25.0, "через 15 мин кромка на месте")
	approx(float(a.weather.thermal_spacing_m), spacing, 1.0e-6, "сетка источников не меняется")
	approx(float(a.weather.wind_speed_kmh), 11.0, 1.0e-6, "ветер не меняется")
	a.free()


## Профиль ветра по устойчивости (C2 v4): α и предел WindModel — WindProfile по высоте солнца часа
## и облачности прогноза; ход дня (мягкое обновление погоды) меняет класс.
func test_wind_profile_follows_hour() -> void:
	var a := _atmo(_day(12.0))
	a.set_wind(10.8, 270.0)  # 3 м/с
	var w12: Dictionary = a.weather._derived
	var cover := float(WeatherModel.sky_params(String(w12.sky)).cover)
	var a12 := WindProfile.alpha(3.0, float(w12.sun_elev_deg), cover)
	approx(a.wind.profile_params().x, a12, 1.0e-6, "12:00: α = WindProfile")
	approx(
		a.wind.profile_params().y,
		WindProfile.max_profile(a12, 3.0, AirCase.Z0, AirCase.F_COR),
		1.0e-6,
		"12:00: предел = WindProfile"
	)
	a.set_weather(_day(20.0), 0.0)
	var w20: Dictionary = a.weather._derived
	check(float(w20.sun_elev_deg) < float(w12.sun_elev_deg), "вечером солнце ниже")
	var a20 := WindProfile.alpha(3.0, float(w20.sun_elev_deg), cover)
	approx(a.wind.profile_params().x, a20, 1.0e-6, "20:00: α = WindProfile")
	check(a20 > a12, "вечером сдвиг больше, чем в полдень: %.3f > %.3f" % [a20, a12])
	a.free()
