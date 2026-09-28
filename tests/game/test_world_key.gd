extends TestCase
## Ключ мира (WorldKey, FlightSettings.world_key / world_hash / from_world_key; сеть, NET-00):
## канонический вид, разбор в любом порядке, значения по умолчанию, место по координатам.

const EXAMPLE := (
	"deltaplan://world?bots=4&date=2026-07-15&from=270&hour=13.00&lat=50.75120&lon=86.12030"
	+ "&seed=4711&sky=clear&temp=26.0&v=1&wind=3.0"
)


func _example_settings() -> FlightSettings:
	var s := FlightSettings.defaults()
	s.pick_lat = 50.7512
	s.pick_lon = 86.1203
	s.month = 7
	s.day = 15
	s.start_hour = 13.0
	s.temperature_c = 26.0
	s.wind_speed_kmh = 10.8
	s.wind_into_launch = false
	s.wind_from_deg = 270.0
	s.sky = "clear"
	return s


func _site_settings() -> FlightSettings:
	var s := FlightSettings.defaults()
	s.location_id = "altai"
	s.site_id = "sinyukha_east"
	s.pick_lat = NAN
	s.pick_lon = NAN
	return s


func test_example_exact() -> void:
	var s := _example_settings()
	var key := s.world_key(4711, 4)
	check(key == EXAMPLE, "канонический вид:\n%s\n%s" % [key, EXAMPLE])
	check(s.world_hash(4711, 4) == key.sha256_text().substr(0, 16), "хэш — 16 hex SHA-256")
	check(s.world_hash(4711, 4).length() == 16, "16 знаков")


func test_parse_any_order_and_round_trip() -> void:
	var key := _site_settings().world_key(99, 2)
	var parts := key.substr(WorldKey.PREFIX.length()).split("&")
	parts.reverse()
	var shuffled := "deltaplan://world?" + "&".join(parts) + "&future_param=xyz"
	var p: Dictionary = FlightSettings.from_world_key(shuffled)
	var s: FlightSettings = p.settings
	check(
		s.location_id == "altai" and s.site_id == "sinyukha_east", "тот же старт встроенной локации"
	)
	check(not s.has_pick(), "не точка с карты")
	check(int(p.seed) == 99 and int(p.bots) == 2, "сид и боты")
	check(s.world_key(int(p.seed), int(p.bots)) == key, "ключ → настройки → ключ:\n%s" % key)
	# Точка с карты вне встроенных локаций — остаётся точкой.
	var far := EXAMPLE.replace("lat=50.75120", "lat=45.00000").replace("lon=86.12030", "lon=40.00000")
	var pf: Dictionary = FlightSettings.from_world_key(far)
	var sf: FlightSettings = pf.settings
	check(sf.has_pick() and absf(sf.pick_lat - 45.0) < 1e-9, "точка с карты")
	var kv := WorldKey.split(far)
	check(sf.world_key(int(pf.seed), int(pf.bots)) == WorldKey.canonical(kv), "точка: круг замкнут")
	# Точка внутри встроенной локации — локация и ближайший старт.
	var pe: Dictionary = FlightSettings.from_world_key(EXAMPLE)
	var se: FlightSettings = pe.settings
	check(se.location_id == "ongudai" and not se.has_pick(), "точка в Онгудае — встроенная локация")
	check(se.site_id == "kayancha_south", "ближайший старт")
	check(not se.wind_into_launch and se.wind_from_deg == 270.0, "ветер с 270°")
	approx(se.wind_speed_kmh, 10.8, 1e-9, "ветер 3,0 м/с")


func test_defaults_for_missing_keys() -> void:
	var p: Dictionary = FlightSettings.from_world_key("deltaplan://world?v=1&temp=31.0")
	var s: FlightSettings = p.settings
	var d := FlightSettings.defaults()
	approx(s.temperature_c, 31.0, 1e-9, "заданное — из ключа")
	check(s.sky == d.sky and s.month == d.month and s.day == d.day, "нет ключа — по умолчанию")
	check(s.wind_into_launch, "нет from — в лоб старту")
	check(int(p.seed) == int(Config.value("atmosphere", "seed")), "нет seed — atmosphere.json")
	check(int(p.bots) == 0, "нет bots — 0")


func test_every_param_changes_hash() -> void:
	var base := _example_settings()
	var h0 := base.world_hash(4711, 4)
	var seen := {h0: "база"}
	var variants := {
		"bots": func(s: FlightSettings) -> Array: return [s, 4711, 5],
		"seed": func(s: FlightSettings) -> Array: return [s, 4712, 4],
		"month": func(s: FlightSettings) -> Array:
			s.month = 8
			return [s, 4711, 4],
		"day": func(s: FlightSettings) -> Array:
			s.day = 16
			return [s, 4711, 4],
		"hour": func(s: FlightSettings) -> Array:
			s.start_hour = 13.25
			return [s, 4711, 4],
		"temp": func(s: FlightSettings) -> Array:
			s.temperature_c = 26.5
			return [s, 4711, 4],
		"wind": func(s: FlightSettings) -> Array:
			s.wind_speed_kmh = 3.1 * 3.6
			return [s, 4711, 4],
		"from": func(s: FlightSettings) -> Array:
			s.wind_from_deg = 271.0
			return [s, 4711, 4],
		"into": func(s: FlightSettings) -> Array:
			s.wind_into_launch = true
			return [s, 4711, 4],
		"sky": func(s: FlightSettings) -> Array:
			s.sky = "partly"
			return [s, 4711, 4],
		"lat": func(s: FlightSettings) -> Array:
			s.pick_lat += 0.0001
			return [s, 4711, 4],
		"lon": func(s: FlightSettings) -> Array:
			s.pick_lon += 0.0001
			return [s, 4711, 4],
	}
	for name: String in variants:
		var r: Array = (variants[name] as Callable).call(base.duplicate())
		var h := (r[0] as FlightSettings).world_hash(int(r[1]), int(r[2]))
		check(not seen.has(h), "%s меняет хэш" % name)
		seen[h] = name
