class_name FlightSettings
extends RefCounted
## Выбор пилота для нового полёта (FR-27, FR-34): крыло, масса, прогноз погоды (FR-16),
## место старта, время и дата.
## Значения по умолчанию — configs/game.json; меню запоминает последний выбор
## в user://last_flight.json (to_dict/from_dict).

## Имя конфига крыла: "wings/sport".
var wing: String = "wings/sport"
## Масса пилота, кг; 0 — из configs/pilot.json (ограничивается диапазоном крыла).
var pilot_mass_kg: float = 0.0
## Прогноз (FR-16): температура днём (максимум у земли в долине), °C. Остальная погода выводится
## из прогноза, даты и места (WeatherModel, configs/weather_model.json).
var temperature_c: float = 26.0
## Ветер по прогнозу у земли, км/ч (в меню — м/с).
var wind_speed_kmh: float = 10.8
## true — ветер в лоб выбранному старту, false — с направления wind_from_deg.
var wind_into_launch: bool = true
## Откуда ветер, градусы (0 — с севера, 90 — с востока), если не «встречный».
var wind_from_deg: float = 270.0
## Облачность: "clear" | "partly" | "overcast" (weather_model.json → sky).
var sky: String = "clear"
## Встроенная локация: "altai" (configs/locations/<id>.json).
var location_id: String = "altai"
## Стартовая площадка локации (id); пусто — первая.
var site_id: String = ""
## Точка с карты (FR-17): если не NAN — рельеф грузится вокруг неё, старт на ближайшем склоне.
var pick_lat: float = NAN
var pick_lon: float = NAN
## Время старта, часы (VR-5); дата — месяц и число. По умолчанию — configs/world.json → time.
var start_hour: float = 13.0
var month: int = 7
var day: int = 15


static func defaults() -> FlightSettings:
	var s := FlightSettings.new()
	var g: Dictionary = Config.get_config("game")
	s.wing = String(g.get("default_wing", s.wing))
	s.location_id = String(g.get("default_location", "locations/altai")).get_file()
	s.site_id = String(g.get("default_site", ""))
	var t: Dictionary = Config.get_config("world").get("time", {})
	s.start_hour = float(t.get("start_hour", s.start_hour))
	s.month = int(t.get("month", s.month))
	s.day = int(t.get("day", s.day))
	var dt: Variant = g.get("default_temperature_c")
	s.temperature_c = (
		float(dt) if dt != null else roundf(WeatherModel.typical_max_c(s.month, s.day))
	)
	s.wind_speed_kmh = float(g.get("default_wind_speed_kmh", s.wind_speed_kmh))
	s.wind_into_launch = bool(g.get("default_wind_into_launch", s.wind_into_launch))
	s.wind_from_deg = float(g.get("default_wind_from_deg", s.wind_from_deg))
	s.sky = String(g.get("default_sky", s.sky))
	return s


## Прогноз для WeatherModel.derive: {temperature_c, wind_speed_kmh, wind_from_deg}.
## При «встречный» направление подставляет Game после выбора старта.
func forecast() -> Dictionary:
	return {
		"temperature_c": temperature_c,
		"wind_speed_kmh": wind_speed_kmh,
		"wind_from_deg": wind_from_deg,
		"sky": sky,
	}


## Зажать прогноз в диапазоны меню (configs/weather_model.json → ui).
func clamp_forecast() -> void:
	var ui: Dictionary = WeatherModel.config().get("ui", {})
	var t_range: Array = ui.get("temperature_c", [-10, 40, 1])
	var wr: Array = ui.get("wind_ms", [0, 12, 1])
	temperature_c = _finite_or(temperature_c, 20.0)
	temperature_c = clampf(temperature_c, float(t_range[0]), float(t_range[1]))
	wind_speed_kmh = _finite_or(wind_speed_kmh, 11.0)
	wind_speed_kmh = clampf(wind_speed_kmh, float(wr[0]) * 3.6, float(wr[1]) * 3.6)
	wind_from_deg = fposmod(_finite_or(wind_from_deg, 270.0), 360.0)
	var skies: Array = WeatherModel.config().get("sky", {}).get("options", ["clear"])
	if not skies.has(sky):
		sky = String(skies[0])


static func _finite_or(v: float, fallback: float) -> float:
	return v if is_finite(v) else fallback


func has_pick() -> bool:
	return not is_nan(pick_lat) and not is_nan(pick_lon)


## "wings/sport" → "sport" (как ждёт Glider.setup).
func wing_id() -> String:
	return wing.get_file()


func duplicate() -> FlightSettings:
	return from_dict(to_dict())


func to_dict() -> Dictionary:
	return {
		"wing": wing,
		"pilot_mass_kg": pilot_mass_kg,
		"temperature_c": temperature_c,
		"wind_speed_kmh": wind_speed_kmh,
		"wind_into_launch": wind_into_launch,
		"wind_from_deg": wind_from_deg,
		"sky": sky,
		"location_id": location_id,
		"site_id": site_id,
		"pick_lat": null if is_nan(pick_lat) else pick_lat,
		"pick_lon": null if is_nan(pick_lon) else pick_lon,
		"start_hour": start_hour,
		"month": month,
		"day": day,
	}


static func from_dict(d: Dictionary, base: FlightSettings = null) -> FlightSettings:
	var s := base.duplicate() if base != null else FlightSettings.defaults()
	s.wing = String(d.get("wing", s.wing))
	s.pilot_mass_kg = float(d.get("pilot_mass_kg", s.pilot_mass_kg))
	s.temperature_c = float(d.get("temperature_c", s.temperature_c))
	s.wind_speed_kmh = float(d.get("wind_speed_kmh", s.wind_speed_kmh))
	s.wind_into_launch = bool(d.get("wind_into_launch", s.wind_into_launch))
	s.wind_from_deg = float(d.get("wind_from_deg", s.wind_from_deg))
	s.sky = String(d.get("sky", s.sky))
	s.location_id = String(d.get("location_id", s.location_id))
	s.site_id = String(d.get("site_id", s.site_id))
	var lat: Variant = d.get("pick_lat")
	var lon: Variant = d.get("pick_lon")
	s.pick_lat = float(lat) if lat != null else NAN
	s.pick_lon = float(lon) if lon != null else NAN
	s.start_hour = float(d.get("start_hour", s.start_hour))
	s.month = int(d.get("month", s.month))
	s.day = int(d.get("day", s.day))
	return s


## Ключ мира (WorldKey, канонический deltaplan://world?…): задаёт мир зоны целиком — место,
## дату, время, прогноз, сид, ботов. Крыло и масса не входят.
func world_key(world_seed: int, bots_count: int) -> String:
	return WorldKey.make(self, world_seed, bots_count)


## Хэш мира: world_key(…).sha256_text().substr(0, 16).
func world_hash(world_seed: int, bots_count: int) -> String:
	return WorldKey.hash_of(world_key(world_seed, bots_count))


## Разобрать ключ мира: {settings: FlightSettings, seed: int, bots: int, v: int} (WorldKey.parse).
## Крыло и масса — из base (свои), без base — по умолчанию.
static func from_world_key(key: String, base: FlightSettings = null) -> Dictionary:
	return WorldKey.parse(key, base)


## Параметры мира сетевой зоны (net.proto → Zone, ключи как в NetMessages): всё, кроме крыла и
## массы — они у каждого пилота свои. pick_lat/lon NAN — поля нет («не задано»).
func to_zone(world_seed: int, bots_count: int) -> Dictionary:
	return {
		"locationId": location_id,
		"siteId": site_id,
		"pickLat": pick_lat,
		"pickLon": pick_lon,
		"month": month,
		"day": day,
		"startHour": start_hour,
		"forecast":
		{
			"temperatureC": temperature_c,
			"windSpeedKmh": wind_speed_kmh,
			"windIntoLaunch": wind_into_launch,
			"windFromDeg": wind_from_deg,
			"sky": sky,
		},
		"seed": world_seed,
		"botsCount": bots_count,
	}


## Настройки полёта из Zone (данные NetMessages.decode). Крыло и масса — из base (свои),
## без base — по умолчанию. Сид и число ботов — в самой Zone (zone.seed, zone.botsCount).
static func from_zone(zone: Dictionary, base: FlightSettings = null) -> FlightSettings:
	var s := base.duplicate() if base != null else FlightSettings.defaults()
	s.location_id = String(zone.get("locationId", s.location_id))
	s.site_id = String(zone.get("siteId", ""))
	s.pick_lat = float(zone.get("pickLat", NAN))
	s.pick_lon = float(zone.get("pickLon", NAN))
	s.month = int(zone.get("month", s.month))
	s.day = int(zone.get("day", s.day))
	s.start_hour = float(zone.get("startHour", s.start_hour))
	var f: Dictionary = zone.get("forecast", {})
	s.temperature_c = float(f.get("temperatureC", s.temperature_c))
	s.wind_speed_kmh = float(f.get("windSpeedKmh", s.wind_speed_kmh))
	s.wind_into_launch = bool(f.get("windIntoLaunch", s.wind_into_launch))
	s.wind_from_deg = float(f.get("windFromDeg", s.wind_from_deg))
	s.sky = String(f.get("sky", s.sky))
	return s
