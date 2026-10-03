extends TestCase
## Упрощённый ветер (air_model.enabled = off): профиль по высоте — как в 0.8.0 (α = 0,14, предел
## ×1,8, опорная высота 10 м), без зависимости от часа и облачности. С полем (auto) — WindProfile.

const HEIGHTS := [10.0, 50.0, 100.0, 300.0, 1000.0]


static func _flat(_x: float, _z: float) -> float:
	return 1000.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


static func _v080(agl: float) -> float:
	return minf(pow(maxf(agl, 1.0) / 10.0, 0.14), 1.8)


func _atmo(mode: String, hour: float, sky: String = "") -> Atmosphere:
	var c: Dictionary = Config.get_config("atmosphere").duplicate(true)
	c.air_model.enabled = mode
	var w := WeatherModel.derive(
		{"temperature_c": 26.0, "wind_speed_kmh": 11.0, "wind_from_deg": 270.0},
		WeatherModel.reference_context(),
		WeatherModel.config(),
		hour
	)
	if sky != "":
		w.sky = sky
	var a := Atmosphere.new()
	a.configure(c, w)
	a.turbulence_enabled = false
	a.set_ground(_flat, _sun)
	return a


func test_off_matches_080_any_hour() -> void:
	for hour in [9.0, 12.0, 15.0, 20.0]:
		for sky in ["", "overcast"]:
			var a := _atmo("off", hour, sky)
			a.set_wind(10.8, 270.0)  # 3 м/с
			check(a.wind.simple_profile, "off: простой профиль (%s ч)" % hour)
			for h in HEIGHTS:
				approx(a.wind.profile(h), _v080(h), 1.0e-6, "off %s ч %s: ×(%s м)" % [hour, sky, h])
			a.free()
	approx(_v080(1000.0), 1.8, 1.0e-9, "предел 0.8.0 достигнут на 1000 м")


func test_auto_keeps_windprofile() -> void:
	var a := _atmo("auto", 12.0)
	a.set_wind(10.8, 270.0)
	check(not a.wind.simple_profile, "auto: не простой профиль")
	var p := a.wind.profile_params()
	check(absf(p.x - 0.14) > 0.02, "auto: α не 0.14 (%.3f)" % p.x)
	a.set_air_mode("off")
	approx(a.wind.profile_params().x, 0.14, 1.0e-9, "переключение в off: α 0.14")
	a.set_air_mode("auto")
	check(not a.wind.simple_profile and absf(a.wind.profile_params().x - 0.14) > 0.02, "назад в auto")
	a.free()
