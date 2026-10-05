extends TestCase
## AchievementFeed (контракт S2) без сцены: порядок событий, ровно один flight_finished,
## отмена без итога, ключ места. Форма словарей на настоящем полёте — в
## tests/contracts/test_steam_contracts_s2.gd.


func test_place_key() -> void:
	var s := FlightSettings.new()
	s.location_id = "altai"
	s.site_id = "a"
	check(AchievementFeed.place_key(s) == "altai/a", "ключ места")
	s.pick_lat = 1.23456
	s.pick_lon = -2.0
	check(AchievementFeed.place_key(s) == "pick/1.235,-2.000", AchievementFeed.place_key(s))


func test_finish_and_cancel_without_begin() -> void:
	var f := AchievementFeed.new(null)
	var got: Array = []
	f.flight_finished.connect(func(d: Dictionary) -> void: got.append(d))
	f.finish("landed", {}, Telemetry.new())
	check(got.is_empty(), "без отрыва итога нет")
	f.begin(Telemetry.new())
	check(not f.active, "без Game поток не стартует")


func test_cancel_drops_flight() -> void:
	var f := AchievementFeed.new(null)
	f.active = true
	var got: Array = []
	f.flight_finished.connect(func(d: Dictionary) -> void: got.append(d))
	f.cancel()
	f.finish("landed", {}, Telemetry.new())
	check(got.is_empty(), "после cancel итога нет")


func test_temp_profile() -> void:
	var c := WeatherModel.config()
	var w := WeatherModel.derive(
		{"temperature_c": 28.0, "wind_speed_kmh": 10.0, "wind_from_deg": 270.0, "sky": "clear"},
		{"month": 7, "day": 15, "lat": 50.0, "valley_msl_m": 500.0, "mean_msl_m": 900.0}
	)
	var dry := float(c.get("dry_adiabat_k_per_km", 9.8))
	approx(AchievementFeed.temp_at_altitude(w, 500.0, 7, 15), 28.0, 0.01, "в долине — t")
	approx(AchievementFeed.temp_at_altitude(w, 1000.0, 7, 15), 28.0 - dry * 0.5, 0.01, "сухая адиабата")
	var z_dry := float(w._derived.z_dry_msl_m)
	var ua: Dictionary = c.upper_air
	var t_u := WeatherModel.monthly(ua.temp_c, 7, 15)
	var gam := float(ua.lapse_k_per_km)
	var z_u := float(ua.z_msl_m) / 1000.0
	var hi := z_dry + 1500.0
	approx(
		AchievementFeed.temp_at_altitude(w, hi, 7, 15),
		t_u + gam * (z_u - hi / 1000.0), 0.01, "выше z_dry — верхний воздух"
	)
	check(
		AchievementFeed.temp_at_altitude(w, 1000.0, 7, 15) > AchievementFeed.temp_at_altitude(w, hi, 7, 15),
		"с высотой холоднее"
	)
