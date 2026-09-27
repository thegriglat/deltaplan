class_name FlightSettings
extends RefCounted
## Выбор пилота для нового полёта (FR-27, FR-34): крыло, масса, погода, место старта.
## Значения по умолчанию — configs/game.json; меню запоминает последний выбор
## в user://last_flight.json (to_dict/from_dict).

## Имя конфига крыла: "wings/sport".
var wing: String = "wings/sport"
## Масса пилота, кг; 0 — из configs/pilot.json (ограничивается диапазоном крыла).
var pilot_mass_kg: float = 0.0
## Имя конфига погоды: "weather/medium".
var weather: String = "weather/medium"
## "into_site" — ветер в лоб старту, "preset" — направление из пресета.
var wind_mode: String = "into_site"
## Встроенная локация: "altai" (configs/locations/<id>.json).
var location_id: String = "altai"
## Стартовая площадка локации (id); пусто — первая.
var site_id: String = ""
## Точка с карты (FR-17): если не NAN — рельеф грузится вокруг неё, старт на ближайшем склоне.
var pick_lat: float = NAN
var pick_lon: float = NAN


static func defaults() -> FlightSettings:
	var s := FlightSettings.new()
	var g: Dictionary = Config.get_config("game")
	s.wing = String(g.get("default_wing", s.wing))
	s.weather = String(g.get("default_weather", s.weather))
	s.wind_mode = String(g.get("default_wind_mode", s.wind_mode))
	s.location_id = String(g.get("default_location", "locations/altai")).get_file()
	s.site_id = String(g.get("default_site", ""))
	return s


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
		"weather": weather,
		"wind_mode": wind_mode,
		"location_id": location_id,
		"site_id": site_id,
		"pick_lat": null if is_nan(pick_lat) else pick_lat,
		"pick_lon": null if is_nan(pick_lon) else pick_lon,
	}


static func from_dict(d: Dictionary, base: FlightSettings = null) -> FlightSettings:
	var s := base.duplicate() if base != null else FlightSettings.defaults()
	s.wing = String(d.get("wing", s.wing))
	s.pilot_mass_kg = float(d.get("pilot_mass_kg", s.pilot_mass_kg))
	s.weather = String(d.get("weather", s.weather))
	s.wind_mode = String(d.get("wind_mode", s.wind_mode))
	s.location_id = String(d.get("location_id", s.location_id))
	s.site_id = String(d.get("site_id", s.site_id))
	var lat: Variant = d.get("pick_lat")
	var lon: Variant = d.get("pick_lon")
	s.pick_lat = float(lat) if lat != null else NAN
	s.pick_lon = float(lon) if lon != null else NAN
	return s
