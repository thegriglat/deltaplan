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
