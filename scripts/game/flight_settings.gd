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
## Точный старт (SP-К1): точка и курс разбега, WGS84 / градусы; NAN — не задан. Уточняет место
## (location_id/site_id/pick_*), а не заменяет его; любой выбор места в PlacePickRow сбрасывает.
var start_lat: float = NAN
var start_lon: float = NAN
var start_heading_deg: float = NAN
## Время старта, часы (VR-5); дата — месяц и число. По умолчанию — configs/world.json → time.
var start_hour: float = 13.0
var month: int = 7
var day: int = 15
## Настройки «Аппарат» (PD-К3 v2): {wing_id: {ключ: значение}} — только то, что пилот менял.
## Полный набор ключей для модели — resolved_apparatus(wing_id).
var apparatus: Dictionary = {}

## Ключи PD-К3: [мин, макс, шаг, запасное умолчание] (docs/contracts/pendulum.md).
const APPARATUS_SPEC := {
	"hang_shift_cm": [-4.0, 4.0, 0.5, 0.0],
	"hang_length_m": [1.0, 1.4, 0.05, 1.2],
	"sail_flex": [0.1, 1.0, 0.05, 0.2],
	"dihedral_eff_deg": [-2.0, 6.0, 0.5, 1.0],
}


## Умолчания «Аппарат»: configs/pendulum.json → apparatus_defaults (PD-К2), нет файла/ключа — запасные.
## С wing_id поверх — pendulum.apparatus_defaults из конфига крыла (PD-К2 v3), если есть.
static func apparatus_defaults(wing_id: String = "") -> Dictionary:
	var file: Dictionary = {}
	if FileAccess.file_exists("res://configs/pendulum.json"):
		file = Config.get_config("pendulum").get("apparatus_defaults", {})
	var wing_def: Dictionary = {}
	if wing_id != "" and FileAccess.file_exists("res://configs/wings/%s.json" % wing_id):
		var pd: Variant = Config.get_config("wings/" + wing_id).get("pendulum")
		if pd is Dictionary:
			var ad: Variant = (pd as Dictionary).get("apparatus_defaults")
			if ad is Dictionary:
				wing_def = ad
	var d := {}
	for k: String in APPARATUS_SPEC:
		d[k] = _clamp_apparatus(k, float(wing_def.get(k, file.get(k, APPARATUS_SPEC[k][3]))))
	return d


static func _clamp_apparatus(k: String, v: float) -> float:
	var sp: Array = APPARATUS_SPEC[k]
	v = _finite_or(v, float(sp[3]))
	v = snappedf(clampf(v, float(sp[0]), float(sp[1])), float(sp[2]))
	return clampf(v, float(sp[0]), float(sp[1]))


## Зажать значения в диапазоны PD-К3 и дополнить пропуски умолчаниями крыла; шаг — к ближайшему.
static func normalize_apparatus(src: Dictionary, wing_id: String = "") -> Dictionary:
	var def := apparatus_defaults(wing_id)
	var d := {}
	for k: String in APPARATUS_SPEC:
		d[k] = _clamp_apparatus(k, float(src.get(k, def[k])))
	return d


## Только присутствующие ключи PD-К3, зажатые в диапазоны (то, что хранится по крылу).
static func _clean_user_apparatus(src: Dictionary) -> Dictionary:
	var d := {}
	for k: String in APPARATUS_SPEC:
		if src.has(k):
			d[k] = _clamp_apparatus(k, float(src[k]))
	return d


## Все 4 ключа для модели: пилот → конфиг крыла → configs/pendulum.json → запасные (PD-К3 v2).
func resolved_apparatus(wing_id: String) -> Dictionary:
	var mine: Variant = apparatus.get(wing_id)
	return normalize_apparatus(mine if mine is Dictionary else {}, wing_id)


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
	var wr := WingCatalog.wind_menu_range()
	temperature_c = _finite_or(temperature_c, 20.0)
	temperature_c = clampf(temperature_c, float(t_range[0]), float(t_range[1]))
	wind_speed_kmh = _finite_or(wind_speed_kmh, 11.0)
	wind_speed_kmh = clampf(wind_speed_kmh, wr.x * 3.6, wr.y * 3.6)
	wind_from_deg = fposmod(_finite_or(wind_from_deg, 270.0), 360.0)
	var skies: Array = WeatherModel.config().get("sky", {}).get("options", ["clear"])
	if not skies.has(sky):
		sky = String(skies[0])


static func _finite_or(v: float, fallback: float) -> float:
	return v if is_finite(v) else fallback


func has_pick() -> bool:
	return not is_nan(pick_lat) and not is_nan(pick_lon)


func has_exact_start() -> bool:
	return is_finite(start_lat) and is_finite(start_lon) and is_finite(start_heading_deg)


func set_exact_start(lat: float, lon: float, heading_deg: float) -> void:
	start_lat = lat
	start_lon = lon
	start_heading_deg = fposmod(heading_deg, 360.0)


func clear_exact_start() -> void:
	start_lat = NAN
	start_lon = NAN
	start_heading_deg = NAN


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
		"start_lat": null if is_nan(start_lat) else start_lat,
		"start_lon": null if is_nan(start_lon) else start_lon,
		"start_heading_deg": null if is_nan(start_heading_deg) else start_heading_deg,
		"start_hour": start_hour,
		"month": month,
		"day": day,
		"apparatus": apparatus.duplicate(true),
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
	var slat: Variant = d.get("start_lat")
	var slon: Variant = d.get("start_lon")
	var shead: Variant = d.get("start_heading_deg")
	s.start_lat = float(slat) if slat != null else NAN
	s.start_lon = float(slon) if slon != null else NAN
	s.start_heading_deg = float(shead) if shead != null else NAN
	s.start_hour = float(d.get("start_hour", s.start_hour))
	s.month = int(d.get("month", s.month))
	s.day = int(d.get("day", s.day))
	var ap: Variant = d.get("apparatus")
	if ap is Dictionary:
		s.apparatus = {}
		for w: Variant in ap:
			if ap[w] is Dictionary:
				var c := _clean_user_apparatus(ap[w])
				if not c.is_empty():
					s.apparatus[String(w)] = c
	StartWeather.apply(s)  # TI-К2: у старта с фиксированной погодой она важнее сохранённой
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
		"startLat": start_lat,
		"startLon": start_lon,
		"startHeadingDeg": start_heading_deg,
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
	s.start_lat = float(zone.get("startLat", NAN))
	s.start_lon = float(zone.get("startLon", NAN))
	s.start_heading_deg = float(zone.get("startHeadingDeg", NAN))
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
