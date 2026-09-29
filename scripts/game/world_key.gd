class_name WorldKey
extends RefCounted
## Ключ мира (сеть, NET-00): строка, которая полностью задаёт мир зоны — место, дату, время
## старта, прогноз, сид и число ботов. Одинаковый ключ → одинаковые термики, облака и ветер у всех
## (атмосфера — чистая функция, docs/atmosphere.md → «Детерминизм»). Часы зоны в ключ не входят.
## Годится и как ссылка «поделиться миром».
##
## Канонический вид (для хэша): все ключи, по алфавиту, числа в фиксированном формате, значения
## экранированы (URI component):
##   deltaplan://world?bots=4&date=2026-07-15&from=270&hour=13.00&lat=50.75120&lon=86.12030
##       &seed=4711&sky=clear&temp=26.0&v=1&wind=3.0
##   bots — число ботов (целое); date — ГГГГ-ММ-ДД (год не влияет, всегда VERSION_YEAR);
##   from — откуда ветер, целые градусы, −1 — «встречный»; hour — час старта, 2 знака;
##   lat/lon — точка старта, 5 знаков (~1 м): у встроенной локации — координаты её старта;
##   seed — сид мира (целое); sky — облачность (clear | partly | overcast); temp — температура
##   днём, °C, 1 знак; v — версия генератора мира (VERSION); wind — ветер у земли, м/с, 1 знак.
## Разбор (parse): порядок ключей любой, неизвестные ключи пропускаются, нет ключа — значение
## по умолчанию (FlightSettings.defaults(); seed — atmosphere.json → seed; bots — 0; from —
## «встречный»). Точка внутри встроенной локации (квадрат детального рельефа) — эта локация
## и ближайший к точке старт; иначе — точка с карты (рельеф грузится по координатам).
## Ключ квантует числа — хозяин зоны тоже строит мир из разобранного ключа, как все.

## Версия генератора мира: менять, когда меняется то, как из ключа получается мир.
const VERSION := 1
const VERSION_YEAR := 2026
const PREFIX := "deltaplan://world?"


## Ключ мира (канонический) по настройкам полёта, сиду и числу ботов.
static func make(s: FlightSettings, world_seed: int, bots_count: int) -> String:
	var ll := launch_latlon(s)
	var from := -1 if s.wind_into_launch else int(roundf(fposmod(s.wind_from_deg, 360.0))) % 360
	return canonical(
		{
			"bots": str(bots_count),
			"date": "%04d-%02d-%02d" % [VERSION_YEAR, s.month, s.day],
			"from": str(from),
			"hour": "%.2f" % s.start_hour,
			"lat": "%.5f" % ll.x,
			"lon": "%.5f" % ll.y,
			"seed": str(world_seed),
			"sky": s.sky,
			"temp": "%.1f" % s.temperature_c,
			"v": str(VERSION),
			"wind": "%.1f" % (s.wind_speed_kmh / 3.6),
		}
	)


## Первые 16 hex SHA-256 ключа (строчные).
static func hash_of(key: String) -> String:
	return key.sha256_text().substr(0, 16)


## Строка из словаря ключ → значение: по алфавиту, значения экранированы.
static func canonical(kv: Dictionary) -> String:
	var keys: Array = kv.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k: String in keys:
		parts.append("%s=%s" % [k.uri_encode(), String(kv[k]).uri_encode()])
	return PREFIX + "&".join(parts)


## Разобрать строку ключа в словарь ключ → значение (строки). Префикс не обязателен.
static func split(key: String) -> Dictionary:
	var q := key
	var i := q.find("?")
	if i >= 0:
		q = q.substr(i + 1)
	var out := {}
	for part in q.split("&", false):
		var kv := part.split("=", true, 1)
		out[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
	return out


## Ключ → {settings: FlightSettings, seed: int, bots: int, v: int}. Крыло и масса — из base.
static func parse(key: String, base: FlightSettings = null) -> Dictionary:
	var kv := split(key)
	var s := base.duplicate() if base != null else FlightSettings.defaults()
	var date := String(kv.get("date", "")).split("-")
	if date.size() == 3:
		s.month = int(date[1])
		s.day = int(date[2])
	if kv.has("hour"):
		s.start_hour = float(kv.hour)
	if kv.has("temp"):
		s.temperature_c = float(kv.temp)
	if kv.has("wind"):
		s.wind_speed_kmh = float(kv.wind) * 3.6
	var from := int(kv.get("from", "-1"))
	s.wind_into_launch = from < 0
	if from >= 0:
		s.wind_from_deg = float(from)
	if kv.has("sky"):
		s.sky = String(kv.sky)
	if kv.has("lat") and kv.has("lon"):
		_place(s, float(kv.lat), float(kv.lon))
	return {
		"settings": s,
		"seed": int(kv.get("seed", str(int(Config.value("atmosphere", "seed", 0))))),
		"bots": int(kv.get("bots", "0")),
		"v": int(kv.get("v", str(VERSION))),
	}


## Точка старта (lat, lon): точка с карты или старт встроенной локации (нет стартов — центр).
static func launch_latlon(s: FlightSettings) -> Vector2:
	if s.has_pick():
		return Vector2(s.pick_lat, s.pick_lon)
	var loc: Dictionary = Config.get_config("locations/" + s.location_id)
	var sites: Array = loc.get("start_sites", [])
	for st: Dictionary in sites:
		if String(st.get("id", "")) == s.site_id:
			return Vector2(float(st.lat), float(st.lon))
	if not sites.is_empty():
		return Vector2(float(sites[0].lat), float(sites[0].lon))
	return Vector2(float(loc.get("center_lat", 0.0)), float(loc.get("center_lon", 0.0)))


## Место по точке: внутри встроенной локации — она и ближайший старт, иначе — точка с карты.
static func _place(s: FlightSettings, lat: float, lon: float) -> void:
	for name in Config.list_configs("locations"):
		var loc: Dictionary = Config.get_config(name)
		if not _inside(loc, lat, lon):
			continue
		s.location_id = name.get_file()
		s.pick_lat = NAN
		s.pick_lon = NAN
		s.site_id = ""
		var best := INF
		for st: Dictionary in loc.get("start_sites", []):
			var d := _dist_km(lat, lon, float(st.lat), float(st.lon))
			if d < best:
				best = d
				s.site_id = String(st.id)
		return
	s.pick_lat = lat
	s.pick_lon = lon


## Точка в квадрате детального рельефа локации (первый слой dem, size_km вокруг центра)?
static func _inside(loc: Dictionary, lat: float, lon: float) -> bool:
	var layers: Array = loc.get("dem", {}).get("layers", [])
	if layers.is_empty() or not loc.has("center_lat"):
		return false
	var half := float(layers[0].get("size_km", 0.0)) * 0.5
	var clat := float(loc.center_lat)
	var dy := (lat - clat) * 111.32
	var dx := (lon - float(loc.center_lon)) * 111.32 * cos(deg_to_rad(clat))
	return absf(dx) <= half and absf(dy) <= half


static func _dist_km(lat0: float, lon0: float, lat1: float, lon1: float) -> float:
	var dy := (lat1 - lat0) * 111.32
	var dx := (lon1 - lon0) * 111.32 * cos(deg_to_rad((lat0 + lat1) * 0.5))
	return sqrt(dx * dx + dy * dy)
