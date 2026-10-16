class_name StartWeather
extends RefCounted
## Фиксированная погода старта (TI-К2, docs/contracts/training-island.md): ключ
## start_sites[].weather в конфиге места переписывает погодные поля FlightSettings.
## Одно правило для меню, last_flight, избранного, повтора, сети, командной строки и Game.start.
## Точка с карты (pick_lat/lon) — без фиксированной погоды. Время полёта идёт как обычно.

const SKIES: PackedStringArray = ["clear", "partly", "overcast"]


## Разбор ключа weather: нормализованный словарь {wind_from_deg, wind_speed_ms, start_hour, month,
## day, sky, temperature_c} или {} (с предупреждением) при отсутствии поля / недопустимом значении.
static func parse(w: Variant, where: String = "") -> Dictionary:
	if not (w is Dictionary):
		return {}
	var d: Dictionary = w
	for k: String in ["wind_from_deg", "wind_speed_ms", "start_hour", "month", "day", "sky", "temperature_c"]:
		if not d.has(k):
			push_warning("StartWeather %s: нет поля weather.%s — погода не фиксируется" % [where, k])
			return {}
	for k: String in ["wind_from_deg", "wind_speed_ms", "start_hour", "month", "day", "temperature_c"]:
		if not (d[k] is float or d[k] is int) or not is_finite(float(d[k])):
			push_warning("StartWeather %s: weather.%s не число — погода не фиксируется" % [where, k])
			return {}
	var hour := float(d.start_hour)
	var hours := SunClock.start_hours()
	var ok_hour := false
	for h in hours:
		if is_equal_approx(h, hour):
			ok_hour = true
	if not ok_hour:
		push_warning("StartWeather %s: час %s не из world.json → time.start_hours — погода не фиксируется" % [where, hour])
		return {}
	var sky_opts: Array = WeatherModel.config().get("sky", {}).get("options", SKIES)
	if not (d.sky is String) or not (String(d.sky) in sky_opts):
		push_warning("StartWeather %s: sky '%s' недопустимо — погода не фиксируется" % [where, d.sky])
		return {}
	var month := int(d.month)
	var day := int(d.day)
	if month < 1 or month > 12 or day < 1 or day > SunClock.days_in_month(month):
		push_warning("StartWeather %s: дата %s.%s недопустима — погода не фиксируется" % [where, day, month])
		return {}
	var speed := float(d.wind_speed_ms)
	if speed < 0.0:
		push_warning("StartWeather %s: wind_speed_ms < 0 — погода не фиксируется" % where)
		return {}
	return {
		"wind_from_deg": fposmod(float(d.wind_from_deg), 360.0),
		"wind_speed_ms": speed,
		"start_hour": hour,
		"month": month,
		"day": day,
		"sky": String(d.sky),
		"temperature_c": float(d.temperature_c),
	}


## Набор погоды выбранного старта settings (location_id/site_id; пустой site_id — первый старт места);
## {} — точка с карты, нет места/старта/ключа или ключ недопустим.
static func for_settings(s: FlightSettings) -> Dictionary:
	if s == null or s.has_pick() or s.location_id == "":
		return {}
	var starts: Array = Locations.config(s.location_id).get("start_sites", [])
	if starts.is_empty():
		return {}
	var site: Dictionary = starts[0]
	if s.site_id != "":
		site = {}
		for st: Dictionary in starts:
			if String(st.get("id", "")) == s.site_id:
				site = st
		if site.is_empty():
			return {}
	if not site.has("weather"):
		return {}
	return parse(site.weather, "%s/%s" % [s.location_id, site.get("id", "")])


static func has_fixed(s: FlightSettings) -> bool:
	return not for_settings(s).is_empty()


## Переписать погодные поля s набором его старта. true — набор есть и применён.
static func apply(s: FlightSettings) -> bool:
	var w := for_settings(s)
	if w.is_empty():
		return false
	s.wind_from_deg = float(w.wind_from_deg)
	s.wind_into_launch = false
	s.wind_speed_kmh = float(w.wind_speed_ms) * 3.6
	s.start_hour = float(w.start_hour)
	s.month = int(w.month)
	s.day = int(w.day)
	s.sky = String(w.sky)
	s.temperature_c = float(w.temperature_c)
	return true


## Строка для меню: «Погода старта фиксирована: ветер 6 м/с с 270°, 12:00, переменная облачность, 24 °C».
static func describe(w: Dictionary) -> String:
	return (
		TranslationServer.translate("setup_weather_fixed")
		% [
			roundi(float(w.wind_speed_ms)),
			roundi(float(w.wind_from_deg)),
			SunClock.format_hour(float(w.start_hour)),
			String(TranslationServer.translate("setup_sky_" + String(w.sky))).to_lower(),
			roundi(float(w.temperature_c)),
		]
	)
