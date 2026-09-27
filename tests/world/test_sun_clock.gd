extends TestCase
## VR-5: положение солнца по времени, дате и месту (SunClock), свет неба по высоте солнца
## (SkyEnvironment), выбор времени и даты (FlightSettings, экран «Полёт…»).

const LAT := 51.0
const MIDSUMMER := 196  ## 15 июля


func test_midsummer_51n_positions() -> void:
	check(SunClock.day_of_year(7, 15) == MIDSUMMER, "15 июля — 196-й день")
	var noon := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 12.0)
	approx(noon.x, 180.0, 0.5, "полдень по солнцу: азимут — юг")
	var d13 := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 13.0)
	check(d13.y >= 57.5 and d13.y <= 60.5, "13:00: высота %.1f° (≈58–60°)" % d13.y)
	check(d13.x > 185.0 and d13.x < 230.0, "13:00: чуть западнее юга (%.0f°)" % d13.x)
	var d7 := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 7.0)
	# по местному солнечному времени в 7:00 солнце ≈ 26°; 15–20° — около 6:00 (или 7:00 декретных)
	check(d7.y > 14.0 and d7.y < 28.0, "7:00: высота %.1f° — невысоко" % d7.y)
	check(d7.x > 60.0 and d7.x < 110.0, "7:00: на востоке (%.0f°)" % d7.x)
	var d6 := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 6.0)
	check(d6.y > 12.0 and d6.y < 20.0, "6:00: высота %.1f° (≈15–20°)" % d6.y)
	var d19 := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 19.0)
	check(d19.x > 250.0 and d19.x < 300.0, "19:00: на западе (%.0f°)" % d19.x)
	var d17 := SunClock.solar_position(LAT, 85.0, MIDSUMMER, 17.0)
	approx(d17.y, d7.y, 0.5, "7:00 и 17:00 симметричны относительно полудня")
	check(d19.y > 4.0 and d19.y < 12.0, "19:00: низко над горизонтом (%.1f°)" % d19.y)


func test_solstice_and_zone_time() -> void:
	# 21 июня, 51° с. ш., полдень: 90 − 51 + 23,44
	var n := SunClock.solar_position(LAT, 0.0, SunClock.day_of_year(6, 21), 12.0)
	approx(n.y, 62.4, 0.4, "высота в полдень солнцестояния")
	var w := SunClock.solar_position(LAT, 0.0, SunClock.day_of_year(12, 21), 12.0)
	approx(w.y, 15.6, 0.4, "высота в полдень зимой")
	# Горно-Алтайск (85,9° в. д., UTC+7): 7:00 по часам — это ≈5:45 по солнцу, солнце ниже
	var solar7 := SunClock.solar_position(51.87, 85.87, MIDSUMMER, 7.0)
	var zone7 := SunClock.solar_position(51.87, 85.87, MIDSUMMER, 7.0, 7.0)
	check(zone7.y < solar7.y - 8.0, "поясное время отстаёт от солнечного на ~1,3 ч")


func test_clock_runs_and_signals() -> void:
	var c := SunClock.new()
	var got: Array = []
	c.sun_changed.connect(func(d: Vector3) -> void: got.append(d))
	c.start_flight(LAT, 85.0, 7, 15, 13.0)
	check(c.active and got.size() == 1, "старт — сигнал с направлением")
	var dir0 := c.to_sun()
	var az0 := c.angles().x
	approx(dir0.length(), 1.0, 1e-4, "единичный вектор")
	approx(rad_to_deg(asin(dir0.y)), c.angles().y, 0.01, "вектор совпадает с высотой")
	c.speed = 0.0
	c.advance(600.0)
	approx(c.hour, 13.0, 1e-6, "стоп — время стоит")
	c.speed = 60.0
	c.advance(60.0)
	approx(c.hour, 14.0, 1e-4, "×60: минута за секунду")
	check(got.size() == 2, "солнце сдвинулось — сигнал")
	check(c.angles().x > az0 + 5.0, "солнце ушло к западу")
	c.advance(3600.0 * 100.0)
	approx(c.hour, 21.0, 1e-6, "после 21:00 время стоит")
	check(c.to_sun().y > 0.0, "солнце для света не ниже горизонта")
	c.reset()
	approx(c.hour, 13.0, 1e-6, "reset — к времени старта")
	check(c.time_text() == "13:00", "подпись времени")
	c.set_hour(3.0)
	approx(c.hour, 6.0, 1e-6, "раньше 6:00 нельзя")
	c.free()


func test_sky_follows_clock() -> void:
	var sky := SkyEnvironment.new()
	sky.apply_config()
	sky.clock.start_flight(LAT, 85.0, 7, 15, 13.0)
	var day_energy := sky.sun.light_energy
	var day_color := sky.sun.light_color
	var fwd := -sky.sun.transform.basis.z
	approx(fwd.dot(-sky.clock.to_sun()), 1.0, 1e-4, "свет светит от солнца")
	sky.clock.set_hour(6.0)
	fwd = -sky.sun.transform.basis.z
	approx(fwd.dot(-sky.clock.to_sun()), 1.0, 1e-4, "свет повернулся за солнцем")
	check(sky.sun.light_energy < day_energy, "утром солнце мягче")
	check(sky.sun.light_color.b < day_color.b * 0.97, "утром свет теплее")
	var mat := sky.haze_material()
	if mat != null:
		var sd: Vector3 = mat.get_shader_parameter("sun_dir")
		approx(sd.dot(sky.clock.to_sun()), 1.0, 1e-4, "дымка знает, где солнце")
	sky.free()


func test_flight_settings_keep_time() -> void:
	var s := FlightSettings.defaults()
	approx(s.start_hour, 13.0, 1e-6, "по умолчанию 13:00")
	check(s.month == 7 and s.day == 15, "по умолчанию середина лета")
	s.start_hour = 7.5
	s.month = 5
	s.day = 3
	var r := FlightSettings.from_dict(s.to_dict())
	check(is_equal_approx(r.start_hour, 7.5) and r.month == 5 and r.day == 3, "время и дата в JSON")


func test_zone_time_by_location() -> void:
	# По умолчанию часы — поясное время места: Алтай UTC+7 → в 13:00 солнце ещё до полудня.
	for id in ["altai", "ongudai", "askarovo", "aushkul"]:
		var loc: Dictionary = Config.get_config("locations/" + id)
		check(loc.has("utc_offset_h"), "%s: задан часовой пояс" % id)
	var c := SunClock.new()
	c.start_flight(51.87, 85.87, 7, 15, 13.0, 7.0)
	check(c.angles().x < 180.0, "Алтай 13:00 UTC+7: солнце ещё на юго-востоке (%.0f°)" % c.angles().x)
	c.start_flight(51.87, 85.87, 7, 15, 20.5, 7.0)
	check(c.angles().y > 0.0, "Алтай 20:30 летом — солнце ещё над горизонтом")
	c.free()
